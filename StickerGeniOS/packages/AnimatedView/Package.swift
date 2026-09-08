// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AnimatedView",
    // macOS is declared so `swift build` / `swift test` run from the command line without a
    // simulator destination. Nothing in the module may depend on UIKit-only types; the
    // `PlatformImage` typealias is the single bridge.
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "AnimatedView",
            targets: ["AnimatedView"]
        )
    ],
    dependencies: [
        // Full SVG document parsing. SVGView builds in Swift 5 language mode and its node model is
        // a tree of non-Sendable ObservableObject classes, so every use of it in this package is
        // confined to `SVGFlattener` (@MainActor) and converted to `SVGDrawing` value types before
        // it can reach anything Sendable.
        .package(url: "https://github.com/exyte/SVGView.git", from: "1.0.6")
    ],
    targets: [
        .target(
            name: "AnimatedView",
            dependencies: ["SVGView"]
        ),
        .testTarget(
            name: "AnimatedViewTests",
            dependencies: ["AnimatedView"],
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)
