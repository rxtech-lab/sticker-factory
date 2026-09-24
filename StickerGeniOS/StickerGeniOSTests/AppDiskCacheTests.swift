import Foundation
import Testing
@testable import StickerGeniOS

@Suite("Disk cache storage")
struct AppDiskCacheTests {
    @Test("Measures and clears only the selected cache directories")
    func selectedDirectories() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "cache-storage-test-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        let imageCache = root.appending(path: "image-cache")
        let messagesCache = root.appending(path: "messages-cache")
        let export = root.appending(path: "export.png")
        try fileManager.createDirectory(at: imageCache, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: messagesCache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 16).write(to: imageCache.appending(path: "image.png"))
        try Data(repeating: 2, count: 24).write(to: messagesCache.appending(path: "sticker.png"))
        try Data(repeating: 3, count: 32).write(to: export)

        let directories = [imageCache, messagesCache]
        #expect(try AppDiskCache.byteCount(in: directories) >= 40)
        try AppDiskCache.remove(directories)
        #expect(try AppDiskCache.byteCount(in: directories) == 0)
        #expect(fileManager.fileExists(atPath: export.path))
    }
}
