import Combine
import RxSubscriptionIOS
import SwiftUI

/// Keep loaded balances and activity visible while refreshing, including when SwiftUI cancels
/// a refresh task. The package supplies the cards and rows; this screen owns request lifetimes.
struct StickerBalanceView: View {
    @StateObject private var model: StickerBalanceViewModel

    init(client: Client) {
        _model = StateObject(wrappedValue: StickerBalanceViewModel(client: client))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)]) {
                    ForEach(model.balances) { BalanceCard(balance: $0) }
                }
                if model.isLoadingBalances && model.balances.isEmpty {
                    ProgressView("Loading balances…")
                } else if model.balances.isEmpty && model.balanceError == nil {
                    Text("No balances").foregroundStyle(.secondary)
                }
                if let error = model.balanceError {
                    retry(error) { await model.loadBalances() }
                }

                Text("Activity").font(.headline)
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.groupedEntries, id: \.day) { group in
                        Text(group.day, format: .dateTime.month().day().year())
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(group.entries) { entry in
                            BalanceHistoryRow(entry: entry)
                                .onAppear {
                                    if entry.id == model.entries.last?.id {
                                        Task { await model.loadNextPage() }
                                    }
                                }
                        }
                    }
                    if model.isLoadingHistory {
                        ProgressView("Loading history…")
                    } else if let error = model.historyError {
                        retry(error) { await model.retryHistory() }
                    } else if model.entries.isEmpty {
                        Text("No balance history").foregroundStyle(.secondary)
                    } else if model.hasMore {
                        Button("Load more") { Task { await model.loadNextPage() } }
                    }
                }
            }
            .padding(20)
        }
        .accessibilityIdentifier("balance-scroll")
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
    }

    private func retry(_ error: String, action: @escaping () async -> Void) -> some View {
        VStack(spacing: 12) {
            ErrorBanner(message: error)
            Button { Task { await action() } } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.posterSecondary)
        }
    }
}

@MainActor
final class StickerBalanceViewModel: ObservableObject {
    @Published private(set) var balances: [Balance] = []
    @Published private(set) var entries: [LedgerEntry] = []
    @Published private(set) var isLoadingBalances = false
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var balanceError: String?
    @Published private(set) var historyError: String?

    private let fetchBalances: () async throws -> [Balance]
    private let fetchLedger: (Int) async throws -> LedgerPage
    private var page = 0
    private var pageCount = 0
    private var historyGeneration = 0
    private var failedHistoryPage: Int?

    convenience init(client: Client) {
        self.init(fetchBalances: { try await client.balances() },
                  fetchLedger: { try await client.ledger(page: $0) })
    }

    init(fetchBalances: @escaping () async throws -> [Balance],
         fetchLedger: @escaping (Int) async throws -> LedgerPage) {
        self.fetchBalances = fetchBalances
        self.fetchLedger = fetchLedger
    }

    var hasMore: Bool { page < pageCount }

    var groupedEntries: [(day: Date, entries: [LedgerEntry])] {
        let groups = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted(by: >).map { (day: $0, entries: groups[$0]!) }
    }

    func refresh() async {
        async let balances: Void = loadBalances()
        async let history: Void = loadHistory(page: 1, replacing: true)
        _ = await (balances, history)
    }

    func loadBalances() async {
        guard !isLoadingBalances else { return }
        isLoadingBalances = true
        balanceError = nil
        defer { isLoadingBalances = false }
        do {
            let updated = try await fetchBalances()
            try Task.checkCancellation()
            balances = updated
        } catch {
            if !Self.isCancellation(error) { balanceError = error.localizedDescription }
        }
    }

    func loadNextPage() async {
        guard hasMore, !isLoadingHistory, historyError == nil else { return }
        await loadHistory(page: page + 1, replacing: false)
    }

    func retryHistory() async {
        let target = failedHistoryPage ?? 1
        await loadHistory(page: target, replacing: target == 1)
    }

    private func loadHistory(page target: Int, replacing: Bool) async {
        // A refresh supersedes pagination, but only replaces its rows after a successful response.
        historyGeneration += 1
        let generation = historyGeneration
        isLoadingHistory = true
        historyError = nil
        failedHistoryPage = nil
        defer { if generation == historyGeneration { isLoadingHistory = false } }
        do {
            let updated = try await fetchLedger(target)
            try Task.checkCancellation()
            guard generation == historyGeneration else { return }
            entries = replacing ? updated.entries : entries + updated.entries
            page = updated.page
            pageCount = updated.pageCount
        } catch {
            guard generation == historyGeneration else { return }
            if !Self.isCancellation(error) {
                historyError = error.localizedDescription
                failedHistoryPage = target
            }
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
