import Foundation
import Testing
@testable import StickerGeniOS

@Suite("App group process lock")
struct AppGroupProcessLockTests {
    private func lockURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "process-lock-\(UUID().uuidString).lock")
    }

    @Test("A held lock times out a second holder instead of blocking forever")
    func contendedLockTimesOut() throws {
        let url = lockURL()
        let first = try AppGroupProcessLock(url: url, unavailableError: TokenBrokerError.lockUnavailable)
        try first.lock()
        try first.ensureHeld()

        let second = try AppGroupProcessLock(url: url, unavailableError: TokenBrokerError.lockUnavailable)
        #expect(throws: TokenBrokerError.lockUnavailable) { try second.lock(timeout: 0.2) }

        first.unlock()
        #expect(throws: TokenBrokerError.lockUnavailable) { try first.ensureHeld() }
        try second.lock(timeout: 0.2)
        try second.ensureHeld()
        second.unlock()
    }
}
