import Messages
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// PhotosUI has not annotated its picker result types as `Sendable`, although the delegate hands
/// this immutable selection across its nonisolated callback. The wrapper moves it to the main
/// actor exactly once; all reads and item-provider loading happen there.
private struct MessagesPickerSelection: @unchecked Sendable {
    let picker: PHPickerViewController
    let results: [PHPickerResult]
}

/// Quick mode: the whole make-a-sticker loop, inside Messages.
///
/// The main app's loop is a conversation — generate, read the transcript, edit layers, choose when
/// to publish. None of that fits a drawer, and porting it would put an editor and a chat log in the
/// place someone opened to send one picture. So this screen keeps three verbs and drops the rest:
/// describe it, look at it, change it. There is no editor and no transcript here.
///
/// The fourth thing it drops is the publish decision. A sticker made here is published as soon as
/// it is generated — see `POST /api/v1/stickers/{id}/publish`, which renders the export ladder on
/// the server precisely so this extension does not have to — because a sticker you cannot send is
/// not a thing anyone came to Messages to make. What the user sees when the spinner stops is the
/// real, sendable sticker, sitting in their library.
///
/// It also makes only static stickers. An animated project is designed before it is drawn — the
/// server plans its layers and asks the user to confirm the plan, because only separate layers can
/// be keyframed — and that confirmation is a conversation this surface does not have. Anyone who
/// wants motion has the main app, where the plan card is something they can actually read.
///
/// The work outlives the screen: every job is server-side, so closing the drawer mid-generation
/// loses the progress bar and nothing else. The project also stays a normal project — the revisions
/// are ordinary chat turns — so the main app can open it later and carry on properly.
@MainActor
final class MessagesCreateViewController: UIViewController, PHPickerViewControllerDelegate, UITextViewDelegate {
    var onClose: (() -> Void)?
    var onReview: ((String) -> Void)?
    /// Asks the host to refresh its library and hand back the published sticker's local file.
    ///
    /// The host owns the cache and the grid, so it — not this screen — is what turns "published on
    /// the server" into "a file on disk". The URL comes back so the result can show the very sticker
    /// a tap would send, rather than a preview that merely resembles it.
    var onPublished: ((String) async -> URL?)?
    /// Sends the published sticker, through whichever of the host's two send paths is selected.
    var onSend: ((String) -> Void)?

    /// Which of the three panes is up.
    private enum Stage {
        case form
        case working
        case result
    }

    private let service: MessagesStickerCreationService
    private var references: [MessagesReferenceImage] = []
    private var creationTask: Task<Void, Never>?
    private var stage = Stage.form
    private var isWorking = false

    private let header = UIStackView()
    private let backButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let formScrollView = UIScrollView()
    private let formStack = UIStackView()
    private let promptTextView = UITextView()
    private let promptPlaceholder = UILabel()
    private let promptCountLabel = UILabel()
    private let addPhotosButton = UIButton(type: .system)
    private let referenceScrollView = UIScrollView()
    private let referenceStack = UIStackView()
    private let privacyLabel = UILabel()
    private let errorLabel = UILabel()
    private let generateButton = UIButton(type: .system)

    private let workingView = UIView()
    private let workingIndicator = UIActivityIndicatorView(style: .large)
    private let workingLabel = UILabel()
    private let workingProgress = UIProgressView(progressViewStyle: .default)
    private let workingSteps = UIStackView()
    private let workingCancelButton = UIButton(type: .system)

    /// One row of the live step list: a tool call the server has announced.
    ///
    /// Identified by the transcript row id rather than by the tool's name, because a turn runs the
    /// same tool more than once — `create_plan`, `create_plan #2` — and each announcement arrives
    /// twice, streaming then complete.
    private struct WorkStep: Equatable {
        let id: String
        let label: String
        var status: String
    }

    private var workSteps: [WorkStep] = []

    /// Which half of the errand the bar is currently reporting.
    ///
    /// Two jobs run back to back — draw it, then publish it — and each reports its own 0…1. Shown
    /// raw, the bar would fill, snap back to zero and fill again, which reads as a restart. So each
    /// job is mapped into its own span of one continuous bar.
    private enum WorkPhase {
        case generating
        case publishing

        var span: ClosedRange<Float> {
            switch self {
            case .generating: 0.02 ... 0.75
            case .publishing: 0.75 ... 1
            }
        }
    }

    private var workPhase = WorkPhase.generating

    private let resultView = UIView()
    private let resultArtwork = UIView()
    private let resultImageView = UIImageView()
    private var resultStickerView: MSStickerView?
    private let resultStatusLabel = UILabel()
    private let reviseTextView = UITextView()
    private let revisePlaceholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private let reviseButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let openAppButton = UIButton(type: .system)

    private var createdStickerID: String?
    /// Set when the sticker generated but could not be auto-published — a document this build's
    /// server-side renderer will not draw. The artwork is still shown; only the Send path is gone.
    private var publishFailure: String?

    init(service: MessagesStickerCreationService) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "sticker-factory-messages-create"
        configureHeader()
        configureForm()
        configureWorking()
        configureResult()
        show(.form)
        updateFormState()
    }

    /// Stops watching, without touching the server.
    ///
    /// Everything in flight is a job the server is running; cancelling here abandons the progress
    /// bar, not the work. A sticker whose job is already past generation will still publish, and
    /// will be waiting in the library the next time this drawer opens.
    func cancelOutstandingWork() {
        guard creationTask != nil else { return }
        creationTask?.cancel()
        creationTask = nil
        isWorking = false
        guard isViewLoaded else { return }
        // A turn that had already produced a sticker keeps its result on screen; only one that had
        // nothing to show yet falls back to the form.
        show(createdStickerID == nil ? .form : .result)
        resetGenerateButton()
        updateFormState()
    }

    func showOpenAppFailure() {
        let message = String(localized: "Open Sticker Factory from the Home Screen to see this sticker.")
        if stage == .result {
            resultStatusLabel.text = message
        } else {
            errorLabel.text = message
            errorLabel.isHidden = false
        }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    // MARK: - Panes

    private func show(_ stage: Stage) {
        self.stage = stage
        formScrollView.isHidden = stage != .form
        workingView.isHidden = stage != .working
        resultView.isHidden = stage != .result
        backButton.isHidden = stage != .form
        switch stage {
        case .form:
            titleLabel.text = String(localized: "Create Sticker")
        case .working:
            titleLabel.text = String(localized: "Making it")
        case .result:
            titleLabel.text = String(localized: "Your sticker")
        }
    }

    // MARK: - Layout

    private func configureHeader() {
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false

        var backConfiguration = UIButton.Configuration.plain()
        backConfiguration.image = UIImage(systemName: "chevron.left")
        backConfiguration.title = String(localized: "Stickers")
        backConfiguration.imagePadding = 4
        backButton.configuration = backConfiguration
        backButton.accessibilityIdentifier = "messages-create-back"
        backButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        titleLabel.text = String(localized: "Create Sticker")
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center

        let trailingSpacer = UIView()
        trailingSpacer.translatesAutoresizingMaskIntoConstraints = false

        header.addArrangedSubview(backButton)
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(trailingSpacer)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        view.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            // Balances the back button so the title stays optically centred. Activated here, once
            // both views share `header` as an ancestor — pairing two orphan anchors throws.
            trailingSpacer.widthAnchor.constraint(equalTo: backButton.widthAnchor),
        ])
    }

    private func configureForm() {
        formScrollView.translatesAutoresizingMaskIntoConstraints = false
        formScrollView.alwaysBounceVertical = true
        formScrollView.keyboardDismissMode = .interactive
        formScrollView.accessibilityIdentifier = "messages-create-form"
        view.addSubview(formScrollView)

        formStack.axis = .vertical
        formStack.alignment = .fill
        formStack.spacing = 14
        formStack.translatesAutoresizingMaskIntoConstraints = false
        formScrollView.addSubview(formStack)

        formStack.addArrangedSubview(sectionLabel(String(localized: "Describe your sticker")))
        configurePrompt()
        formStack.addArrangedSubview(promptTextView)
        formStack.addArrangedSubview(promptCountLabel)

        let referenceHeader = UIStackView()
        referenceHeader.axis = .horizontal
        referenceHeader.alignment = .center
        referenceHeader.spacing = 8
        let referenceTitle = sectionLabel(String(localized: "Reference images · optional"))
        referenceHeader.addArrangedSubview(referenceTitle)
        referenceHeader.addArrangedSubview(addPhotosButton)
        referenceTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        configureAddPhotosButton()
        formStack.addArrangedSubview(referenceHeader)

        referenceScrollView.showsHorizontalScrollIndicator = false
        referenceScrollView.isHidden = true
        referenceScrollView.translatesAutoresizingMaskIntoConstraints = false
        referenceStack.axis = .horizontal
        referenceStack.alignment = .center
        referenceStack.spacing = 10
        referenceStack.translatesAutoresizingMaskIntoConstraints = false
        referenceScrollView.addSubview(referenceStack)
        NSLayoutConstraint.activate([
            referenceScrollView.heightAnchor.constraint(equalToConstant: 82),
            referenceStack.leadingAnchor.constraint(equalTo: referenceScrollView.contentLayoutGuide.leadingAnchor),
            referenceStack.trailingAnchor.constraint(equalTo: referenceScrollView.contentLayoutGuide.trailingAnchor),
            referenceStack.topAnchor.constraint(equalTo: referenceScrollView.contentLayoutGuide.topAnchor),
            referenceStack.bottomAnchor.constraint(equalTo: referenceScrollView.contentLayoutGuide.bottomAnchor),
            referenceStack.heightAnchor.constraint(equalTo: referenceScrollView.frameLayoutGuide.heightAnchor),
        ])
        formStack.addArrangedSubview(referenceScrollView)

        privacyLabel.text = String(localized: "Selected photos are uploaded privately as generation references. New stickers are added to your library so you can send them straight away.")
        privacyLabel.font = .preferredFont(forTextStyle: .caption1)
        privacyLabel.textColor = .secondaryLabel
        privacyLabel.numberOfLines = 0
        privacyLabel.adjustsFontForContentSizeCategory = true
        formStack.addArrangedSubview(privacyLabel)

        errorLabel.font = .preferredFont(forTextStyle: .callout)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "messages-create-error"
        formStack.addArrangedSubview(errorLabel)

        var generateConfiguration = UIButton.Configuration.filled()
        generateConfiguration.title = String(localized: "Generate")
        generateConfiguration.image = UIImage(systemName: "wand.and.stars")
        generateConfiguration.imagePadding = 8
        generateConfiguration.cornerStyle = .capsule
        generateButton.configuration = generateConfiguration
        generateButton.accessibilityIdentifier = "messages-generate-sticker"
        generateButton.addTarget(self, action: #selector(generate), for: .touchUpInside)
        formStack.addArrangedSubview(generateButton)
        generateButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true

        NSLayoutConstraint.activate([
            formScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            formScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            formScrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            formScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            formStack.leadingAnchor.constraint(equalTo: formScrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            formStack.trailingAnchor.constraint(equalTo: formScrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            formStack.topAnchor.constraint(equalTo: formScrollView.contentLayoutGuide.topAnchor, constant: 12),
            formStack.bottomAnchor.constraint(equalTo: formScrollView.contentLayoutGuide.bottomAnchor, constant: -20),
            formStack.widthAnchor.constraint(equalTo: formScrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])
    }

    private func configurePrompt() {
        promptTextView.delegate = self
        promptTextView.font = .preferredFont(forTextStyle: .body)
        promptTextView.adjustsFontForContentSizeCategory = true
        promptTextView.backgroundColor = .secondarySystemBackground
        promptTextView.layer.cornerRadius = 14
        promptTextView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        promptTextView.accessibilityIdentifier = "messages-sticker-prompt"
        promptTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true

        promptPlaceholder.text = String(localized: "A joyful corgi in a raincoat, with a thick white sticker outline…")
        promptPlaceholder.font = .preferredFont(forTextStyle: .body)
        promptPlaceholder.textColor = .placeholderText
        promptPlaceholder.numberOfLines = 0
        promptPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        promptTextView.addSubview(promptPlaceholder)
        NSLayoutConstraint.activate([
            promptPlaceholder.leadingAnchor.constraint(equalTo: promptTextView.leadingAnchor, constant: 15),
            promptPlaceholder.trailingAnchor.constraint(equalTo: promptTextView.trailingAnchor, constant: -15),
            promptPlaceholder.topAnchor.constraint(equalTo: promptTextView.topAnchor, constant: 12),
        ])

        promptCountLabel.font = .preferredFont(forTextStyle: .caption1)
        promptCountLabel.textColor = .secondaryLabel
        promptCountLabel.textAlignment = .right
        promptCountLabel.adjustsFontForContentSizeCategory = true
    }

    private func configureAddPhotosButton() {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = String(localized: "Add")
        configuration.image = UIImage(systemName: "photo.badge.plus")
        configuration.imagePadding = 5
        configuration.cornerStyle = .capsule
        addPhotosButton.configuration = configuration
        addPhotosButton.accessibilityIdentifier = "messages-add-reference-images"
        addPhotosButton.addTarget(self, action: #selector(addPhotos), for: .touchUpInside)
    }

    private func configureWorking() {
        workingView.translatesAutoresizingMaskIntoConstraints = false
        workingView.isHidden = true
        workingView.accessibilityIdentifier = "messages-create-working"

        workingIndicator.startAnimating()
        workingLabel.text = String(localized: "Starting securely…")
        workingLabel.font = .preferredFont(forTextStyle: .body)
        workingLabel.textAlignment = .center
        workingLabel.numberOfLines = 0
        workingLabel.adjustsFontForContentSizeCategory = true

        let hint = UILabel()
        hint.text = String(localized: "This keeps running if you close Messages.")
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .secondaryLabel
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.adjustsFontForContentSizeCategory = true

        var cancelConfiguration = UIButton.Configuration.plain()
        cancelConfiguration.title = String(localized: "Stop watching")
        workingCancelButton.configuration = cancelConfiguration
        workingCancelButton.accessibilityIdentifier = "messages-create-stop-watching"
        workingCancelButton.addTarget(self, action: #selector(stopWatching), for: .touchUpInside)

        workingProgress.progressTintColor = .systemBlue
        workingProgress.accessibilityIdentifier = "messages-create-progress"

        workingSteps.axis = .vertical
        workingSteps.alignment = .fill
        workingSteps.spacing = 6
        workingSteps.accessibilityIdentifier = "messages-create-steps"

        let stack = UIStackView(arrangedSubviews: [
            workingIndicator, workingLabel, workingProgress, workingSteps, hint, workingCancelButton,
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        workingView.addSubview(stack)
        view.addSubview(workingView)
        NSLayoutConstraint.activate([
            workingView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            workingView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            workingView.topAnchor.constraint(equalTo: header.bottomAnchor),
            workingView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: workingView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: workingView.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: workingView.centerYAnchor),
        ])
    }

    private func configureResult() {
        resultView.translatesAutoresizingMaskIntoConstraints = false
        resultView.isHidden = true
        resultView.accessibilityIdentifier = "messages-create-result"

        // A plain box the artwork is dropped into. Which view goes in depends on what exists yet:
        // a published sticker gets an `MSStickerView`, so the result screen offers Apple's own peel
        // and drag; anything else gets a still of the candidate.
        resultArtwork.translatesAutoresizingMaskIntoConstraints = false
        resultImageView.contentMode = .scaleAspectFit
        resultImageView.translatesAutoresizingMaskIntoConstraints = false
        resultArtwork.addSubview(resultImageView)

        resultStatusLabel.font = .preferredFont(forTextStyle: .subheadline)
        resultStatusLabel.textColor = .secondaryLabel
        resultStatusLabel.textAlignment = .center
        resultStatusLabel.numberOfLines = 0
        resultStatusLabel.adjustsFontForContentSizeCategory = true
        resultStatusLabel.accessibilityIdentifier = "messages-create-result-status"

        configureReviseField()

        var sendConfiguration = UIButton.Configuration.filled()
        sendConfiguration.title = String(localized: "Send")
        sendConfiguration.image = UIImage(systemName: "paperplane.fill")
        sendConfiguration.imagePadding = 7
        sendConfiguration.cornerStyle = .capsule
        sendButton.configuration = sendConfiguration
        sendButton.accessibilityIdentifier = "messages-send-created-sticker"
        sendButton.addTarget(self, action: #selector(sendCreatedSticker), for: .touchUpInside)

        var reviseConfiguration = UIButton.Configuration.tinted()
        reviseConfiguration.title = String(localized: "Revise")
        reviseConfiguration.image = UIImage(systemName: "arrow.triangle.2.circlepath")
        reviseConfiguration.imagePadding = 7
        reviseConfiguration.cornerStyle = .capsule
        reviseButton.configuration = reviseConfiguration
        reviseButton.accessibilityIdentifier = "messages-revise-created-sticker"
        reviseButton.addTarget(self, action: #selector(revise), for: .touchUpInside)

        var openConfiguration = UIButton.Configuration.tinted()
        openConfiguration.title = String(localized: "Open the main app")
        openConfiguration.cornerStyle = .capsule
        openAppButton.configuration = openConfiguration
        openAppButton.isHidden = true
        openAppButton.accessibilityIdentifier = "messages-review-created-sticker"
        openAppButton.addTarget(self, action: #selector(reviewCreatedSticker), for: .touchUpInside)

        var doneConfiguration = UIButton.Configuration.plain()
        doneConfiguration.title = String(localized: "Done")
        doneButton.configuration = doneConfiguration
        doneButton.accessibilityIdentifier = "messages-created-back-to-library"
        doneButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        let actions = UIStackView(arrangedSubviews: [sendButton, reviseButton])
        actions.axis = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 10

        let stack = UIStackView(arrangedSubviews: [
            resultArtwork, resultStatusLabel, reviseTextView, actions, openAppButton, doneButton,
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        resultView.addSubview(stack)
        view.addSubview(resultView)
        NSLayoutConstraint.activate([
            resultView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            resultView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            resultView.topAnchor.constraint(equalTo: header.bottomAnchor),
            resultView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: resultView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: resultView.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: resultView.centerYAnchor),
            resultArtwork.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            resultImageView.leadingAnchor.constraint(equalTo: resultArtwork.leadingAnchor),
            resultImageView.trailingAnchor.constraint(equalTo: resultArtwork.trailingAnchor),
            resultImageView.topAnchor.constraint(equalTo: resultArtwork.topAnchor),
            resultImageView.bottomAnchor.constraint(equalTo: resultArtwork.bottomAnchor),
            sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            reviseButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
    }

    private func configureReviseField() {
        reviseTextView.delegate = self
        reviseTextView.font = .preferredFont(forTextStyle: .callout)
        reviseTextView.adjustsFontForContentSizeCategory = true
        reviseTextView.backgroundColor = .secondarySystemBackground
        reviseTextView.layer.cornerRadius = 12
        reviseTextView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        reviseTextView.accessibilityIdentifier = "messages-revise-prompt"
        reviseTextView.heightAnchor.constraint(equalToConstant: 72).isActive = true

        revisePlaceholder.text = String(localized: "Change something — \"make it blue\", \"add sunglasses\"…")
        revisePlaceholder.font = .preferredFont(forTextStyle: .callout)
        revisePlaceholder.textColor = .placeholderText
        revisePlaceholder.numberOfLines = 0
        revisePlaceholder.translatesAutoresizingMaskIntoConstraints = false
        reviseTextView.addSubview(revisePlaceholder)
        NSLayoutConstraint.activate([
            revisePlaceholder.leadingAnchor.constraint(equalTo: reviseTextView.leadingAnchor, constant: 13),
            revisePlaceholder.trailingAnchor.constraint(equalTo: reviseTextView.trailingAnchor, constant: -13),
            revisePlaceholder.topAnchor.constraint(equalTo: reviseTextView.topAnchor, constant: 10),
        ])
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    // MARK: - Form

    func textViewDidChange(_ textView: UITextView) {
        updateFormState()
    }

    @objc
    private func formChanged() {
        updateFormState()
    }

    private func updateFormState() {
        let count = promptTextView.text.count
        promptPlaceholder.isHidden = !promptTextView.text.isEmpty
        promptCountLabel.text = "\(count)/4,000"
        promptCountLabel.textColor = count > 4_000 ? .systemRed : .secondaryLabel
        generateButton.isEnabled = !isWorking
            && !promptTextView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && count <= 4_000
        addPhotosButton.isEnabled = !isWorking && references.count < MessagesReferenceImage.maximumCount
        backButton.isEnabled = !isWorking
        promptTextView.isEditable = !isWorking

        revisePlaceholder.isHidden = !reviseTextView.text.isEmpty
        reviseButton.isEnabled = !isWorking
            && !reviseTextView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc
    private func addPhotos() {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = MessagesReferenceImage.maximumCount - references.count
        configuration.selection = .ordered
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let selection = MessagesPickerSelection(picker: picker, results: results)
        Task { @MainActor [weak self] in
            selection.picker.dismiss(animated: true)
            guard let self, !selection.results.isEmpty else { return }
            self.errorLabel.isHidden = true
            self.loadPickedImages(MessagesPickerSelection(
                picker: selection.picker,
                results: Array(selection.results.prefix(MessagesReferenceImage.maximumCount - self.references.count))
            ))
        }
    }

    private func loadPickedImages(_ selection: MessagesPickerSelection, at index: Int = 0) {
        guard selection.results.indices.contains(index) else {
            rebuildReferenceThumbnails()
            updateFormState()
            return
        }
        let provider = selection.results[index].itemProvider
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            loadPickedImages(selection, at: index + 1)
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, error in
            let errorMessage = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data {
                    do {
                        let reference = try MessagesReferenceImageNormalizer.normalize(
                            data,
                            index: self.references.count + 1
                        )
                        self.references.append(reference)
                    } catch {
                        self.errorLabel.text = error.localizedDescription
                        self.errorLabel.isHidden = false
                    }
                } else if let errorMessage {
                    self.errorLabel.text = errorMessage
                    self.errorLabel.isHidden = false
                }
                self.loadPickedImages(selection, at: index + 1)
            }
        }
    }

    private func rebuildReferenceThumbnails() {
        for view in referenceStack.arrangedSubviews {
            referenceStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, reference) in references.enumerated() {
            guard let image = UIImage(data: reference.data) else { continue }
            let button = UIButton(type: .custom)
            button.tag = index
            button.setBackgroundImage(image, for: .normal)
            button.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
            button.tintColor = .white
            button.contentHorizontalAlignment = .right
            button.contentVerticalAlignment = .top
            button.imageView?.layer.shadowColor = UIColor.black.cgColor
            button.imageView?.layer.shadowOpacity = 0.5
            button.imageView?.layer.shadowRadius = 2
            button.layer.cornerRadius = 14
            button.clipsToBounds = true
            button.accessibilityLabel = String(localized: "Remove reference image \(index + 1)")
            button.addTarget(self, action: #selector(removeReference(_:)), for: .touchUpInside)
            referenceStack.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 80),
                button.heightAnchor.constraint(equalToConstant: 80),
            ])
        }
        referenceScrollView.isHidden = references.isEmpty
        var configuration = addPhotosButton.configuration
        configuration?.title = references.isEmpty
            ? String(localized: "Add")
            : String(localized: "Add \(references.count)/8")
        addPhotosButton.configuration = configuration
    }

    @objc
    private func removeReference(_ sender: UIButton) {
        guard references.indices.contains(sender.tag), !isWorking else { return }
        references.remove(at: sender.tag)
        rebuildReferenceThumbnails()
        updateFormState()
    }

    // MARK: - The quick-mode loop

    @objc
    private func generate() {
        let prompt = promptTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= 4_000, !isWorking else { return }
        let references = references
        beginWork(String(localized: "Starting securely…"))
        creationTask = Task { [weak self, service] in
            do {
                let created = try await service.create(
                    kind: .staticSticker,
                    prompt: prompt,
                    references: references
                )
                guard let self else { return }
                self.createdStickerID = created.stickerID
                try await self.finishTurn(stickerID: created.stickerID, jobID: created.jobID)
            } catch {
                self?.failWork(error)
            }
        }
    }

    @objc
    private func revise() {
        let prompt = reviseTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isWorking, let stickerID = createdStickerID else { return }

        beginWork(String(localized: "Making that change…"))
        creationTask = Task { [weak self, service] in
            do {
                let jobID = try await service.revise(stickerID: stickerID, prompt: prompt)
                guard let self else { return }
                self.reviseTextView.text = ""
                try await self.finishTurn(stickerID: stickerID, jobID: jobID)
            } catch {
                self?.failWork(error)
            }
        }
    }

    /// Watches a turn to its end, publishes what it produced, and shows the result.
    ///
    /// The publish is unconditional, which is what "quick mode" means: nobody is asked to approve a
    /// candidate they are about to look at anyway, and a sticker that is not in the library is not
    /// one this drawer can send. Someone who dislikes what they see revises, and the next turn
    /// supersedes this one.
    private func finishTurn(stickerID: String, jobID: String) async throws {
        setPhase(.generating)
        // The one failure that leaves nothing behind. Past this line a turn has run, and whatever
        // else goes wrong the user has a sticker somewhere — so everything below degrades into the
        // result screen rather than replacing it with an error.
        try await service.awaitJob(jobID, onProgress: report)
        try Task.checkCancellation()

        publishFailure = nil
        do {
            setPhase(.publishing)
            workingLabel.text = String(localized: "Adding it to your stickers…")
            let publishJob = try await service.publish(stickerID: stickerID)
            try await service.awaitJob(publishJob, onProgress: report)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The artwork exists; only the automatic publish did not. Show it anyway with the
            // server's reason and the way out, rather than throwing away a sticker the user has
            // already paid to generate — the main app can still finish it.
            publishFailure = error.localizedDescription
        }
        try Task.checkCancellation()

        let fileURL = publishFailure == nil ? await onPublished?(stickerID) : nil
        let preview = fileURL == nil ? await previewImage(stickerID: stickerID) : nil
        try Task.checkCancellation()
        showResult(stickerID: stickerID, fileURL: fileURL, preview: preview)
    }

    /// The candidate's own artwork, for a sticker that has not been published.
    ///
    /// Best effort: a result screen with a working Revise button and no picture is still usable,
    /// and failing the whole turn because a preview would not download is not.
    private func previewImage(stickerID: String) async -> UIImage? {
        guard let assetID = try? await service.snapshot(stickerID: stickerID).displayRevision?.previewAssetID,
              let data = try? await service.preview(assetID: assetID) else { return nil }
        return UIImage(data: data)
    }

    private func showResult(stickerID: String, fileURL: URL?, preview: UIImage?) {
        creationTask = nil
        isWorking = false
        resetGenerateButton()

        resultStickerView?.removeFromSuperview()
        resultStickerView = nil
        resultImageView.isHidden = true

        if let fileURL,
           let sticker = try? MSSticker(contentsOfFileURL: fileURL, localizedDescription: String(localized: "Your sticker")) {
            // The real thing, not a picture of it: `MSStickerView` animates an APNG and carries
            // Apple's peel-and-drag, so the sticker can be dragged straight into the conversation
            // from here exactly as it can from the grid.
            let stickerView = MSStickerView(frame: .zero, sticker: sticker)
            stickerView.translatesAutoresizingMaskIntoConstraints = false
            stickerView.accessibilityIdentifier = "messages-created-sticker"
            resultArtwork.addSubview(stickerView)
            NSLayoutConstraint.activate([
                stickerView.leadingAnchor.constraint(equalTo: resultArtwork.leadingAnchor),
                stickerView.trailingAnchor.constraint(equalTo: resultArtwork.trailingAnchor),
                stickerView.topAnchor.constraint(equalTo: resultArtwork.topAnchor),
                stickerView.bottomAnchor.constraint(equalTo: resultArtwork.bottomAnchor),
            ])
            stickerView.startAnimating()
            resultStickerView = stickerView
        } else {
            resultImageView.image = preview
            resultImageView.isHidden = preview == nil
        }

        let published = fileURL != nil
        sendButton.isHidden = !published
        openAppButton.isHidden = published
        resultStatusLabel.text = published
            ? String(localized: "Saved to your stickers. Tap Send, or drag it into the conversation.")
            : publishFailure ?? String(localized: "Your sticker is ready to finish in the main app.")

        show(.result)
        updateFormState()
        UIAccessibility.post(notification: .screenChanged, argument: resultStatusLabel)
    }

    /// The live status line and bar, driven by the server's own progress frames.
    ///
    /// `@Sendable` and free of any main-actor work of its own: it is handed to the job watcher,
    /// which calls it from whatever context the stream is being read on.
    private var report: @Sendable (MessagesJobProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                self.absorb(progress)
                if let fraction = progress.fraction {
                    self.apply(fraction: Float(fraction))
                } else {
                    // A tool-call frame carries no fraction, and most of a turn is tool calls. Creep
                    // the bar a little on each one so it reads as working rather than as wedged;
                    // the ceiling keeps it out of the way of the real numbers when they arrive.
                    self.creepProgress()
                }
            }
        }
    }

    private func setPhase(_ phase: WorkPhase) {
        workPhase = phase
        apply(fraction: 0)
    }

    /// Maps one job's 0…1 into its phase's span, and never lets the bar go backwards inside a phase.
    private func apply(fraction: Float) {
        let span = workPhase.span
        let mapped = span.lowerBound + (span.upperBound - span.lowerBound) * min(max(fraction, 0), 1)
        guard mapped > workingProgress.progress else { return }
        workingProgress.setProgress(mapped, animated: true)
    }

    /// Advances the bar a fraction of the way to the phase's halfway mark, never reaching it.
    ///
    /// Deliberately asymptotic: this is a step of unknown length, so it can show that something is
    /// happening but must never imply a position it does not know. A real fraction overtakes it.
    private func creepProgress() {
        let span = workPhase.span
        let ceiling = span.lowerBound + (span.upperBound - span.lowerBound) * 0.5
        let next = workingProgress.progress + (ceiling - workingProgress.progress) * 0.25
        guard next > workingProgress.progress else { return }
        workingProgress.setProgress(next, animated: true)
    }

    private func beginWork(_ message: String) {
        view.endEditing(true)
        isWorking = true
        errorLabel.isHidden = true
        workingLabel.text = message
        workingIndicator.startAnimating()
        workingProgress.setProgress(0, animated: false)
        workSteps.removeAll()
        renderSteps()
        setPhase(.generating)
        show(.working)
        updateFormState()
    }

    private func failWork(_ error: Error) {
        if error is CancellationError { return }
        creationTask = nil
        isWorking = false
        resetGenerateButton()
        // Back to whichever pane the user can act on: the form if nothing has been made yet, the
        // result if a previous turn is still on screen to revise.
        if createdStickerID == nil || stage == .form {
            errorLabel.text = error.localizedDescription
            errorLabel.isHidden = false
            show(.form)
        } else {
            resultStatusLabel.text = error.localizedDescription
            // Nothing was published, so Send would insert nothing. Offer the way out instead.
            sendButton.isHidden = true
            openAppButton.isHidden = false
            show(.result)
        }
        updateFormState()
        UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
    }

    private func resetGenerateButton() {
        var configuration = generateButton.configuration
        configuration?.title = String(localized: "Generate")
        configuration?.showsActivityIndicator = false
        generateButton.configuration = configuration
    }

    /// Files one progress frame into the headline or the step list.
    ///
    /// The server draws the same distinction the main app's chat does, and this honours it rather
    /// than flattening everything into one line: a *phase* (`plan-sticker`, `animate-sticker`) is
    /// the turn's overall stage and belongs in the headline, while a *tool call* (`create_plan`,
    /// `edit_layers`) is one step inside it and belongs in the list underneath. `StickerToolLabel`
    /// is shared with the main app, so a step reads the same in both places and a tool added to the
    /// server later still reads as English here.
    private func absorb(_ progress: MessagesJobProgress) {
        if let stage = progress.stage, let text = Self.describe(stage: stage) {
            workingLabel.text = text
        }
        guard let tool = progress.tool else { return }
        if StickerToolLabel.isPhase(tool) {
            workingLabel.text = StickerToolLabel.text(for: tool)
            return
        }
        // Without a row id there is nothing to update, and appending would grow a duplicate on the
        // frame that reports the same step complete.
        guard let id = progress.toolCallID else { return }
        let step = WorkStep(id: id, label: StickerToolLabel.text(for: tool), status: progress.toolStatus ?? "streaming")
        if let index = workSteps.firstIndex(where: { $0.id == id }) {
            guard workSteps[index] != step else { return }
            workSteps[index] = step
        } else {
            workSteps.append(step)
        }
        renderSteps()
    }

    /// How many steps stay on screen.
    ///
    /// A turn runs more of them than a drawer has room for, and the older ones are the least useful:
    /// what is happening now, and the couple of things that just finished, is the whole question.
    private static let visibleStepCount = 4

    private func renderSteps() {
        for view in workingSteps.arrangedSubviews {
            workingSteps.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for step in workSteps.suffix(Self.visibleStepCount) {
            workingSteps.addArrangedSubview(stepRow(step))
        }
    }

    private func stepRow(_ step: WorkStep) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8

        let glyph: UIView
        switch step.status {
        case "complete":
            let image = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
            image.tintColor = .systemGreen
            glyph = image
        case "failed":
            let image = UIImageView(image: UIImage(systemName: "xmark.circle.fill"))
            image.tintColor = .systemRed
            glyph = image
        default:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            glyph = spinner
        }
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let label = UILabel()
        label.text = step.label
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        // The finished ones recede so the eye lands on the step that is still running.
        label.textColor = step.status == "streaming" ? .label : .secondaryLabel

        row.addArrangedSubview(glyph)
        row.addArrangedSubview(label)
        return row
    }

    /// The handful of stages the server reports outside the tool vocabulary, chiefly the publish.
    ///
    /// An unrecognised stage returns nil rather than a generic sentence: leaving the previous, more
    /// specific headline up beats replacing it with "Working on it…".
    private static func describe(stage: String) -> String? {
        switch stage {
        case "preparing_context": String(localized: "Reading your request…")
        case "planning_edit", "planning_animation": String(localized: "Planning it…")
        case "generating_image", "composing", "composing_part": String(localized: "Drawing it…")
        case "validating_candidate": String(localized: "Checking it over…")
        case "rendering_exports": String(localized: "Adding it to your stickers…")
        case "verifying_exports": String(localized: "Almost there…")
        default: nil
        }
    }

    // MARK: - Actions

    @objc
    private func sendCreatedSticker() {
        guard let createdStickerID, publishFailure == nil else { return }
        onSend?(createdStickerID)
    }

    @objc
    private func reviewCreatedSticker() {
        guard let createdStickerID else { return }
        onReview?(createdStickerID)
    }

    @objc
    private func stopWatching() {
        cancelOutstandingWork()
    }

    @objc
    private func close() {
        cancelOutstandingWork()
        onClose?()
    }
}
