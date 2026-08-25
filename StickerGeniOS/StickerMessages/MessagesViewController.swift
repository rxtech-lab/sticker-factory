import Messages
import UIKit

/// The Messages root stays an `MSMessagesAppViewController` so Apple can deliver
/// conversation and activation callbacks. Its child `MSStickerBrowserViewController`
/// supplies the system tap-to-insert and peel/drag interactions.
@MainActor
final class MessagesViewController: MSMessagesAppViewController {
    private let browserViewController = StickerBrowserViewController()
    private let statusContainer = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let statusLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let openAppButton = UIButton(type: .system)
    private let offlineLabel = UILabel()

    private var libraryService: MessagesLibraryService?
    private var loadTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureBrowser()
        configureStatusView()
        configureOfflineBadge()

        do {
            libraryService = try MessagesLibraryService()
            showLoading()
        } catch {
            showError(error, offersOpenApp: true)
        }
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        refreshLibrary()
    }

    override func didResignActive(with conversation: MSConversation) {
        super.didResignActive(with: conversation)
        loadTask?.cancel()
    }

    private func configureBrowser() {
        addChild(browserViewController)
        browserViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browserViewController.view)
        NSLayoutConstraint.activate([
            browserViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browserViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browserViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            browserViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        browserViewController.didMove(toParent: self)
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

    private func refreshLibrary() {
        guard let libraryService else { return }
        loadTask?.cancel()
        showLoading()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await libraryService.refresh()
                guard !Task.isCancelled else { return }
                browserViewController.replaceStickers(with: snapshot.stickers)
                offlineLabel.isHidden = !snapshot.isOffline
                if snapshot.stickers.isEmpty {
                    showEmptyLibrary()
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

    private func showLoading() {
        statusContainer.isHidden = false
        statusLabel.text = "Refreshing your stickers…"
        activityIndicator.startAnimating()
        openAppButton.isHidden = true
        offlineLabel.isHidden = true
    }

    private func showEmptyLibrary() {
        statusContainer.isHidden = false
        statusLabel.text = "Create and publish a sticker in Sticker Factory, then return here."
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
                self?.statusLabel.text = "Open Sticker Factory from the Home Screen and sign in."
            }
        }
    }
}
