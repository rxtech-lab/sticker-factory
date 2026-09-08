// swift-tools-version: 6.0
import PackageDescription

/// The official WhatsApp third-party sticker integration, as a module.
///
/// Adapted from WhatsApp's `WAStickersThirdParty` sample (BSD-licensed; see `LICENSE`): the
/// pasteboard hand-off, the limits WhatsApp enforces, and a pack model that validates against
/// them. Trimmed of the sample app's UI and of its bundled WebP decoder — ImageIO reads WebP on
/// every supported iOS, so inspection goes through it instead.
let package = Package(
    name: "WASticker",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "WASticker", targets: ["WASticker"])
    ],
    targets: [
        .target(name: "WASticker", swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
