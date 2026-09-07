#if DEBUG
import Foundation
import RxSubscriptionIOS

/// Exercises the real subscription client and credit sheet without a signed-in billing account.
nonisolated final class BalanceRefreshFixture: URLProtocol, @unchecked Sendable {
    private static let counts = Counts()
    private final class Counts: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Int] = [:]
        func next(_ path: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            values[path, default: 0] += 1
            return values[path]!
        }
    }

    @MainActor static func makeClient() -> Client {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return Client(
            serverURL: URL(string: "https://balance-ui-test.invalid")!,
            publishableKey: "rxs_pk_xcode_ui_test",
            rxlabUserID: "balance-ui-test",
            userToken: { _ in "ui-test-token" },
            session: URLSession(configuration: configuration)
        )
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url!.path
        let attempt = Self.counts.next(path)
        let isBalance = path == "/api/v1/balances"
        let isLedger = path == "/api/v1/balances/ledger"
        if (isBalance || isLedger), attempt == 2 {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let amount = attempt >= 3 ? 250 : 100
        let json: String
        if isBalance {
            json = """
            {"balances":[{"unit":"points","name":"Points","precision":0,"amount":\(amount),"available":\(amount)}]}
            """
        } else if isLedger {
            json = """
            {"entries":[{"id":"grant","kind":"credit","unit":"points","delta":\(amount),"balanceAfter":\(amount),"description":"Refresh fixture grant \(amount)","createdAt":"2026-09-07T00:00:00Z"}],"total":1,"page":1,"pageSize":20,"pageCount":1}
            """
        } else if path == "/api/v1/entitlements" {
            json = """
            {"user":{"id":"test","rxlabUserId":"balance-ui-test","level":0},"plans":[],"roles":[],"permissions":[],"features":{},"balances":[],"usage":[]}
            """
        } else {
            json = """
            {"plans":[],"topups":[]}
            """
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
