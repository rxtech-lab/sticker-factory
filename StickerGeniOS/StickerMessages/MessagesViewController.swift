import Messages
import UIKit
import os

/// The Messages root stays an `MSMessagesAppViewController` so Apple can deliver
/// conversation and activation callbacks. Its child `StickerGridViewController` keeps
/// Apple's peel/drag (owned by `MSStickerView`) but routes taps back here so we can call
/// `MSConversation.insert(_ sticker:)` — the only sticker insertion API that is not
/// restricted in `MSMessagesAppPresentationContextMedia`, i.e. the system Stickers drawer.
@MainActor
final class MessagesViewController: MSMessagesAppViewController {
    private let gridViewController = StickerGridViewController()
    private let legacyBrowserViewController = StickerBrowserViewController()
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
    /// sectioned grid misbehaves on device; retire it once that has shipped.
    private let useLegacyBrowser = UserDefaults(suiteName: SharedAuthConfiguration.appGroupIdentifier)?
        .bool(forKey: "StickerFactoryUseLegacyBrowser") ?? false

    private var libraryService: MessagesLibraryService?
    private var loadTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?

    /// `activeConversation` can lag on the first activation in non-Messages hosts, while the
    /// conversation handed to `willBecomeActive(with:)` is guaranteed valid for that activation.
    private var lastKnownConversation: MSConversation?
    private var insertionTarget: MSConversation? { activeConversation ?? lastKnownConversation }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureStickerSurface()
        configureStatusView()
        configureOfflineBadge()
        configureHintLabel()

        do {
            libraryService = try MessagesLibraryService()
            showLoading()
        } catch {
            showError(error, offersOpenApp: true)
        }
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        lastKnownConversation = conversation
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
        gridViewController.suspendAnimations()
        lastKnownConversation = nil
    }

    private func configureStickerSurface() {
        let child: UIViewController = useLegacyBrowser ? legacyBrowserViewController : gridViewController
        gridViewController.onSelect = { [weak self] sticker in
            self?.insertSticker(sticker)
        }

        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        child.didMove(toParent: self)
    }

    private func replaceSections(with sections: [StickerSection]) {
        if useLegacyBrowser {
            // MSStickerBrowserView cannot render sections, so the legacy path flattens them —
            // "My Stickers" first, then each pack in order. Grouping is silently lost there.
            legacyBrowserViewController.replaceStickers(with: sections.flatMap(\.stickers))
        } else {
            gridViewController.replaceSections(with: sections)
        }
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
        buttonConfiguration.title = "Open Sticker Factory"
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

    private func configureOfflineBadge() {
        offlineLabel.translatesAutoresizingMaskIntoConstraints = false
        offlineLabel.text = "Offline · cached"
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

    private func refreshLibrary() {
        guard let libraryService else { return }
        loadTask?.cancel()
        showLoading()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await libraryService.refresh()
                guard !Task.isCancelled else { return }
                replaceSections(with: snapshot.sections)
                offlineLabel.isHidden = !snapshot.isOffline
                if snapshot.stickers.isEmpty {
                    showEmptyLibrary(hasInstalledPacks: snapshot.sections.contains { $0.id != SharedStickerCache.mineSectionID })
                } else {
                    statusContainer.isHidden = true
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                showError(error, offersOpenApp: true)
            }
        }
    }

    // MARK: - Insertion

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

    private func applyInsertOutcome(_ outcome: StickerInsertOutcome) {
        guard let text = StickerInsertPolicy.hint(for: outcome, context: presentationContext) else {
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
        statusLabel.text = "Refreshing your stickers…"
        activityIndicator.startAnimating()
        openAppButton.isHidden = true
        offlineLabel.isHidden = true
    }

    private func showEmptyLibrary(hasInstalledPacks: Bool = false) {
        statusContainer.isHidden = false
        // Telling someone to publish a sticker is unhelpful when they added packs and it is the
        // packs that are currently empty.
        statusLabel.text = hasInstalledPacks
            ? "The packs you added have nothing published right now. Open Sticker Factory to add more."
            : "Create and publish a sticker in Sticker Factory, then return here."
        activityIndicator.stopAnimating()
        openAppButton.isHidden = false
        offlineLabel.isHidden = true
    }

    private func showError(_ error: Error, offersOpenApp: Bool) {
        statusContainer.isHidden = false
        statusLabel.text = (error as? LocalizedError)?.errorDescription
            ?? "Your sticker library is unavailable."
        activityIndicator.stopAnimating()
        openAppButton.isHidden = !offersOpenApp
        offlineLabel.isHidden = true
    }

    @objc
    private func openMainApplication() {
        guard let url = URL(string: "stickerfactory://open?source=messages") else { return }
        extensionContext?.open(url) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in
                guard let self else { return }
                self.logger.error("extensionContext.open refused (context=\(self.presentationContext.rawValue))")
                self.statusLabel.text = "Open Sticker Factory from the Home Screen and sign in."
            }
        }
    }
}
