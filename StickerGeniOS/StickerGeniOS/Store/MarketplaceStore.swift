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
    /// "My packs" pages the same way Browse does — an author with more packs than one page still
    /// has to be able to reach the rest of them.
    private(set) var nextMyPacksCursor: String?
    var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var isLoadingMoreMyPacks = false
    var errorMessage: String?

    var sort: PackSort = .recent
    /// What the search field currently holds. Typing here is not itself a request — the view hands
    /// it to `searchQueryChanged()`, which debounces before reloading.
    var searchQuery = ""
    /// The query the packs on screen were actually loaded with.
    ///
    /// The empty state has to say why a list is empty, and `searchQuery` cannot answer that: it
    /// changes the moment a key is pressed and again the moment the search field is dismissed,
    /// while the results below it still belong to the previous term. Reading the live text is what
    /// made a cleared search sit on "Nothing here yet" over results that were only ever a search's.
    private(set) var appliedQuery = ""

    let api: StickerAPIClientProtocol

    /// Called after an install or uninstall so the Library's sections reload. A closure rather than
    /// a direct reference keeps the two stores from knowing about each other.
    @ObservationIgnored var onInstallsChanged: (() async -> Void)?

    /// What a browse reload was started for. Two callers asking the same question share one
    /// request; a caller asking a *different* one — a new search term, another sort — must not be
    /// handed the in-flight answer to the old question, which is what left a typed search showing
    /// the unfiltered feed.
    private struct RefreshKey: Equatable {
        var query: String
        var sort: PackSort
    }

    /// The in-flight browse reload. Mirrors `StickerStore.refreshTask`: the tab's appearance task
    /// and a pull-to-refresh can both fire, and the server should see one request, not two.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshKey: RefreshKey?
    @ObservationIgnored private var refreshGeneration = 0
    /// The pending debounced search. Keystrokes replace it; only the last one survives to reload.
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(api: StickerAPIClientProtocol) { self.api = api }

    func reset() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshKey = nil
        searchTask?.cancel()
        searchTask = nil
        packs = []
        myPacks = []
        details = [:]
        creators = [:]
        nextCursor = nil
        nextMyPacksCursor = nil
        isLoadingMore = false
        isLoadingMoreMyPacks = false
        errorMessage = nil
        searchQuery = ""
        appliedQuery = ""
    }

    /// Leading and trailing spaces are typed constantly on iOS and mean nothing to the server, so
    /// they are trimmed before they become part of a request or of the applied-query bookkeeping.
    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reloads shortly after the last keystroke.
    ///
    /// Search used to reload on submit alone, so results only ever appeared for someone who pressed
    /// return — and dismissing the field, which clears the text without submitting, left the last
    /// search's results on screen with nothing to explain them.
    func searchQueryChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh() async {
        searchTask?.cancel()
        searchTask = nil
        let key = RefreshKey(query: trimmedQuery, sort: sort)
        if let refreshTask, refreshKey == key {
            await refreshTask.value
            return
        }
        // A reload for different parameters supersedes this one: its results are already the wrong
        // answer, and letting it finish would only race to overwrite the right one.
        refreshTask?.cancel()
        let generation = refreshGeneration &+ 1
        refreshGeneration = generation
        refreshKey = key
        let task = Task { await performRefresh(key, generation: generation) }
        refreshTask = task
        defer {
            if refreshGeneration == generation {
                refreshTask = nil
                refreshKey = nil
            }
        }
        await task.value
    }

    private func performRefresh(_ key: RefreshKey, generation: Int) async {
        isLoading = true
        // Only the newest reload owns the flag; an older one finishing must not clear the spinner
        // its successor is still showing.
        defer { if refreshGeneration == generation { isLoading = false } }
        do {
            let query = key.query.isEmpty ? nil : key.query
            async let browse = api.marketplacePacks(sort: key.sort, query: query, cursor: nil)
            async let mine = api.myPacks(query: query, cursor: nil)
            let (browsed, owned) = try await (browse, mine)
            guard generation == refreshGeneration else { return }
            packs = browsed.items
            nextCursor = Self.usableCursor(browsed.nextCursor)
            myPacks = owned.items
            nextMyPacksCursor = Self.usableCursor(owned.nextCursor)
            appliedQuery = key.query
            errorMessage = nil
        } catch {
            guard generation == refreshGeneration, !StickerStore.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Fetches one more page of the browse feed.
    ///
    /// The guards matter now that the grid re-arms its sentinel per cursor: without them a second
    /// pass would request the page already in flight, and a server that repeats a cursor would keep
    /// the feed asking for the same page forever.
    func loadMore() async {
        guard let cursor = nextCursor, !isLoading, !isLoadingMore else { return }
        let generation = refreshGeneration
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            // `appliedQuery`, not the live field: the next page has to continue the search these
            // results came from, even if the reader has already started typing another one.
            let page = try await api.marketplacePacks(
                sort: sort,
                query: appliedQuery.isEmpty ? nil : appliedQuery,
                cursor: cursor
            )
            guard generation == refreshGeneration else { return }
            var seen = Set(packs.map(\.id))
            packs.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
            let next = Self.usableCursor(page.nextCursor)
            nextCursor = next == cursor ? nil : next
        } catch {
            guard generation == refreshGeneration, !StickerStore.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreMyPacks() async {
        guard let cursor = nextMyPacksCursor, !isLoading, !isLoadingMoreMyPacks else { return }
        let generation = refreshGeneration
        isLoadingMoreMyPacks = true
        defer { isLoadingMoreMyPacks = false }
        do {
            let page = try await api.myPacks(query: appliedQuery.isEmpty ? nil : appliedQuery, cursor: cursor)
            guard generation == refreshGeneration else { return }
            var seen = Set(myPacks.map(\.id))
            myPacks.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
            let next = Self.usableCursor(page.nextCursor)
            nextMyPacksCursor = next == cursor ? nil : next
        } catch {
            guard generation == refreshGeneration, !StickerStore.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private static func usableCursor(_ cursor: String?) -> String? {
        guard let cursor, !cursor.isEmpty else { return nil }
        return cursor
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

    /// Renames a pack, or rewrites its description. Applies to a published pack as much as a draft:
    /// the slug is the shared link and the server keeps it, so a rename never breaks a URL.
    ///
    /// `summary: nil` clears the description rather than leaving it alone — the request encodes it
    /// explicitly for exactly that reason.
    func updateDetails(packID: String, title: String, summary: String?) async throws {
        apply(try await api.updatePack(
            id: packID,
            request: .init(title: title, summary: summary),
            idempotencyKey: UUID().uuidString
        ))
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
