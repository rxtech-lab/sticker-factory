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
    /// Which rendition of the sticker this entry holds, for a cache that keeps more than one.
    ///
    /// Always `nil` in the system cache, which holds exactly one file per placement — so every
    /// existing key, and every existing index entry, means what it always did. The full-size cache
    /// sets `SystemStickerDescriptor.fullSizeVariant`, so its entry for a sticker does not collide
    /// with the system cache's on the same `(section, sticker)` pair.
    var variant: String?
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
    var variant: String?

    var key: CacheKey { CacheKey(sectionID: sectionID, stickerID: stickerID, variant: variant) }
}

/// The full-resolution rendition WinkySticker attaches in `.image` mode.
///
/// The sharing rendition: the 1024² `master` PNG for a static sticker, the APNG for an animated
/// one. Present only when the server offered one that is worth downloading; see
/// `StickerDTO.systemDescriptor` for the rules that reduce it to `nil`.
struct FullSizeRendition: Equatable, Sendable {
    let assetID: String
    let mimeType: String
    let byteSize: Int?
    let sha256: String?
    let width: Int?
    let height: Int?
    /// The server's preview chain fell back to the system asset, which happens for an animated
    /// sticker with no APNG. There is nothing bigger to fetch: the ≤500 KB file already on disk
    /// *is* the best rendition, so the full-size cache must never hold a second copy of it.
    let isSystemAssetFallback: Bool
}

struct SystemStickerDescriptor: Equatable, Sendable {
    let stickerID: String
    var assetID: String
    let title: String
    /// Overwritten with the response's own content type once the bytes arrive, so what is cached
    /// is what was actually served rather than what the listing claimed.
    var mimeType: String
    var byteSize: Int?
    var sha256: String?
    let updatedAt: Date
    var sectionID: String = SharedStickerCache.mineSectionID
    var sectionTitle: String = SharedStickerCache.mineSectionTitle
    var sectionSubtitle: String?
    var sectionPosition: Int = 0
    var position: Int = 0
    var variant: String?
    /// The full-resolution rendition the server offered, if it offered one worth downloading.
    ///
    /// `nil` for a sticker whose only asset is the ≤500 KB Messages file, which is a legitimate
    /// state rather than a broken one — an `.image` send then attaches that file instead.
    var fullSize: FullSizeRendition?

    var key: CacheKey { CacheKey(sectionID: sectionID, stickerID: stickerID, variant: variant) }

    /// The same placement — section, sticker, ordering — pointed at the full-size asset, so the
    /// full-size cache reuses `store(_:descriptor:for:)` unchanged rather than growing a second
    /// write path.
    ///
    /// `nil` when there is nothing separate to fetch, which is exactly when the caller should
    /// attach the cached sticker file instead.
    func fullSizeDescriptor() -> SystemStickerDescriptor? {
        guard let fullSize, !fullSize.isSystemAssetFallback else { return nil }
        var copy = self
        copy.assetID = fullSize.assetID
        copy.mimeType = fullSize.mimeType
        copy.byteSize = fullSize.byteSize
        copy.sha256 = fullSize.sha256
        copy.fullSize = nil
        // Distinguishes this entry from the system cache's, which shares the section/sticker pair.
        copy.variant = Self.fullSizeVariant
        return copy
    }

    /// The variant every full-size cache entry is written under.
    static let fullSizeVariant = "full"
}

enum StickerCacheError: Error, LocalizedError, Sendable {
    case appGroupUnavailable
    case unsupportedFile
    case fileTooLarge
    case invalidDimensions
    case checksumMismatch
    /// The full-size counterparts of the two above. Separate cases rather than a reworded
    /// `fileTooLarge`, because that string names Apple's 500 KB sticker limit — true for the
    /// Messages rendition and meaningless for a 1024 px attachment.
    case fullSizeTooLarge
    case fullSizeInvalidDimensions

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            String(localized: "The shared sticker cache is unavailable.")
        case .unsupportedFile:
            String(localized: "The downloaded rendition is not in a format this sticker can be sent as.")
        case .fileTooLarge:
            String(localized: "The downloaded rendition exceeds the 500 KB Messages limit.")
        case .invalidDimensions:
            String(localized: "The downloaded rendition has invalid system-sticker dimensions.")
        case .checksumMismatch:
            String(localized: "The downloaded rendition failed its integrity check.")
        case .fullSizeTooLarge:
            String(localized: "The full-size image is too large to send.")
        case .fullSizeInvalidDimensions:
            String(localized: "The full-size image has unexpected dimensions.")
        }
    }
}

/// The rules one cache directory enforces on everything it stores.
///
/// Two surfaces read the same library and want opposite things from it. The Messages extension
/// needs files Apple will accept as an `MSSticker` — under 500 KB, square, and at one of three
/// exact sizes. The full-size extension sends attachments, which have none of those rules and
/// would be pointless if they did. Rather than branch inside the cache, each surface hands it a
/// policy and gets its own directory.
struct StickerCachePolicy: Equatable, Sendable {
    let directoryName: String
    let maximumByteCount: Int
    /// `nil` means any dimension up to `maximumPixelDimension` is fine.
    let allowedPixelDimensions: Set<Int>?
    let maximumPixelDimension: Int
    let requiresSquare: Bool
    /// Whether a WebP may be stored here.
    ///
    /// False for the sticker cache and true for the full-size one, and the difference is Apple's
    /// rather than ours: `MSSticker.h` requires a file conforming to `kUTTypePNG`, `kUTTypeGIF` or
    /// `kUTTypeJPEG`, and WebP (`org.webmproject.webp`) conforms to none of them. A WebP in the
    /// sticker directory would therefore become an `MSSticker` that fails to initialise at grid
    /// build time, long after the bytes were fetched — so it is refused where it lands instead.
    let allowsWebP: Bool
    /// Budget for the whole directory, enforced by `trim()`. `nil` is unbounded — which is what
    /// the system cache has always been, since it is capped implicitly by the library's size.
    let maximumTotalByteCount: Int?
    let tooLargeError: StickerCacheError
    let invalidDimensionsError: StickerCacheError

    /// A conservative decimal threshold keeps every cached file below Apple's
    /// 500 KB limit regardless of whether a caller labels KB as 1000 or 1024.
    static let systemSticker = StickerCachePolicy(
        directoryName: "StickerFactoryMessages",
        maximumByteCount: 500_000,
        allowedPixelDimensions: [300, 408, 618],
        maximumPixelDimension: 618,
        requiresSquare: true,
        allowsWebP: false,
        maximumTotalByteCount: nil,
        tooLargeError: .fileTooLarge,
        invalidDimensionsError: .invalidDimensions
    )

    /// Matched to `StickerExportMetadataPolicy.uploadByteCeiling`, which is the real bound on
    /// anything this path can be asked to fetch: the publisher walks its ladder against that
    /// ceiling and uploads whatever fits under it.
    ///
    /// This was 8 MB, on the reasoning that it "sits far above any real 1024² PNG or APNG". That is
    /// not true of what the pipeline actually produces — a published 618 px APNG measured 9.8 MB and
    /// a 1024 px one 23.5 MB — so the cap was silently rejecting the Large rendition of animated
    /// stickers and falling the send back to the 300 px system sticker. A ceiling below what the
    /// publisher can upload is not a safety margin, it is a rendition that never arrives.
    static let fullSize = StickerCachePolicy(
        directoryName: "StickerFactoryMessagesFull",
        maximumByteCount: 25 * 1024 * 1024,
        allowedPixelDimensions: nil,
        maximumPixelDimension: 1024,
        requiresSquare: false,
        // `insertAttachment` in the expanded context is the only thing that reads these files, and
        // it has none of `MSSticker`'s format rules.
        allowsWebP: true,
        maximumTotalByteCount: 150_000_000,
        tooLargeError: .fullSizeTooLarge,
        invalidDimensionsError: .fullSizeInvalidDimensions
    )
}

actor SharedStickerCache {
    /// Kept as statics because they read as the Messages contract everywhere they are used —
    /// and because `StickerLibraryClient` and the contract tests reference them by these names.
    static let maximumByteCount = StickerCachePolicy.systemSticker.maximumByteCount
    static let maximumPixelDimension = StickerCachePolicy.systemSticker.maximumPixelDimension
    static let allowedPixelDimensions = StickerCachePolicy.systemSticker.allowedPixelDimensions!

    static let mineSectionID = "mine"
    static let mineSectionTitle = String(localized: "My Stickers")
    /// 2 added sections; 3 added `lastUsedAt`; 4 added `variant`. Older indexes migrate in place —
    /// see `CacheEntry.init(from:)` — so a bump costs nothing and no cache is ever discarded for it.
    ///
    /// A full-size entry written before 4 carries no variant and so matches none of the size-keyed
    /// lookups that replaced it. That is the right outcome and it cleans itself up: the next
    /// refresh's `removeEntries(notIn:)` is passed only variant-bearing keys, so the orphan is
    /// deleted rather than left occupying the 150 MB budget.
    static let indexVersion = 4

    private let fileManager: FileManager
    private let policy: StickerCachePolicy
    private let rootURL: URL
    private let indexURL: URL
    private var index: CacheIndex?

    init(policy: StickerCachePolicy = .systemSticker, fileManager: FileManager = .default) throws {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: SharedAuthConfiguration.appGroupIdentifier
        ) else {
            throw StickerCacheError.appGroupUnavailable
        }
        self.fileManager = fileManager
        self.policy = policy
        rootURL = container
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Caches", directoryHint: .isDirectory)
            .appending(path: policy.directoryName, directoryHint: .isDirectory)
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
                || (try? Self.validateFile(at: url, policy: policy)) == nil
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
                position: entry.position,
                variant: entry.variant
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
        guard data.count < policy.maximumByteCount else {
            throw policy.tooLargeError
        }
        if let declaredSize = descriptor.byteSize, declaredSize >= policy.maximumByteCount {
            throw policy.tooLargeError
        }
        guard Self.checksumMatches(data, expected: descriptor.sha256) else {
            throw StickerCacheError.checksumMismatch
        }

        let fileExtension = try Self.validatedFileExtension(
            for: data,
            declaredMimeType: descriptor.mimeType,
            policy: policy
        )
        try Self.validateImage(data, policy: policy)
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
            position: descriptor.position,
            lastUsedAt: Date(),
            variant: descriptor.variant
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
            position: entry.position,
            variant: entry.variant
        )
    }

    /// One entry, without materializing every section.
    ///
    /// The full-size cache is filled lazily on tap, so "do I already have this?" is the hot
    /// question there — and answering it by building the whole sectioned library would re-validate
    /// every file on disk to answer about one.
    func cachedSticker(for key: CacheKey, subject: String) throws -> CachedSticker? {
        try prepare(for: subject)
        let current = try loadIndex()
        guard let entry = current.entries.first(where: { $0.key == key }) else { return nil }
        let url = rootURL.appending(path: entry.filename)
        guard fileManager.fileExists(atPath: url.path),
              (try? Self.validateFile(at: url, policy: policy)) != nil else {
            return nil
        }
        return CachedSticker(
            stickerID: entry.stickerID,
            assetID: entry.assetID,
            title: entry.title,
            fileURL: url,
            updatedAt: entry.updatedAt,
            sectionID: entry.sectionID,
            sectionTitle: entry.sectionTitle,
            sectionSubtitle: entry.sectionSubtitle,
            sectionPosition: entry.sectionPosition,
            position: entry.position,
            variant: entry.variant
        )
    }

    /// Refreshes an entry's LRU stamp. Cheap enough to call on every send.
    func markUsed(_ key: CacheKey) throws {
        var current = try loadIndex()
        guard let position = current.entries.firstIndex(where: { $0.key == key }) else { return }
        current.entries[position].lastUsedAt = Date()
        index = current
        try persistIndex()
    }

    /// Evicts least-recently-used files until the directory fits the policy's budget.
    ///
    /// A no-op for any policy without one, so the system cache is never touched.
    func trim() throws {
        guard let budget = policy.maximumTotalByteCount else { return }
        var current = try loadIndex()

        // One file can back several entries (the same sticker in two packs), so size is measured
        // per unique file and an eviction only happens once every entry pointing at it is gone.
        var sizeByFilename: [String: Int] = [:]
        for filename in Set(current.entries.map(\.filename)) {
            let url = rootURL.appending(path: filename)
            sizeByFilename[filename] = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        var total = sizeByFilename.values.reduce(0, +)
        guard total > budget else { return }

        for entry in current.entries.sorted(by: { $0.lastUsedAt < $1.lastUsedAt }) {
            guard total > budget else { break }
            current.entries.removeAll { $0.key == entry.key }
            guard !current.entries.contains(where: { $0.filename == entry.filename }) else { continue }
            try? fileManager.removeItem(at: rootURL.appending(path: entry.filename))
            total -= sizeByFilename[entry.filename] ?? 0
        }

        index = current
        try persistIndex()
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

    /// - Parameter policy: which directory the file is bound for. Only WebP differs between the
    ///   two, and it defaults to the stricter of them so a caller that does not say gets the
    ///   sticker cache's rules.
    static func validatedFileExtension(
        for data: Data,
        declaredMimeType: String,
        policy: StickerCachePolicy = .systemSticker
    ) throws -> String {
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
        // A RIFF container whose form type is `WEBP`, which is the whole of the signature. What
        // follows says which codec chunk it carries — `VP8 `, `VP8L`, or the `VP8X` that an
        // animation uses — and neither this gate nor `insertAttachment` needs to know which.
        let header = Array(data.prefix(12))
        if header.count == 12,
           Array(header[0 ..< 4]) == Array("RIFF".utf8),
           Array(header[8 ..< 12]) == Array("WEBP".utf8) {
            guard policy.allowsWebP,
                  normalizedMimeType.isEmpty || normalizedMimeType == "image/webp" else {
                throw StickerCacheError.unsupportedFile
            }
            return "webp"
        }
        throw StickerCacheError.unsupportedFile
    }

    /// The Messages-rendition rules, unchanged. Kept as the bare signature because that is the
    /// contract every existing caller and test asserts against.
    static func validateImage(_ data: Data) throws {
        try validateImage(data, policy: .systemSticker)
    }

    /// Header-only: `CGImageSourceCopyPropertiesAtIndex` reads dimensions without decoding the
    /// image, which matters on the full-size path where a decode would be megabytes of pixels.
    static func validateImage(_ data: Data, policy: StickerCachePolicy) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0,
              max(width, height) <= policy.maximumPixelDimension else {
            throw policy.invalidDimensionsError
        }
        if policy.requiresSquare, width != height {
            throw policy.invalidDimensionsError
        }
        if let allowed = policy.allowedPixelDimensions, !allowed.contains(width) {
            throw policy.invalidDimensionsError
        }
    }

    private static func validateFile(at url: URL, policy: StickerCachePolicy) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size < policy.maximumByteCount else {
            throw policy.tooLargeError
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        _ = try validatedFileExtension(for: data, declaredMimeType: "")
        try validateImage(data, policy: policy)
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
    /// Drives LRU eviction in `trim()`. Only the full-size cache has a budget to enforce, but
    /// every entry carries the stamp so the two directories share one index format.
    var lastUsedAt: Date
    /// Which rendition this entry holds — see `CacheKey.variant`. Nil throughout the system cache.
    let variant: String?

    var key: CacheKey { CacheKey(sectionID: sectionID, stickerID: stickerID, variant: variant) }

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
        position: Int,
        lastUsedAt: Date,
        variant: String?
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
        self.lastUsedAt = lastUsedAt
        self.variant = variant
    }

    /// A v1 entry has no section fields and describes a sticker the user owns, so it migrates
    /// straight into "My Stickers" with nothing re-downloaded. A v2 entry has no `lastUsedAt`,
    /// so it starts life as old as its content — which is the right initial LRU ordering. A v3
    /// entry has no `variant`, which is what a single-rendition cache means and exactly what the
    /// system cache still writes — so it migrates by meaning the same thing.
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
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt) ?? updatedAt
        variant = try container.decodeIfPresent(String.self, forKey: .variant)
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
