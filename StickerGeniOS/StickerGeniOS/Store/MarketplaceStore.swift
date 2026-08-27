import Foundation
import Observation

@MainActor
@Observable
final class MarketplaceStore {
    private(set) var packs: [StickerPack] = []
    private(set) var myPacks: [StickerPack] = []
    private(set) var details: [String: StickerPackDetail] = [:]
    private(set) var creators: [String: CreatorPacksResponse] = [:]
    private(set) var nextCursor: String?
    var isLoading = false
    var errorMessage: String?

    var sort: PackSort = .recent
    var searchQuery = ""

    let api: StickerAPIClientProtocol

    /// Called after an install or uninstall so the Library's sections reload. A closure rather than
    /// a direct reference keeps the two stores from knowing about each other.
    @ObservationIgnored var onInstallsChanged: (() async -> Void)?

    /// The in-flight browse reload. Mirrors `StickerStore.refreshTask`: the tab's appearance task
    /// and a pull-to-refresh can both fire, and the server should see one request, not two.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0

    init(api: StickerAPIClientProtocol) { self.api = api }

    func reset() {
        refreshTask?.cancel()
        refreshTask = nil
        packs = []
        myPacks = []
        details = [:]
        creators = [:]
        nextCursor = nil
        errorMessage = nil
    }

    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let generation = refreshGeneration &+ 1
        refreshGeneration = generation
        let task = Task { await performRefresh() }
        refreshTask = task
        defer { if refreshGeneration == generation { refreshTask = nil } }
        await task.value
    }

    private func performRefresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let browse = api.marketplacePacks(sort: sort, query: searchQuery.isEmpty ? nil : searchQuery, cursor: nil)
            async let mine = api.myPacks(cursor: nil)
            let (browsed, owned) = try await (browse, mine)
            packs = browsed.items
            nextCursor = browsed.nextCursor
            myPacks = owned.items
            errorMessage = nil
        } catch {
            guard !StickerStore.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let cursor = nextCursor else { return }
        do {
            let page = try await api.marketplacePacks(
                sort: sort,
                query: searchQuery.isEmpty ? nil : searchQuery,
                cursor: cursor
            )
            var seen = Set(packs.map(\.id))
            packs.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
            nextCursor = page.nextCursor
        } catch {
            guard !StickerStore.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func loadDetail(packID: String) async -> StickerPackDetail? {
        do {
            let detail = try await api.pack(id: packID)
            apply(detail)
            errorMessage = nil
            return detail
        } catch {
            guard !StickerStore.isCancellation(error) else { return details[packID] }
            errorMessage = error.localizedDescription
            return details[packID]
        }
    }

    func loadCreator(handle: String) async {
        do {
            creators[handle] = try await api.packsByCreator(handle: handle, cursor: nil)
            errorMessage = nil
        } catch {
            guard !StickerStore.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Flips the install state immediately and rolls back if the request fails, so the button
    /// never sits inert while a round trip completes.
    func setInstalled(_ installed: Bool, packID: String) async {
        let rollback = snapshot(of: packID)
        applyInstalled(installed, packID: packID)
        do {
            _ = installed
                ? try await api.installPack(id: packID, idempotencyKey: UUID().uuidString)
                : try await api.uninstallPack(id: packID, idempotencyKey: UUID().uuidString)
            errorMessage = nil
            // The response carries no count on purpose (it can be replayed for 24 hours), so the
            // authoritative number comes from a refetch.
            await loadDetail(packID: packID)
            await onInstallsChanged?()
            await publishSectionAllowlist()
        } catch {
            restore(rollback, packID: packID)
            guard !StickerStore.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Authoring

    func createPack(title: String, summary: String?, stickerIDs: [String]) async throws -> StickerPackDetail {
        let detail = try await api.createPack(
            .init(title: title, summary: summary, stickerIds: stickerIDs),
            idempotencyKey: UUID().uuidString
        )
        apply(detail)
        myPacks.removeAll { $0.id == detail.id }
        myPacks.insert(detail.pack, at: 0)
        return detail
    }

    func setItems(packID: String, stickerIDs: [String]) async throws {
        apply(try await api.setPackItems(id: packID, stickerIDs: stickerIDs, idempotencyKey: UUID().uuidString))
    }

    func publish(packID: String) async throws {
        apply(try await api.publishPack(id: packID, idempotencyKey: UUID().uuidString))
        await refresh()
    }

    func unpublish(packID: String) async throws {
        apply(try await api.unpublishPack(id: packID, state: .draft, idempotencyKey: UUID().uuidString))
        await refresh()
    }

    func deletePack(packID: String) async throws {
        _ = try await api.deletePack(id: packID, idempotencyKey: UUID().uuidString)
        details[packID] = nil
        packs.removeAll { $0.id == packID }
        myPacks.removeAll { $0.id == packID }
        await onInstallsChanged?()
    }

    /// Tells the Messages extension which sections still belong to this user.
    ///
    /// Without it, uninstalling a pack while offline leaves its stickers insertable from the
    /// extension's cache until the next successful network refresh.
    private func publishSectionAllowlist() async {
        do {
            let sections = try await api.librarySections(status: .published).packSections
            SharedSectionAllowlist.publish(installedPackIDs: sections.compactMap(\.packId))
        } catch {
            // A stale allowlist is worse than none: drop it and let the cache be served whole.
            SharedSectionAllowlist.clear()
        }
    }

    // MARK: - Local state

    private func apply(_ detail: StickerPackDetail) {
        details[detail.id] = detail
        replace(detail.pack)
    }

    private func replace(_ pack: StickerPack) {
        if let index = packs.firstIndex(where: { $0.id == pack.id }) { packs[index] = pack }
        if let index = myPacks.firstIndex(where: { $0.id == pack.id }) { myPacks[index] = pack }
    }

    private func snapshot(of packID: String) -> (detail: StickerPackDetail?, pack: StickerPack?) {
        (details[packID], packs.first { $0.id == packID } ?? myPacks.first { $0.id == packID })
    }

    private func applyInstalled(_ installed: Bool, packID: String) {
        if var detail = details[packID] {
            detail.installed = installed
            detail.installCount = max(0, detail.installCount + (installed ? 1 : -1))
            apply(detail)
        } else if var pack = packs.first(where: { $0.id == packID }) {
            pack.installed = installed
            pack.installCount = max(0, pack.installCount + (installed ? 1 : -1))
            replace(pack)
        }
    }

    private func restore(_ snapshot: (detail: StickerPackDetail?, pack: StickerPack?), packID: String) {
        details[packID] = snapshot.detail
        if let pack = snapshot.pack { replace(pack) }
    }
}
