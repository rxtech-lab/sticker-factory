import Foundation

nonisolated enum SharedLogoutPurger {
    static func purge(fileManager: FileManager = .default) {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier) else { return }
        for directory in ["StickerCache", "Exports", "Uploads"] {
            let url = container.appending(path: directory, directoryHint: .isDirectory)
            try? fileManager.removeItem(at: url)
        }
        let messagesCache = container
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Caches", directoryHint: .isDirectory)
            .appending(path: "StickerFactoryMessages", directoryHint: .isDirectory)
        try? fileManager.removeItem(at: messagesCache)
    }
}
