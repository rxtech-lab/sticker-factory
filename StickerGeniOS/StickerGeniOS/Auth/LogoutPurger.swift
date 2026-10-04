import Foundation

nonisolated enum SharedLogoutPurger {
    static func purge(fileManager: FileManager = .default) {
        // The app's own container, not the group's: `StickerAssetData` caches the container bytes
        // of animated artwork so a sticker only downloads once, and those bytes are the outgoing
        // account's private art.
        StickerAssetData.purge(fileManager: fileManager)
        try? fileManager.removeItem(at: StickerVideoFrameLoader.directory)
        Task { await StickerVideoFrameLoader.shared.removeAll() }
        // Where the outgoing account was and how far it walked, kept for the Messages extension.
        PetContextCache().clear()

        let group = AppConfiguration.appGroupIdentifier
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: group) else { return }
        // "Pet" is `PetSnapshotStore`'s: the widget's picture of the outgoing account's pet.
        for directory in ["StickerCache", "Exports", "Uploads", "Pet"] {
            let url = container.appending(path: directory, directoryHint: .isDirectory)
            try? fileManager.removeItem(at: url)
        }
        // Mirrors StickerCachePolicy.{systemSticker,fullSize}.directoryName in
        // StickerMessages/SharedStickerCache.swift, which this target does not compile.
        // Adding a cache policy there means adding its directory name here.
        for name in ["StickerFactoryMessages", "StickerFactoryMessagesFull"] {
            let messagesCache = container
                .appending(path: "Library", directoryHint: .isDirectory)
                .appending(path: "Caches", directoryHint: .isDirectory)
                .appending(path: name, directoryHint: .isDirectory)
            try? fileManager.removeItem(at: messagesCache)
        }
    }
}
