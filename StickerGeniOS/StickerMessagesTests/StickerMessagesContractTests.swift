import Foundation
import Messages
import Testing
import UIKit
@testable import StickerMessages

@Suite("Messages shared contracts")
struct StickerMessagesContractTests {
    @Test("Main and extension token codecs are bidirectional")
    func tokenCodecCompatibility() throws {
        let expiration = Date(timeIntervalSince1970: 1_893_459_845)
        let extensionBundle = SharedTokenBundle(
            accessToken: "fixture.header.payload.signature",
            refreshToken: "rotating-refresh-token",
            idToken: "fixture.id.token",
            expiresAt: expiration,
            subject: "fixture-user"
        )

        let extensionEncoded = try JSONEncoder().encode(extensionBundle)
        let mainDecoder = JSONDecoder()
        mainDecoder.dateDecodingStrategy = .iso8601
        let decodedByMain = try mainDecoder.decode(MainTokenBundle.self, from: extensionEncoded)
        #expect(decodedByMain.accessToken == extensionBundle.accessToken)
        #expect(decodedByMain.expiresAt == expiration)

        let mainEncoder = JSONEncoder()
        mainEncoder.dateEncodingStrategy = .iso8601
        let mainEncoded = try mainEncoder.encode(decodedByMain)
        let decodedByExtension = try JSONDecoder().decode(SharedTokenBundle.self, from: mainEncoded)
        #expect(decodedByExtension == extensionBundle)
    }

    @Test("System renditions stay below the conservative 500 KB threshold")
    func systemRenditionLimit() {
        #expect(SharedStickerCache.maximumByteCount == 500_000)
    }

    @Test("Rapid duplicate sticker insertions are suppressed without throttling other stickers")
    func duplicateStickerInsertionsAreSuppressed() {
        let first = URL(fileURLWithPath: "/tmp/first.png")
        let second = URL(fileURLWithPath: "/tmp/second.png")
        var gate = StickerInsertGate()

        // Each result is bound before it reaches `#expect`: the macro expands its argument into a
        // closure, and calling a `mutating` member on a captured `var` there does not compile.
        let acceptsFirst = gate.shouldInsert(stickerURL: first, uptime: 10)
        let rejectsRepeat = gate.shouldInsert(stickerURL: first, uptime: 10.2)
        let acceptsOther = gate.shouldInsert(stickerURL: second, uptime: 10.3)
        let acceptsAfterWindow = gate.shouldInsert(stickerURL: first, uptime: 10.7)

        #expect(acceptsFirst)
        #expect(!rejectsRepeat)
        #expect(acceptsOther)
        #expect(acceptsAfterWindow)

        // The full-size surface adds a second, longer-lived gate on top of this one: a download
        // outlives the 0.6 s window, so this alone cannot dedupe taps there.
    }

    @Test("Only PNG, APNG, and GIF cache formats are accepted")
    func supportedCacheFormats() throws {
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(try SharedStickerCache.validatedFileExtension(for: pngHeader, declaredMimeType: "image/png") == "png")

        let gifHeader = Data("GIF89a".utf8)
        #expect(try SharedStickerCache.validatedFileExtension(for: gifHeader, declaredMimeType: "image/gif") == "gif")

        let jpegHeader = Data([0xFF, 0xD8, 0xFF])
        #expect(throws: StickerCacheError.self) {
            try SharedStickerCache.validatedFileExtension(for: jpegHeader, declaredMimeType: "image/jpeg")
        }
    }

    /// The one format the two caches disagree about, and the disagreement is Apple's:
    /// `MSSticker.h` takes a file conforming to `kUTTypePNG`, `kUTTypeGIF` or `kUTTypeJPEG`, and
    /// `org.webmproject.webp` conforms to none of them. So a WebP is a legitimate `.image`
    /// attachment and never a sticker, and the gate has to say so where the bytes land rather than
    /// leaving an `MSSticker` to fail to initialise later.
    @Test("WebP is cacheable for full-size sends and refused for Messages stickers")
    func webPIsFullSizeOnly() throws {
        var header = Data("RIFF".utf8)
        header.append(contentsOf: [0x24, 0x00, 0x00, 0x00])
        header.append(Data("WEBPVP8 ".utf8))

        #expect(try SharedStickerCache.validatedFileExtension(
            for: header, declaredMimeType: "image/webp", policy: .fullSize
        ) == "webp")

        #expect(throws: StickerCacheError.self) {
            try SharedStickerCache.validatedFileExtension(
                for: header, declaredMimeType: "image/webp", policy: .systemSticker
            )
        }
        // The default is the stricter policy, so a caller that forgets to say gets the sticker
        // cache's rules rather than the permissive ones.
        #expect(throws: StickerCacheError.self) {
            try SharedStickerCache.validatedFileExtension(for: header, declaredMimeType: "image/webp")
        }
        // A RIFF container that is not WebP is not a WebP.
        var riffOnly = Data("RIFF".utf8)
        riffOnly.append(contentsOf: [0x24, 0x00, 0x00, 0x00])
        riffOnly.append(Data("WAVEfmt ".utf8))
        #expect(throws: StickerCacheError.self) {
            try SharedStickerCache.validatedFileExtension(
                for: riffOnly, declaredMimeType: "image/webp", policy: .fullSize
            )
        }
    }

    @Test("System cache rejects non-preset and non-square local images")
    func strictSystemStickerDimensions() throws {
        let valid = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).pngData { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }
        try SharedStickerCache.validateImage(valid)

        let unsupported = UIGraphicsImageRenderer(size: CGSize(width: 301, height: 301)).pngData { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 301, height: 301))
        }
        #expect(throws: StickerCacheError.self) { try SharedStickerCache.validateImage(unsupported) }

        let nonsquare = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 408)).pngData { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 408))
        }
        #expect(throws: StickerCacheError.self) { try SharedStickerCache.validateImage(nonsquare) }
    }

    @Test("Concurrent extension callers share one detached refresh rotation")
    func concurrentRefreshIsSerialized() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let storage = MessagesInMemoryTokenStorage(.init(
            accessToken: "expired",
            refreshToken: "refresh-1",
            idToken: nil,
            expiresAt: now.addingTimeInterval(-10),
            subject: "user-a"
        ))
        let response = RefreshTokenResponse(
            accessToken: try messagesJWT(subject: "user-a", expiration: now.addingTimeInterval(3_600)),
            refreshToken: "refresh-2",
            idToken: nil,
            expiresIn: 3_600
        )
        let transport = MessagesCountingRefreshTransport(response: response)
        let broker = SharedTokenBroker(
            configuration: .init(tokenURL: URL(string: "https://auth.example/token")!, clientID: "ios", accessGroup: "test"),
            storage: storage,
            transport: transport,
            now: { now },
            lockURL: FileManager.default.temporaryDirectory.appending(path: "messages-refresh-\(UUID().uuidString).lock")
        )

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 {
                group.addTask { try await broker.authenticatedSession().accessToken }
            }
            var values: [String] = []
            for try await token in group { values.append(token) }
            return values
        }

        #expect(Set(tokens) == [response.accessToken])
        #expect(await transport.callCount() == 1)
        #expect(try storage.read()?.refreshToken == "refresh-2")
    }

    @Test("Messages library follows every cursor before returning a sync snapshot")
    func libraryPagination() async throws {
        let transport = PaginatedStickerTransport()
        let client = StickerLibraryClient(baseURL: URL(string: "https://api.example/")!, transport: transport)
        let stickers = try await client.fetchLibrary(accessToken: "access")

        #expect(Set(stickers.map(\.stickerID)) == ["sticker-1", "sticker-2"])
        #expect(await transport.requestedCursors() == ["<first>", "page-2"])
    }

    @Test("A partial live sync fails atomically so the service can keep its offline cache")
    func partialLibraryFailureDoesNotReturnPartialState() async {
        let transport = FailingSecondPageTransport()
        let client = StickerLibraryClient(baseURL: URL(string: "https://api.example/")!, transport: transport)
        do {
            _ = try await client.fetchLibrary(accessToken: "access")
            #expect(Bool(false), "A partial fetch must not look like a complete library")
        } catch {
            #expect(error is URLError)
        }
        #expect(await transport.callCount() == 2)
    }

    @MainActor
    @Test("Grid routes taps to an injectable insert handler and manages the animation lifecycle")
    func stickerGridRoutesTapsToInsertHandler() throws {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).pngData { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "messages-grid-\(UUID().uuidString).png")
        try data.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let controller = StickerGridViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        controller.loadViewIfNeeded()

        var inserted: [String] = []
        // The seam that stands in for MSConversation, which is unavailable in a unit test.
        controller.onSelect = { inserted.append($0.localizedDescription) }

        controller.replaceStickers(with: [
            .init(stickerID: "sticker", assetID: "asset", title: "Purple", fileURL: fileURL, updatedAt: Date())
        ])
        controller.view.layoutIfNeeded()

        #expect(controller.view.accessibilityIdentifier == "sticker-factory-messages-browser")
        #expect(controller.stickerCount == 1)

        controller.selectSticker(at: 0)
        #expect(inserted == ["Purple"])
        controller.selectSticker(at: 99)
        #expect(inserted == ["Purple"])

        let indexPath = IndexPath(item: 0, section: 0)
        // Through the collection view's own data source: the grid is diffable now, so the
        // controller no longer implements `cellForItemAt` itself.
        let cell = try #require(
            controller.collectionView.dataSource?
                .collectionView(controller.collectionView, cellForItemAt: indexPath) as? StickerCell
        )
        #expect(cell.accessibilityLabel == "Purple")
        #expect(cell.isAccessibilityElement)
        #expect(cell.displayedStickerFileURL == fileURL)

        // Assert our tracked intent, not MSStickerView.isAnimating(): a static PNG has an
        // animationDuration of zero and reports false even after startAnimating().
        controller.resumeAnimations()
        controller.collectionView(controller.collectionView, willDisplay: cell, forItemAt: indexPath)
        #expect(cell.animationRequested)
        controller.collectionView(controller.collectionView, didEndDisplaying: cell, forItemAt: indexPath)
        #expect(!cell.animationRequested)

        controller.collectionView(controller.collectionView, willDisplay: cell, forItemAt: indexPath)
        cell.prepareForReuse()
        #expect(!cell.animationRequested)
        #expect(cell.displayedStickerFileURL == nil)
        // Peel/drag stays owned by MSStickerView and remains part of the real-device check.
    }

    @MainActor
    @Test("Static sticker cells suppress native taps across layout, send-mode changes, and reuse")
    func staticStickerCellHasOneTapPath() throws {
        let fileURL = try Self.writeStickerPNG()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let sticker = try MSSticker(contentsOfFileURL: fileURL, localizedDescription: "Static")
        let cell = StickerCell(frame: CGRect(x: 0, y: 0, width: 84, height: 84))
        cell.configure(with: sticker) {}
        let stickerView = try #require(cell.contentView.subviews.compactMap { $0 as? MSStickerView }.first)
        #expect(stickerView.gestureRecognizers?.filter { $0 is UITapGestureRecognizer && $0.isEnabled }.count == 1)

        // Model a native recognizer installed after initial configuration. Layout must
        // suppress it, and switching back from image mode must not re-enable it.
        let nativeTap = UITapGestureRecognizer()
        let nativeDrag = UILongPressGestureRecognizer()
        stickerView.addGestureRecognizer(nativeTap)
        stickerView.addGestureRecognizer(nativeDrag)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        #expect(!nativeTap.isEnabled)
        #expect(nativeDrag.isEnabled)

        cell.setPeelDragEnabled(false)
        #expect(!nativeTap.isEnabled)
        #expect(!nativeDrag.isEnabled)
        cell.setPeelDragEnabled(true)
        #expect(!nativeTap.isEnabled)
        #expect(nativeDrag.isEnabled)

        cell.prepareForReuse()
        cell.configure(with: sticker) {}
        #expect(!nativeTap.isEnabled)
        let activeTaps = (stickerView.gestureRecognizers ?? []).filter {
            $0 is UITapGestureRecognizer && $0.isEnabled
        }
        #expect(activeTaps.count == 1)
        let customTap = try #require(activeTaps.first)
        #expect(customTap.cancelsTouchesInView)
        #expect(!cell.gestureRecognizer(customTap, shouldRecognizeSimultaneouslyWith: nativeTap))
        #expect(cell.gestureRecognizer(customTap, shouldRecognizeSimultaneouslyWith: nativeDrag))
    }

    @Test("Sectioned library fetch groups stickers and stamps their pack byline")
    func fetchSectionsGroupsByPack() async throws {
        let transport = SectionedStickerTransport()
        let client = StickerLibraryClient(
            baseURL: URL(string: "https://api.example/")!,
            transport: transport,
            appVersion: "1.2.3",
            acceptLanguage: "zh-Hans-CN"
        )
        let descriptors = try await client.fetchSections(accessToken: "access")

        #expect(descriptors.map(\.stickerID) == ["mine-1", "borrowed-1", "borrowed-2"])
        #expect(descriptors[0].sectionID == "mine")
        #expect(descriptors[0].sectionTitle == "My Stickers")
        #expect(descriptors[0].sectionSubtitle == nil)
        #expect(descriptors[1].sectionID == "pack:p1")
        #expect(descriptors[1].sectionSubtitle == "by Mika Lin")
        // Section and item order come from the response, not from updatedAt.
        #expect(descriptors[1].sectionPosition == 1)
        #expect(descriptors[2].position == 1)
        #expect(await transport.requestedAppVersions() == ["1.2.3"])
        #expect(await transport.requestedLanguages() == ["zh-Hans-CN"])
    }

    @Test("A server with no sections endpoint falls back to the flat library")
    func fetchSectionsFallsBackOn404() async throws {
        // The extension ships inside the app binary and can be newer than the server it talks to.
        let transport = SectionsMissingTransport()
        let client = StickerLibraryClient(baseURL: URL(string: "https://api.example/")!, transport: transport)
        let descriptors = try await client.fetchSections(accessToken: "access")

        #expect(descriptors.map(\.stickerID) == ["sticker-1"])
        #expect(descriptors[0].sectionID == "mine")
        #expect(await transport.paths() == ["/api/v1/library/sections", "/api/v1/stickers"])
    }

    @Test("A listing rejection preserves the server message")
    func listingRejectionPreservesServerMessage() async {
        let client = StickerLibraryClient(
            baseURL: URL(string: "https://api.example/")!,
            transport: RejectedListingTransport(),
            appVersion: "1.0",
            acceptLanguage: "en-US"
        )

        do {
            _ = try await client.fetchSections(accessToken: "access")
            #expect(Bool(false), "The rejected listing must throw")
        } catch let error as StickerLibraryError {
            #expect(error.localizedDescription == "Update Winky Sticker Factory to version 1.2 or later to view your stickers.")
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @MainActor
    @Test("Grid draws one section per pack and routes taps by index path")
    func stickerGridGroupsSections() throws {
        let fileURL = try Self.writeStickerPNG()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let controller = StickerGridViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        controller.loadViewIfNeeded()
        var inserted: [String] = []
        controller.onSelect = { inserted.append($0.localizedDescription) }

        controller.replaceSections(with: [
            .init(id: "mine", title: "My Stickers", subtitle: nil, stickers: [
                .init(stickerID: "own", assetID: "a1", title: "Mine", fileURL: fileURL, updatedAt: Date())
            ]),
            .init(id: "pack:p1", title: "Cozy Cats", subtitle: "by Mika Lin", stickers: [
                .init(stickerID: "borrowed", assetID: "a2", title: "Loaf", fileURL: fileURL, updatedAt: Date())
            ])
        ])
        controller.view.layoutIfNeeded()

        #expect(controller.collectionView.numberOfSections == 2)
        #expect(controller.stickerCount == 2)

        controller.selectSticker(at: IndexPath(item: 0, section: 1))
        #expect(inserted == ["Loaf"])
        // The flat form still addresses the whole grid, in display order.
        controller.selectSticker(at: 0)
        #expect(inserted == ["Loaf", "Mine"])
        controller.selectSticker(at: IndexPath(item: 5, section: 9))
        #expect(inserted == ["Loaf", "Mine"])

        let header = try #require(
            controller.collectionView.dataSource?.collectionView?(
                controller.collectionView,
                viewForSupplementaryElementOfKind: UICollectionView.elementKindSectionHeader,
                at: IndexPath(item: 0, section: 1)
            ) as? StickerSectionHeaderView
        )
        #expect(header.accessibilityLabel == "Cozy Cats, by Mika Lin")
    }

    @MainActor
    @Test("An empty pack section is not drawn as a bare header")
    func stickerGridDropsEmptySections() throws {
        let fileURL = try Self.writeStickerPNG()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let controller = StickerGridViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        controller.loadViewIfNeeded()
        // A pack whose members all fell back to draft still arrives, so the cache can reconcile
        // it — but there is nothing to draw under its header.
        controller.replaceSections(with: [
            .init(id: "mine", title: "My Stickers", subtitle: nil, stickers: [
                .init(stickerID: "own", assetID: "a1", title: "Mine", fileURL: fileURL, updatedAt: Date())
            ]),
            .init(id: "pack:hollow", title: "Hollow", subtitle: "by Someone", stickers: [])
        ])
        controller.view.layoutIfNeeded()

        #expect(controller.collectionView.numberOfSections == 1)
        #expect(controller.stickerCount == 1)
    }

    @MainActor
    @Test("A tap after a refresh inserts the sticker now on screen, not the one that was")
    func stickerGridTapSurvivesReload() throws {
        let fileURL = try Self.writeStickerPNG()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let controller = StickerGridViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        controller.loadViewIfNeeded()
        var inserted: [String] = []
        controller.onSelect = { inserted.append($0.localizedDescription) }

        controller.replaceStickers(with: [
            .init(stickerID: "first", assetID: "a1", title: "First", fileURL: fileURL, updatedAt: Date())
        ])
        controller.view.layoutIfNeeded()
        // Cells capture an item id rather than an index path, which goes stale the moment a
        // snapshot is applied.
        controller.replaceStickers(with: [
            .init(stickerID: "second", assetID: "a2", title: "Second", fileURL: fileURL, updatedAt: Date()),
            .init(stickerID: "first", assetID: "a1", title: "First", fileURL: fileURL, updatedAt: Date())
        ])
        controller.view.layoutIfNeeded()

        let cell = try #require(
            controller.collectionView.dataSource?
                .collectionView(controller.collectionView, cellForItemAt: IndexPath(item: 0, section: 0)) as? StickerCell
        )
        #expect(cell.accessibilityLabel == "Second")
        controller.selectSticker(at: 0)
        #expect(inserted == ["Second"])
    }

    @MainActor
    private static func writeStickerPNG() throws -> URL {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).pngData { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "messages-grid-\(UUID().uuidString).png")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    @Test("An offline extension stops offering a pack the user already removed")
    func allowlistFiltersCachedSections() {
        let sections: [StickerSection] = [
            .init(id: "mine", title: "My Stickers", subtitle: nil, stickers: []),
            .init(id: "pack:kept", title: "Kept", subtitle: "by A", stickers: []),
            .init(id: "pack:removed", title: "Removed", subtitle: "by B", stickers: [])
        ]

        // No allowlist means no opinion: the cache is served exactly as before.
        #expect(SharedSectionAllowlist.filter(sections, allowed: nil).count == 3)

        let filtered = SharedSectionAllowlist.filter(sections, allowed: ["mine", "pack:kept"])
        #expect(filtered.map(\.id) == ["mine", "pack:kept"])
    }

    @Test("Insert failures in a non-Messages host surface the peel/drag hint")
    func insertPolicyMapsContextRejectionToDragHint() {
        #expect(StickerInsertPolicy.outcome(domain: nil, code: nil) == .inserted)
        #expect(StickerInsertPolicy.outcome(
            domain: MSMessagesErrorDomain,
            code: MSMessageErrorCode.apiUnavailableInPresentationContext.rawValue
        ) == .unavailableInContext)
        #expect(StickerInsertPolicy.outcome(
            domain: MSStickersErrorDomain,
            code: MSMessageErrorCode.apiUnavailableInPresentationContext.rawValue
        ) == .unavailableInContext)
        #expect(StickerInsertPolicy.outcome(
            domain: MSStickersErrorDomain,
            code: MSMessageErrorCode.stickerFileImproperFileSize.rawValue
        ) == .failed)

        #expect(StickerInsertPolicy.hint(for: .inserted, context: .media) == nil)
        #expect(StickerInsertPolicy.hint(for: .noConversation, context: .media)?
            .contains("Press and hold") == true)
        #expect(StickerInsertPolicy.hint(for: .unavailableInContext, context: .messages)?
            .contains("Press and hold") == true)
    }

    // MARK: - Full-size rendition

    @Test("Adding a full-size policy leaves the Messages cache contract untouched")
    func systemCachePolicyIsUnchanged() {
        #expect(StickerCachePolicy.systemSticker.maximumByteCount == 500_000)
        #expect(StickerCachePolicy.systemSticker.allowedPixelDimensions == [300, 408, 618])
        #expect(StickerCachePolicy.systemSticker.maximumPixelDimension == 618)
        #expect(StickerCachePolicy.systemSticker.requiresSquare)
        // No directory budget: the system cache is bounded by the library itself, and evicting
        // from it would silently blank stickers the grid is about to draw.
        #expect(StickerCachePolicy.systemSticker.maximumTotalByteCount == nil)
        #expect(StickerCachePolicy.systemSticker.directoryName == "StickerFactoryMessages")

        // The statics the client and this suite read must keep tracking the policy.
        #expect(SharedStickerCache.maximumByteCount == StickerCachePolicy.systemSticker.maximumByteCount)
        #expect(SharedStickerCache.maximumPixelDimension == StickerCachePolicy.systemSticker.maximumPixelDimension)
        #expect(SharedStickerCache.allowedPixelDimensions == StickerCachePolicy.systemSticker.allowedPixelDimensions)

        // Two directories, or the two caches would overwrite each other's index.
        #expect(StickerCachePolicy.fullSize.directoryName != StickerCachePolicy.systemSticker.directoryName)
    }

    @Test("The full-size policy accepts large and non-square images the sticker policy rejects")
    func fullSizePolicyAcceptsLargeNonSquareImages() throws {
        func png(_ width: Int, _ height: Int) -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).pngData { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
        }

        try SharedStickerCache.validateImage(png(1024, 1024), policy: .fullSize)
        // Non-square is legitimate here: nothing crops a message attachment to a sticker.
        try SharedStickerCache.validateImage(png(1024, 768), policy: .fullSize)
        try SharedStickerCache.validateImage(png(300, 300), policy: .fullSize)

        #expect(throws: StickerCacheError.self) {
            try SharedStickerCache.validateImage(png(2048, 2048), policy: .fullSize)
        }

        // The bare overload must still mean exactly what it meant before the policy existed.
        #expect(throws: StickerCacheError.self) { try SharedStickerCache.validateImage(png(1024, 1024)) }
        #expect(throws: StickerCacheError.self) { try SharedStickerCache.validateImage(png(1024, 768)) }
    }

    @Test("previewAsset becomes a full-size rendition only when it is worth downloading")
    func previewAssetDecodesIntoFullSizeRendition() async throws {
        let transport = PreviewAssetTransport()
        let client = StickerLibraryClient(baseURL: URL(string: "https://api.example/")!, transport: transport)
        let byID = Dictionary(
            uniqueKeysWithValues: try await client.fetchSections(accessToken: "access").map { ($0.stickerID, $0) }
        )

        let full = try #require(byID["full"]?.fullSize)
        #expect(full.assetID == "master-1")
        #expect(full.width == 1024)
        #expect(!full.isSystemAssetFallback)

        // A server that never learned the field, and one that has nothing bigger to offer.
        #expect(byID["no-preview"]?.fullSize == nil)

        // The animated chain coalesced down to the system asset: cached already, nothing to fetch.
        let fallback = try #require(byID["fallback"]?.fullSize)
        #expect(fallback.isSystemAssetFallback)
        #expect(fallback.assetID == byID["fallback"]?.assetID)

        // Not ready, oversized, and over-budget all fail closed rather than becoming a doomed tap.
        #expect(byID["pending"]?.fullSize == nil)
        #expect(byID["huge-pixels"]?.fullSize == nil)
        #expect(byID["huge-bytes"]?.fullSize == nil)

        // The sticker itself still appears in every one of those cases.
        #expect(byID.count == 10)
    }

    /// An image send resolves one rendition or attaches the cached sticker file. There is no ladder
    /// to walk: Small/Medium/Large stood here once and could not work, because `insertAttachment`
    /// scales an image attachment to a fixed bubble width and ignores its pixel dimensions
    /// entirely. Physical size is now the Sticker/Image choice, not a rendition.
    @Test("An image send resolves the one rendition, or nothing at all")
    func imageSendResolvesTheSingleRendition() async throws {
        let transport = PreviewAssetTransport()
        let client = StickerLibraryClient(baseURL: URL(string: "https://api.example/")!, transport: transport)
        let byID = Dictionary(
            uniqueKeysWithValues: try await client.fetchSections(accessToken: "access").map { ($0.stickerID, $0) }
        )

        let full = try #require(byID["full"])
        #expect(full.fullSizeDescriptor()?.assetID == "master-1")
        // Keyed apart from the system cache's entry for the same sticker, or the two would evict
        // each other from the same `(section, sticker)` pair.
        #expect(full.fullSizeDescriptor()?.variant == SystemStickerDescriptor.fullSizeVariant)

        // Nothing to fetch: the caller attaches the cached ≤500 KB rendition instead, which is a
        // legitimate send rather than a failed one.
        #expect(try #require(byID["no-preview"]).fullSizeDescriptor() == nil)
        // Coalesced onto the system asset, so it is already on disk and must not be downloaded
        // into the full-size cache a second time.
        #expect(try #require(byID["fallback"]).fullSizeDescriptor() == nil)
    }

    @Test("Only image types the cache can store survive as full-size renditions")
    func previewAssetWithUnsupportedMimeTypeIsIgnored() async throws {
        let transport = PreviewAssetTransport()
        let client = StickerLibraryClient(baseURL: URL(string: "https://api.example/")!, transport: transport)
        let byID = Dictionary(
            uniqueKeysWithValues: try await client.fetchSections(accessToken: "access").map { ($0.stickerID, $0) }
        )

        // JPEG has no magic-byte branch in `validatedFileExtension`, so offering it would download
        // bytes the full-size cache then refuses.
        #expect(byID["jpeg"]?.fullSize == nil)
        // WebP does have one, on the full-size side. The cache the file is bound for can store it,
        // so the offer is honourable.
        #expect(byID["webp"]?.fullSize?.mimeType == "image/webp")
        // GIF is a real animated sharing rendition and must survive.
        #expect(byID["gif"]?.fullSize?.mimeType == "image/gif")
    }

    /// The point of publishing a second container: a 9.8 MB APNG and a 410 KB WebP hold the same
    /// frames, and the one the person is waiting on should be the small one.
    @Test("A WebP rendition is preferred over the APNG, and falls back to it when unusable")
    func webPRenditionIsPreferredWhenOffered() async throws {
        let transport = PreviewAssetTransport()
        let client = StickerLibraryClient(baseURL: URL(string: "https://api.example/")!, transport: transport)
        let byID = Dictionary(
            uniqueKeysWithValues: try await client.fetchSections(accessToken: "access").map { ($0.stickerID, $0) }
        )

        let preferred = try #require(byID["prefers-webp"]?.fullSize)
        #expect(preferred.assetID == "webp-11")
        #expect(preferred.mimeType == "image/webp")
        #expect(preferred.byteSize == 410_000)

        // Every gate fails closed *to the APNG* rather than to the ≤500 KB sticker file: the larger
        // download is still the right one when the smaller is not there to be had.
        let fallback = try #require(byID["webp-pending"]?.fullSize)
        #expect(fallback.assetID == "apng-12")
        #expect(fallback.mimeType == "image/png")

        // A sticker with no WebP at all is untouched by any of this.
        #expect(byID["sizes"]?.fullSize?.assetID == "apng-9")
    }

    @Test("The full-size descriptor swaps asset identity but keeps the sticker's placement")
    func fullSizeDescriptorSwapsAssetIdentityOnly() {
        var descriptor = SystemStickerDescriptor(
            stickerID: "s1",
            assetID: "system-1",
            title: "Wave",
            mimeType: "image/png",
            byteSize: 400_000,
            sha256: "system-sha",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        descriptor.sectionID = "pack:p1"
        descriptor.sectionTitle = "Cozy Cats"
        descriptor.sectionPosition = 2
        descriptor.position = 7
        descriptor.fullSize = FullSizeRendition(
            assetID: "master-1",
            mimeType: "image/png",
            byteSize: 3_000_000,
            sha256: "master-sha",
            width: 1024,
            height: 1024,
            isSystemAssetFallback: false
        )

        let full = try? #require(descriptor.fullSizeDescriptor())
        #expect(full?.assetID == "master-1")
        #expect(full?.byteSize == 3_000_000)
        #expect(full?.sha256 == "master-sha")
        // Placement is identity in the cache index — swapping it would file the copy under a
        // different sticker.
        #expect(full?.stickerID == "s1")
        #expect(full?.sectionID == "pack:p1")
        #expect(full?.position == 7)
        // Nothing to recurse into.
        #expect(full?.fullSize == nil)

        // Two files, so two cache entries: the full-size copy must not share the ≤500 KB
        // rendition's key, or one send would evict the other.
        #expect(full?.key != descriptor.key)
        #expect(full?.key.variant == SystemStickerDescriptor.fullSizeVariant)
        #expect(full?.key.stickerID == descriptor.key.stickerID)
        #expect(full?.key.sectionID == descriptor.key.sectionID)

        // A fallback has nothing to describe: its asset is the ≤500 KB file already on disk.
        descriptor.fullSize = FullSizeRendition(
            assetID: "system-1",
            mimeType: "image/png",
            byteSize: 400_000,
            sha256: "system-sha",
            width: 618,
            height: 618,
            isSystemAssetFallback: true
        )
        #expect(descriptor.fullSizeDescriptor() == nil)

        descriptor.fullSize = nil
        #expect(descriptor.fullSizeDescriptor() == nil)
    }

    @Test("The full-size surface never tells anyone to drag the small sticker in")
    func fullSizeHintNeverSuggestsPeelDrag() {
        for outcome in [StickerInsertOutcome.unavailableInContext, .noConversation, .failed] {
            for context in [MSMessagesAppPresentationContext.messages, .media] {
                let hint = StickerInsertPolicy.hint(for: outcome, context: context, surface: .fullSize)
                // Following that advice would insert the ≤500 KB MSSticker instead.
                #expect(hint?.contains("Press and hold") == false)
                #expect(hint?.isEmpty == false)
            }
        }
        #expect(StickerInsertPolicy.hint(for: .inserted, context: .messages, surface: .fullSize) == nil)

        // The sticker surface keeps its wording, including via the defaulted parameter.
        #expect(StickerInsertPolicy.hint(for: .noConversation, context: .media, surface: .sticker)?
            .contains("Press and hold") == true)
        #expect(
            StickerInsertPolicy.hint(for: .noConversation, context: .media)
                == StickerInsertPolicy.hint(for: .noConversation, context: .media, surface: .sticker)
        )
    }

    @Test("The download size gate is per call, not a single global ceiling")
    func downloadSizeGateIsPerCall() async throws {
        let transport = OversizedAssetTransport(byteCount: 1_000_000)
        let client = StickerLibraryClient(baseURL: URL(string: "https://api.example/")!, transport: transport)

        await #expect(throws: StickerLibraryError.self) {
            try await client.download(
                assetID: "a1",
                accessToken: "access",
                maximumByteCount: SharedStickerCache.maximumByteCount
            )
        }

        let rendition = try await client.download(
            assetID: "a1",
            accessToken: "access",
            maximumByteCount: StickerCachePolicy.fullSize.maximumByteCount
        )
        #expect(rendition.data.count == 1_000_000)
    }
}
