import Messages
import UIKit

/// A sticker grid that keeps Apple's peel/drag interaction (`MSStickerView` owns it) while
/// routing taps through `onSelect` instead of `MSStickerBrowserView`'s built-in handling.
///
/// `MSStickerBrowserView` is documented to insert taps into "Messages input field" and drags
/// into "the Messages transcript", so both are inert in the system Stickers drawer
/// (`MSMessagesAppPresentationContextMedia`). Owning the tap lets the parent call
/// `MSConversation.insert(_ sticker:)`, the one sticker API without a media-context restriction.
@MainActor
final class StickerGridViewController: UIViewController {
    /// Injection seam: the grid never touches `MSConversation`, so tests can drive selection.
    var onSelect: ((MSSticker) -> Void)?

    private(set) var stickers: [MSSticker] = []
    private(set) lazy var collectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: Self.makeLayout()
    )

    private var isActive = false

    var stickerCount: Int { stickers.count }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "sticker-factory-messages-browser"

        collectionView.accessibilityIdentifier = "sticker-factory-messages-grid"
        collectionView.backgroundColor = .clear
        // MSStickerView consumes touches, so cell selection never fires reliably. The tap
        // recognizer inside the cell is the single insert path; two paths would double-insert.
        collectionView.allowsSelection = false
        collectionView.alwaysBounceVertical = true
        // Without this the 150ms touch delay swallows the start of Apple's peel gesture.
        collectionView.delaysContentTouches = false
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.register(StickerCell.self, forCellWithReuseIdentifier: StickerCell.reuseIdentifier)
        collectionView.dataSource = self
        collectionView.delegate = self

        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(collectionView)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        resumeAnimations()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        suspendAnimations()
    }

    func replaceStickers(with cachedStickers: [CachedSticker]) {
        stickers = cachedStickers.compactMap { cached in
            try? MSSticker(
                contentsOfFileURL: cached.fileURL,
                localizedDescription: String(cached.title.prefix(150))
            )
        }
        loadViewIfNeeded()
        // reloadData discards visible cells, so willDisplay re-fires and animations restart.
        collectionView.reloadData()
        // ...but only for cells the layout has already produced. The library usually lands before
        // the drawer finishes its first layout pass, so without this the freshly loaded stickers
        // sit on their first frame — invisible for any sticker that fades or slides in.
        if isActive { resumeAnimations() }
    }

    /// The single funnel every tap goes through.
    func selectSticker(at index: Int) {
        guard stickers.indices.contains(index) else { return }
        onSelect?(stickers[index])
    }

    func resumeAnimations() {
        isActive = true
        // `visibleCells` is empty until the layout has run, and a cell that never animates is a
        // blank square for any sticker whose first frame is transparent.
        collectionView.layoutIfNeeded()
        for case let cell as StickerCell in collectionView.visibleCells {
            cell.startStickerAnimation()
        }
    }

    /// `willDisplay` never fires again for cells already on screen, so a suspended extension
    /// would keep animating forever without this.
    func suspendAnimations() {
        isActive = false
        for case let cell as StickerCell in collectionView.visibleCells {
            cell.stopStickerAnimation()
        }
    }

    private static func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let spacing: CGFloat = 8
            let inset: CGFloat = 12
            // Close to `MSStickerSize.small`, which is what Apple's own drawer uses: four across on
            // a standard iPhone. `.regular` (~136pt) fits two, so a library of any size reads as a
            // couple of posters rather than a grid you can scan.
            let target: CGFloat = 84
            let available = max(target, environment.container.effectiveContentSize.width - inset * 2)
            let columns = max(3, Int((available + spacing) / (target + spacing)))
            let side = ((available - spacing * CGFloat(columns - 1)) / CGFloat(columns))
                .rounded(.down)

            // Absolute widths in an explicit `subitems:` array, not `repeatingSubitem:count:`: the
            // count form divides the group evenly *before* interItemSpacing is applied, so the row
            // overflows its group by `spacing * (columns - 1)` and clips the last sticker.
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .absolute(side),
                    heightDimension: .absolute(side)
                )
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .absolute(side)
                ),
                subitems: Array(repeating: item, count: columns)
            )
            group.interItemSpacing = .fixed(spacing)

            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            section.contentInsets = NSDirectionalEdgeInsets(
                top: inset, leading: inset, bottom: inset, trailing: inset
            )
            return section
        }
    }
}

extension StickerGridViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        stickers.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: StickerCell.reuseIdentifier,
            for: indexPath
        )
        guard let stickerCell = cell as? StickerCell, stickers.indices.contains(indexPath.item) else {
            return cell
        }
        stickerCell.configure(with: stickers[indexPath.item]) { [weak self] in
            self?.selectSticker(at: indexPath.item)
        }
        return stickerCell
    }
}

extension StickerGridViewController: UICollectionViewDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard isActive, let cell = cell as? StickerCell else { return }
        cell.startStickerAnimation()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        (cell as? StickerCell)?.stopStickerAnimation()
    }
}

@MainActor
final class StickerCell: UICollectionViewCell {
    static let reuseIdentifier = "sticker-cell"

    private let stickerView = MSStickerView(frame: .zero, sticker: nil)
    private let tapRecognizer = UITapGestureRecognizer()
    private var onTap: (() -> Void)?

    /// Tracks our intent rather than `MSStickerView.isAnimating()`: a static PNG has an
    /// `animationDuration` of zero and reports `false` even after `startAnimating()`.
    private(set) var animationRequested = false

    var displayedStickerFileURL: URL? { stickerView.sticker?.imageFileURL }

    override init(frame: CGRect) {
        super.init(frame: frame)

        // Autoresizing, not Auto Layout: MSStickerView derives an intrinsic size from its
        // sticker and fights pinned constraints when the sticker is swapped on reuse.
        stickerView.frame = contentView.bounds
        stickerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stickerView.isUserInteractionEnabled = true
        contentView.addSubview(stickerView)

        tapRecognizer.addTarget(self, action: #selector(handleTap))
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delaysTouchesBegan = false
        tapRecognizer.delaysTouchesEnded = false
        tapRecognizer.delegate = self
        stickerView.addGestureRecognizer(tapRecognizer)

        isAccessibilityElement = true
        accessibilityTraits = [.button, .image]
        accessibilityIdentifier = "sticker-cell"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with sticker: MSSticker, onTap: @escaping () -> Void) {
        self.onTap = onTap
        stopStickerAnimation()
        stickerView.sticker = sticker
        accessibilityLabel = sticker.localizedDescription
    }

    func startStickerAnimation() {
        // startAnimating() always restarts from the first frame, so re-entrant calls would
        // visibly re-sync every animated sticker.
        guard stickerView.sticker != nil, !animationRequested else { return }
        animationRequested = true
        stickerView.startAnimating()
    }

    func stopStickerAnimation() {
        guard animationRequested else { return }
        animationRequested = false
        stickerView.stopAnimating()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopStickerAnimation()
        stickerView.sticker = nil
        onTap = nil
        accessibilityLabel = nil
    }

    @objc
    private func handleTap() {
        onTap?()
    }
}

extension StickerCell: UIGestureRecognizerDelegate {
    /// MSStickerView owns the recognizers behind peel/drag; never block them.
    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
