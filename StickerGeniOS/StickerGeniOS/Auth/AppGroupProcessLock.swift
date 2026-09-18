import Darwin
import Foundation

/// Cross-process `flock` on a file in the shared App Group container.
///
/// iOS terminates a suspended process that still holds a lock inside a shared
/// container (RUNNINGBOARD 0xdead10cc). While locked, this class therefore holds
/// an expiring-activity assertion so the process keeps running, and releases the
/// lock itself if the system revokes that assertion before `unlock()` is called.
/// Acquisition polls with a deadline so a peer suspended mid-refresh cannot park
/// this process forever.
///
/// Shared with the StickerMessages extension via target membership.
nonisolated final class AppGroupProcessLock: @unchecked Sendable {
    static let defaultAcquireTimeout: TimeInterval = 20

    private let descriptor: Int32
    private let unavailableError: any Error
    private let state = NSLock()
    private var isLocked = false
    private var isRevoked = false
    private var activityRelease: DispatchSemaphore?

    init(url: URL, unavailableError: any Error) throws {
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw unavailableError }
        self.descriptor = descriptor
        self.unavailableError = unavailableError
    }

    deinit {
        unlock()
        Darwin.close(descriptor)
    }

    func lock(timeout: TimeInterval = AppGroupProcessLock.defaultAcquireTimeout) throws {
        beginBackgroundActivity()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            state.lock()
            if isRevoked {
                state.unlock()
                endBackgroundActivity()
                throw unavailableError
            }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                isLocked = true
                state.unlock()
                return
            }
            let failure = errno
            state.unlock()
            guard failure == EWOULDBLOCK || failure == EINTR, Date() < deadline else {
                endBackgroundActivity()
                throw unavailableError
            }
            usleep(50_000)
        }
    }

    /// Throws when the lock was force-released because the process was about to
    /// be suspended. Call before committing work that requires exclusivity.
    func ensureHeld() throws {
        state.lock()
        defer { state.unlock() }
        guard isLocked, !isRevoked else { throw unavailableError }
    }

    func unlock() {
        state.lock()
        if isLocked { flock(descriptor, LOCK_UN) }
        isLocked = false
        state.unlock()
        endBackgroundActivity()
    }

    private func revoke() {
        state.lock()
        isRevoked = true
        if isLocked { flock(descriptor, LOCK_UN) }
        isLocked = false
        state.unlock()
    }

    private func beginBackgroundActivity() {
        let release = DispatchSemaphore(value: 0)
        state.lock()
        guard activityRelease == nil else {
            state.unlock()
            return
        }
        activityRelease = release
        state.unlock()
        // The first invocation (expired == false) keeps the assertion alive until
        // `release` is signalled. A later invocation with expired == true means
        // suspension is imminent, so drop the lock before it happens.
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Shared session refresh") { [weak self] expired in
            if expired {
                self?.revoke()
                release.signal()
            } else {
                release.wait()
            }
        }
    }

    private func endBackgroundActivity() {
        state.lock()
        let release = activityRelease
        activityRelease = nil
        state.unlock()
        release?.signal()
    }
}
