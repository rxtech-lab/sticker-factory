import SwiftUI

#if canImport(UIKit)
import UIKit

/// `UIImage` on iOS, `NSImage` on macOS.
///
/// The single bridge between this package and a platform UI framework. Keeping it to one typealias
/// is what lets the whole module build for macOS, which in turn is what lets `swift test` run from
/// the command line instead of only through an iOS simulator destination.
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit

public typealias PlatformImage = NSImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}
