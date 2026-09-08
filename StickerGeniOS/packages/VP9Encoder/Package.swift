// swift-tools-version: 6.0
import PackageDescription

/// VP9-in-WebM encoding for Telegram video stickers, on the phone.
///
/// `libvpx` is a prebuilt static xcframework produced by `scripts/build-libvpx.sh` from a pinned
/// upstream tag — VP9 only, BSD-licensed, with nothing GPL or "nonfree" in the tree. `CVPX` is a
/// thin C shim over the parts of the libvpx API that Swift cannot call directly (variadic
/// controls, ABI-version macros, union packet fields). `VP9Encoder` is the Swift API: RGBA frames
/// in, a transparent VP9 WebM out, plus a reader that decodes one back for validation.
let package = Package(
    name: "VP9Encoder",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "VP9Encoder", targets: ["VP9Encoder"])
    ],
    targets: [
        .binaryTarget(name: "libvpx", path: "libvpx.xcframework"),
        .target(
            name: "CVPX",
            dependencies: ["libvpx"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "VP9Encoder",
            dependencies: ["CVPX"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VP9EncoderTests",
            dependencies: ["VP9Encoder"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
