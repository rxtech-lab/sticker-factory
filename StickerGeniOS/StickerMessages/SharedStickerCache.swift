import CryptoKit
import Foundation
import ImageIO

/// The section a sticker belongs to: the user's own library, or one installed pack.
///
/// Sections exist because the same sticker can legitimately appear in two different installed
/// packs, so `stickerID` alone is no longer a unique key anywhere in this cache.
struct StickerSection: Equatable, Sendable {
    /// `"mine"`, or `"pack:<uuid>"`.
    let id: String
    let title: String
    /// The creator byline, for a pack section. Nil for the user's own stickers.
    let subtitle: String?
    let stickers: [CachedSticker]
}

/// Identity of one cached sticker. A sticker in two packs is two entries — pointing at one file.
struct CacheKey: Hashable, Sendable {
    let sectionID: String
    let stickerID: String
}

struct CachedSticker: Equatable, Sendable {
    let stickerID: String
    let assetID: String
    let title: String
    let fileURL: URL
    let updatedAt: Date
    var sectionID: String = SharedStickerCache.mineSectionID
    var sectionTitle: String = SharedStickerCache.mineSectionTitle
    var sectionSubtitle: String?
    var sectionPosition: Int = 0
    var position: Int = 0

    var key: CacheKey { CacheKey(sectionID: sectionID, stickerID: stickerID) }
}

struct SystemStickerDescriptor: Equatable, Sendable {
    let stickerID: String
    let assetID: String
    let title: String
    /// Overwritten with the response's own content type once the bytes arrive, so what is cached
    /// is what was actually served rather than what the listing claimed.
    var mimeType: String
    let byteSize: Int?
    let sha256: String?
    let updatedAt: Date
    var sectionID: String = SharedStickerCache.mineSectionID
    var sectionTitle: String = SharedStickerCache.mineSectionTitle
    var sectionSubtitle: String?
    var sectionPosition: Int = 0
    var position: Int = 0

    var key: CacheKey { CacheKey(sectionID: sectionID, stickerID: stickerID) }
}

enum StickerCacheError: Error, LocalizedError, Sendable {
    case appGroupUnavailable
    case unsupportedFile
    case fileTooLarge
    case invalidDimensions
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "The shared sticker cache is unavailable."
        case .unsupportedFile:
            "The downloaded rendition is not a supported PNG, APNG, or GIF."
        case .fileTooLarge:
            "The downloaded rendition exceeds the 500 KB Messages limit."
        case .invalidDimensions:
            "The downloaded rendition has invalid system-sticker dimensions."
        case .checksumMismatch:
            "The downloaded rendition failed its integrity check."
        }
    }
}

actor SharedStickerCache {
    /// A conservative decimal threshold keeps every cached file below Apple's
    /// 500 KB limit regardless of whether a caller labels KB as 1000 or 1024.
    static let maximumByteCount = 500_000
    static let maximumPixelDimension = 618
    static let allowedPixelDimensions: Set<Int> = [300, 408, 618]

    static let mineSectionID = "mine"
    static let mineSectionTitle = "My Stickers"
    /// 2 added sections. A v1 index migrates in place — see `CacheEntry.init(from:)`.
    static let indexVersion = 2

    private let fileManager: FileManager
    private let rootURL: URL
    private let indexURL: URL
    private var index: CacheIndex?

    init(fileManager: FileManager = .default) throws {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: SharedAuthConfiguration.appGroupIdentifier
        ) else {
            throw StickerCacheError.appGroupUnavailable
        }
        self.fileManager = fileManager
        rootURL = container
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Caches", directoryHint: .isDirectory)
            .appending(path: "StickerFactoryMessages", directoryHint: .isDirectory)
        indexURL = rootURL.appending(path: "cache-index.json")
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func prepare(for subject: String) throws {
        let fingerprint = Self.fingerprint(subject)
        let current = try loadIndex()
        guard current.accountFingerprint != fingerprint else { return }
        try purgeFiles()
        index = CacheIndex(accountFingerprint: fingerprint, entries: [])
        try persistIndex()
    }

    /// Every cached sticker, flat. Kept for callers that only need the whole set.
    func cachedStickers(for subject: String) throws -> [CachedSticker] {
        try cachedSections(for: subject).flatMap(\.stickers)
    }

    /// The cached library, grouped: "My Stickers" first, then one section per installed pack.
    ///
    /// Sections are ordered by their server position and stickers by theirs, falling back to
    /// `updatedAt` descending — which is exactly the ordering this cache had before sections
    /// existed, so a migrated v1 index reads unchanged.
    func cachedSections(for subject: String) throws -> [StickerSection] {
        try prepare(for: subject)
        var current = try loadIndex()
        current.entries.removeAll { entry in
            let url = rootURL.appending(path: entry.filename)
            return !fileManager.fileExists(atPath: url.path)
                || (try? Self.validateFile(at: url)) == nil
        }
        index = current
        try persistIndex()

        let stickers = current.entries.map { entry in
            CachedSticker(
                stickerID: entry.stickerID,
                assetID: entry.assetID,
                title: entry.title,
                fileURL: rootURL.appending(path: entry.filename),
                updatedAt: entry.updatedAt,
                sectionID: entry.sectionID,
                sectionTitle: entry.sectionTitle,
                sectionSubtitle: entry.sectionSubtitle,
                sectionPosition: entry.sectionPosition,
                position: entry.position
            )
        }

        return Dictionary(grouping: stickers, by: \.sectionID)
            .map { _, members in
                let ordered = members.sorted {
                    $0.position != $1.position ? $0.position < $1.position : $0.updatedAt > $1.updatedAt
                }
                let first = ordered[0]
                return StickerSection(
                    id: first.sectionID,
                    title: first.sectionTitle,
                    subtitle: first.sectionSubtitle,
                    stickers: ordered
                )
            }
            .sorted { left, right in
                let leftPosition = left.stickers[0].sectionPosition
                let rightPosition = right.stickers[0].sectionPosition
                return leftPosition != rightPosition ? leftPosition < rightPosition : left.id < right.id
            }
    }

    func store(_ data: Data, descriptor: SystemStickerDescriptor, for subject: String) throws -> CachedSticker {
        try prepare(for: subject)
        guard data.count < Self.maximumByteCount else {
            throw StickerCacheError.fileTooLarge
        }
        if let declaredSize = descriptor.byteSize, declaredSize >= Self.maximumByteCount {
            throw StickerCacheError.fileTooLarge
        }
        guard Self.checksumMatches(data, expected: descriptor.sha256) else {
            throw StickerCacheError.checksumMismatch
        }

        let fileExtension = try Self.validatedFileExtension(for: data, declaredMimeType: descriptor.mimeType)
        try Self.validateImage(data)
        let filename = "\(Self.fingerprint(descriptor.assetID)).\(fileExtension)"
        let destination = rootURL.appending(path: filename)
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])

        var current = try loadIndex()
        let key = descriptor.key
        let superseded = current.entries.first { $0.key == key }
        current.entries.removeAll { $0.key == key }
        let entry = CacheEntry(
            stickerID: descriptor.stickerID,
            assetID: descriptor.assetID,
            title: String(descriptor.title.prefix(150)),
            filename: filename,
            updatedAt: descriptor.updatedAt,
            sectionID: descriptor.sectionID,
            sectionTitle: descriptor.sectionTitle,
            sectionSubtitle: descriptor.sectionSubtitle,
            sectionPosition: descriptor.sectionPosition,
            position: descriptor.position
        )
        current.entries.append(entry)
        // Only now, with the new entry in place, is it safe to drop the superseded file — and only
        // if nothing else still points at it. Files are keyed by asset, entries by (section,
        // sticker), so the same file legitimately backs a sticker that sits in two packs.
        if let superseded, superseded.filename != filename {
            deleteFileIfUnreferenced(superseded.filename, in: current.entries)
        }
        index = current
        try persistIndex()
        return CachedSticker(
            stickerID: entry.stickerID,
            assetID: entry.assetID,
            title: entry.title,
            fileURL: destination,
            updatedAt: entry.updatedAt,
            sectionID: entry.sectionID,
            sectionTitle: entry.sectionTitle,
            sectionSubtitle: entry.sectionSubtitle,
            sectionPosition: entry.sectionPosition,
            position: entry.position
        )
    }

    /// Drops everything the latest server response did not mention.
    ///
    /// Keyed on `CacheKey`, not `stickerID`: removing a pack must not evict the same sticker from
    /// another pack that still contains it.
    func removeEntries(notIn keys: Set<CacheKey>, for subject: String) throws {
        try prepare(for: subject)
        var current = try loadIndex()
        let removed = current.entries.filter { !keys.contains($0.key) }
        current.entries.removeAll { !keys.contains($0.key) }
        for entry in removed {
            deleteFileIfUnreferenced(entry.filename, in: current.entries)
        }
        index = current
        try persistIndex()
    }

    /// Deletes a cached file only when no surviving entry references it.
    ///
    /// Getting this wrong silently blanks a sticker in whichever pack was not being edited, which
    /// looks like a corrupt cache rather than a bug.
    private func deleteFileIfUnreferenced(_ filename: String, in survivors: [CacheEntry]) {
        guard !survivors.contains(where: { $0.filename == filename }) else { return }
        try? fileManager.removeItem(at: rootURL.appending(path: filename))
    }

    func purge() throws {
        try purgeFiles()
        index = nil
    }

    private func loadIndex() throws -> CacheIndex {
        if let index { return index }
        guard fileManager.fileExists(atPath: indexURL.path) else {
            let empty = CacheIndex(accountFingerprint: "", entries: [])
            index = empty
            return empty
        }
        // A corrupt index used to throw, which bricked the extension until the app group was
        // cleared. Every file it describes is re-fetchable, so starting over is strictly better.
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder.stickerFactory.decode(CacheIndex.self, from: data) else {
            let empty = CacheIndex(accountFingerprint: "", entries: [])
            index = empty
            return empty
        }
        index = decoded
        return decoded
    }

    private func persistIndex() throws {
        guard let index else { return }
        let data = try JSONEncoder.stickerFactory.encode(index)
        try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func purgeFiles() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        for fileURL in try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    static func validatedFileExtension(for data: Data, declaredMimeType: String) throws -> String {
        let normalizedMimeType = declaredMimeType.lowercased().split(separator: ";").first.map(String.init) ?? ""
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
           normalizedMimeType.isEmpty || normalizedMimeType == "image/png" || normalizedMimeType == "image/apng" {
            return "png"
        }
        if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) {
            guard normalizedMimeType.isEmpty || normalizedMimeType == "image/gif" else {
                throw StickerCacheError.unsupportedFile
            }
            return "gif"
        }
        throw StickerCacheError.unsupportedFile
    }

    static func validateImage(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == height,
              allowedPixelDimensions.contains(width) else {
            throw StickerCacheError.invalidDimensions
        }
    }

    private static func validateFile(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size < maximumByteCount else {
            throw StickerCacheError.fileTooLarge
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        _ = try validatedFileExtension(for: data, declaredMimeType: "")
        try validateImage(data)
    }

    private static func checksumMatches(_ data: Data, expected: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return true }
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        if expected.lowercased() == hex { return true }
        return Data(digest).base64EncodedString() == expected
    }

    private static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CacheIndex: Codable, Sendable {
    /// 1 predates sections. Bumped on every write; only read for diagnostics, because
    /// `CacheEntry` migrates itself field by field.
    var version: Int = SharedStickerCache.indexVersion
    let accountFingerprint: String
    var entries: [CacheEntry]

    init(accountFingerprint: String, entries: [CacheEntry]) {
        self.accountFingerprint = accountFingerprint
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        accountFingerprint = try container.decode(String.self, forKey: .accountFingerprint)
        entries = try container.decodeIfPresent([CacheEntry].self, forKey: .entries) ?? []
    }
}

private struct CacheEntry: Codable, Sendable {
    let stickerID: String
    let assetID: String
    let title: String
    let filename: String
    let updatedAt: Date
    let sectionID: String
    let sectionTitle: String
    let sectionSubtitle: String?
    let sectionPosition: Int
    let position: Int

    var key: CacheKey { CacheKey(sectionID: sectionID, stickerID: stickerID) }

    init(
        stickerID: String,
        assetID: String,
        title: String,
        filename: String,
        updatedAt: Date,
        sectionID: String,
        sectionTitle: String,
        sectionSubtitle: String?,
        sectionPosition: Int,
        position: Int
    ) {
        self.stickerID = stickerID
        self.assetID = assetID
        self.title = title
        self.filename = filename
        self.updatedAt = updatedAt
        self.sectionID = sectionID
        self.sectionTitle = sectionTitle
        self.sectionSubtitle = sectionSubtitle
        self.sectionPosition = sectionPosition
        self.position = position
    }

    /// A v1 entry has no section fields and describes a sticker the user owns, so it migrates
    /// straight into "My Stickers" with nothing re-downloaded.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stickerID = try container.decode(String.self, forKey: .stickerID)
        assetID = try container.decode(String.self, forKey: .assetID)
        title = try container.decode(String.self, forKey: .title)
        filename = try container.decode(String.self, forKey: .filename)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        sectionID = try container.decodeIfPresent(String.self, forKey: .sectionID) ?? SharedStickerCache.mineSectionID
        sectionTitle = try container.decodeIfPresent(String.self, forKey: .sectionTitle) ?? SharedStickerCache.mineSectionTitle
        sectionSubtitle = try container.decodeIfPresent(String.self, forKey: .sectionSubtitle)
        sectionPosition = try container.decodeIfPresent(Int.self, forKey: .sectionPosition) ?? 0
        position = try container.decodeIfPresent(Int.self, forKey: .position) ?? 0
    }
}

private extension JSONEncoder {
    static var stickerFactory: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var stickerFactory: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
