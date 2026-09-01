import ImageIO
import Messages
import UIKit
import os

/// The app's single Messages extension, and the only one iOS permits: a host app may embed exactly
/// one `com.apple.message-payload-provider`, so "a sticker pack" and "an iMessage app" cannot be
/// two targets. They are two behaviours of this one controller, chosen by `presentationContext`.
///
/// - `.media` — the system Stickers drawer, and any other app that offers a sticker picker. Behaves
///   as a sticker pack: Apple's peel/drag stays live and a tap calls
///   `MSConversation.insert(_ sticker:)`, the one sticker API without a media-context restriction.
/// - `.messages` — the app drawer inside Messages. Offers both: a control chooses whether a tap
///   sends the `MSSticker` (as above) or the full-resolution rendition through `insertAttachment`,
///   which carries no 500 KB / square / 300-408-618 px ceiling because it never builds one.
///
/// `Info.plist` declares both in `MSSupportedPresentationContexts`. Dropping
/// `MSMessagesAppPresentationContextMedia` is exactly what would take this out of the Stickers
/// drawer and out of other apps, so the two keys are load-bearing rather than boilerplate.
@MainActor
final class MessagesViewController: MSMessagesAppViewController {
    /// Which of the two behaviours the host asked for.
    private enum Surface {
        case sticker
        case fullSize

        init(_ context: MSMessagesAppPresentationContext) {
            self = context == .media ? .sticker : .fullSize
        }

        /// The recovery advice differs per surface, and wrongly telling someone in the full-size
        /// surface to peel and drag would send the small file they came here to avoid.
        var insertSurface: StickerInsertPolicy.StickerInsertSurface {
            switch self {
            case .sticker: .sticker
            case .fullSize: .fullSize
            }
        }
    }

    /// Both surfaces refresh the same listing; only the full-size one also resolves attachments,
    /// so the second (much larger) cache is never constructed for the Stickers drawer.
    private enum Library: Sendable {
        case sticker(MessagesLibraryService)
        case fullSize(FullSizeStickerLibraryService)

        func refresh() async throws -> MessagesLibrarySnapshot {
            switch self {
            case .sticker(let service): try await service.refresh()
            case .fullSize(let service): try await service.refresh()
            }
        }

        var fullSize: FullSizeStickerLibraryService? {
            guard case .fullSize(let service) = self else { return nil }
            return service
        }
    }

    private let gridViewController = StickerGridViewController()
    private let legacyBrowserViewController = StickerBrowserViewController()
    /// Holds whichever child is installed, so swapping surfaces never re-derives the chrome's
    /// constraints — the grid's top edge stays pinned below the mode control either way.
    private let surfaceContainer = UIView()
    private let modeControl = UISegmentedControl(
        items: StickerSendMode.allCases.map(\.label)
    )
    private var modeControlHeight: NSLayoutConstraint?
    private let statusContainer = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let statusLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let openAppButton = UIButton(type: .system)
    private let offlineLabel = UILabel()
    private let hintLabel = UILabel()

    private let logger = Logger(subsystem: "app.rxlab.stickerfactory.message", category: "insert")

    /// Escape hatch for on-device A/B against the stock browser without a rebuild:
    /// `defaults write group.app.rxlab.stickerfactory StickerFactoryUseLegacyBrowser -bool YES`
    ///
    /// `MSStickerBrowserView` has no concept of sections, so this path shows every sticker in one
    /// flat list — the pack a sticker came from is not visible. Kept only as a fallback if the
    /// sectioned grid misbehaves on device; retire it once that has shipped. Honoured in the
    /// sticker surface only: it has no mode control, so a tap there could never mean anything but
    /// the `MSSticker`.
    private let useLegacyBrowser = UserDefaults(suiteName: SharedAuthConfiguration.appGroupIdentifier)?
        .bool(forKey: "StickerFactoryUseLegacyBrowser") ?? false

    private var surface: Surface?
    private var library: Library?
    private var loadTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    /// Image sends only — a sticker send resolves nothing and finishes within the tap.
    private var sendTasks: [SendKey: Task<Void, Never>] = [:]
    private var insertGate = StickerInsertGate()

    private struct SendKey: Hashable {
        let itemID: StickerGridViewController.StickerItemID
    }

    /// What a tap in the full-size surface sends, restored from the app group so it survives the
    /// drawer closing.
    ///
    /// Also decides whether Apple's peel/drag stays live: in sticker mode a drag inserts the same
    /// `MSSticker` the tap would, so suppressing it would remove a gesture for no reason.
    private var sendMode = StickerSendMode.preferred() {
        didSet {
            guard oldValue != sendMode else { return }
            sendMode.remember()
            gridViewController.suppressesPeelDrag = sendMode == .image
        }
    }

    /// `activeConversation` can lag on the first activation in non-Messages hosts, while the
    /// conversation handed to `willBecomeActive(with:)` is guaranteed valid for that activation.
    private var lastKnownConversation: MSConversation?
    private var insertionTarget: MSConversation? { activeConversation ?? lastKnownConversation }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureModeControl()
        configureSurfaceContainer()
        configureStatusView()
        configureOfflineBadge()
        configureHintLabel()
        applyPresentationContext()
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        lastKnownConversation = conversation
        // Before the refresh, so the snapshot lands in whichever surface this activation is for.
        applyPresentationContext()
        refreshLibrary()
    }

    override func didBecomeActive(with conversation: MSConversation) {
        super.didBecomeActive(with: conversation)
        lastKnownConversation = conversation
        gridViewController.resumeAnimations()
    }

    override func didResignActive(with conversation: MSConversation) {
        super.didResignActive(with: conversation)
        loadTask?.cancel()
        hintTask?.cancel()
        // In-flight downloads are abandoned rather than left to finish into a dead conversation.
        for task in sendTasks.values { task.cancel() }
        sendTasks.removeAll()
        gridViewController.suspendAnimations()
        lastKnownConversation = nil
    }

    // MARK: - Surface selection

    /// Picks the surface for the context the host actually presented us in.
    ///
    /// Called from `viewDidLoad` and again from `willBecomeActive(with:)`. The second call is the
    /// one that matters: an activation is the first moment `presentationContext` is certainly
    /// settled, and building the sticker surface for a Messages presentation would silently cap
    /// every send at 500 KB.
    private func applyPresentationContext() {
        let resolved = Surface(presentationContext)
        guard resolved != surface else { return }
        surface = resolved
        logger.log("surface=\(String(describing: resolved), privacy: .public) context=\(self.presentationContext.rawValue)")
        installChild(for: resolved)
        installLibrary(for: resolved)
    }

    private func installChild(for surface: Surface) {
        let useLegacy = useLegacyBrowser && surface == .sticker
        let child: UIViewController = useLegacy ? legacyBrowserViewController : gridViewController

        // A drag hands Messages the `MSSticker` behind the thumbnail. That is the entire
        // interaction in the Stickers drawer, and the wrong file only when the full-size surface is
        // sending images — so it follows the send mode there rather than being off outright.
        gridViewController.suppressesPeelDrag = surface == .fullSize && sendMode == .image
        gridViewController.onSelect = nil
        gridViewController.onSelectItem = nil
        switch surface {
        case .sticker:
            gridViewController.onSelect = { [weak self] sticker in
                self?.insertSticker(sticker)
            }
        case .fullSize:
            // By item id rather than by sticker, because only one of the two modes sends the
            // `MSSticker` the grid is holding; the other resolves a file it has never seen.
            gridViewController.onSelectItem = { [weak self] itemID in
                self?.send(itemID)
            }
        }

        for existing in children where existing !== child {
            existing.willMove(toParent: nil)
            existing.view.removeFromSuperview()
            existing.removeFromParent()
        }
        guard child.parent !== self else { return }

        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        surfaceContainer.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: surfaceContainer.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: surfaceContainer.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: surfaceContainer.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: surfaceContainer.bottomAnchor),
        ])
        child.didMove(toParent: self)
    }

    private func installLibrary(for surface: Surface) {
        do {
            switch surface {
            case .sticker:
                library = .sticker(try MessagesLibraryService())
            case .fullSize:
                library = .fullSize(try FullSizeStickerLibraryService())
            }
            showLoading()
        } catch {
            library = nil
            showError(error, offersOpenApp: true)
        }
    }

    // MARK: - Chrome

    private func configureSurfaceContainer() {
        surfaceContainer.translatesAutoresizingMaskIntoConstraints = false
        surfaceContainer.backgroundColor = .clear
        view.addSubview(surfaceContainer)
        NSLayoutConstraint.activate([
            surfaceContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surfaceContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surfaceContainer.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 6),
            surfaceContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// One control for the whole grid rather than a choice per sticker: whether someone wants a
    /// sticker or an image is a property of the conversation they are in, not of the sticker they
    /// are picking, and a per-sticker menu would put a second gesture on top of the one tap this
    /// surface has.
    private func configureModeControl() {
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.selectedSegmentIndex = StickerSendMode.allCases
            .firstIndex(of: sendMode) ?? 0
        modeControl.accessibilityIdentifier = "sticker-factory-send-mode-picker"
        modeControl.accessibilityLabel = String(localized: "Send as")
        // The drawer's backdrop is black and `view.backgroundColor` is clear, so a default
        // segmented control is dark-grey-on-black — present, and very easy to look straight past.
        // These give it an edge against the backdrop rather than restyling it.
        modeControl.backgroundColor = .secondarySystemBackground
        modeControl.selectedSegmentTintColor = .systemBlue
        modeControl.setTitleTextAttributes([.foregroundColor: UIColor.label], for: .normal)
        modeControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        modeControl.addTarget(self, action: #selector(modeControlChanged), for: .valueChanged)
        modeControl.isHidden = true
        view.addSubview(modeControl)

        // The control's own height, collapsed to zero while it is hidden. `isHidden` removes a view
        // from the screen but not from Auto Layout, so without this the grid keeps a control-sized
        // gap above it — in the sticker surface, which never shows the control at all, that gap
        // would be permanent.
        let modeControlHeight = modeControl.heightAnchor.constraint(equalToConstant: 0)
        self.modeControlHeight = modeControlHeight
        NSLayoutConstraint.activate([
            modeControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            modeControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            // Short of the trailing edge, where the offline badge sits.
            modeControl.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -124),
            modeControlHeight,
        ])
    }

    /// Shows or hides the mode control, collapsing its height so the grid closes the gap.
    ///
    /// Never shows in the sticker surface: `insertAttachment` is refused in the media context, so
    /// there is no second option there to offer.
    private func setModeControlVisible(_ isVisible: Bool) {
        let shows = isVisible && surface == .fullSize
        modeControl.isHidden = !shows
        modeControlHeight?.constant = shows ? modeControl.intrinsicContentSize.height : 0
    }

    @objc
    private func modeControlChanged() {
        let cases = StickerSendMode.allCases
        guard cases.indices.contains(modeControl.selectedSegmentIndex) else { return }
        sendMode = cases[modeControl.selectedSegmentIndex]
        logger.log("modeControl selected=\(self.sendMode.rawValue, privacy: .public)")
    }

    private func configureStatusView() {
        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.layer.cornerRadius = 24
        statusContainer.clipsToBounds = true
        statusContainer.accessibilityIdentifier = "sticker-factory-messages-status"

        let stack = UIStackView(arrangedSubviews: [activityIndicator, statusLabel, openAppButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.contentView.addSubview(stack)

        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .label
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.adjustsFontForContentSizeCategory = true

        var buttonConfiguration = UIButton.Configuration.filled()
        buttonConfiguration.title = String(localized: "Open Sticker Factory")
        buttonConfiguration.cornerStyle = .capsule
        openAppButton.configuration = buttonConfiguration
        openAppButton.accessibilityIdentifier = "open-sticker-factory"
        openAppButton.addTarget(self, action: #selector(openMainApplication), for: .touchUpInside)

        view.addSubview(statusContainer)
        NSLayoutConstraint.activate([
            statusContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusContainer.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusContainer.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: statusContainer.contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: statusContainer.contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: statusContainer.contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: statusContainer.contentView.bottomAnchor, constant: -20),
        ])
    }

    // The badge sits opposite the size control, which is why that control stops short of the
    // trailing edge.
    private func configureOfflineBadge() {
        offlineLabel.translatesAutoresizingMaskIntoConstraints = false
        offlineLabel.text = String(localized: "Offline · cached")
        offlineLabel.font = .preferredFont(forTextStyle: .caption1)
        offlineLabel.textColor = .secondaryLabel
        offlineLabel.backgroundColor = .secondarySystemBackground.withAlphaComponent(0.85)
        offlineLabel.layer.cornerRadius = 10
        offlineLabel.clipsToBounds = true
        offlineLabel.textAlignment = .center
        offlineLabel.isHidden = true
        offlineLabel.accessibilityIdentifier = "sticker-factory-offline-badge"
        view.addSubview(offlineLabel)
        NSLayoutConstraint.activate([
            offlineLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            offlineLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            offlineLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 104),
            offlineLabel.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    /// Hosts that reject a programmatic insert still accept Apple's peel/drag, so a failed tap
    /// tells the user what to do instead of doing nothing.
    private func configureHintLabel() {
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .preferredFont(forTextStyle: .caption1)
        hintLabel.adjustsFontForContentSizeCategory = true
        hintLabel.textColor = .secondaryLabel
        hintLabel.backgroundColor = .secondarySystemBackground.withAlphaComponent(0.85)
        hintLabel.layer.cornerRadius = 10
        hintLabel.clipsToBounds = true
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2
        hintLabel.isHidden = true
        hintLabel.accessibilityIdentifier = "sticker-factory-drag-hint"
        view.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            hintLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
    }

    /// Where the size control actually landed, once per layout pass.
    ///
    /// It is anchored to `safeAreaLayoutGuide.topAnchor`, and whether Messages insets that guide for
    /// its own grabber is not something a build can prove — the simulator cannot host this extension
    /// and `xcodebuild` never lays it out. So the frame is logged instead of assumed: a control that
    /// is present, unhidden and sized, but sitting at a `y` inside Messages' header, is a very
    /// different bug from one that was never shown.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard surface == .fullSize else { return }
        let frame = modeControl.frame
        logger.log(
            """
            modeControl hidden=\(self.modeControl.isHidden) \
            frame=\(frame.debugDescription, privacy: .public) \
            safeAreaTop=\(self.view.safeAreaInsets.top) \
            style=\(self.presentationStyle.rawValue) \
            surfaceTop=\(self.surfaceContainer.frame.minY)
            """
        )
    }

    // MARK: - Library

    private func refreshLibrary() {
        guard let library else { return }
        loadTask?.cancel()
        showLoading()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await library.refresh()
                guard !Task.isCancelled else { return }
                replaceSections(with: snapshot.sections)
                offlineLabel.isHidden = !snapshot.isOffline
                if snapshot.stickers.isEmpty {
                    showEmptyLibrary(
                        hasInstalledPacks: snapshot.sections.contains { $0.id != SharedStickerCache.mineSectionID }
                    )
                } else {
                    statusContainer.isHidden = true
                    // Only once there is a grid to size. Offering the control over an empty
                    // library, or over a sign-in prompt, is a setting for nothing.
                    setModeControlVisible(true)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                showError(error, offersOpenApp: true)
            }
        }
    }

    private func replaceSections(with sections: [StickerSection]) {
        if legacyBrowserViewController.parent === self {
            // MSStickerBrowserView cannot render sections, so the legacy path flattens them —
            // "My Stickers" first, then each pack in order. Grouping is silently lost there.
            legacyBrowserViewController.replaceStickers(with: sections.flatMap(\.stickers))
        } else {
            gridViewController.replaceSections(with: sections)
        }
    }

    // MARK: - Insertion (sticker surface)

    private func insertSticker(_ sticker: MSSticker) {
        guard let conversation = insertionTarget else {
            logger.error("insert skipped: no conversation (context=\(self.presentationContext.rawValue))")
            applyInsertOutcome(.noConversation)
            return
        }
        // MSSticker and MSConversation are not Sendable, so the retry carries only these
        // scalars across the actor hop and re-resolves the conversation on the main actor.
        let fileURL = sticker.imageFileURL
        let filename = sticker.localizedDescription
        guard insertGate.shouldInsert(
            stickerURL: fileURL,
            uptime: ProcessInfo.processInfo.systemUptime
        ) else {
            logger.debug("insert skipped: duplicate tap for \(fileURL.lastPathComponent, privacy: .private)")
            return
        }

        conversation.insert(sticker) { [weak self] error in
            // The imported completion handler is a plain, non-Sendable ObjC block and
            // `any Error` is not Sendable, so reduce to scalars before the actor hop.
            let nsError = error as NSError?
            let domain = nsError?.domain
            let code = nsError?.code
            Task { @MainActor in
                guard let self else { return }
                let outcome = StickerInsertPolicy.outcome(domain: domain, code: code)
                self.log(outcome: outcome, domain: domain, code: code, api: "insertSticker")
                if outcome == .unavailableInContext {
                    // insertAttachment is permitted in the media context for image types
                    // supported by MSSticker, which every cached rendition is.
                    self.insertAsAttachment(fileURL: fileURL, filename: filename)
                } else {
                    self.applyInsertOutcome(outcome)
                }
            }
        }
    }

    private func insertAsAttachment(fileURL: URL, filename: String) {
        guard let conversation = insertionTarget else {
            applyInsertOutcome(.noConversation)
            return
        }
        conversation.insertAttachment(
            fileURL,
            withAlternateFilename: filename
        ) { [weak self] error in
            let nsError = error as NSError?
            let domain = nsError?.domain
            let code = nsError?.code
            Task { @MainActor in
                guard let self else { return }
                let outcome = StickerInsertPolicy.outcome(domain: domain, code: code)
                self.log(outcome: outcome, domain: domain, code: code, api: "insertAttachment")
                self.applyInsertOutcome(outcome)
            }
        }
    }

    // MARK: - Sending (full-size surface)

    /// Routes one tap to whichever of the two sends the mode control is on.
    ///
    /// Sticker mode is the Stickers drawer's own path, unchanged: the `MSSticker` the grid is
    /// already holding, straight into `insert(_ sticker:)`. It needs no download and no task, which
    /// is why it returns before any of the machinery below.
    private func send(_ itemID: StickerGridViewController.StickerItemID) {
        if sendMode == .sticker {
            guard let sticker = gridViewController.sticker(for: itemID) else { return }
            insertSticker(sticker)
            return
        }
        sendImage(itemID)
    }

    /// Two gates, because they guard different things.
    ///
    /// `sendTasks` covers the download, which routinely outlives `StickerInsertGate`'s 0.6 s
    /// window — without it a second tap would start a second download of the same file.
    /// `insertGate` then covers the insert itself, exactly as it does in the sticker surface.
    private func sendImage(_ itemID: StickerGridViewController.StickerItemID) {
        let sendKey = SendKey(itemID: itemID)
        guard sendTasks[sendKey] == nil, let libraryService = library?.fullSize else { return }
        let key = CacheKey(sectionID: itemID.sectionID, stickerID: itemID.stickerID)

        gridViewController.setBusy(true, for: itemID)
        sendTasks[sendKey] = Task { [weak self] in
            defer {
                self?.sendTasks[sendKey] = nil
                self?.gridViewController.setBusy(false, for: itemID)
            }
            do {
                let attachment = try await libraryService.attachment(for: key)
                guard let self, !Task.isCancelled else { return }
                // Read off the file, not off the descriptor: this reports the bytes that actually
                // went out, which is what separates a resolver problem from a rendering one.
                logger.log(
                    """
                    resolve fullSize=\(attachment.isFullSize) \
                    \(Self.fileFacts(attachment.fileURL), privacy: .public)
                    """
                )
                guard insertGate.shouldInsert(
                    stickerURL: attachment.fileURL,
                    uptime: ProcessInfo.processInfo.systemUptime
                ) else {
                    logger.debug("insert skipped: duplicate tap")
                    return
                }
                insert(attachment)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                showHint(Self.message(for: error))
            }
        }
    }

    private func insert(_ attachment: ResolvedAttachment) {
        guard let conversation = insertionTarget else {
            logger.error("insert skipped: no conversation (context=\(self.presentationContext.rawValue))")
            applyInsertOutcome(.noConversation)
            return
        }
        conversation.insertAttachment(
            attachment.fileURL,
            withAlternateFilename: Self.filename(for: attachment)
        ) { [weak self] error in
            // The imported completion handler is a plain, non-Sendable ObjC block and
            // `any Error` is not Sendable, so reduce to scalars before the actor hop.
            let nsError = error as NSError?
            let domain = nsError?.domain
            let code = nsError?.code
            Task { @MainActor in
                guard let self else { return }
                let outcome = StickerInsertPolicy.outcome(domain: domain, code: code)
                self.logger.log(
                    """
                    insertAttachment outcome=\(String(describing: outcome), privacy: .public) \
                    fullSize=\(attachment.isFullSize) \
                    context=\(self.presentationContext.rawValue) \
                    \(Self.fileFacts(attachment.fileURL), privacy: .public) \
                    domain=\(domain ?? "-", privacy: .public) code=\(code ?? 0)
                    """
                )
                // A send that worked but from the ≤500 KB file is still a send, so it must not read
                // as a failure — but it does need saying, or the image looks needlessly soft.
                if outcome == .inserted, let notice = Self.substitutionNotice(for: attachment) {
                    self.showHint(notice)
                } else {
                    self.applyInsertOutcome(outcome)
                }
            }
        }
    }

    /// Pixel dimensions, byte count and filename of a rendition, read from disk.
    ///
    /// `CGImageSourceCopyPropertiesAtIndex` reads the header only, so this never decodes the image
    /// — cheap enough to run on every send inside an extension's memory budget. For an APNG the
    /// frame count comes along too, since a rendition that lost frames to fit is worth seeing.
    private static func fileFacts(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return "px=unreadable bytes=\(bytes) file=\(url.lastPathComponent)"
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? -1
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? -1
        let frames = CGImageSourceGetCount(source)
        return "px=\(width)x\(height) frames=\(frames) bytes=\(bytes) file=\(url.lastPathComponent)"
    }

    /// Why the image that went out is not the full-resolution one, or `nil` when it is.
    ///
    /// The sticker has no rendition beyond the ≤500 KB Messages file, so that file is what an image
    /// send attaches. It arrives as an image either way; it is simply softer than it would be after
    /// a republish.
    private static func substitutionNotice(for attachment: ResolvedAttachment) -> String? {
        guard !attachment.isFullSize else { return nil }
        return String(localized: "This sticker has no full-size copy yet. Republish it for a sharper image.")
    }

    /// Messages shows this to the recipient, so it carries the sticker's name and, importantly,
    /// the real extension — `insertAttachment` infers the type from it.
    private static func filename(for attachment: ResolvedAttachment) -> String {
        let sanitized = attachment.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = sanitized.isEmpty ? String(localized: "Sticker") : String(sanitized.prefix(150))
        let ext = attachment.fileURL.pathExtension
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private static func message(for error: Error) -> String {
        if error is URLError { return String(localized: "Full-size images need a connection.") }
        return (error as? LocalizedError)?.errorDescription
            ?? String(localized: "That image couldn't be sent. Try again.")
    }

    // MARK: - Outcome reporting

    private func applyInsertOutcome(_ outcome: StickerInsertOutcome) {
        guard let text = StickerInsertPolicy.hint(
            for: outcome,
            context: presentationContext,
            surface: (surface ?? .sticker).insertSurface
        ) else {
            hintTask?.cancel()
            hintLabel.isHidden = true
            return
        }
        showHint(text)
    }

    private func log(outcome: StickerInsertOutcome, domain: String?, code: Int?, api: String) {
        logger.log(
            """
            \(api, privacy: .public) outcome=\(String(describing: outcome), privacy: .public) \
            context=\(self.presentationContext.rawValue) \
            domain=\(domain ?? "-", privacy: .public) code=\(code ?? 0)
            """
        )
    }

    private func showHint(_ text: String) {
        hintTask?.cancel()
        hintLabel.text = "  \(text)  "
        hintLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: text)
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hintLabel.isHidden = true
        }
    }

    // MARK: - Status

    private func showLoading() {
        statusContainer.isHidden = false
        setModeControlVisible(false)
        statusLabel.text = String(localized: "Refreshing your stickers…")
        activityIndicator.startAnimating()
        openAppButton.isHidden = true
        offlineLabel.isHidden = true
    }

    private func showEmptyLibrary(hasInstalledPacks: Bool = false) {
        statusContainer.isHidden = false
        setModeControlVisible(false)
        // Telling someone to publish a sticker is unhelpful when they added packs and it is the
        // packs that are currently empty.
        statusLabel.text = hasInstalledPacks
            ? String(localized: "The packs you added have nothing published right now. Open Sticker Factory to add more.")
            : String(localized: "Create and publish a sticker in Sticker Factory, then return here.")
        activityIndicator.stopAnimating()
        openAppButton.isHidden = false
        offlineLabel.isHidden = true
    }

    private func showError(_ error: Error, offersOpenApp: Bool) {
        statusContainer.isHidden = false
        setModeControlVisible(false)
        statusLabel.text = (error as? LocalizedError)?.errorDescription
            ?? String(localized: "Your sticker library is unavailable.")
        activityIndicator.stopAnimating()
        openAppButton.isHidden = !offersOpenApp
        offlineLabel.isHidden = true
    }

    @objc
    private func openMainApplication() {
        let source = surface == .fullSize ? "fullsize" : "messages"
        guard let url = URL(string: "stickerfactory://open?source=\(source)") else { return }
        extensionContext?.open(url) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in
                guard let self else { return }
                self.logger.error("extensionContext.open refused (context=\(self.presentationContext.rawValue))")
                self.statusLabel.text = String(localized: "Open Sticker Factory from the Home Screen and sign in.")
            }
        }
    }
}
