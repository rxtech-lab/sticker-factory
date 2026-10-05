import Foundation
import Kingfisher
import UIKit

/// Keeps downloaded artwork in its original format, including WebP item images.
nonisolated private struct PetArtworkCacheSerializer: CacheSerializer {
    func data(with image: UIImage, original: Data?) -> Data? { original ?? image.pngData() }
    func image(with data: Data, options: KingfisherParsedOptionsInfo) -> UIImage? { UIImage(data: data) }
}

actor PetArtworkImageCache {
    static let shared = PetArtworkImageCache()

    private nonisolated let cache: ImageCache
    private nonisolated let weatherCache: ImageCache
    /// Rooms are drawn once and never change, so a room is kept until the cache needs the space.
    private nonisolated let roomCache: ImageCache
    private static let weatherScopeKey = "pet.weatherArtwork.scope.v1"
    private var weatherScope = UserDefaults.standard.string(forKey: weatherScopeKey)
    private var weatherReset: Task<Void, Never>?
    private var downloads: [String: Task<UIImage, Error>] = [:]
    private let options = KingfisherParsedOptionsInfo([
        .cacheSerializer(PetArtworkCacheSerializer()),
        .diskCacheExpiration(.seconds(12 * 60 * 60)),
        .diskCacheAccessExtendingExpiration(.none)
    ])
    private let weatherOptions = KingfisherParsedOptionsInfo([
        .cacheSerializer(PetArtworkCacheSerializer()),
        .memoryCacheExpiration(.never),
        .diskCacheExpiration(.never),
        .diskCacheAccessExtendingExpiration(.none)
    ])

    private init() {
        // Keep the existing directory so item images cached before weather support remain usable.
        cache = ImageCache(name: "pet-items-v1")
        cache.diskStorage.config.sizeLimit = 32 * 1024 * 1024
        cache.memoryStorage.config.totalCostLimit = 8 * 1024 * 1024
        weatherCache = ImageCache(name: "pet-weather-v1")
        weatherCache.diskStorage.config.expiration = .never
        weatherCache.diskStorage.config.sizeLimit = 0
        weatherCache.memoryStorage.config.totalCostLimit = 8 * 1024 * 1024
        roomCache = ImageCache(name: "pet-rooms-v1")
        roomCache.diskStorage.config.expiration = .never
        roomCache.diskStorage.config.sizeLimit = 64 * 1024 * 1024
        roomCache.memoryStorage.config.totalCostLimit = 24 * 1024 * 1024
    }

    nonisolated var diskDirectory: URL { cache.diskStorage.directoryURL }
    nonisolated var weatherDiskDirectory: URL { weatherCache.diskStorage.directoryURL }

    func clear() async {
        await weatherReset?.value
        await cache.clearCache()
        await weatherCache.clearCache()
        await roomCache.clearCache()
    }

    /// Weather looks stay until the owner changes pets or this sticker's playback changes.
    @discardableResult
    func prepareWeather(for pet: Pet?) async -> Bool {
        let scope = pet.map(Self.scope)
        let changed = scope != weatherScope
        if changed {
            weatherScope = scope
            UserDefaults.standard.set(scope, forKey: Self.weatherScopeKey)
            let pending = downloads.filter { $0.key.hasPrefix("weather.") }.map(\.value)
            pending.forEach { $0.cancel() }
            let previous = weatherReset
            let weatherCache = weatherCache
            weatherReset = Task {
                await previous?.value
                for download in pending { _ = try? await download.value }
                await weatherCache.clearCache()
            }
        }
        await weatherReset?.value
        return changed
    }

    private static func scope(_ pet: Pet) -> String {
        "\(pet.sticker.id)|\(pet.sticker.playbackRevisionId ?? "")|\(pet.selectedAt.timeIntervalSince1970)"
    }

    func load(artKey: String, index: Int, size: Int, api: StickerAPIClientProtocol) async throws -> UIImage {
        let key = "\(artKey).\(index).\(size)"
        return try await load(key: key, cache: cache, options: options) {
            try await api.petItemArt(index: index, size: size, artKey: artKey)
        }
    }

    func loadWeather(pet: Pet, artKey: String, size: Int, api: StickerAPIClientProtocol) async throws -> UIImage {
        await prepareWeather(for: pet)
        let scope = Self.scope(pet)
        guard scope == weatherScope else { throw CancellationError() }
        return try await load(key: "weather.\(scope).\(artKey).\(size)", cache: weatherCache, options: weatherOptions) {
            try await api.petWeatherArt(size: size, artKey: artKey)
        }
    }

    /// One room's drawing. Keyed by its `artKey`, which names a drawing that never changes.
    func loadRoom(roomID: String, artKey: String, api: StickerAPIClientProtocol) async throws -> UIImage {
        try await load(key: "room.\(artKey)", cache: roomCache, options: weatherOptions) {
            try await api.petRoomArt(roomID: roomID)
        }
    }

    private func load(
        key: String, cache: ImageCache, options: KingfisherParsedOptionsInfo,
        fetch: @escaping @Sendable () async throws -> Data
    ) async throws -> UIImage {
        if let download = downloads[key] { return try await download.value }
        let download = Task<UIImage, Error> {
            if let result = try? await cache.retrieveImage(forKey: key, options: options),
               let image = result.image { return image }
            let data = try await fetch()
            try Task.checkCancellation()
            guard let image = UIImage(data: data) else { throw StickerAPIError.invalidResponse }
            // Disk failures must not prevent an already downloaded image from being shown.
            try? await cache.store(image, original: data, forKey: key, options: options)
            return image
        }
        downloads[key] = download
        defer { downloads[key] = nil }
        return try await download.value
    }
}
