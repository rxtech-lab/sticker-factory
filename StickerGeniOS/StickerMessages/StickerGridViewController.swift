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
    /// Identity of one grid item. `MSSticker` is not `Hashable`, so the diffable snapshot carries
    /// ids and the controller keeps the stickers themselves alongside.
    struct StickerItemID: Hashable, Sendable {
        let sectionID: String
        let stickerID: String
    }

    /// Injection seam: the grid never touches `MSConversation`, so tests can drive selection.
    var onSelect: ((MSSticker) -> Void)?

    /// The same tap, reported as an item id instead of an `MSSticker`.
    ///
    /// The full-size surface inserts a file the grid has never seen — the cached `MSSticker` is
    /// only the thumbnail there — so it needs the identity to look a descriptor up, not the sticker.
    var onSelectItem: ((StickerItemID) -> Void)?

    /// Suppresses Apple's peel/drag on every cell.
    ///
    /// Set while the surface is sending images, because a drag inserts the `MSSticker` behind the
    /// caller's back — which is the wrong file when someone asked for the full-size image, and
    /// exactly the right one when they asked for a sticker. Setting it re-applies to every visible
    /// cell as well as to future dequeues, so it can follow the send mode.
    var suppressesPeelDrag = false {
        didSet {
            guard oldValue != suppressesPeelDrag, isViewLoaded else { return }
            for case let cell as StickerCell in collectionView.visibleCells {
                cell.setPeelDragEnabled(!suppressesPeelDrag)
            }
        }
    }

    private(set) var sections: [StickerSection] = []
    private var stickersByID: [StickerItemID: MSSticker] = [:]
    /// Flat display order, so a global index still maps to an item.
    private var orderedIDs: [StickerItemID] = []
    private var sectionHeaders: [String: (title: String, subtitle: String?)] = [:]
    /// Items with work in flight. Held here rather than on the cell so the state survives reuse
    /// and scrolling — a cell recycled mid-download would otherwise come back tappable.
    private var busyItemIDs: Set<StickerItemID> = []

    private(set) lazy var collectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: Self.makeLayout()
    )
    private var dataSource: UICollectionViewDiffableDataSource<String, StickerItemID>!

    private var isActive = false

    var stickers: [MSSticker] { orderedIDs.compactMap { stickersByID[$0] } }
    var stickerCount: Int { orderedIDs.count }

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
        collectionView.register(
            StickerSectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: StickerSectionHeaderView.reuseIdentifier
        )
        configureDataSource()
        collectionView.delegate = self

        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<String, StickerItemID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, itemID in
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: StickerCell.reuseIdentifier,
                for: indexPath
            )
            guard let self, let stickerCell = cell as? StickerCell, let sticker = stickersByID[itemID] else {
                return cell
            }
            // Captures the item id, never the index path: index paths go stale the moment a
            // snapshot is applied, and a stale one inserts the wrong sticker.
            stickerCell.configure(with: sticker) { [weak self] in
                self?.select(itemID)
            }
            stickerCell.setBusy(busyItemIDs.contains(itemID))
            // Set both ways, not just off: one controller now serves both presentation contexts,
            // and a cell recycled from the full-size surface must come back draggable rather than
            // silently inert.
            stickerCell.setPeelDragEnabled(!suppressesPeelDrag)
            return stickerCell
        }

        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard kind == UICollectionView.elementKindSectionHeader else { return nil }
            let view = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: StickerSectionHeaderView.reuseIdentifier,
                for: indexPath
            )
            guard let self, let header = view as? StickerSectionHeaderView else { return view }
            let sectionID = dataSource.snapshot().sectionIdentifiers[indexPath.section]
            let content = sectionHeaders[sectionID]
            header.configure(title: content?.title ?? "", subtitle: content?.subtitle)
            return header
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        resumeAnimations()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        suspendAnimations()
    }

    /// A single flat list, shown as one unnamed section. Used by the legacy browser bridge and by
    /// tests that do not care about grouping.
    func replaceStickers(with cachedStickers: [CachedSticker]) {
        replaceSections(with: [
            StickerSection(
                id: SharedStickerCache.mineSectionID,
                title: SharedStickerCache.mineSectionTitle,
                subtitle: nil,
                stickers: cachedStickers
            ),
        ])
    }

    func replaceSections(with sections: [StickerSection]) {
        // An empty section would draw a header over nothing.
        let populated = sections.filter { !$0.stickers.isEmpty }
        self.sections = populated

        stickersByID = [:]
        orderedIDs = []
        sectionHeaders = [:]
        var snapshot = NSDiffableDataSourceSnapshot<String, StickerItemID>()

        for section in populated {
            var itemIDs: [StickerItemID] = []
            for cached in section.stickers {
                guard let sticker = try? MSSticker(
                    contentsOfFileURL: cached.fileURL,
                    localizedDescription: String(cached.title.prefix(150))
                ) else { continue }
                let id = StickerItemID(sectionID: section.id, stickerID: cached.stickerID)
                // The same sticker in two packs is two items; a duplicate within one section
                // would crash the diffable data source.
                guard stickersByID[id] == nil else { continue }
                stickersByID[id] = sticker
                itemIDs.append(id)
                orderedIDs.append(id)
            }
            guard !itemIDs.isEmpty else { continue }
            sectionHeaders[section.id] = (section.title, section.subtitle)
            snapshot.appendSections([section.id])
            snapshot.appendItems(itemIDs, toSection: section.id)
        }

        // Keep the busy marks whose items survived the reload — their downloads are still running
        // — and drop the rest, which nothing will ever clear.
        busyItemIDs.formIntersection(orderedIDs)

        loadViewIfNeeded()
        // Without animation: the drawer is small, and a cross-fade on a full library reload reads
        // as flicker rather than as motion.
        dataSource.applySnapshotUsingReloadData(snapshot)
        // Cells the layout has already produced do not re-fire `willDisplay`. The library usually
        // lands before the drawer finishes its first layout pass, so without this the freshly
        // loaded stickers sit on their first frame — invisible for any sticker that fades in.
        if isActive { resumeAnimations() }
    }

    /// The single funnel every tap goes through.
    func select(_ itemID: StickerItemID) {
        guard let sticker = stickersByID[itemID] else { return }
        // A busy item is already working; a second tap must not queue a second send.
        guard !busyItemIDs.contains(itemID) else { return }
        onSelect?(sticker)
        onSelectItem?(itemID)
    }

    /// The `MSSticker` behind one grid item.
    ///
    /// The full-size surface needs it as well as the item id: a sticker send inserts this object
    /// directly, exactly as the Stickers drawer does, while an image send resolves a file the grid
    /// has never seen.
    func sticker(for itemID: StickerItemID) -> MSSticker? { stickersByID[itemID] }

    /// Marks one item as working, so it shows a spinner and stops accepting taps.
    func setBusy(_ busy: Bool, for itemID: StickerItemID) {
        if busy {
            busyItemIDs.insert(itemID)
        } else {
            busyItemIDs.remove(itemID)
        }
        guard let indexPath = dataSource.indexPath(for: itemID),
              let cell = collectionView.cellForItem(at: indexPath) as? StickerCell else {
            return
        }
        cell.setBusy(busy)
    }

    func isBusy(_ itemID: StickerItemID) -> Bool { busyItemIDs.contains(itemID) }

    func selectSticker(at indexPath: IndexPath) {
        let snapshot = dataSource.snapshot()
        guard snapshot.sectionIdentifiers.indices.contains(indexPath.section) else { return }
        let items = snapshot.itemIdentifiers(inSection: snapshot.sectionIdentifiers[indexPath.section])
        guard items.indices.contains(indexPath.item) else { return }
        select(items[indexPath.item])
    }

    /// Selection by global position across every section — "insert the Nth sticker".
    func selectSticker(at index: Int) {
        guard orderedIDs.indices.contains(index) else { return }
        select(orderedIDs[index])
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
            // Not pinned: pinning would need an opaque backing to keep the label readable over
            // the stickers sliding under it, and that backing is a light bar across the drawer.
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(38)
                ),
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            section.boundarySupplementaryItems = [header]
            return section
        }
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

/// The pack name, plus its creator byline, above one group of stickers.
@MainActor
final class StickerSectionHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "sticker-section-header"

    private let titleLabel = UILabel()
    private let titleBadge = UIView()
    private let subtitleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Pill badge gives the title its own opaque backdrop so it reads on any
        // drawer background (glass, light, dark) without relying on transparency.
        titleBadge.backgroundColor = .secondarySystemBackground
        titleBadge.layer.cornerRadius = 10
        titleBadge.clipsToBounds = true
        titleBadge.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: titleBadge.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: titleBadge.trailingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: titleBadge.topAnchor, constant: 4),
            titleLabel.bottomAnchor.constraint(equalTo: titleBadge.bottomAnchor, constant: -4),
        ])

        subtitleLabel.font = .preferredFont(forTextStyle: .caption2)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [titleBadge, subtitleLabel])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        accessibilityIdentifier = "sticker-section-header"
        isAccessibilityElement = true
        accessibilityTraits = [.header]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, subtitle: String?) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true
        accessibilityLabel = [title, subtitle].compactMap { $0 }.joined(separator: ", ")
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

@MainActor
final class StickerCell: UICollectionViewCell {
    static let reuseIdentifier = "sticker-cell"

    private let stickerView = MSStickerView(frame: .zero, sticker: nil)
    private let tapRecognizer = UITapGestureRecognizer()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var onTap: (() -> Void)?
    private(set) var isBusy = false

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

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        contentView.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

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

    /// Work is in flight for this sticker: dim it, spin, and refuse further touches.
    func setBusy(_ busy: Bool) {
        isBusy = busy
        if busy {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        stickerView.alpha = busy ? 0.35 : 1
        stickerView.isUserInteractionEnabled = !busy
        if busy {
            accessibilityTraits.insert(.notEnabled)
        } else {
            accessibilityTraits.remove(.notEnabled)
        }
    }

    /// Toggles Apple's peel/drag while leaving our own tap recognizer alone.
    ///
    /// `MSStickerView` installs those recognizers itself and exposes no switch for them, so this
    /// reaches for `gestureRecognizers` directly and may quietly stop working on a future OS.
    /// The full-size surface's hint copy — never "press and hold" — is the real defense; this is
    /// belt-and-braces so a drag cannot substitute the ≤500 KB rendition for the one asked for.
    func setPeelDragEnabled(_ enabled: Bool) {
        for recognizer in stickerView.gestureRecognizers ?? [] where recognizer !== tapRecognizer {
            recognizer.isEnabled = enabled
        }
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
        setBusy(false)
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
