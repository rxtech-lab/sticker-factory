import AnimatedView
import SwiftUI
import ImageIO
import Messages
import UIKit
import os

extension MessagesViewController {
    /// The views that belong to the Stickers page. Hidden by alpha rather than `isHidden` when the
    /// Pet page is up, because their `isHidden` already answers a different question — what state
    /// the library is in — and the two must not overwrite each other: coming back to Stickers
    /// should find the grid, the spinner or the empty state exactly as the library left it.
    var stickerPageViews: [UIView] {
        [surfaceContainer, modeControl, statusContainer, offlineLabel, hintLabel, createButton]
    }

    func configureTabControl() {
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        tabControl.selectedSegmentIndex = MessagesTab.allCases.firstIndex(of: selectedTab) ?? 0
        tabControl.accessibilityIdentifier = "sticker-factory-tab-picker"
        // Same edge against the drawer's black backdrop as the send-mode control.
        tabControl.backgroundColor = .secondarySystemBackground
        tabControl.selectedSegmentTintColor = .systemBlue
        tabControl.setTitleTextAttributes([.foregroundColor: UIColor.label], for: .normal)
        tabControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        tabControl.addTarget(self, action: #selector(tabControlChanged), for: .valueChanged)
        tabControl.addAction(UIAction { _ in Haptics.selection() }, for: .valueChanged)
        tabControl.isHidden = true
        view.addSubview(tabControl)
        NSLayoutConstraint.activate([
            tabControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tabControl.centerYAnchor.constraint(equalTo: createButton.centerYAnchor),
            tabControl.trailingAnchor.constraint(lessThanOrEqualTo: createButton.leadingAnchor, constant: -12),
            tabControl.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    func configurePetContainer() {
        petContainer.translatesAutoresizingMaskIntoConstraints = false
        petContainer.backgroundColor = .clear
        petContainer.isHidden = true
        view.addSubview(petContainer)
        NSLayoutConstraint.activate([
            petContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            petContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            petContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            petContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc
    func tabControlChanged() {
        let cases = MessagesTab.allCases
        guard cases.indices.contains(tabControl.selectedSegmentIndex) else { return }
        selectedTab = cases[tabControl.selectedSegmentIndex]
        logger.log("tabControl selected=\(self.selectedTab.rawValue, privacy: .public)")
        applyTab()
        if showsPetPage {
            petModel.reload()
            gridViewController.suspendAnimations()
        } else if creationController == nil {
            gridViewController.resumeAnimations()
        }
    }

    /// Shows whichever page the tab names, and the tab control wherever it applies.
    func applyTab() {
        tabControl.isHidden = !(surface == .fullSize && creationController == nil && controlsController == nil)
        let showsPet = showsPetPage
        for page in stickerPageViews {
            page.alpha = showsPet ? 0 : 1
            page.isUserInteractionEnabled = !showsPet
            page.accessibilityElementsHidden = showsPet
        }
        if showsPet { installPetPageIfNeeded() }
        petContainer.isHidden = !showsPet
        view.bringSubviewToFront(tabControl)
    }

    func installPetPageIfNeeded() {
        guard petController == nil else { return }
        let controller = UIHostingController(rootView: MessagesPetView(model: petModel))
        controller.view.backgroundColor = .clear
        // Clears the bottom row, where the tab control sits, as the grid's own inset does.
        controller.additionalSafeAreaInsets.bottom = 58
        petController = controller
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        petContainer.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: petContainer.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: petContainer.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: petContainer.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: petContainer.bottomAnchor)
        ])
        controller.didMove(toParent: self)
    }

    func makePetModel() -> MessagesPetModel {
        let model = MessagesPetModel(service: try? MessagesPetService())
        model.insertCard = { [weak self] payload, pose in
            guard let self else { throw CancellationError() }
            try await self.insertPetCard(payload, pose: pose)
        }
        model.presentFailure = { [weak self] message in self?.presentAlert(message: message) }
        model.openApp = { [weak self] in self?.openMainApplication(stickerID: nil) }
        return model
    }

    /// Puts the pet card into the conversation as an interactive message.
    ///
    /// A message rather than an image attachment because only a message carries a URL to the
    /// recipient's copy of this extension — which is what lets a tap on the bubble open the card
    /// with its stats, instead of a picture of it. The template layout is what everyone else sees:
    /// someone without the app still gets the pose, the name, the class and the stat line.
    ///
    /// Not reported to `/pet/sends`: that endpoint is the pet reading the stickers its owner sends,
    /// and the card is not a sticker — the share it follows is its own record.
    func insertPetCard(_ payload: PetCardPayload, pose: UIImage?) async throws {
        guard let conversation = insertionTarget else { throw MessagesPetError.noConversation }
        let layout = MSMessageTemplateLayout()
        layout.image = pose
        layout.caption = payload.name
        layout.subcaption = [payload.petClass.map(MessagesPet.displayName(forClass:)), payload.caption]
            .compactMap { $0 }
            .joined(separator: " · ")
        layout.trailingSubcaption = payload.statLine
        let message = MSMessage()
        message.layout = layout
        message.url = payload.url
        message.summaryText = String(localized: "Sent a pet card: \(payload.name)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conversation.insert(message) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        // The card is staged in the input field; collapsing puts it, and the Send arrow, in view.
        requestPresentationStyle(.compact)
    }

    /// The card someone sent, as a sheet over whatever this drawer was showing — it is a detour
    /// from the drawer's own pages, and closing it should land back on them untouched.
    func presentReceivedCard(_ payload: PetCardPayload) {
        let rootView = ReceivedPetCardView(payload: payload) { [weak self] in
            self?.dismissReceivedCard(animated: true)
        }
        // A second card tapped while the first is open replaces it in place. One swiped away is
        // gone, even though nothing told this controller, so presence is checked, not remembered.
        if let existing = receivedCardController as? UIHostingController<ReceivedPetCardView>,
           existing.presentingViewController != nil {
            existing.rootView = rootView
            return
        }
        receivedCardController = nil
        guard presentedViewController == nil else { return }
        let controller = UIHostingController(rootView: rootView)
        controller.modalPresentationStyle = .pageSheet
        controller.sheetPresentationController?.detents = [.large()]
        controller.sheetPresentationController?.prefersGrabberVisible = true
        receivedCardController = controller
        Haptics.tap()
        present(controller, animated: true)
    }

    func dismissReceivedCard(animated: Bool) {
        guard let controller = receivedCardController else { return }
        receivedCardController = nil
        controller.dismiss(animated: animated)
    }

    func presentAlert(message: String) {
        let alert = UIAlertController(
            title: String(localized: "Couldn’t Complete Action"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        if presentedViewController == nil { present(alert, animated: true) }
    }
}
