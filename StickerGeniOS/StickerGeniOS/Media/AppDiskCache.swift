import Foundation

/// Only regenerable artwork and Messages downloads belong here. Exports and uploads may still be
/// needed by the user, so they are intentionally outside this list.
nonisolated enum AppDiskCache {
    static func directories(fileManager: FileManager = .default) -> [URL] {
        var paths = [
            StickerImageCache.diskDirectory,
            PetArtworkImageCache.shared.diskDirectory,
            PetArtworkImageCache.shared.weatherDiskDirectory,
            StickerAssetData.directory,
            StickerVideoFrameLoader.directory
        ]
        if let group = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier
        ) {
            let sharedCaches = group
                .appending(path: "Library", directoryHint: .isDirectory)
                .appending(path: "Caches", directoryHint: .isDirectory)
            paths += ["StickerFactoryMessages", "StickerFactoryMessagesFull"].map {
                sharedCaches.appending(path: $0, directoryHint: .isDirectory)
            }
            paths.append(group.appending(path: "StickerCache", directoryHint: .isDirectory))
        }
        return paths
    }

    static func byteCount(in directories: [URL], fileManager: FileManager = .default) throws -> Int64 {
        try directories.reduce(into: Int64(0)) { total, directory in
            total += try byteCount(at: directory, fileManager: fileManager)
        }
    }

    private static func byteCount(at url: URL, fileManager: FileManager) throws -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey])
        if values.isDirectory == true {
            return try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .reduce(into: Int64(0)) { total, child in
                    total += try byteCount(at: child, fileManager: fileManager)
                }
        }
        guard values.isRegularFile == true else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }

    static func remove(_ directories: [URL], fileManager: FileManager = .default) throws {
        for directory in directories where fileManager.fileExists(atPath: directory.path) {
            for item in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                try fileManager.removeItem(at: item)
            }
        }
    }

    static func clear() async throws -> Int64 {
        let paths = directories()
        await StickerImageCache.clear()
        await PetArtworkImageCache.shared.clear()
        await StickerVideoFrameLoader.shared.removeAll()
        try await Task.detached(priority: .utility) {
            try remove(paths)
        }.value
        return try await Task.detached(priority: .utility) {
            try byteCount(in: paths)
        }.value
    }
}
