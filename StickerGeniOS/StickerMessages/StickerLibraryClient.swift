import Foundation

enum StickerLibraryError: Error, LocalizedError, Sendable {
    case invalidConfiguration
    case unauthorized
    case server(statusCode: Int)
    case invalidResponse
    case renditionTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            String(localized: "Sticker Factory's API address is not configured.")
        case .unauthorized:
            String(localized: "Your Sticker Factory sign-in has expired.")
        case .server(let statusCode):
            String(localized: "Sticker Factory could not refresh the library (HTTP \(statusCode)).")
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

struct StickerHTTPResult: @unchecked Sendable {
    let data: Data
    let response: HTTPURLResponse
}

protocol StickerHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> StickerHTTPResult
}

struct URLSessionStickerHTTPTransport: StickerHTTPTransport {
    let session: URLSession

    func data(for request: URLRequest) async throws -> StickerHTTPResult {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw StickerLibraryError.invalidResponse
        }
        return .init(data: data, response: response)
    }
}

struct StickerLibraryClient: Sendable {
    static let maximumPageCount = 100

    private let baseURL: URL
    private let transport: any StickerHTTPTransport

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
    }

    private static func isAllowedBaseURL(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        #if DEBUG
        return url.scheme?.lowercased() == "http" && url.host?.lowercased() == "localhost"
        #else
        return false
        #endif
    }

    init(baseURL: URL, transport: any StickerHTTPTransport) {
        self.baseURL = baseURL
        self.transport = transport
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
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let result = try await transport.data(for: request)
        if result.response.statusCode == 404 {
            return try await fetchLibrary(accessToken: accessToken)
        }
        try Self.validate(result.response)
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
            URLQueryItem(name: "limit", value: "100"),
        ]
        if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw StickerLibraryError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let result = try await transport.data(for: request)
        try Self.validate(result.response)
        guard let page = try? JSONDecoder().decode(StickerPageDTO.self, from: result.data) else {
            throw StickerLibraryError.invalidResponse
        }
        return page
    }

    func download(_ descriptor: SystemStickerDescriptor, accessToken: String) async throws -> DownloadedRendition {
        let endpoint = baseURL
            .appending(path: "api/v1/assets")
            .appending(path: descriptor.assetID)
            .appending(path: "download")
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, image/png, image/apng, image/gif", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let result = try await transport.data(for: request)
        try Self.validate(result.response)
        if result.data.count >= SharedStickerCache.maximumByteCount {
            throw StickerLibraryError.renditionTooLarge
        }

        let contentType = result.response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
        if contentType?.contains("application/json") == true || result.data.first == 0x7B {
            guard let envelope = try? JSONDecoder().decode(AssetDownloadEnvelope.self, from: result.data),
                  let signedURL = URL(string: envelope.url),
                  signedURL.scheme == "https" else {
                throw StickerLibraryError.invalidResponse
            }
            var signedRequest = URLRequest(url: signedURL)
            signedRequest.setValue("image/png, image/apng, image/gif", forHTTPHeaderField: "Accept")
            signedRequest.cachePolicy = .reloadIgnoringLocalCacheData
            let rendition = try await transport.data(for: signedRequest)
            try Self.validate(rendition.response)
            guard rendition.data.count < SharedStickerCache.maximumByteCount else {
                throw StickerLibraryError.renditionTooLarge
            }
            return DownloadedRendition(
                data: rendition.data,
                mimeType: rendition.response.value(forHTTPHeaderField: "Content-Type")
            )
        }
        return DownloadedRendition(data: result.data, mimeType: contentType)
    }

    private static func validate(_ response: HTTPURLResponse) throws {
        if response.statusCode == 401 || response.statusCode == 403 {
            throw StickerLibraryError.unauthorized
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw StickerLibraryError.server(statusCode: response.statusCode)
        }
    }
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
    let id: String
    let title: String
    let updatedAt: Date
    let systemSticker: AssetDTO?
    let systemStickerAssetID: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case updatedAt
        case systemSticker
        case systemStickerAssetID = "systemStickerAssetId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? String(localized: "Sticker")
        updatedAt = (try? container.decode(FlexibleDate.self, forKey: .updatedAt).value) ?? .distantPast
        systemSticker = try container.decodeIfPresent(AssetDTO.self, forKey: .systemSticker)
        systemStickerAssetID = try container.decodeIfPresent(String.self, forKey: .systemStickerAssetID)
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
            updatedAt: updatedAt
        )
    }
}

private struct AssetDTO: Decodable {
    let assetID: String
    let mimeType: String
    let byteSize: Int?
    let sha256: String?

    private enum CodingKeys: String, CodingKey {
        case assetID = "assetId"
        case id
        case mimeType
        case byteSize
        case size
        case sha256
        case checksum
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
