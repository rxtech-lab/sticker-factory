import Foundation
import PhotosUI
import SwiftUI

/// A photo the user has attached but not yet uploaded.
///
/// Lives in its own file rather than in `StickerStore` because of `source`: `PhotosPickerItem` is
/// declared in PhotosUI's SwiftUI overlay, so naming it drags `import SwiftUI` in with it, and a
/// store has no business importing SwiftUI.
nonisolated struct PendingMediaAttachment: Identifiable, Sendable {
    var id = UUID()
    var data: Data
    var filename: String
    var mimeType: String
    /// Set only when `data` is a frame atlas lifted from a Live Photo. Its presence is what makes
    /// this attachment upload as `AssetKind.sequence` instead of as an ordinary reference — the
    /// bytes alone cannot say, since an atlas is a perfectly ordinary still PNG.
    var sequence: SequenceMetadata?
    /// The picked item this came from, kept so the photo can be re-opened later.
    ///
    /// `data` has already been normalized — re-encoded, downscaled, and reduced to a single still —
    /// so by the time an attachment exists, the paired video of a Live Photo is gone. Lifting a
    /// subject *with its motion* has to go back to the original item, and this is the only handle
    /// on it. Nil for anything not picked from the photo library, and never uploaded.
    var source: PhotosPickerItem?
}
