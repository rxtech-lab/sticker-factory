#!/usr/bin/env swift

// Generates the "iMessage App Icon" stickers icon set from icon.icon.
//
// Icon Composer only renders square icons, but Messages needs 4:3 art (and an
// opaque 1024x768 marketing image). This renders the square icon with ictool and
// letterboxes it onto a flat white canvas at every size Messages asks for.
//
// Usage: scripts/generate-imessage-icon.swift

import AppKit
import Foundation

let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let iconDocument = projectRoot.appendingPathComponent("icon.icon")
let iconSet = projectRoot
    .appendingPathComponent("StickerMessages/Assets.xcassets/iMessage App Icon.stickersiconset")

let ictool = URL(fileURLWithPath:
    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool")

struct Variant {
    let width: Int      // points
    let height: Int
    let scale: Int
    let idiom: String
    let filename: String
}

let variants = [
    Variant(width: 29, height: 29, scale: 2, idiom: "iphone", filename: "icon-29@2x.png"),
    Variant(width: 29, height: 29, scale: 3, idiom: "iphone", filename: "icon-29@3x.png"),
    Variant(width: 60, height: 45, scale: 2, idiom: "iphone", filename: "icon-60x45@2x.png"),
    Variant(width: 60, height: 45, scale: 3, idiom: "iphone", filename: "icon-60x45@3x.png"),
    Variant(width: 29, height: 29, scale: 2, idiom: "ipad", filename: "icon-29@2x~ipad.png"),
    Variant(width: 67, height: 50, scale: 2, idiom: "ipad", filename: "icon-67x50@2x.png"),
    Variant(width: 74, height: 55, scale: 2, idiom: "ipad", filename: "icon-74x55@2x.png"),
    Variant(width: 27, height: 20, scale: 2, idiom: "universal", filename: "icon-27x20@2x.png"),
    Variant(width: 27, height: 20, scale: 3, idiom: "universal", filename: "icon-27x20@3x.png"),
    Variant(width: 32, height: 24, scale: 2, idiom: "universal", filename: "icon-32x24@2x.png"),
    Variant(width: 32, height: 24, scale: 3, idiom: "universal", filename: "icon-32x24@3x.png"),
    Variant(width: 1024, height: 768, scale: 1, idiom: "ios-marketing", filename: "icon-1024x768.png"),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// MARK: - Render the square icon with Icon Composer's own renderer

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("imessage-icon-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

let squareURL = scratch.appendingPathComponent("square.png")
let render = Process()
render.executableURL = ictool
render.arguments = [
    iconDocument.path, "--export-image",
    "--output-file", squareURL.path,
    "--platform", "iOS", "--rendition", "Default",
    "--width", "1024", "--height", "1024", "--scale", "2",
]
render.standardOutput = FileHandle.nullDevice
try render.run()
render.waitUntilExit()
guard render.terminationStatus == 0,
      let squareImage = NSImage(contentsOf: squareURL),
      let square = squareImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fail("ictool could not render \(iconDocument.lastPathComponent)") }

// MARK: - Compose each variant

let colorSpace = CGColorSpaceCreateDeviceRGB()

func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fail("could not encode \(url.lastPathComponent)")
    }
    try data.write(to: url)
}

for variant in variants {
    let width = variant.width * variant.scale
    let height = variant.height * variant.scale

    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { fail("could not allocate context for \(variant.filename)") }
    context.interpolationQuality = .high

    // Flat white behind the art: keeps the file opaque (App Store icons reject alpha)
    // without inventing a background color the icon does not have.
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let inset = CGFloat(width - height) / 2
    context.draw(square, in: CGRect(x: inset, y: 0, width: CGFloat(height), height: CGFloat(height)))

    guard let image = context.makeImage() else { fail("could not compose \(variant.filename)") }
    try write(image, to: iconSet.appendingPathComponent(variant.filename))
}

// MARK: - Contents.json

var entries: [String] = []
for variant in variants {
    var fields = [
        "\"filename\" : \"\(variant.filename)\"",
        "\"idiom\" : \"\(variant.idiom)\"",
        "\"size\" : \"\(variant.width)x\(variant.height)\"",
        "\"scale\" : \"\(variant.scale)x\"",
    ]
    if variant.idiom == "universal" || variant.idiom == "ios-marketing" {
        fields.append("\"platform\" : \"ios\"")
    }
    entries.append("    {\n      " + fields.joined(separator: ",\n      ") + "\n    }")
}
let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(to: iconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

print("Wrote \(variants.count) images + Contents.json to \(iconSet.path)")
