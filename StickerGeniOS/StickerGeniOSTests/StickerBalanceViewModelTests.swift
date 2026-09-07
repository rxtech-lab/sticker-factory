import Foundation
import RxSubscriptionIOS
import XCTest
@testable import StickerGeniOS

@MainActor
final class StickerBalanceViewModelTests: XCTestCase {
    func testBothCancellationTypesPreserveBalanceAndHistoryAndAllowNextRefresh() async throws {
        for cancellation in [CancellationError() as any Error, URLError(.cancelled)] {
            var attempt = 0
            let model = StickerBalanceViewModel(
                fetchBalances: {
                    attempt += 1
                    if attempt == 2 { throw cancellation }
                    return try self.balances(attempt == 1 ? 100 : 250)
                },
                fetchLedger: { _ in
                    // The balance and ledger requests run independently.
                    try self.ledger(page: 1)
                }
            )
            await model.refresh()
            await model.refresh()
            XCTAssertEqual(model.balances.first?.available, 100)
            XCTAssertEqual(model.entries.map(\.id), ["entry-1"])
            XCTAssertNil(model.balanceError)
            XCTAssertFalse(model.isLoadingBalances)
            await model.refresh()
            XCTAssertEqual(model.balances.first?.available, 250)
        }
    }

    func testCancelledHistoryRefreshPreservesPagination() async throws {
        var cancelReload = false
        var requestedPages: [Int] = []
        let model = StickerBalanceViewModel(fetchBalances: { try self.balances(100) }, fetchLedger: { page in
            requestedPages.append(page)
            if cancelReload, page == 1 { throw URLError(.cancelled) }
            return try self.ledger(page: page)
        })
        await model.refresh()
        cancelReload = true
        await model.refresh()
        XCTAssertEqual(model.entries.map(\.id), ["entry-1"])
        XCTAssertNil(model.historyError)
        XCTAssertFalse(model.isLoadingHistory)
        await model.loadNextPage()
        XCTAssertEqual(requestedPages, [1, 1, 2])
        XCTAssertEqual(model.entries.map(\.id), ["entry-1", "entry-2"])
        XCTAssertFalse(model.hasMore)
    }

    func testRealRefreshFailureKeepsDataAndRetriesFirstPage() async throws {
        var fail = false
        var requestedPages: [Int] = []
        let model = StickerBalanceViewModel(fetchBalances: { try self.balances(100) }, fetchLedger: { page in
            requestedPages.append(page)
            if fail { throw URLError(.notConnectedToInternet) }
            return try self.ledger(page: page)
        })
        await model.refresh()
        await model.loadNextPage()
        fail = true
        await model.refresh()
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertNotNil(model.historyError)
        fail = false
        await model.retryHistory()
        XCTAssertEqual(requestedPages, [1, 2, 1, 1])
        XCTAssertEqual(model.entries.map(\.id), ["entry-1"])
        XCTAssertNil(model.historyError)
    }

    private func balances(_ amount: Int) throws -> [Balance] {
        try JSONDecoder().decode([Balance].self, from: Data("""
        [{"unit":"points","name":"Points","precision":0,"amount":\(amount),"available":\(amount)}]
        """.utf8))
    }

    private func ledger(page: Int) throws -> LedgerPage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LedgerPage.self, from: Data("""
        {"entries":[{"id":"entry-\(page)","kind":"credit","unit":"points","delta":100,"balanceAfter":100,"description":"Grant","createdAt":"2026-09-07T00:00:00Z"}],"total":2,"page":\(page),"pageSize":1,"pageCount":2}
        """.utf8))
    }
}
