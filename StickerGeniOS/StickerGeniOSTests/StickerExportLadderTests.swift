import AnimatedView
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import StickerGeniOS

/// The sticker rendition is the one export with a hard external limit — Apple rejects anything at or
/// above 500 KB — and the ladder that fits into it is hand-written down to the PNG chunk. These tests
/// cover the two things that are easy to get wrong and impossible to notice late: a file that no
/// decoder accepts, and a ladder that runs out of rungs and refuses to export at all.
@Suite("System sticker ladder")
struct StickerExportLadderTests {
    /// Dense, moving artwork: a gradient body that never repeats a colour and a marker that crosses
    /// the canvas, so neither the palette nor the frame differencing gets an easy ride.
    private func frame(index: Int, frameCount: Int, dimension: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: dimension, height: dimension, bitsPerComponent: 8,
            bytesPerRow: dimension * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let side = Double(dimension)
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.saveGState()
        context.addEllipse(in: CGRect(x: side * 0.1, y: side * 0.1, width: side * 0.8, height: side * 0.8))
        context.clip()
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 0.98, green: 0.71, blue: 0.2, alpha: 1),
                CGColor(red: 0.36, green: 0.28, blue: 0.92, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
        context.restoreGState()
        let progress = Double(index) / Double(frameCount)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        context.fillEllipse(in: CGRect(
            x: side * 0.1 + progress * side * 0.7, y: side * 0.45,
            width: side * 0.2, height: side * 0.2
        ))
        return context.makeImage()!
    }

    private func census(frames: [CGImage]) -> IndexedPNGEncoder.ColorCensus {
        var census = IndexedPNGEncoder.ColorCensus(lattice: .init(colorLevels: 32, alphaLevels: 8))
        for frame in frames { census.add(frame) }
        return census
    }

    @Test("A palette APNG decodes to the frames and timing it was written with")
    func indexedAnimationRoundTrips() throws {
        let dimension = 300
        let frameCount = 32
        let frames = (0..<frameCount).map { frame(index: $0, frameCount: frameCount, dimension: dimension) }
        let delays = StickerExportMetadataPolicy.apngFrameDelays(frameCount: frameCount, fps: 8, holdSeconds: 0.6)
        let stream = IndexedPNGEncoder.AnimationStream(
            palette: census(frames: frames).palette(limit: 256),
            dimension: dimension,
            frameCount: frameCount,
            loopCount: 0,
            byteBudget: StickerExportMetadataPolicy.systemStickerByteCeiling - 1
        )
        for (index, image) in frames.enumerated() { stream.append(frame: image, delaySeconds: delays[index]) }
        let data = try #require(stream.finish())

        // The frames span 4 s at 8 FPS and the last one is held 0.6 s longer before the loop
        // restarts, which is the duration the server recomputes from the file.
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == frameCount)
        let decodedDuration = (0..<CGImageSourceGetCount(source)).reduce(0.0) { total, index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            return total + ((png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double) ?? 0)
        }
        #expect(abs(decodedDuration - 4.6) < 0.01)

        // Every frame is reconstructed from the palette and the rectangle that changed, so a
        // decoded frame has to match the frame it was written from — bar the quantization.
        for index in [0, frameCount / 2, frameCount - 1] {
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
            #expect(decoded.width == dimension && decoded.height == dimension)
            let rendered = try #require(IndexedPNGEncoder.rgbaBytes(from: decoded)?.pixels)
            let expected = try #require(IndexedPNGEncoder.rgbaBytes(from: frames[index])?.pixels)
            #expect(rendered.count == expected.count)
            var error = 0.0
            for offset in stride(from: 0, to: rendered.count, by: 4) {
                error += abs(Double(rendered[offset + 3]) - Double(expected[offset + 3])) / 255
            }
            #expect(error / Double(rendered.count / 4) < 0.05)
        }
    }

    @Test("The palette encoder beats ImageIO by enough to matter")
    func indexedAnimationIsSmallerThanImageIO() throws {
        let dimension = 300
        let frameCount = 32
        let frames = (0..<frameCount).map { frame(index: $0, frameCount: frameCount, dimension: dimension) }
        let stream = IndexedPNGEncoder.AnimationStream(
            palette: census(frames: frames).palette(limit: 256),
            dimension: dimension,
            frameCount: frameCount,
            loopCount: 0,
            byteBudget: StickerExportMetadataPolicy.systemStickerByteCeiling - 1
        )
        for image in frames { stream.append(frame: image, delaySeconds: 0.125) }
        let indexed = try #require(stream.finish())

        let reference = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            reference, UTType.png.identifier as CFString, frameCount, nil
        ))
        for image in frames {
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.125],
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))

        // This is the whole reason the encoder exists: the same animation ImageIO writes as full
        // RGBA frames does not fit under the ceiling, and indexed it does, several times over.
        #expect(reference.length > StickerExportMetadataPolicy.systemStickerByteCeiling)
        #expect(indexed.count < StickerExportMetadataPolicy.systemStickerByteCeiling)
        #expect(indexed.count * 4 < reference.length)
    }

    @Test("A still at the ladder's floor fits the ceiling even when nothing compresses")
    func stillFloorAlwaysFits() throws {
        // Noise is the worst case for deflate: nothing repeats, so the file is essentially the raw
        // scanlines. At 300 px and sixteen palette entries those are four bits a pixel — 45 KB — so
        // the bottom of the ladder is under Apple's limit by construction rather than by luck.
        var seed: UInt64 = 0x5DEECE66D
        func random() -> UInt8 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8((seed >> 33) & 0xFF)
        }
        let dimension = 300
        var pixels = [UInt8](repeating: 0, count: dimension * dimension * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = random()
            pixels[offset + 1] = random()
            pixels[offset + 2] = random()
            pixels[offset + 3] = offset % 8 == 0 ? 0 : random()
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let noise = try #require(CGImage(
            width: dimension, height: dimension, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: dimension * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        var noiseCensus = IndexedPNGEncoder.ColorCensus(lattice: .init(colorLevels: 32, alphaLevels: 8))
        noiseCensus.add(noise)
        let data = try #require(IndexedPNGEncoder.encodeStill(
            noise, palette: noiseCensus.palette(limit: 16), dimension: dimension
        ))
        #expect(data.count < StickerExportMetadataPolicy.systemStickerByteCeiling)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == dimension && decoded.height == dimension)
    }

    /// A lifted photograph sitting inside flat sticker art: the shape that posterized in the field.
    ///
    /// A face occupies the middle third. Everything around it is the crown and the lettering —
    /// saturated, high-contrast, and most of the pixels — inside a die-cut rim that fades to
    /// transparent. The face is a narrow skin ramp broken up by the sensor noise every Live Photo
    /// frame carries, which scatters it across hundreds of lattice cells that are individually rare
    /// and collectively the whole subject.
    private struct LiftedPhotograph {
        var image: CGImage
        var rows: Range<Int>
        var dimension: Int

        func isFace(x: Int, y: Int) -> Bool {
            rows.contains(y) && abs(Double(x) / Double(dimension) - 0.5) < 0.22
        }

        /// The shade the ramp asks for at a point, before noise and before quantization.
        func skin(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
            let shade = 0.45 * (Double(x) / Double(dimension))
                + 0.55 * (Double(y - rows.lowerBound) / Double(rows.count))
            return (UInt8(238 - shade * 120), UInt8(206 - shade * 126), UInt8(182 - shade * 120))
        }
    }

    private func liftedPhotograph(dimension: Int) throws -> LiftedPhotograph {
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func noise(_ spread: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(spread * 2 + 1)) - spread
        }
        func clamp(_ value: Int) -> UInt8 { UInt8(min(255, max(0, value))) }

        let rows = (dimension * 30 / 100)..<(dimension * 62 / 100)
        var pixels = [UInt8](repeating: 0, count: dimension * dimension * 4)
        // A one-pixel placeholder the real canvas replaces, so the geometry helpers are available
        // while the pixels that use them are still being written.
        let placeholder = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
        var shape = LiftedPhotograph(
            image: try #require(placeholder),
            rows: rows,
            dimension: dimension
        )
        for y in 0..<dimension {
            for x in 0..<dimension {
                let offset = (y * dimension + x) * 4
                let across = Double(x) / Double(dimension) - 0.5
                let down = Double(y) / Double(dimension) - 0.5
                let radius = across * across + down * down
                guard radius <= 0.235 else { continue }
                pixels[offset + 3] = clamp(Int(min(1, (0.235 - radius) / 0.02) * 255))
                if shape.isFace(x: x, y: y) {
                    let skin = shape.skin(x: x, y: y)
                    pixels[offset] = clamp(Int(skin.red) + noise(5))
                    pixels[offset + 1] = clamp(Int(skin.green) + noise(5))
                    pixels[offset + 2] = clamp(Int(skin.blue) + noise(5))
                } else {
                    // Flat art, but not literally flat: a sticker's gold and its rim carry shading
                    // and anti-aliasing, and those are the high-count cells that used to win every
                    // palette slot.
                    let band = (y / 9 + x / 31) % 4
                    let lift = Double(y) / Double(dimension)
                    pixels[offset] = clamp([252, 214, 255, 176][band] - Int(lift * 55) + noise(3))
                    pixels[offset + 1] = clamp([206, 36, 255, 22][band] - Int(lift * 44) + noise(3))
                    pixels[offset + 2] = clamp([26, 44, 255, 118][band] - Int(lift * 30) + noise(3))
                }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        shape.image = try #require(CGImage(
            width: dimension, height: dimension, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: dimension * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        return shape
    }

    @Test("A lifted photograph keeps its shading when flat art shares the palette")
    func photographKeepsItsPalette() throws {
        // The bug this covers: the palette used to be the *most frequent* colours, so the art around
        // the face — more pixels, fewer colours, every one of them common — took the whole palette
        // and the face collapsed onto a handful of plates that no longer read as a person. Median
        // cut divides the colours by how far apart they are, so the face earns entries in proportion
        // to the range it covers rather than to how often any one point on it repeats.
        let dimension = 300
        let shape = try liftedPhotograph(dimension: dimension)
        var census = IndexedPNGEncoder.ColorCensus(lattice: .init(colorLevels: 32, alphaLevels: 8))
        census.add(shape.image)
        let palette = census.palette(limit: 256)

        var used = Set<UInt8>()
        var worstError = 0
        var totalError = 0
        var samples = 0
        for y in shape.rows {
            for x in stride(from: 0, to: dimension, by: 3) where shape.isFace(x: x, y: y) {
                let wanted = shape.skin(x: x, y: y)
                let index = palette.index(forKey: palette.lattice.key(
                    red: wanted.red, green: wanted.green, blue: wanted.blue, alpha: 255
                ))
                used.insert(index)
                let entry = palette.entries[Int(index)]
                worstError = max(worstError, max(
                    abs(Int(entry.red) - Int(wanted.red)),
                    abs(Int(entry.green) - Int(wanted.green)),
                    abs(Int(entry.blue) - Int(wanted.blue))
                ))
                totalError += abs(Int(entry.red) - Int(wanted.red))
                samples += 1
            }
        }
        // A tenth of the canvas earning a twelfth of the palette is the floor, not the target.
        #expect(used.count >= 18)
        // The lattice itself rounds to 8-unit steps, so no palette can resolve the ramp better than
        // that. Within a step or two of it reads as shading; the plates in the report were 40 apart.
        #expect(worstError <= 12)
        #expect(Double(totalError) / Double(samples) <= 5)
    }

    @Test("Dithering costs bytes, so every dithered palette has a plain one behind it")
    func ditherIsPairedWithAFallback() throws {
        let dimension = 300
        let shape = try liftedPhotograph(dimension: dimension)
        var census = IndexedPNGEncoder.ColorCensus(lattice: .init(colorLevels: 32, alphaLevels: 8))
        census.add(shape.image)

        let plain = try #require(IndexedPNGEncoder.encodeStill(
            shape.image, palette: census.palette(limit: 64), dimension: dimension
        ))
        let dithered = try #require(IndexedPNGEncoder.encodeStill(
            shape.image, palette: census.palette(limit: 64, dithered: true), dimension: dimension
        ))
        // Both decode as palette PNGs of the right size, and the dithered one is the larger. That is
        // the whole reason `paletteLadder` carries the pair rather than the dither alone: on a
        // sticker with no slack, the extra bytes would cost a rung of frame rate.
        for data in [plain, dithered] {
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(decoded.width == dimension && decoded.height == dimension)
        }
        #expect(dithered.count > plain.count)

        // Ordered, not error-diffused: the offset depends only on the position in the 8×8 tile, so a
        // frame that did not move maps to the indices it mapped to last time and `changedRect` stays
        // tight. Error diffusion would carry a single moved pixel across the rest of the canvas and
        // frame differencing — most of what buys the animation its budget — would stop working.
        let palette = census.palette(limit: 64, dithered: true)
        let first = try #require(palette.indices(for: shape.image, width: dimension, height: dimension))
        let second = try #require(palette.indices(for: shape.image, width: dimension, height: dimension))
        #expect(first == second)
        #expect(IndexedPNGEncoder.changedRect(from: first, to: second, dimension: dimension)
            == .init(x: 0, y: 0, width: 1, height: 1))

        // A dither that survived quantization: neighbouring positions in the tile land on different
        // entries where a flat mapping would give them the same one.
        let flat = try #require(census.palette(limit: 64)
            .indices(for: shape.image, width: dimension, height: dimension))
        #expect(zip(first, flat).contains { $0 != $1 })
    }

    @Test("Colour depth is spent last, and only on art that does not need it")
    func fidelityDecidesWhatTheLadderSpends() throws {
        // The census reports what quantizing costs *this* sticker, which is how the ladder knows
        // whether it is allowed to spend colour. Flat art absorbs a sixteen-entry palette without a
        // mark on it; the same palette is what turned a lifted face into plates.
        let dimension = 300
        let photograph = try liftedPhotograph(dimension: dimension)
        var photographic = IndexedPNGEncoder.ColorCensus(lattice: .init(colorLevels: 32, alphaLevels: 8))
        photographic.add(photograph.image)

        // The same canvas with the face replaced by more of the flat art around it.
        let context = try #require(CGContext(
            data: nil, width: dimension, height: dimension, bitsPerComponent: 8,
            bytesPerRow: dimension * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for y in 0..<dimension {
            for x in 0..<dimension {
                let band = (y / 9 + x / 31) % 4
                context.setFillColor(
                    red: [252, 214, 255, 176][band] / 255,
                    green: [206, 36, 255, 22][band] / 255,
                    blue: [26, 44, 255, 118][band] / 255,
                    alpha: 1
                )
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        var flat = IndexedPNGEncoder.ColorCensus(lattice: .init(colorLevels: 32, alphaLevels: 8))
        flat.add(try #require(context.makeImage()))

        // The threshold the exporter uses: the census lattice's own step, below which a richer
        // palette has nothing left to resolve.
        let step = Double(255 / 31)
        #expect(flat.error(of: flat.palette(limit: 16)) <= step)
        #expect(photographic.error(of: photographic.palette(limit: 16)) > step)
        #expect(photographic.error(of: photographic.palette(limit: 256)) <= step)
        // Monotonic in both directions: a richer palette never reports a worse error, or the ladder
        // could talk itself into spending colour it did not need.
        for census in [flat, photographic] {
            let rich = census.error(of: census.palette(limit: 256))
            let middle = census.error(of: census.palette(limit: 64))
            let poor = census.error(of: census.palette(limit: 16))
            #expect(rich <= middle)
            #expect(middle <= poor)
        }
    }

    @Test("A frame that changes nothing still costs a frame, not a canvas")
    func changedRectangles() {
        let dimension = 8
        var first = [UInt8](repeating: 0, count: dimension * dimension)
        #expect(IndexedPNGEncoder.changedRect(from: nil, to: first, dimension: dimension)
            == .init(x: 0, y: 0, width: dimension, height: dimension))
        // Nothing moved: an APNG frame cannot be empty, so it degenerates to one pixel repainting
        // itself rather than to the whole canvas.
        #expect(IndexedPNGEncoder.changedRect(from: first, to: first, dimension: dimension)
            == .init(x: 0, y: 0, width: 1, height: 1))

        var second = first
        second[2 * dimension + 3] = 4
        second[5 * dimension + 6] = 7
        #expect(IndexedPNGEncoder.changedRect(from: first, to: second, dimension: dimension)
            == .init(x: 3, y: 2, width: 4, height: 4))
        first[0] = 9
        #expect(IndexedPNGEncoder.changedRect(from: first, to: second, dimension: dimension)
            == .init(x: 0, y: 0, width: 7, height: 6))
    }

    @MainActor
    @Test("An animated sticker always exports under the ceiling, at a size Messages accepts")
    func animatedSystemStickerAlwaysFits() async throws {
        var document = PreviewFixtures.animatedBaseDocument
        document.layers = [
            .shape(.init(base: .init(id: "backdrop", name: "Backdrop"), shape: .burst, fill: .solid("#FFE7A3"))),
            .shape(.init(base: .init(id: "hero", name: "Hero"), shape: .circle, fill: .solid("#A88BFF"))),
        ]
        document.durationSeconds = 1
        document.fps = 12
        let rendition = try await StickerExporter().exportSystemSticker(document: document, assets: .init(), size: .small)
        defer { try? FileManager.default.removeItem(at: rendition.url) }
        let written = try Data(contentsOf: rendition.url)

        #expect(rendition.metadata.byteCount < StickerExportMetadataPolicy.systemStickerByteCeiling)
        #expect(rendition.metadata.byteCount == written.count)
        // The sizes Messages and `SharedStickerCache.allowedPixelDimensions` accept.
        #expect(StickerExportMetadataPolicy.staticSystemDimensions.contains(rendition.metadata.width))
        #expect(rendition.metadata.width == rendition.metadata.height)
        // Asking for Small means the ladder never starts above 300 px, whatever the artwork is.
        #expect(rendition.metadata.width <= SystemStickerSize.small.dimension)
        #expect(rendition.metadata.hasAlpha)

        let source = try #require(CGImageSourceCreateWithData(written as CFData, nil))
        if rendition.isStillFallback {
            #expect(CGImageSourceGetCount(source) == 1)
        } else {
            // The frame grid the server recovers from the file has to be the one the metadata
            // claims, or the publish is rejected for timing it cannot verify.
            let fps = try #require(rendition.metadata.fps)
            #expect(CGImageSourceGetCount(source)
                == StickerExportMetadataPolicy.frameCount(document: document, fps: fps))
            #expect(rendition.metadata.durationSeconds == StickerExportMetadataPolicy.renderedDuration(document))
        }
    }

    /// The APNG and its WebP copy come out of one pass, at one size, on one frame grid.
    ///
    /// The pairing is the whole design: a WebP rendered separately would mean a second full pass
    /// over the cycle — the slowest step of a publish, run twice, for identical pixels.
    @MainActor
    @Test("One pass yields both sharing containers, matched in size and timing")
    func sharingRenditionsComeFromOnePass() async throws {
        var document = PreviewFixtures.animatedBaseDocument
        document.layers = [
            .shape(.init(base: .init(id: "hero", name: "Hero"), shape: .circle, fill: .solid("#A88BFF"))),
        ]
        document.durationSeconds = 1
        document.fps = 8
        let exporter = StickerExporter()

        let rendered = try await exporter.exportSharingRenditions(document: document, assets: .init())
        defer { try? FileManager.default.removeItem(at: rendered.apng.url) }
        let webp = try #require(rendered.webp)
        defer { try? FileManager.default.removeItem(at: webp.url) }

        #expect(webp.metadata.format == .webp)
        #expect(webp.url.pathExtension == "webp")
        // Same rung of the same ladder — the server admits both only at these sizes.
        #expect(webp.metadata.width == rendered.apng.metadata.width)
        #expect(webp.metadata.height == rendered.apng.metadata.height)
        #expect(StickerExportMetadataPolicy.sharingApngDimensions.contains(webp.metadata.width))
        #expect(webp.metadata.durationSeconds == rendered.apng.metadata.durationSeconds)

        // Decoded by ImageIO, which is what the recipient's Messages uses, and holding the same
        // frame grid the server checks the APNG's against.
        let source = try #require(CGImageSourceCreateWithData(try Data(contentsOf: webp.url) as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.webP.identifier)
        #expect(CGImageSourceGetCount(source)
            == StickerExportMetadataPolicy.frameCount(document: document, fps: document.fps))

        // The reason it is published at all.
        #expect(webp.metadata.byteCount < rendered.apng.metadata.byteCount)
    }

    @MainActor
    @Test("A sharing APNG too big to upload is written smaller rather than not at all")
    func sharingApngFitsTheUploadCeiling() async throws {
        var document = PreviewFixtures.animatedBaseDocument
        document.layers = [
            .shape(.init(base: .init(id: "backdrop", name: "Backdrop"), shape: .burst, fill: .solid("#FFE7A3"))),
            .shape(.init(base: .init(id: "hero", name: "Hero"), shape: .circle, fill: .solid("#A88BFF"))),
        ]
        document.durationSeconds = 1
        document.fps = 8
        let exporter = StickerExporter()

        let full = try await exporter.exportAPNG(document: document, assets: .init())
        defer { try? FileManager.default.removeItem(at: full.url) }
        #expect(full.metadata.width == StickerExportMetadataPolicy.sharingApngDimensions[0])

        // The regression this guards: the sharing rendition used to be written at a flat 1024 px, so a long dense
        // animation declared a byteSize the API refuses to presign and the publish died on a 400
        // with the sticker left in draft. A ceiling this file cannot meet at full size stands in for
        // that animation without spending 240 frames to reproduce it.
        let squeezed = try await exporter.exportAPNG(
            document: document, assets: .init(), byteCeiling: full.metadata.byteCount / 2
        )
        defer { try? FileManager.default.removeItem(at: squeezed.url) }
        #expect(squeezed.metadata.byteCount <= full.metadata.byteCount / 2)
        #expect(squeezed.metadata.width < full.metadata.width)
        // Every rung the ladder can land on is one `validateImageForKind` in
        // `server/lib/services/assets.ts` accepts, and it is always square.
        #expect(StickerExportMetadataPolicy.sharingApngDimensions.contains(squeezed.metadata.width))
        #expect(squeezed.metadata.width == squeezed.metadata.height)

        // Pixels are the only thing this ladder may spend. The server checks the sharing rendition's frame grid
        // against the document's own frame rate and count, so a rung that thinned either would be
        // rejected for timing rather than for size.
        let source = try #require(CGImageSourceCreateWithData(try Data(contentsOf: squeezed.url) as CFData, nil))
        #expect(CGImageSourceGetCount(source)
            == StickerExportMetadataPolicy.frameCount(document: document, fps: document.fps))
        #expect(squeezed.metadata.fps == document.fps)
        #expect(squeezed.metadata.durationSeconds == StickerExportMetadataPolicy.renderedDuration(document))
    }

    /// A publish renders one sharing rendition, at the top of the ladder, and that single file is
    /// what WinkySticker sends at every size.
    ///
    /// It briefly rendered three — 618, 408 and 300 — and they were indistinguishable once sent,
    /// because `insertAttachment` scales an image attachment to a fixed bubble width whatever its
    /// pixels are. The physical size is chosen on the device now; `AttachmentCanvasRendererTests`
    /// in the extension's suite is where that ratio is asserted.
    @MainActor
    @Test("A publish renders one sharing rendition, at the top of the ladder")
    func sharingRenditionIsExportedAtFullSize() async throws {
        var document = PreviewFixtures.animatedBaseDocument
        document.layers = [
            .shape(.init(base: .init(id: "backdrop", name: "Backdrop"), shape: .burst, fill: .solid("#FFE7A3"))),
            .shape(.init(base: .init(id: "hero", name: "Hero"), shape: .circle, fill: .solid("#A88BFF"))),
        ]
        document.durationSeconds = 1
        document.fps = 12
        let exporter = StickerExporter()
        let expectedFrames = StickerExportMetadataPolicy.frameCount(document: document, fps: document.fps)

        let rendition = try await exporter.exportAPNG(document: document, assets: .init())
        defer { try? FileManager.default.removeItem(at: rendition.url) }
        // The top rung, not a rung it fell to: this fixture is two flat shapes and cannot overshoot
        // the upload ceiling.
        #expect(rendition.metadata.width == StickerExportMetadataPolicy.sharingApngDimensions[0])
        #expect(rendition.metadata.height == rendition.metadata.width)
        // Unlike the Messages rendition, this ladder never spends frame rate.
        #expect(rendition.metadata.fps == document.fps)
        let source = try #require(
            CGImageSourceCreateWithData(try Data(contentsOf: rendition.url) as CFData, nil)
        )
        #expect(CGImageSourceGetCount(source) == expectedFrames)
    }

    /// A static sticker's sharing rendition is its master: one frame has no byte ceiling to fight,
    /// so it is a plain full-colour PNG at full size.
    @MainActor
    @Test("A static sticker exports its master at full colour and full size")
    func staticMasterRendersAtFullColour() throws {
        let document = PreviewFixtures.staticDocument
        let exporter = StickerExporter()

        let master = try exporter.exportStaticPNG(document: document, assets: .init())
        defer { try? FileManager.default.removeItem(at: master.url) }
        #expect(master.metadata.width == 1024)
        #expect(master.metadata.height == 1024)
        #expect(master.metadata.hasAlpha)
        #expect(master.metadata.fps == nil)
    }


    @MainActor
    @Test("Exporting as video renders the video and nothing else")
    func videoOnlyExportSkipsTheStickerLadder() async throws {
        var revision = PreviewFixtures.candidate
        revision.candidateState = .accepted
        // The cycle stays as authored — its keyframes live on it — and only the grid is thinned, so
        // this renders a handful of frames rather than sixty.
        revision.document.fps = 8
        let publisher = StickerPublisher(api: MockStickerAPIClient())

        let video = try await publisher.export(
            revision: revision, assets: .init(), verifiedAssetIDs: [], selection: .video
        )
        defer { video.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        #expect(video.map(\.metadata.format) == [.mp4])

        let sticker = try await publisher.export(
            revision: revision, assets: .init(), verifiedAssetIDs: [], selection: .sticker
        )
        defer { sticker.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        // The sharing rendition and the Messages rendition, both APNG, and no video encode at all.
        #expect(sticker.map(\.metadata.format) == [.apng, .apng])
    }

    @MainActor
    @Test("Choosing GIF shares a GIF and still publishes the APNG")
    func gifSharingFormatSharesAGifAndPublishesTheApng() async throws {
        var revision = PreviewFixtures.candidate
        revision.candidateState = .accepted
        revision.document.fps = 8
        let api = MockStickerAPIClient()
        let publisher = StickerPublisher(api: api)

        let result = try await publisher.publish(
            stickerID: "sticker-demo", revision: revision, assets: .init(), verifiedAssetIDs: [],
            selection: .sticker, sharing: .gif
        )
        defer { result.localExports.forEach { try? FileManager.default.removeItem(at: $0.url) } }

        // The whole point of the option: the file handed to the share sheet is the GIF that will
        // animate in WhatsApp or Discord, and the file that reaches the server is still the APNG.
        // Sharing both would put two files in the sheet that differ in a way nothing explains.
        #expect(result.localExports.map(\.metadata.format) == [.gif, .apng])
        // The sharing rendition, then the ≤500 KB Messages one. Nothing else: WinkySticker's three
        // sizes are derived from the APNG on the device rather than uploaded.
        #expect(await api.uploadedKinds == [.apng, .system])

        // Nothing about the published sticker changed, so the sharing choice must not have leaked
        // into the publish request — the server accepts no GIF for a new animated sticker.
        #expect(await api.publishedExportRequests.last?.apngAssetId != nil)

        let gif = try #require(result.localExports.first { $0.metadata.format == .gif })
        #expect(gif.url.pathExtension == "gif")
        #expect(StickerExportMetadataPolicy.sharingGifDimensions.contains(gif.metadata.width))
        // A GIF cannot spend frame rate either: its grid is the document's own, and the loop hold
        // rides on the last frame's delay rather than on a frame of its own.
        #expect(gif.metadata.fps == revision.document.fps)
        #expect(gif.metadata.durationSeconds == StickerExportMetadataPolicy.renderedDuration(revision.document))
        let source = try #require(CGImageSourceCreateWithData(try Data(contentsOf: gif.url) as CFData, nil))
        #expect(CGImageSourceGetCount(source)
            == StickerExportMetadataPolicy.frameCount(document: revision.document, fps: revision.document.fps))
    }

    @MainActor
    @Test("The GIF encode only earns a timeline row when a GIF was asked for")
    func gifStageAppearsOnlyForAGifShare() throws {
        var revision = PreviewFixtures.candidate
        revision.candidateState = .accepted

        #expect(StickerExportProgress.stages(for: revision, selection: .sticker, sharing: .apng)
            == [.prepare, .renderAPNG, .renderSticker, .upload, .publish])
        #expect(StickerExportProgress.stages(for: revision, selection: .sticker, sharing: .gif)
            == [.prepare, .renderAPNG, .renderGIF, .renderSticker, .upload, .publish])
    }

    @MainActor
    @Test("Publishing as a sticker uploads no video, and a later share renders one")
    func stickerOnlyPublishSkipsTheVideoEncode() async throws {
        var revision = PreviewFixtures.candidate
        revision.candidateState = .accepted
        revision.document.fps = 8
        let api = MockStickerAPIClient()
        let publisher = StickerPublisher(api: api)

        let result = try await publisher.publish(
            stickerID: "sticker-demo", revision: revision, assets: .init(), verifiedAssetIDs: [],
            selection: .sticker
        )
        defer { result.localExports.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        // The sticker set is published however the export was asked for; the video is not, because
        // nothing on the platform reads it and encoding one is the slowest step of a publish.
        #expect(await api.uploadedKinds == [.apng, .system])
        #expect(await api.publishedExportRequests.last?.mp4AssetId == nil)

        // Wanting the video later is not a dead end: the document is unchanged, so the encode that
        // was skipped at publish time runs now instead of a re-publish.
        var published = revision
        published.apngAssetId = "apng-asset"
        published.systemAssetId = "system-asset"
        #expect(published.hasPublishedExports)
        #expect(!published.hasPublishedVideo)
        let shared = try await publisher.publishedExports(
            for: published, assets: .init(), verifiedAssetIDs: [], selection: .video
        )
        defer { shared.forEach { try? FileManager.default.removeItem(at: $0) } }
        // Rendered here rather than downloaded — the mock refuses every asset download.
        #expect(shared.map(\.pathExtension) == ["mp4"])
    }

    @MainActor
    @Test("An MP4 spells its loop hold out in frames, so the file measures the whole export")
    func mp4CarriesTheLoopHold() async throws {
        var document = PreviewFixtures.animatedBaseDocument
        document.layers = [
            .shape(.init(base: .init(id: "hero", name: "Hero"), shape: .circle, fill: .solid("#A88BFF"))),
        ]
        document.durationSeconds = 1
        document.fps = 8
        document.loop = .loop

        let rendition = try await StickerExporter().exportMP4(document: document, assets: .init())
        defer { try? FileManager.default.removeItem(at: rendition.url) }

        // 1 s of motion at 8 FPS is 8 frames, and the 0.6 s hold is 5 more of the last one.
        let motionFrames = StickerExportMetadataPolicy.frameCount(document: document, fps: document.fps)
        let holdFrames = StickerExportMetadataPolicy.holdFrameCount(document: document, fps: document.fps)
        #expect(motionFrames == 8)
        #expect(holdFrames == 5)

        // The regression this guards: AVAssetWriter re-derives every sample's duration from the
        // spacing of the next, so an export that asked its final sample to last a hold longer was
        // written at the cadence like any other and the file measured exactly the cycle — which the
        // server rejects, leaving a sticker the user pressed Publish on sitting in draft.
        let asset = AVURLAsset(url: rendition.url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - Double(motionFrames + holdFrames) / Double(document.fps)) < 0.02)
        #expect(duration > document.renderedCycleDuration + 0.4)
        #expect(rendition.metadata.durationSeconds == duration)
    }

    @MainActor
    @Test("A static sticker exports its own rendition without quantizing what already fits")
    func staticSystemSticker() async throws {
        var document = PreviewFixtures.staticDocument
        document.layers = [
            .shape(.init(base: .init(id: "base", name: "Base"), shape: .roundedRectangle, fill: .solid("#A88BFF"))),
        ]
        let rendition = try await StickerExporter().exportSystemSticker(document: document, assets: .init(), size: .large)
        defer { try? FileManager.default.removeItem(at: rendition.url) }

        #expect(rendition.metadata.format == .png)
        #expect(rendition.metadata.durationSeconds == nil)
        #expect(rendition.metadata.byteCount < StickerExportMetadataPolicy.systemStickerByteCeiling)
        #expect(rendition.metadata.width == SystemStickerSize.large.dimension)
        // A still that fits is not a compromise, and the sheet should stay quiet about it.
        #expect(rendition.compromise?.message == nil)
        #expect(!rendition.isStillFallback)
    }
}
