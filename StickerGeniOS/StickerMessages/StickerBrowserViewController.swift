import Messages
import UIKit

@MainActor
final class StickerBrowserViewController: MSStickerBrowserViewController {
    private var stickers: [MSSticker] = []

    init() {
        super.init(stickerSize: .regular)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "sticker-factory-messages-browser"
    }

    override func numberOfStickers(in stickerBrowserView: MSStickerBrowserView) -> Int {
        stickers.count
    }

    override func stickerBrowserView(
        _ stickerBrowserView: MSStickerBrowserView,
        stickerAt index: Int
    ) -> MSSticker {
        stickers[index]
    }

    func replaceStickers(with cachedStickers: [CachedSticker]) {
        stickers = cachedStickers.compactMap { cached in
            try? MSSticker(
                contentsOfFileURL: cached.fileURL,
                localizedDescription: String(cached.title.prefix(150))
            )
        }
        stickerBrowserView.reloadData()
    }
}
