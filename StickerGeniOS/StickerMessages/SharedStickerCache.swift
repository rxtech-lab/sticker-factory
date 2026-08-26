import CryptoKit
import Foundation
import ImageIO

struct CachedSticker: Equatable, Sendable {
    let stickerID: String
    let assetID: String
    let title: String
    let fileURL: URL
    let updatedAt: Date
}

struct SystemStickerDescriptor: Equatable, Sendable {
    let stickerID: String
    let assetID: String
    let title: String
    let mimeType: String
    let byteSize: Int?
    let sha256: String?
    let updatedAt: Date
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

    func cachedStickers(for subject: String) throws -> [CachedSticker] {
        try prepare(for: subject)
        var current = try loadIndex()
        current.entries.removeAll { entry in
            let url = rootURL.appending(path: entry.filename)
            return !fileManager.fileExists(atPath: url.path)
                || (try? Self.validateFile(at: url)) == nil
        }
        index = current
        try persistIndex()
        return current.entries
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { entry in
                CachedSticker(
                    stickerID: entry.stickerID,
                    assetID: entry.assetID,
                    title: entry.title,
                    fileURL: rootURL.appending(path: entry.filename),
                    updatedAt: entry.updatedAt
                )
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
        if let oldEntry = current.entries.first(where: { $0.stickerID == descriptor.stickerID }),
           oldEntry.filename != filename {
            try? fileManager.removeItem(at: rootURL.appending(path: oldEntry.filename))
        }
        current.entries.removeAll { $0.stickerID == descriptor.stickerID }
        let entry = CacheEntry(
            stickerID: descriptor.stickerID,
            assetID: descriptor.assetID,
            title: String(descriptor.title.prefix(150)),
            filename: filename,
            updatedAt: descriptor.updatedAt
        )
        current.entries.append(entry)
        index = current
        try persistIndex()
        return CachedSticker(
            stickerID: entry.stickerID,
            assetID: entry.assetID,
            title: entry.title,
            fileURL: destination,
            updatedAt: entry.updatedAt
        )
    }

    func removeEntries(notIn stickerIDs: Set<String>, for subject: String) throws {
        try prepare(for: subject)
        var current = try loadIndex()
        let removed = current.entries.filter { !stickerIDs.contains($0.stickerID) }
        current.entries.removeAll { !stickerIDs.contains($0.stickerID) }
        for entry in removed {
            try? fileManager.removeItem(at: rootURL.appending(path: entry.filename))
        }
        index = current
        try persistIndex()
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
        let data = try Data(contentsOf: indexURL)
        let decoded = try JSONDecoder.stickerFactory.decode(CacheIndex.self, from: data)
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
    let accountFingerprint: String
    var entries: [CacheEntry]
}

private struct CacheEntry: Codable, Sendable {
    let stickerID: String
    let assetID: String
    let title: String
    let filename: String
    let updatedAt: Date
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
