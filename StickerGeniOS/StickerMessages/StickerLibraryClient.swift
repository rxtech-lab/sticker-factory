import AnimatedView
import Foundation
import os

enum StickerLibraryError: Error, LocalizedError, Sendable {
    case invalidConfiguration
    case unauthorized
    case updateRequired(message: String)
    case server(statusCode: Int, message: String?)
    case invalidResponse
    case renditionTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            String(localized: "Sticker Factory's API address is not configured.")
        case .unauthorized:
            String(localized: "Your Sticker Factory sign-in has expired.")
        case .updateRequired(let message):
            message
        case .server(let statusCode, let message):
            message ?? String(localized: "Sticker Factory could not refresh the library (HTTP \(statusCode)).")
        case .invalidResponse:
            String(localized: "Sticker Factory returned an invalid library response.")
        case .renditionTooLarge:
            String(localized: "A downloaded sticker exceeds the Messages file-size limit.")
        }
    }
}

struct DownloadedRendition: Sendable {
    let data: Data
    let mimeType: String?
}

struct StickerLibraryClient: Sendable {
    static let maximumPageCount = 100
    private static let playbackLogger = Logger(subsystem: "app.rxlab.stickerfactory.message", category: "playback")

    private let baseURL: URL
    private let transport: any StickerHTTPTransport
    private let appVersion: String?
    private let acceptLanguage: String?

    init(bundle: Bundle = .main, session: URLSession = .shared) throws {
        guard let value = bundle.object(forInfoDictionaryKey: "StickerFactoryAPIBaseURL") as? String,
              !value.isEmpty,
              !value.contains("$("),
              let url = URL(string: value),
              Self.isAllowedBaseURL(url) else {
            throw StickerLibraryError.invalidConfiguration
        }
        baseURL = url
        transport = URLSessionStickerHTTPTransport(session: session)
        appVersion = Self.appVersion(in: bundle)
        acceptLanguage = Locale.preferredLanguages.first
    }

    private static func isAllowedBaseURL(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        #if DEBUG
        return url.scheme?.lowercased() == "http" && url.host?.lowercased() == "localhost"
        #else
        return false
        #endif
    }

    init(
        baseURL: URL,
        transport: any StickerHTTPTransport,
        appVersion: String? = nil,
        acceptLanguage: String? = Locale.preferredLanguages.first
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.appVersion = appVersion
        self.acceptLanguage = acceptLanguage
    }

    /// The sectioned library: the user's own published stickers, then each installed pack.
    ///
    /// One request, never paginated. The cache reconciles by removing whatever the response did
    /// not mention, so a pack split across a page boundary would read as a pack that lost half its
    /// stickers.
    ///
    /// Falls back to the legacy flat endpoint on 404: this extension ships inside the app binary
    /// and can be newer than the server it talks to.
    func fetchSections(accessToken: String) async throws -> [SystemStickerDescriptor] {
        var components = URLComponents(
            url: baseURL.appending(path: "api/v1/library/sections"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "status", value: "published")]
        guard let url = components?.url else {
            throw StickerLibraryError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addClientHeaders(to: &request)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let result = try await transport.data(for: request)
        if result.response.statusCode == 404 {
            return try await fetchLibrary(accessToken: accessToken)
        }
        try Self.validate(result)
        guard let payload = try? JSONDecoder().decode(LibrarySectionsDTO.self, from: result.data) else {
            throw StickerLibraryError.invalidResponse
        }
        return payload.descriptors()
    }

    /// The pre-marketplace flat library. Retained as the `fetchSections` fallback.
    func fetchLibrary(accessToken: String) async throws -> [SystemStickerDescriptor] {
        var cursor: String?
        var seenCursors = Set<String>()
        var descriptorsByStickerID: [String: SystemStickerDescriptor] = [:]

        for _ in 0..<Self.maximumPageCount {
            let page = try await fetchLibraryPage(accessToken: accessToken, cursor: cursor)
            for descriptor in page.items.compactMap(\.systemDescriptor) {
                descriptorsByStickerID[descriptor.stickerID] = descriptor
            }
            guard let nextCursor = page.nextCursor else {
                return descriptorsByStickerID.values.sorted { $0.updatedAt > $1.updatedAt }
            }
            guard !nextCursor.isEmpty, seenCursors.insert(nextCursor).inserted else {
                throw StickerLibraryError.invalidResponse
            }
            cursor = nextCursor
        }
        throw StickerLibraryError.invalidResponse
    }

    private func fetchLibraryPage(accessToken: String, cursor: String?) async throws -> StickerPageDTO {
        var components = URLComponents(
            url: baseURL.appending(path: "api/v1/stickers"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "status", value: "published"),
            URLQueryItem(name: "limit", value: "100")
        ]
        if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw StickerLibraryError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addClientHeaders(to: &request)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let result = try await transport.data(for: request)
        try Self.validate(result)
        guard let page = try? JSONDecoder().decode(StickerPageDTO.self, from: result.data) else {
            throw StickerLibraryError.invalidResponse
        }
        return page
    }

    /// The Messages rendition, held to Apple's sticker ceiling.
    func download(_ descriptor: SystemStickerDescriptor, accessToken: String) async throws -> DownloadedRendition {
        try await download(
            assetID: descriptor.assetID,
            accessToken: accessToken,
            maximumByteCount: SharedStickerCache.maximumByteCount
        )
    }

    /// - Parameter maximumByteCount: the caller's ceiling, checked before and after the signed
    ///   redirect. The full-size surface passes its own, much larger, budget.
    func download(
        assetID: String,
        accessToken: String,
        maximumByteCount: Int
    ) async throws -> DownloadedRendition {
        let endpoint = baseURL
            .appending(path: "api/v1/assets")
            .appending(path: assetID)
            .appending(path: "download")
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, image/png, image/apng, image/gif, image/webp", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let result = try await transport.data(for: request)
        try Self.validate(result)
        if result.data.count >= maximumByteCount {
            throw StickerLibraryError.renditionTooLarge
        }

        let contentType = result.response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
        if contentType?.contains("application/json") == true || result.data.first == 0x7B {
            guard let envelope = try? JSONDecoder().decode(AssetDownloadEnvelope.self, from: result.data),
                  let signedURL = URL(string: envelope.url),
                  signedURL.scheme == "https" else {
                Self.playbackLogger.error(
                    "asset download envelope rejected asset=\(assetID, privacy: .private) status=\(result.response.statusCode) bytes=\(result.data.count) contentType=\(contentType ?? "missing", privacy: .public)"
                )
                throw StickerLibraryError.invalidResponse
            }
            var signedRequest = URLRequest(url: signedURL)
            signedRequest.setValue("image/png, image/apng, image/gif, image/webp", forHTTPHeaderField: "Accept")
            signedRequest.cachePolicy = .reloadIgnoringLocalCacheData
            let rendition = try await transport.data(for: signedRequest)
            try Self.validate(rendition)
            guard rendition.data.count < maximumByteCount else {
                throw StickerLibraryError.renditionTooLarge
            }
            return DownloadedRendition(
                data: rendition.data,
                mimeType: rendition.response.value(forHTTPHeaderField: "Content-Type")
            )
        }
        return DownloadedRendition(data: result.data, mimeType: contentType)
    }

    func fetchPlayback(stickerID: String, revisionID: String, accessToken: String) async throws -> StickerPlaybackBundle {
        let endpoint = baseURL.appending(path: "api/v1/stickers/\(stickerID)/playback")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "revisionId", value: revisionID)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(String(AnimatedDocument.currentVersion), forHTTPHeaderField: "X-Sticker-Contract")
        addClientHeaders(to: &request)
        let result = try await transport.data(for: request)
        Self.playbackLogger.info(
            "playback response sticker=\(stickerID, privacy: .private) revision=\(revisionID, privacy: .private) status=\(result.response.statusCode) bytes=\(result.data.count) contentType=\(result.response.value(forHTTPHeaderField: "Content-Type") ?? "missing", privacy: .public)"
        )
        try Self.validate(result)
        do {
            return try JSONDecoder().decode(StickerPlaybackBundle.self, from: result.data)
        } catch {
            Self.playbackLogger.error(
                "playback decode failed sticker=\(stickerID, privacy: .private) revision=\(revisionID, privacy: .private) reason=\(Self.decodingFailure(error), privacy: .public)"
            )
            throw error
        }
    }

    private static func decodingFailure(_ error: Error) -> String {
        let path: [any CodingKey]
        let reason: String
        switch error {
        case DecodingError.typeMismatch(let type, let context):
            path = context.codingPath
            reason = "typeMismatch(\(type))"
        case DecodingError.valueNotFound(let type, let context):
            path = context.codingPath
            reason = "valueNotFound(\(type))"
        case DecodingError.keyNotFound(let key, let context):
            path = context.codingPath + [key]
            reason = "keyNotFound"
        case DecodingError.dataCorrupted(let context):
            path = context.codingPath
            reason = "dataCorrupted"
        default:
            return String(describing: type(of: error))
        }
        return "\(reason) path=\(path.map(\.stringValue).joined(separator: "."))"
    }

    private func addClientHeaders(to request: inout URLRequest) {
        if let appVersion, !appVersion.isEmpty, !appVersion.contains("$(") {
            request.setValue(appVersion, forHTTPHeaderField: "X-iOS-App-Version")
        }
        if let acceptLanguage, !acceptLanguage.isEmpty {
            request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        }
    }

    private static func appVersion(in bundle: Bundle) -> String? {
        let value = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let value, !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    private static func validate(_ result: StickerHTTPResult) throws {
        let response = result.response
        if response.statusCode == 401 || response.statusCode == 403 {
            throw StickerLibraryError.unauthorized
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            let envelope = try? JSONDecoder().decode(StickerLibraryErrorEnvelope.self, from: result.data)
            if response.statusCode == 426,
               envelope?.error.code == "IOS_APP_UPDATE_REQUIRED",
               let message = envelope?.error.message {
                throw StickerLibraryError.updateRequired(message: message)
            }
            throw StickerLibraryError.server(
                statusCode: response.statusCode,
                message: envelope?.error.message
            )
        }
    }
}

private struct StickerLibraryErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
        let message: String
    }

    let error: Body
}

/// Permissive decoding for the sectioned library.
///
/// Reuses `StickerDTO`/`AssetDTO` below: a section's stickers are exactly the shape the flat
/// endpoint already returns, so there is one sticker decoder in this file, not two.
private struct LibrarySectionsDTO: Decodable {
    let sections: [SectionDTO]

    private enum CodingKeys: String, CodingKey { case sections, data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sections = try container.decodeIfPresent([SectionDTO].self, forKey: .sections)
            ?? container.decodeIfPresent([SectionDTO].self, forKey: .data)
            ?? []
    }

    /// Flattens to the descriptor list the cache stores, stamping section identity and order onto
    /// each one. A sticker with no system rendition is skipped: there is nothing to insert.
    func descriptors() -> [SystemStickerDescriptor] {
        var result: [SystemStickerDescriptor] = []
        for (sectionIndex, section) in sections.enumerated() {
            for (itemIndex, sticker) in section.stickers.enumerated() {
                guard var descriptor = sticker.systemDescriptor else { continue }
                descriptor.sectionID = section.id
                descriptor.sectionTitle = section.title
                descriptor.sectionSubtitle = section.subtitle
                descriptor.sectionPosition = sectionIndex
                descriptor.position = itemIndex
                result.append(descriptor)
            }
        }
        return result
    }
}

private struct SectionDTO: Decodable {
    let id: String
    let title: String
    let subtitle: String?
    let stickers: [StickerDTO]

    private enum CodingKeys: String, CodingKey { case id, kind, title, creator, stickers, data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decodeIfPresent(String.self, forKey: .kind)
            ?? "mine"
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? String(localized: "Stickers")
        // The byline is the only part of the creator this surface shows.
        let creator = try? container.decodeIfPresent(CreatorDTO.self, forKey: .creator)
        subtitle = (creator?.displayName).map { String(localized: "by \($0)") }
        stickers = try container.decodeIfPresent([StickerDTO].self, forKey: .stickers)
            ?? container.decodeIfPresent([StickerDTO].self, forKey: .data)
            ?? []
    }
}

private struct CreatorDTO: Decodable {
    let displayName: String?

    private enum CodingKeys: String, CodingKey { case displayName, handle }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let name = try container.decodeIfPresent(String.self, forKey: .displayName), !name.isEmpty {
            displayName = name
        } else if let handle = try container.decodeIfPresent(String.self, forKey: .handle) {
            displayName = "@\(handle)"
        } else {
            displayName = nil
        }
    }
}

private struct StickerPageDTO: Decodable {
    let items: [StickerDTO]
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case data
        case items
        case stickers
        case nextCursor
    }

    init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            var decoded: [StickerDTO] = []
            while !unkeyed.isAtEnd {
                decoded.append(try unkeyed.decode(StickerDTO.self))
            }
            items = decoded
            nextCursor = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outerNextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        if let values = try container.decodeIfPresent([StickerDTO].self, forKey: .items)
            ?? container.decodeIfPresent([StickerDTO].self, forKey: .stickers)
            ?? container.decodeIfPresent([StickerDTO].self, forKey: .data) {
            items = values
            nextCursor = outerNextCursor
            return
        }
        if let nested = try container.decodeIfPresent(NestedStickerPageDTO.self, forKey: .data) {
            items = nested.items
            nextCursor = outerNextCursor ?? nested.nextCursor
            return
        }
        items = []
        nextCursor = outerNextCursor
    }
}

private struct NestedStickerPageDTO: Decodable {
    let items: [StickerDTO]
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case items
        case stickers
        case nextCursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([StickerDTO].self, forKey: .items)
            ?? container.decodeIfPresent([StickerDTO].self, forKey: .stickers)
            ?? []
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

private struct StickerDTO: Decodable {
    let playbackRevisionId: String?
    let id: String
    let title: String
    let updatedAt: Date
    let systemSticker: AssetDTO?
    let systemStickerAssetID: String?
    /// The server's largest rendition: the 1024² `master` PNG for a static sticker, the 618 APNG
    /// for an animated one. Absent on servers older than this field.
    let previewAsset: AssetDTO?
    /// The same artwork as `previewAsset`, in WebP, when the publishing client could encode one.
    ///
    /// Null far more often than not — iOS has no system WebP encoder, and nothing published before
    /// the format existed has one — so this is read as an optimisation over `previewAsset` and
    /// never as a replacement for it.
    let webpAsset: AssetDTO?

    private enum CodingKeys: String, CodingKey {
        case playbackRevisionId
        case id
        case title
        case name
        case updatedAt
        case systemSticker
        case systemStickerAssetID = "systemStickerAssetId"
        case previewAsset
        case webpAsset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playbackRevisionId = try container.decodeIfPresent(String.self, forKey: .playbackRevisionId)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? String(localized: "Sticker")
        updatedAt = (try? container.decode(FlexibleDate.self, forKey: .updatedAt).value) ?? .distantPast
        systemSticker = try container.decodeIfPresent(AssetDTO.self, forKey: .systemSticker)
        systemStickerAssetID = try container.decodeIfPresent(String.self, forKey: .systemStickerAssetID)
        previewAsset = try container.decodeIfPresent(AssetDTO.self, forKey: .previewAsset)
        webpAsset = try container.decodeIfPresent(AssetDTO.self, forKey: .webpAsset)
    }

    var systemDescriptor: SystemStickerDescriptor? {
        let assetID = systemSticker?.assetID ?? systemStickerAssetID
        guard let assetID, !assetID.isEmpty else { return nil }
        return SystemStickerDescriptor(
            stickerID: id,
            assetID: assetID,
            title: title,
            mimeType: systemSticker?.mimeType ?? "image/png",
            byteSize: systemSticker?.byteSize,
            sha256: systemSticker?.sha256,
            updatedAt: updatedAt,
            fullSize: fullSize(systemAssetID: assetID),
            playbackRevisionID: playbackRevisionId
        )
    }

    /// The full-resolution rendition a sticker has, if it is worth downloading.
    ///
    /// `previewAsset` — the sharing rendition, which every published sticker carries. `nil` when the
    /// asset fails one of `fullSizeRendition`'s gating rules, which the caller resolves by
    /// attaching the cached ≤500 KB file instead.
    ///
    /// WebP is preferred when the server offers one, and *only* preferred: it is the same frames in
    /// a container that costs a fraction of the bytes — a published 618 px APNG measured 9.8 MB —
    /// so taking it saves a download the person is waiting on. Every reason it might not be there
    /// is ordinary (an older sticker, a client with no encoder), and a WebP that fails one of the
    /// gates below falls through to the APNG rather than reducing the sticker to its ≤500 KB file.
    private func fullSize(systemAssetID: String) -> FullSizeRendition? {
        Self.fullSizeRendition(webpAsset, systemAssetID: systemAssetID)
            ?? Self.fullSizeRendition(previewAsset, systemAssetID: systemAssetID)
    }

    /// Every rule here fails closed: an offer that cannot be honoured is worse than no offer,
    /// because it becomes a tap that spins and then errors.
    private static func fullSizeRendition(
        _ preview: AssetDTO?,
        systemAssetID: String
    ) -> FullSizeRendition? {
        guard let preview, !preview.assetID.isEmpty else { return nil }

        // `pending`/`failed`/`deleted` would 404 or serve bytes that fail their checksum. An
        // absent state is an older server that only ever listed ready assets.
        if let state = preview.state, state != "ready" { return nil }

        // The animated chain coalesces down to the system asset. Identity is the only signal
        // that happened, and it means "already cached, nothing to download".
        guard preview.assetID != systemAssetID else {
            return FullSizeRendition(
                assetID: preview.assetID,
                mimeType: preview.mimeType,
                byteSize: preview.byteSize,
                sha256: preview.sha256,
                width: preview.width,
                height: preview.height,
                isSystemAssetFallback: true
            )
        }

        // Filtered here rather than by loosening `validatedFileExtension`, which stays the single
        // magic-byte gate both caches share.
        //
        // WebP is admitted for the full-size cache alone. It can only ever be an `.image`-mode
        // attachment: `MSSticker.h` requires a file conforming to `kUTTypePNG`, `kUTTypeGIF` or
        // `kUTTypeJPEG`, and `org.webmproject.webp` conforms to none of the three — so the system
        // cache, whose files become `MSSticker`s, refuses it in `validatedFileExtension`.
        let normalized = preview.mimeType.lowercased().split(separator: ";").first.map(String.init) ?? ""
        guard ["image/png", "image/apng", "image/gif", "image/webp"].contains(normalized) else { return nil }

        if let byteSize = preview.byteSize, byteSize >= StickerCachePolicy.fullSize.maximumByteCount {
            return nil
        }
        if let width = preview.width, let height = preview.height,
           max(width, height) > StickerCachePolicy.fullSize.maximumPixelDimension {
            return nil
        }

        return FullSizeRendition(
            assetID: preview.assetID,
            mimeType: preview.mimeType,
            byteSize: preview.byteSize,
            sha256: preview.sha256,
            width: preview.width,
            height: preview.height,
            isSystemAssetFallback: false
        )
    }
}

private struct AssetDTO: Decodable {
    let assetID: String
    let mimeType: String
    let byteSize: Int?
    let sha256: String?
    /// Only `previewAsset` carries these; `systemSticker` is a narrower projection without them.
    let kind: String?
    let state: String?
    let width: Int?
    let height: Int?

    private enum CodingKeys: String, CodingKey {
        case assetID = "assetId"
        case id
        case mimeType
        case byteSize
        case size
        case sha256
        case checksum
        case kind
        case state
        case width
        case height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetID = try container.decodeIfPresent(String.self, forKey: .assetID)
            ?? container.decode(String.self, forKey: .id)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType) ?? "image/png"
        byteSize = try container.decodeIfPresent(Int.self, forKey: .byteSize)
            ?? container.decodeIfPresent(Int.self, forKey: .size)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
            ?? container.decodeIfPresent(String.self, forKey: .checksum)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
    }
}

private struct AssetDownloadEnvelope: Decodable {
    let url: String
}

private struct FlexibleDate: Decodable {
    let value: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let timestamp = try? container.decode(TimeInterval.self) {
            value = Date(timeIntervalSince1970: timestamp)
            return
        }
        let string = try container.decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            value = date
            return
        }
        let standard = ISO8601DateFormatter()
        guard let date = standard.date(from: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
        }
        value = date
    }
}
