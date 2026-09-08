import AnimatedView
import CryptoKit
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import StickerGeniOS

@Suite("Interpolation and export policy")
struct StickerRenderingPolicyTests {
    @Test("Linear interpolation and ping-pong timing are deterministic")
    func interpolationAndPingPong() {
        let animation = AnimatedLayerAnimation(position: [
            .init(timeSeconds: 0, x: 0, y: 0.25, easing: .linear),
            .init(timeSeconds: 2, x: 1, y: 0.75, easing: .linear)
        ])
        let layer = AnimatedLayer.shape(.init(
            base: .init(id: "shape", name: "Shape", animation: animation),
            shape: .circle,
            fill: .solid("#FFFFFF")
        ))
        let document = AnimatedDocument(kind: .animated, durationSeconds: 2, fps: 30, loop: .pingPong, layers: [layer])
        let midpoint = AnimationInterpolator.state(for: layer, at: 1, in: document)

        #expect(abs(midpoint.position.x - 0.5) < 0.000_001)
        #expect(abs(AnimationInterpolator.mappedTime(3, document: document) - 1) < 0.000_001)
        #expect(AnimationInterpolator.renderedCycleDuration(document) == 4)
        #expect(StickerExportMetadataPolicy.frameCount(document: document, fps: 30) == 120)
    }

    @Test("MP4 is opaque and adaptive system renditions use the expected presets")
    func exportMetadataPolicy() {
        #expect(!StickerExportMetadataPolicy.hasAlpha(for: .mp4))
        #expect(StickerExportMetadataPolicy.hasAlpha(for: .gif))
        // Dimension is what the recipient perceives as sticker size, so the ladder spends frame
        // rate first and only concedes pixels once that is exhausted.
        #expect(SystemStickerPreset.adaptive.map(\.dimension) == [618, 618, 618, 408, 408, 300, 300, 300, 300, 300])
        // Monotonic: a rung never costs more bytes than the one it falls back from.
        #expect(zip(SystemStickerPreset.adaptive, SystemStickerPreset.adaptive.dropFirst()).allSatisfy {
            $1.dimension <= $0.dimension && ($1.dimension < $0.dimension || $1.fps <= $0.fps)
        })
        // Dense art needs the 300 @ 4 floor, which `validateAnimatedRenditionTiming` accepts; below
        // it the export gives up its motion rather than its existence.
        #expect(SystemStickerPreset.adaptive.last == .init(dimension: 300, fps: 4))
        #expect(SystemStickerPreset.adaptive.allSatisfy { $0.fps >= 4 })
        // Colour is spent inside a rung instead of being a rung, so every attempt in a rung reuses
        // the frames the rung already rendered.
        #expect(SystemStickerPreset.paletteLadder.map(\.count) == [256, 256, 64, 64, 16, 16])
        #expect(SystemStickerPreset.paletteLadder.allSatisfy { $0.count <= 256 })
        // Richest first, so the first candidate still standing at the end of a rung is the best one
        // that fit.
        #expect(zip(SystemStickerPreset.paletteLadder, SystemStickerPreset.paletteLadder.dropFirst())
            .allSatisfy { $1.count <= $0.count })
        // Every dithered palette is backed by the same palette undithered, so breaking up banding
        // can never cost a sticker the rung it would otherwise have held.
        #expect(SystemStickerPreset.paletteLadder.allSatisfy { attempt in
            !attempt.dithered || SystemStickerPreset.paletteLadder
                .contains { $0.count == attempt.count && !$0.dithered }
        })
    }

    @Test("Millisecond APNG delays land on the exact cycle a 24 FPS grid describes")
    func apngDelayGrid() {
        // 1/24 s is not a whole millisecond. Rounding each frame to 42 ms would run a 192-frame
        // cycle 64 ms long, which is more than the server's tolerance and would reject every
        // rendition of a full-length animation.
        let delays = StickerExportMetadataPolicy.apngFrameDelays(frameCount: 192, fps: 24, holdSeconds: 0.6)
        #expect(delays.count == 192)
        #expect(abs(delays.reduce(0, +) - 8.6) < 0.000_001)
        #expect(delays.allSatisfy { abs($0 * 1000 - ($0 * 1000).rounded()) < 0.000_001 })

        let plain = StickerExportMetadataPolicy.apngFrameDelays(frameCount: 60, fps: 30)
        #expect(abs(plain.reduce(0, +) - 2) < 0.000_001)
    }

    @Test("Export selections name the files they hand over")
    func exportSelections() {
        #expect(StickerExportSelection.sticker.includesSticker)
        #expect(!StickerExportSelection.sticker.includesVideo)
        #expect(StickerExportSelection.video.includesVideo)
        #expect(!StickerExportSelection.video.includesSticker)
        #expect(StickerExportSelection.both.includesSticker && StickerExportSelection.both.includesVideo)
        // A static sticker has no video to describe, and the picker that would offer one is hidden.
        #expect(StickerExportSelection.video.detail(isAnimated: false)
            == StickerExportSelection.sticker.detail(isAnimated: false))
    }

    @Test("Centisecond delays preserve a 30 FPS cycle duration")
    func centisecondTiming() {
        // A coarser grid than the APNG encoder's own millisecond one, kept under test because it is
        // where cumulative rounding is easiest to get wrong: 30 FPS does not divide 100 evenly.
        let delays = StickerExportMetadataPolicy.frameDelays(frameCount: 60, fps: 30, ticksPerSecond: 100)
        #expect(delays.count == 60)
        #expect(delays.filter { abs($0 - 0.03) < 0.000_001 }.count == 40)
        #expect(delays.filter { abs($0 - 0.04) < 0.000_001 }.count == 20)
        #expect(abs(delays.reduce(0, +) - 2) < 0.000_001)
    }

    @Test("The loop hold lingers on the last frame without adding one")
    func loopHoldTiming() {
        let held = StickerExportMetadataPolicy.frameDelays(frameCount: 60, fps: 30, holdSeconds: 0.6, ticksPerSecond: 100)
        let plain = StickerExportMetadataPolicy.frameDelays(frameCount: 60, fps: 30, ticksPerSecond: 100)
        // Same grid: a hold is display time on a frame that already exists, never an extra frame.
        #expect(held.count == plain.count)
        #expect(Array(held.dropLast()) == Array(plain.dropLast()))
        #expect(abs(held[59] - (plain[59] + 0.6)) < 0.000_001)
        #expect(abs(held.reduce(0, +) - 2.6) < 0.000_001)

        // A play-once export has no repeat to separate, so it is never held.
        #expect(StickerExportMetadataPolicy.holdSeconds(for: .once) == 0)
        #expect(StickerExportMetadataPolicy.holdSeconds(for: .loop) == StickerExportMetadataPolicy.loopHoldSeconds)
        #expect(StickerExportMetadataPolicy.holdSeconds(for: .pingPong) == StickerExportMetadataPolicy.loopHoldSeconds)
    }

    @Test("Rendered duration is the motion cycle plus the hold, and the frame grid is unchanged")
    func renderedDurationIncludesHold() {
        let layer = AnimatedLayer.shape(.init(
            base: .init(id: "shape", name: "Shape"),
            shape: .circle,
            fill: .solid("#FFFFFF")
        ))
        let pingPong = AnimatedDocument(kind: .animated, durationSeconds: 2, fps: 30, loop: .pingPong, layers: [layer])
        let once = AnimatedDocument(kind: .animated, durationSeconds: 2, fps: 30, loop: .once, layers: [layer])

        #expect(abs(StickerExportMetadataPolicy.renderedDuration(pingPong) - 4.6) < 0.000_001)
        #expect(abs(StickerExportMetadataPolicy.renderedDuration(once) - 2) < 0.000_001)
        // The server recovers the grid by dividing frames by the cycle, so this must not move.
        #expect(StickerExportMetadataPolicy.frameCount(document: pingPong, fps: 30) == 120)
    }

    @Test("Empty resumed terminal SSE responses stop reconnecting")
    func terminalSSEState() {
        #expect(SSEStreamTermination.isTerminal(jobState: "succeeded"))
        #expect(SSEStreamTermination.isTerminal(jobState: "failed"))
        #expect(!SSEStreamTermination.isTerminal(jobState: "running"))
    }
}

@Suite("Shared OAuth storage and refresh")
struct SharedAuthenticationTests {
    @Test("Extension ISO-8601 fractional date bundle decodes")
    func fractionalTokenBundle() throws {
        let bundle = try TokenBundleCodec.decode(Data("""
        {"accessToken":"a.b.c","refreshToken":"refresh","idToken":"id","expiresAt":"2030-01-02T03:04:05.123Z","subject":"user-a"}
        """.utf8))
        #expect(bundle.subject == "user-a")
        #expect(bundle.refreshToken == "refresh")
    }

    @Test("RxAuth callbacks expose no half-rotated bundle and hide refresh from its timer")
    func atomicRxAuthStorageCommit() throws {
        let old = SharedTokenBundle(
            accessToken: "old",
            refreshToken: "old-refresh",
            idToken: "old-id",
            expiresAt: .distantFuture,
            subject: "user-a"
        )
        let vault = InMemoryTokenVault(old)
        let storage = RxAuthSharedTokenStorage(vault: vault, processLockURL: uniqueLockURL())
        let access = try jwt(subject: "user-a", expiresAt: Date().addingTimeInterval(3_600))

        try storage.saveAccessToken(access)
        #expect(try vault.load() == old)
        try storage.saveRefreshToken("new-refresh")
        #expect(try vault.load() == old)
        try storage.saveExpiresAt(Date().addingTimeInterval(3_600))

        #expect(try vault.load()?.accessToken == access)
        #expect(try vault.load()?.refreshToken == "new-refresh")
        #expect(storage.getRefreshToken() == nil)
    }

    @Test("Subject changes never combine a new access token with the prior account")
    func subjectChangeIsAtomic() throws {
        let old = SharedTokenBundle(
            accessToken: "old",
            refreshToken: "user-a-refresh",
            idToken: "user-a-id",
            expiresAt: .distantFuture,
            subject: "user-a"
        )
        let vault = InMemoryTokenVault(old)
        let storage = RxAuthSharedTokenStorage(vault: vault, processLockURL: uniqueLockURL())
        let access = try jwt(subject: "user-b", expiresAt: Date().addingTimeInterval(3_600))

        try storage.saveAccessToken(access)
        #expect(try vault.load() == old)
        try storage.saveRefreshToken("user-b-refresh")
        try storage.saveExpiresAt(Date().addingTimeInterval(3_600))

        let loaded = try vault.load()
        let committed = try #require(loaded)
        #expect(committed.subject == "user-b")
        #expect(committed.refreshToken == "user-b-refresh")
        #expect(committed.idToken == nil)
    }

    @Test("Concurrent callers rotate a refresh token only once")
    func concurrentRefreshIsSerialized() async throws {
        let vault = InMemoryTokenVault(.init(
            accessToken: "expired", refreshToken: "refresh-1", idToken: nil,
            expiresAt: .distantPast, subject: "user-a"
        ))
        let response = OAuthRefreshResponse(
            accessToken: try jwt(subject: "user-a", expiresAt: Date().addingTimeInterval(3_600)),
            refreshToken: "refresh-2",
            idToken: nil,
            expiresIn: 3_600
        )
        let transport = CountingRefreshTransport(response: response)
        let broker = SharedTokenBroker(
            vault: vault,
            transport: transport,
            tokenURL: URL(string: "https://auth.example/token")!,
            clientID: "ios",
            lockURL: uniqueLockURL()
        )

        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 { group.addTask { try await broker.validAccessToken() } }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        let calls = transport.callCount()

        #expect(Set(values) == Set([response.accessToken]))
        #expect(calls == 1)
        #expect(try vault.load()?.refreshToken == "refresh-2")
    }

    @Test("Logout waits for an in-flight cross-process rotation, then clears")
    func logoutWinsRefreshRace() async throws {
        let vault = InMemoryTokenVault(.init(
            accessToken: "expired", refreshToken: "refresh-1", idToken: nil,
            expiresAt: .distantPast, subject: "user-a"
        ))
        let response = OAuthRefreshResponse(accessToken: "new-access", refreshToken: "refresh-2", idToken: nil, expiresIn: 3_600)
        let transport = CountingRefreshTransport(response: response, delay: .milliseconds(60))
        let broker = SharedTokenBroker(
            vault: vault,
            transport: transport,
            tokenURL: URL(string: "https://auth.example/token")!,
            clientID: "ios",
            lockURL: uniqueLockURL()
        )

        let refresh = Task { try await broker.validAccessToken() }
        try await Task.sleep(for: .milliseconds(10))
        try await broker.logout()
        do {
            _ = try await refresh.value
            #expect(Bool(false), "An API caller must not escape with a rotated token after logout starts")
        } catch {
            #expect(error as? TokenBrokerError == .missingSession)
        }

        #expect(try vault.load() == nil)
    }

    @Test("Rejected refresh clears the session and emits expiry")
    func rejectedRefreshRevokesSession() async throws {
        let vault = InMemoryTokenVault(.init(
            accessToken: "expired", refreshToken: "refresh", idToken: nil,
            expiresAt: .distantPast, subject: "user-a"
        ))
        let probe = NotificationProbe()
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name("rxAuthSessionExpired"),
            object: nil,
            queue: nil
        ) { _ in probe.mark() }
        defer { NotificationCenter.default.removeObserver(token) }
        let broker = SharedTokenBroker(
            vault: vault,
            transport: RejectingRefreshTransport(),
            tokenURL: URL(string: "https://auth.example/token")!,
            clientID: "ios",
            lockURL: uniqueLockURL()
        )

        do {
            _ = try await broker.validAccessToken()
            #expect(Bool(false), "A rejected refresh must throw")
        } catch {
            #expect(error as? TokenBrokerError == .refreshRejected(400))
        }
        #expect(try vault.load() == nil)
        #expect(probe.value == 1)
    }

    @Test("Production storage has no private-Keychain or temporary-lock fallback")
    func sharedConfigurationFailsClosed() throws {
        let vault = SharedKeychainTokenVault(service: "test", account: UUID().uuidString, accessGroup: nil, allowUnsharedFallback: false)
        #expect(throws: TokenVaultError.self) { try vault.load() }
        let temporary = FileManager.default.temporaryDirectory
        #expect(SharedTokenBroker.lockURL(containerURL: nil, temporaryDirectory: temporary, allowTemporaryFallback: false) == nil)
        #expect(SharedTokenBroker.lockURL(containerURL: nil, temporaryDirectory: temporary, allowTemporaryFallback: true) != nil)
    }
}
