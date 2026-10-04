import Messages
import UIKit
import os

extension MessagesViewController {
    func showLoading() {
        statusContainer.isHidden = false
        setModeControlVisible(false)
        statusLabel.text = String(localized: "Refreshing your stickers…")
        activityIndicator.startAnimating()
        openAppButton.isHidden = true
        setCreateButtonVisible(false)
        offlineLabel.isHidden = true
    }

    func showEmptyLibrary(hasInstalledPacks: Bool = false) {
        statusContainer.isHidden = false
        setModeControlVisible(false)
        // Telling someone to publish a sticker is unhelpful when they added packs and it is the
        // packs that are currently empty.
        statusLabel.text = hasInstalledPacks
            ? String(localized: "The packs you added have nothing published right now. Open Sticker Factory to add more.")
            : String(localized: "Create a sticker here, then review and publish it in the main app.")
        activityIndicator.stopAnimating()
        openAppButton.isHidden = false
        offlineLabel.isHidden = true
    }

    func showError(_ error: Error, offersOpenApp: Bool) {
        let message = (error as? LocalizedError)?.errorDescription
            ?? String(localized: "Your sticker library is unavailable.")
        statusContainer.isHidden = false
        setModeControlVisible(false)
        statusLabel.text = message
        activityIndicator.stopAnimating()
        openAppButton.isHidden = !offersOpenApp
        setCreateButtonVisible(false)
        offlineLabel.isHidden = true

        if let libraryError = error as? StickerLibraryError, libraryError.isServerResponse {
            let alert = UIAlertController(
                title: String(localized: "Couldn’t Complete Action"),
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            if presentedViewController == nil { present(alert, animated: true) }
        }
    }

    @objc
    func openMainApplicationFromButton() {
        openMainApplication(stickerID: nil)
    }

    func openMainApplication(stickerID: String?) {
        let source = surface == .fullSize ? "fullsize" : "messages"
        var components = URLComponents()
        components.scheme = "stickerfactory"
        components.host = stickerID == nil ? "open" : "sticker"
        if let stickerID { components.path = "/\(stickerID)" }
        components.queryItems = [URLQueryItem(name: "source", value: source)]
        guard let url = components.url else { return }
        extensionContext?.open(url) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in
                guard let self else { return }
                self.logger.error("extensionContext.open refused (context=\(self.presentationContext.rawValue))")
                if let creationController = self.creationController {
                    creationController.showOpenAppFailure()
                } else if self.showsPetPage {
                    self.presentAlert(message: String(localized: "Open Winky from the Home Screen to adopt a pet."))
                } else {
                    self.statusLabel.text = String(localized: "Open Sticker Factory from the Home Screen and sign in.")
                }
            }
        }
    }
}

private extension StickerLibraryError {
    var isServerResponse: Bool {
        switch self {
        case .updateRequired, .server: true
        default: false
        }
    }
}
