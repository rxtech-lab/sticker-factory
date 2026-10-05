import AnimatedView
import SwiftUI
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
    let gridViewController = StickerGridViewController()
    private let legacyBrowserViewController = StickerBrowserViewController()
    /// Holds whichever child is installed, so swapping surfaces never re-derives the chrome's
    /// constraints — the grid's top edge stays pinned below the mode control either way.
    let surfaceContainer = UIView()
    let modeControl = UISegmentedControl(
        items: StickerSendMode.allCases.map(\.label)
    )
    private var modeControlHeight: NSLayoutConstraint?
    let statusContainer = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    let statusLabel = UILabel()
    let activityIndicator = UIActivityIndicatorView(style: .medium)
    let openAppButton = UIButton(type: .system)
    let createButton = UIButton(type: .system)
    /// What the library state last asked for, before the surface on top of it gets a say.
    private var wantsCreateButton = false
    let offlineLabel = UILabel()
    let hintLabel = UILabel()
    private var hintBottom: NSLayoutConstraint?

    /// Stickers | Pet, at the bottom-leading corner of the full-size surface.
    ///
    /// Bottom rather than top, beside the Create button, because the top row already belongs to the
    /// *Stickers* page's own options — the Sticker/Image send mode on the left and the offline badge
    /// on the right — and a phone is not wide enough for a third control there without truncating
    /// one. Stacking a second segmented control under the first would read as two settings for the
    /// same thing. So the bottom row is navigation and actions (where iOS puts tabs anyway), and the
    /// top row is options for whichever page is showing: the send mode simply goes away on the Pet
    /// page, where a tap never sends a sticker.
    let tabControl = UISegmentedControl(items: MessagesTab.allCases.map(\.label))
    /// Holds the Pet page, beside `surfaceContainer` rather than inside it, so switching tabs never
    /// uninstalls the grid — its scroll position and loaded thumbnails survive a look at the pet.
    let petContainer = UIView()
    var petController: UIViewController?
    lazy var petModel: MessagesPetModel = makePetModel()
    var receivedCardController: UIViewController?
    /// A pet card selected in the transcript before the view was on screen, presented once it is.
    private var pendingReceivedCard: PetCardPayload?

    let logger = Logger(subsystem: "app.rxlab.stickerfactory.message", category: "insert")
    private let playbackLogger = Logger(subsystem: "app.rxlab.stickerfactory.message", category: "playback")

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

    var surface: Surface?
    private var library: Library?
    private var loadTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    var creationController: MessagesCreateViewController?
    /// Image sends only — a sticker send resolves nothing and finishes within the tap.
    private var sendTasks: [SendKey: Task<Void, Never>] = [:]
    private var hasConfigurableStickers = false
    private var playbackService: MessagesPlaybackService?
    private let petSends = try? PetSendReporter()
    var controlsController: UIViewController?
    private var controlsLoadTask: Task<Void, Never>?
    /// Set when opening the controls is what expanded the drawer, so closing them puts the host back
    /// the way it was. False when the user was already expanded — collapsing then would take away a
    /// size they chose themselves.
    private var expandedForControls = false
    private let controlSendSession = StickerSendSession()
    /// The artwork a prepare produced, held until it is sent, re-posed, or the sheet closes.
    private var prepared: PreparedSticker?

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

    /// Which page the full-size surface shows, restored from the app group like `sendMode`.
    var selectedTab = MessagesTab.preferred() {
        didSet {
            guard oldValue != selectedTab else { return }
            selectedTab.remember()
        }
    }

    /// True when the Pet page is what is on screen. Creation and the controls sheet each take the
    /// whole surface, and the Stickers drawer has no pet at all, so any of those means "no".
    var showsPetPage: Bool {
        surface == .fullSize && selectedTab == .pet && creationController == nil && controlsController == nil
    }
    var insertionTarget: MSConversation? { activeConversation ?? lastKnownConversation }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        do {
            playbackService = try MessagesPlaybackService()
        } catch {
            playbackLogger.error("playback service init failed error=\(String(describing: error), privacy: .private)")
        }
        configureModeControl()
        configureSurfaceContainer()
        configureStatusView()
        configurePetContainer()
        configureCreateButton()
        configureOfflineBadge()
        configureHintLabel()
        configureTabControl()
        applyPresentationContext()
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        lastKnownConversation = conversation
        // Before the refresh, so the snapshot lands in whichever surface this activation is for.
        applyPresentationContext()
        if creationController == nil { refreshLibrary() }
        if showsPetPage { petModel.reload() }
        // Presented in `didBecomeActive`: a sheet raised before the view is in a window is dropped.
        pendingReceivedCard = presentationContext == .messages
            ? PetCardPayload(url: conversation.selectedMessage?.url)
            : nil
        if pendingReceivedCard != nil, presentationStyle == .compact { requestPresentationStyle(.expanded) }
    }

    override func didBecomeActive(with conversation: MSConversation) {
        super.didBecomeActive(with: conversation)
        lastKnownConversation = conversation
        if creationController == nil, !showsPetPage { gridViewController.resumeAnimations() }
        if let pending = pendingReceivedCard {
            pendingReceivedCard = nil
            presentReceivedCard(pending)
        }
    }

    /// A message tapped in the transcript while the extension is already open.
    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        super.didSelect(message, conversation: conversation)
        lastKnownConversation = conversation
        guard presentationContext == .messages, let payload = PetCardPayload(url: message.url) else { return }
        if presentationStyle == .compact { requestPresentationStyle(.expanded) }
        presentReceivedCard(payload)
    }

    override func didResignActive(with conversation: MSConversation) {
        super.didResignActive(with: conversation)
        loadTask?.cancel()
        hintTask?.cancel()
        // In-flight downloads are abandoned rather than left to finish into a dead conversation.
        for task in sendTasks.values { task.cancel() }
        sendTasks.removeAll()
        creationController?.cancelOutstandingWork()
        gridViewController.suspendAnimations()
        controlsLoadTask?.cancel()
        controlSendSession.cancel()
        if controlsController != nil { closeControls() }
        petModel.cancel()
        pendingReceivedCard = nil
        if receivedCardController != nil { dismissReceivedCard(animated: false) }
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
        if resolved == .sticker {
            creationController?.cancelOutstandingWork()
            creationController = nil
        }
        surface = resolved
        logger.log("surface=\(String(describing: resolved), privacy: .public) context=\(self.presentationContext.rawValue)")
        installChild(for: resolved)
        installLibrary(for: resolved)
        refreshCreateButton()
        hintBottom?.constant = resolved == .fullSize ? -60 : -8
    }

    private func installChild(for surface: Surface) {
        let useLegacy = useLegacyBrowser && surface == .sticker && !hasConfigurableStickers
        let child: UIViewController = useLegacy ? legacyBrowserViewController : gridViewController

        // A drag hands Messages the `MSSticker` behind the thumbnail. That is the entire
        // interaction in the Stickers drawer, and the wrong file only when the full-size surface is
        // sending images — so it follows the send mode there rather than being off outright.
        gridViewController.suppressesPeelDrag = surface == .fullSize && sendMode == .image
        gridViewController.additionalSafeAreaInsets.bottom = surface == .fullSize ? 58 : 0
        gridViewController.onSelect = nil
        gridViewController.onSelectItem = nil
        switch surface {
        case .sticker:
            gridViewController.onSelectItem = { [weak self] itemID in self?.send(itemID) }
        case .fullSize:
            // By item id rather than by sticker, because only one of the two modes sends the
            // `MSSticker` the grid is holding; the other resolves a file it has never seen.
            gridViewController.onSelectItem = { [weak self] itemID in
                self?.send(itemID)
            }
        }

        install(child)
    }

    private func install(_ child: UIViewController) {
        // The Pet page is a sibling of the surface, not one of its occupants.
        for existing in children where existing !== child && existing !== petController {
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
            child.view.bottomAnchor.constraint(equalTo: surfaceContainer.bottomAnchor)
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
            surfaceContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
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
        modeControl.addAction(UIAction { _ in Haptics.selection() }, for: .valueChanged)
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
            modeControlHeight
        ])
    }

    /// Shows or hides the mode control, collapsing its height so the grid closes the gap.
    ///
    /// Never shows in the sticker surface: `insertAttachment` is refused in the media context, so
    /// there is no second option there to offer.
    func setModeControlVisible(_ isVisible: Bool) {
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
        openAppButton.addHapticAction(self, action: #selector(openMainApplicationFromButton))

        view.addSubview(statusContainer)
        NSLayoutConstraint.activate([
            statusContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusContainer.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusContainer.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: statusContainer.contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: statusContainer.contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: statusContainer.contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: statusContainer.contentView.bottomAnchor, constant: -20)
        ])
    }

    /// Creation is available only in the full Messages app. The system Stickers/media surface is
    /// intentionally kept as a pure sticker picker because its host context offers fewer APIs and
    /// can be embedded over the camera or FaceTime.
    private func configureCreateButton() {
        var configuration = UIButton.Configuration.filled()
        configuration.title = String(localized: "Create")
        configuration.image = UIImage(systemName: "wand.and.stars")
        configuration.imagePadding = 6
        configuration.cornerStyle = .capsule
        createButton.configuration = configuration
        createButton.translatesAutoresizingMaskIntoConstraints = false
        createButton.isHidden = true
        createButton.accessibilityIdentifier = "sticker-factory-messages-create-button"
        createButton.addHapticAction(self, action: #selector(showCreation), feedback: .medium)
        view.addSubview(createButton)
        NSLayoutConstraint.activate([
            createButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            createButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            createButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    func setCreateButtonVisible(_ visible: Bool) {
        wantsCreateButton = visible
        refreshCreateButton()
    }

    /// Re-answers the question with the library's last wish and whatever is on screen now.
    ///
    /// Creation and the controls sheet each take the whole surface, so the floating button would
    /// otherwise sit on top of one — over the controls it lands on the Reset row, and tapping it
    /// would abandon a sticker mid-pose. Kept apart from `setCreateButtonVisible` so a child going
    /// up and coming down again gives back exactly what it took, rather than guessing that the
    /// library is in a state that wants the button.
    private func refreshCreateButton() {
        createButton.isHidden = !(
            wantsCreateButton && surface == .fullSize && creationController == nil && controlsController == nil
        )
        applyTab()
    }

    @objc
    private func showCreation() {
        guard surface == .fullSize, creationController == nil else { return }
        do {
            let controller = MessagesCreateViewController(service: try MessagesStickerCreationService())
            controller.onClose = { [weak self] in self?.closeCreation() }
            controller.onReview = { [weak self] stickerID in
                self?.openMainApplication(stickerID: stickerID)
            }
            // Quick mode publishes on the server, so by the time this runs the sticker is live and
            // the only thing missing is a local copy. Refreshing here rather than in the create
            // screen keeps the cache, the grid and the send paths owned by one object.
            controller.onPublished = { [weak self] stickerID in
                await self?.adoptPublishedSticker(stickerID)
            }
            controller.onSend = { [weak self] stickerID in
                self?.send(StickerGridViewController.StickerItemID(
                    sectionID: SharedStickerCache.mineSectionID,
                    stickerID: stickerID
                ))
            }
            creationController = controller
            loadTask?.cancel()
            setModeControlVisible(false)
            setCreateButtonVisible(false)
            statusContainer.isHidden = true
            offlineLabel.isHidden = true
            hintLabel.isHidden = true
            install(controller)
            requestPresentationStyle(.expanded)
        } catch {
            showError(error, offersOpenApp: true)
        }
    }

    /// Pulls a just-published sticker into the local library and hands back its file.
    ///
    /// The refresh is the same one the grid does, so the sticker the create screen shows and the
    /// sticker a tap on the grid would send are the same bytes on disk — and the grid is already
    /// correct by the time someone presses Done.
    ///
    /// `nil` when the sticker did not arrive: the server has published it, but this device could not
    /// download it, and the create screen then falls back to a still preview rather than offering a
    /// Send that would insert nothing.
    private func adoptPublishedSticker(_ stickerID: String) async -> URL? {
        guard let library, let snapshot = try? await library.refresh(onUpdate: { _ in }) else { return nil }
        replaceSections(with: snapshot.sections)
        offlineLabel.isHidden = !snapshot.isOffline
        return snapshot.stickers.first {
            $0.stickerID == stickerID && $0.sectionID == SharedStickerCache.mineSectionID
        }?.fileURL
    }

    private func closeCreation() {
        creationController?.cancelOutstandingWork()
        creationController = nil
        refreshCreateButton()
        guard let surface else { return }
        installChild(for: surface)
        refreshLibrary()
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
            offlineLabel.heightAnchor.constraint(equalToConstant: 24)
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
        // Above the tab/Create row in the full-size surface, so a hint never covers the controls
        // it might be telling someone to use; `applyPresentationContext` sets the constant.
        let hintBottom = hintLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        self.hintBottom = hintBottom
        NSLayoutConstraint.activate([
            hintBottom,
            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            hintLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
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
        if gridViewController.stickerCount == 0 { showLoading() }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await library.refresh { [weak self] snapshot in
                    guard !Task.isCancelled else { return }
                    await self?.apply(snapshot)
                }
                guard !Task.isCancelled else { return }
                apply(snapshot)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                replaceSections(with: [])
                showError(error, offersOpenApp: true)
            }
        }
    }

    private func apply(_ snapshot: MessagesLibrarySnapshot) {
        guard !Task.isCancelled else { return }
        replaceSections(with: snapshot.sections, reconcilePlayback: !snapshot.isRefreshing)
        offlineLabel.isHidden = !snapshot.isOffline
        setCreateButtonVisible(true)
        if snapshot.stickers.isEmpty {
            if snapshot.isRefreshing {
                showLoading()
            } else {
                showEmptyLibrary(hasInstalledPacks: snapshot.sections.contains { $0.id != SharedStickerCache.mineSectionID })
            }
        } else {
            statusContainer.isHidden = true
            activityIndicator.stopAnimating()
            setModeControlVisible(true)
        }
    }

    private func replaceSections(with sections: [StickerSection], reconcilePlayback: Bool = true) {
        hasConfigurableStickers = sections.flatMap(\.stickers).contains { $0.playbackRevisionID != nil }
        if reconcilePlayback, let playbackService { Task { await playbackService.reconcile(sections) } }
        if legacyBrowserViewController.parent === self && !hasConfigurableStickers {
            // MSStickerBrowserView cannot render sections, so the legacy path flattens them —
            // "My Stickers" first, then each pack in order. Grouping is silently lost there.
            legacyBrowserViewController.replaceStickers(with: sections.flatMap(\.stickers))
        } else {
            if controlsController == nil, gridViewController.parent !== self { install(gridViewController) }
            gridViewController.replaceSections(with: sections)
        }
    }

    // MARK: - Insertion (sticker surface)

    private func insertSticker(_ sticker: MSSticker, stickerID: String?) {
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
                    self.insertAsAttachment(fileURL: fileURL, filename: filename, stickerID: stickerID)
                } else {
                    self.applyInsertOutcome(outcome, stickerID: stickerID)
                }
            }
        }
    }

    private func insertAsAttachment(fileURL: URL, filename: String, stickerID: String?) {
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
                self.applyInsertOutcome(outcome, stickerID: stickerID)
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
        if let item = gridViewController.cachedItem(for: itemID), let revisionID = item.playbackRevisionID {
            openControls(itemID: itemID, item: item, revisionID: revisionID)
            return
        }
        if surface == .sticker || sendMode == .sticker {
            guard let sticker = gridViewController.sticker(for: itemID) else { return }
            insertSticker(sticker, stickerID: itemID.stickerID)
            return
        }
        sendImage(itemID)
    }

    private func openControls(itemID: StickerGridViewController.StickerItemID, item: CachedSticker, revisionID: String) {
        guard controlsController == nil, controlsLoadTask == nil, let service = playbackService else {
            playbackLogger.error("""
                controls unavailable sticker=\(item.stickerID, privacy: .private) serviceReady=\(self.playbackService != nil) \
                sheetOpen=\(self.controlsController != nil) loading=\(self.controlsLoadTask != nil)
                """)
            return
        }
        playbackLogger.info("controls opening sticker=\(item.stickerID, privacy: .private) revision=\(revisionID, privacy: .private)")
        gridViewController.setBusy(true, for: itemID)
        // A compact drawer is a single row of thumbnails: a mood picker, a pose picker, a speed
        // slider and a preview cannot be operated in it, and the sheet would open somewhere the user
        // cannot reach. Requested before the bundle loads rather than after, so the expansion
        // animates while the artwork downloads instead of jolting the drawer once it lands.
        //
        // This is the opposite of the collapse in `applyInsertOutcome` and not in tension with it:
        // that one ends an errand the user finished, while this one opens a screen they have to use.
        // It applies in the Stickers drawer too — Apple's chrome owns the *browsing* surface, but a
        // sheet nobody can operate is not a browsing surface.
        if presentationStyle == .compact {
            expandedForControls = true
            requestPresentationStyle(.expanded)
        }
        controlsLoadTask = Task { [weak self] in
            defer {
                self?.controlsLoadTask = nil
                self?.gridViewController.setBusy(false, for: itemID)
                // The artwork never arrived, or the conversation went away: nothing was installed, so
                // the expansion above has nothing to show and is given back.
                if self?.controlsController == nil { self?.restoreCompactAfterControls() }
            }
            do {
                let (account, bundle) = try await service.bundle(stickerID: item.stickerID, revisionID: revisionID)
                try Task.checkCancellation()
                guard let self, self.insertionTarget != nil else { return }
                let image = self.surface == .fullSize && self.sendMode == .image
                let sheet = StickerControlsSheet(document: bundle.document, stickerID: item.stickerID, accountID: account,
                    // A full-size image has nothing to peel — `MSSticker` is the ≤500 KB artwork and
                    // an attachment is not one — so that mode keeps sending in a single step.
                    actionTitle: image ? String(localized: "Send Image") : String(localized: "Prepare"),
                    loadAssets: { documents in try await service.loadAssets(bundle: bundle, documents: documents, accountID: account) },
                    onApply: { [weak self] settings, document, assets in
                        guard let self else { throw CancellationError() }
                        try await self.controlSendSession.perform(
                            prepare: {
                                try await PreparedSticker.renderedFile(
                                    service: service, account: account, bundle: bundle, document: document,
                                    settings: settings, assets: assets, image: image
                                )
                            },
                            validate: {
                                guard account == (try await service.accountID()), self.insertionTarget != nil else {
                                    throw CancellationError()
                                }
                            },
                            // In image mode this is still the send. In sticker mode it is the end of
                            // preparing: the file is kept, and what happens to it is the reader's
                            // next choice — dragged onto a bubble, or sent.
                            insert: { file in
                                let fileURL = file.url
                                guard !image else {
                                    try await self.insertRendered(fileURL, title: item.title, stickerID: item.stickerID, image: true)
                                    return
                                }
                                self.prepared = try .init(fileURL: fileURL, title: item.title, firstAnimationOnly: file.firstAnimationOnly)
                                self.collapseForPreparedSticker()
                            }
                        )
                    }, onClose: { [weak self] in self?.closeControls() },
                    preparedSending: image ? nil : .init(
                        preview: { [weak self] in
                            guard let sticker = self?.prepared?.sticker else { return AnyView(EmptyView()) }
                            return AnyView(PreparedStickerView(sticker: sticker))
                        },
                        notice: { [weak self] in
                            guard self?.prepared?.firstAnimationOnly == true else { return nil }
                            return String(localized: """
                                Only the first animation fits as an iMessage sticker. \
                                The full combination is still saved.
                                """)
                        },
                        send: { [weak self] in
                            guard let self, let prepared = self.prepared else { throw CancellationError() }
                            try await self.insertRendered(prepared.fileURL, title: prepared.title, stickerID: item.stickerID, image: false)
                            // The errand is finished, so the drawer stops covering the conversation
                            // the sticker just landed in — the same courtesy `applyInsertOutcome`
                            // pays an ordinary send.
                            self.requestPresentationStyle(.compact)
                        }
                    ))
                let controller = UIHostingController(rootView: sheet)
                self.controlsController = controller
                self.refreshCreateButton()
                self.install(controller)
            } catch is CancellationError {} catch {
                self?.playbackLogger.error(
                    """
                    controls open failed sticker=\(item.stickerID, privacy: .private) revision=\(revisionID, privacy: .private) \
                    error=\(String(describing: error), privacy: .private)
                    """
                )
                self?.showHint(error.localizedDescription)
            }
        }
    }

    /// Hands the rendered file to the conversation: an attachment in image mode, an `MSSticker`
    /// otherwise. The conversation is read again here rather than captured — the send session
    /// validated it a moment ago, but an extension can lose it between the two.
    private func insertRendered(_ fileURL: URL, title: String, stickerID: String, image: Bool) async throws {
        guard let conversation = insertionTarget else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion: (Error?) -> Void = { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            guard !image else {
                conversation.insertAttachment(fileURL, withAlternateFilename: title + ".png", completionHandler: completion)
                return
            }
            do {
                let sticker = try MSSticker(contentsOfFileURL: fileURL, localizedDescription: title)
                conversation.insert(sticker, completionHandler: completion)
            } catch {
                continuation.resume(throwing: error)
            }
        }
        reportPetSend(stickerID)
    }

    private func closeControls() {
        controlSendSession.cancel()
        controlsController = nil
        prepared = nil
        refreshCreateButton()
        if let surface { installChild(for: surface) }
        restoreCompactAfterControls()
    }

    /// A prepared sticker is peeled and dropped onto a bubble, and there is no bubble on screen
    /// while the drawer is expanded.
    ///
    /// Unconditional, unlike `restoreCompactAfterControls()`: that one returns a loan, and this one
    /// is what makes the prepared state usable at all, so it applies whether this controller took
    /// the expansion or the user did. The flag is cleared alongside, or the later restore would try
    /// to give back an expansion that is already gone.
    private func collapseForPreparedSticker() {
        expandedForControls = false
        if presentationStyle == .expanded { requestPresentationStyle(.compact) }
    }

    /// Gives back only what opening the controls took: the drawer collapses if this controller was
    /// the one that expanded it, and is left alone if the user had already expanded it themselves or
    /// if a completed send has collapsed it already.
    private func restoreCompactAfterControls() {
        guard expandedForControls else { return }
        expandedForControls = false
        if presentationStyle == .expanded { requestPresentationStyle(.compact) }
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
                insert(attachment, stickerID: itemID.stickerID)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                showHint(Self.message(for: error))
            }
        }
    }

    private func insert(_ attachment: ResolvedAttachment, stickerID: String) {
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
                    self.reportPetSend(stickerID)
                    self.showHint(notice)
                } else {
                    self.applyInsertOutcome(outcome, stickerID: stickerID)
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

    /// Every path that puts one of the user's stickers into the conversation ends here, so the pet
    /// hears about it once per send. Fire-and-forget: see `PetSendReporter`.
    private func reportPetSend(_ stickerID: String) {
        guard let petSends else { return }
        Task { await petSends.report(stickerID: stickerID) }
    }

    private func applyInsertOutcome(_ outcome: StickerInsertOutcome, stickerID: String? = nil) {
        if outcome == .inserted, let stickerID { reportPetSend(stickerID) }
        // A sticker that landed is the end of the errand: collapse so the conversation — and the
        // sticker now staged in its input field — is what the user is looking at.
        //
        // The app drawer only. In the system Stickers drawer the host owns the presentation, and a
        // sticker there is picked from a browsing surface someone is usually sending more than one
        // thing from; taking that over would be this extension overruling Apple's own chrome.
        if outcome == .inserted, surface == .fullSize {
            requestPresentationStyle(.compact)
        }
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
}
