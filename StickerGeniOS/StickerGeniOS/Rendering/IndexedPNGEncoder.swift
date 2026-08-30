import Compression
import CoreGraphics
import Foundation

/// A palette PNG and APNG writer, used when ImageIO's renditions are too large to be a sticker.
///
/// ImageIO writes an animated PNG as a sequence of complete, full-colour RGBA frames: four bytes a
/// pixel, every pixel, every frame, no matter how little of the canvas moved. Apple's 500 KB sticker
/// ceiling is the whole budget for that, so a four-second animation runs out of room long before it
/// runs out of quality to spend, and the export ladder used to fall off its bottom rung and fail.
///
/// This writer spends bytes where the old ladder could not reach:
///
/// - **Indexed colour.** Sticker art is flat. A palette of 256 entries carries it at one byte a
///   pixel — a quarter of RGBA before compression — and a 16-entry palette packs four pixels into
///   that same byte.
/// - **Real alpha.** A palette entry carries its own alpha through `tRNS`, so soft edges survive.
///   That is the reason this writes APNG rather than GIF, whose one-bit transparency hard-edges
///   every sticker it touches.
/// - **Frame differencing.** Each frame after the first is written as the rectangle that actually
///   changed. A sticker whose corner wiggles stops paying for the canvas that did not move.
///
/// The frames are handed in one at a time and never all held at once: a 618 px cycle can run to
/// nearly two hundred frames, which is a quarter gigabyte of pixels if they are kept around.
nonisolated enum IndexedPNGEncoder {
    /// The colour lattice pixels are bucketed onto before the palette is chosen.
    ///
    /// Quantizing first is what makes palette selection affordable: a histogram over a fixed lattice
    /// is a flat array of counts rather than a dictionary of millions of distinct colours, and the
    /// same lattice key doubles as the lookup index when frames are encoded.
    struct Lattice: Equatable, Sendable {
        /// Steps per colour channel, 2...32.
        var colorLevels: Int
        /// Steps for alpha, 2...8. Level 0 is exactly transparent and the top level exactly opaque.
        var alphaLevels: Int

        init(colorLevels: Int, alphaLevels: Int) {
            self.colorLevels = min(32, max(2, colorLevels))
            self.alphaLevels = min(8, max(2, alphaLevels))
        }

        var keyCount: Int { colorLevels * colorLevels * colorLevels * alphaLevels }

        private func level(_ value: UInt8, steps: Int) -> Int {
            Int((Double(value) / 255 * Double(steps - 1)).rounded())
        }

        private func value(ofLevel level: Int, steps: Int) -> UInt8 {
            UInt8((Double(level) * 255 / Double(steps - 1)).rounded())
        }

        /// Fully transparent pixels all collapse onto one key. Their colour channels are noise the
        /// renderer never shows, and left alone they would scatter across the lattice and crowd
        /// visible colours out of the palette.
        func key(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> Int {
            let alphaLevel = level(alpha, steps: alphaLevels)
            guard alphaLevel > 0 else { return 0 }
            let redLevel = level(red, steps: colorLevels)
            let greenLevel = level(green, steps: colorLevels)
            let blueLevel = level(blue, steps: colorLevels)
            return ((redLevel * colorLevels + greenLevel) * colorLevels + blueLevel) * alphaLevels + alphaLevel
        }

        func color(forKey key: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
            let alphaLevel = key % alphaLevels
            guard alphaLevel > 0 else { return (0, 0, 0, 0) }
            let rgb = key / alphaLevels
            let blueLevel = rgb % colorLevels
            let greenLevel = (rgb / colorLevels) % colorLevels
            let redLevel = rgb / (colorLevels * colorLevels)
            return (
                value(ofLevel: redLevel, steps: colorLevels),
                value(ofLevel: greenLevel, steps: colorLevels),
                value(ofLevel: blueLevel, steps: colorLevels),
                value(ofLevel: alphaLevel, steps: alphaLevels)
            )
        }
    }

    /// A colour census taken over a sample of frames.
    ///
    /// Sampling rather than reading every frame is deliberate: the palette has to exist before the
    /// first frame can be encoded, so a full census would mean rendering the whole animation twice.
    /// A sticker's palette barely moves across its cycle, and any colour the sample missed still
    /// maps to its nearest palette entry when it turns up.
    struct ColorCensus {
        let lattice: Lattice
        private var counts: [Int32]

        init(lattice: Lattice) {
            self.lattice = lattice
            counts = [Int32](repeating: 0, count: lattice.keyCount)
        }

        mutating func add(_ image: CGImage) {
            guard let rgba = IndexedPNGEncoder.rgbaBytes(from: image) else { return }
            let lattice = self.lattice
            counts.withUnsafeMutableBufferPointer { counts in
                rgba.pixels.withUnsafeBufferPointer { pixels in
                    var offset = 0
                    while offset + 3 < pixels.count {
                        let key = lattice.key(
                            red: pixels[offset],
                            green: pixels[offset + 1],
                            blue: pixels[offset + 2],
                            alpha: pixels[offset + 3]
                        )
                        counts[key] &+= 1
                        offset += 4
                    }
                }
            }
        }

        var isEmpty: Bool { counts.allSatisfy { $0 == 0 } }

        /// `limit` colours chosen by median cut, ordered so `tRNS` stays short.
        ///
        /// Taking the *most frequent* colours instead — which this used to do — is what posterized
        /// lifted photographs. Flat sticker art occupies a handful of lattice cells with enormous
        /// counts; a face is a smooth ramp spread thinly over hundreds of cells, none of them
        /// individually common. Ranking by frequency handed the whole palette to the crown and the
        /// lettering, culled nearly every skin tone, and left `index(forKey:)` to snap the whole
        /// face onto the few survivors. Median cut divides the colours that are *present* by how far
        /// apart they are, so a ramp earns entries in proportion to the ground it covers rather than
        /// to how often any one point on it repeats.
        ///
        /// PNG only lets `tRNS` run from the front of the palette, so every entry that carries alpha
        /// is sorted ahead of every opaque one: the chunk then covers the translucent entries and
        /// stops, instead of spelling out 255 for the whole palette.
        func palette(limit: Int, dithered: Bool = false) -> Palette {
            let cap = min(256, max(2, limit))
            var cells: [Cell] = []
            var hasTransparent = false
            for key in 0..<counts.count where counts[key] > 0 {
                // Key 0 is the collapsed fully-transparent bucket. It is reserved rather than
                // quantized: averaged into a box it would come back faintly opaque, and the
                // sticker's cut-out background would turn into a haze.
                if key == 0 { hasTransparent = true; continue }
                let color = lattice.color(forKey: key)
                cells.append(Cell(
                    red: Int32(color.red),
                    green: Int32(color.green),
                    blue: Int32(color.blue),
                    alpha: Int32(color.alpha),
                    count: Int64(counts[key])
                ))
            }
            var colors = [(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)]()
            if hasTransparent { colors.append((0, 0, 0, 0)) }
            colors.append(contentsOf: IndexedPNGEncoder.medianCut(cells, limit: cap - colors.count))
            // A palette needs at least two entries for a one-bit image to be legal, and a sticker
            // that is entirely one colour still has to be writable.
            if colors.isEmpty { colors = [(0, 0, 0, 0)] }
            if colors.count == 1 {
                colors.append(colors[0].alpha == 0 ? (255, 255, 255, 255) : (0, 0, 0, 0))
            }
            let order = colors.indices.sorted { left, right in
                colors[left].alpha == colors[right].alpha
                    ? left < right
                    : colors[left].alpha < colors[right].alpha
            }
            return Palette(lattice: lattice, entries: order.map { colors[$0] }, dithered: dithered)
        }

        /// What quantizing to `palette` costs the pixels it treats worst, in colour steps.
        ///
        /// This is how the export ladder tells a photograph from flat art without being told which
        /// it has. Sixteen entries reproduce a crown and a word mark exactly, so the ladder is free
        /// to spend its budget on size and frame rate instead; the same sixteen turn a face into
        /// plates, and this says so before the rung is chosen.
        ///
        /// A percentile rather than a mean, because the damage that matters is local. A lifted face
        /// is a tenth of a sticker and the flat art around it quantizes perfectly, so an average
        /// stays near zero while the one thing anybody looks at falls apart — which is exactly the
        /// failure this reports on.
        func error(of palette: Palette, percentile: Double = 0.9) -> Double {
            var samples: [(error: Double, share: Double)] = []
            var weight = 0.0
            for key in 0..<counts.count where counts[key] > 0 {
                let wanted = lattice.color(forKey: key)
                guard wanted.alpha > 0 else { continue }
                let entry = palette.entries[Int(palette.index(forKey: key))]
                let error = max(
                    abs(Int(entry.red) - Int(wanted.red)),
                    abs(Int(entry.green) - Int(wanted.green)),
                    abs(Int(entry.blue) - Int(wanted.blue))
                )
                // Weighted by how much of the sticker is this colour and by how opaque it is: an
                // error under a nearly transparent pixel is not one anybody sees.
                let share = Double(counts[key]) * Double(wanted.alpha) / 255
                samples.append((Double(error), share))
                weight += share
            }
            guard weight > 0 else { return 0 }
            samples.sort { $0.error < $1.error }
            var running = 0.0
            for sample in samples {
                running += sample.share
                if running >= weight * percentile { return sample.error }
            }
            return samples.last?.error ?? 0
        }
    }

    // MARK: - Median cut

    /// One populated lattice cell: a colour, and how many pixels landed on it.
    fileprivate struct Cell {
        var red: Int32
        var green: Int32
        var blue: Int32
        var alpha: Int32
        var count: Int64

        func channel(_ index: Int) -> Int32 {
            switch index {
            case 0: return red
            case 1: return green
            case 2: return blue
            default: return alpha
            }
        }
    }

    /// A contiguous run of `cells`, kept sorted along whichever channel it was last split on.
    private struct Box {
        var start: Int
        var end: Int
        var count: Int64
        /// The channel this box is widest along, and how wide.
        var channel: Int
        var extent: Int32

        var isSplittable: Bool { end - start > 1 && extent > 0 }

        /// Which box to divide next.
        ///
        /// Spread alone would spend splits on a dozen stray anti-aliasing pixels that happen to run
        /// from black to white; mass alone is the frequency bias median cut exists to avoid. The
        /// cube root keeps mass as a tiebreaker between boxes of similar spread without ever letting
        /// it dominate — doubling a box's spread outranks multiplying its pixel count by eight.
        var priority: Double { Double(extent) * pow(Double(count), 1.0 / 3.0) }
    }

    /// Alpha's weight when measuring how wide a box is.
    ///
    /// It matches the 4× on the *squared* alpha term in `Palette.index(forKey:)`, so the axis a box
    /// is split along is the same one the nearest-colour search cares most about. A soft edge
    /// rendered opaque is a visible halo; a slightly wrong hue inside the shape is not.
    private static let alphaExtentWeight: Int32 = 2

    /// Divides the populated colours into `limit` boxes and returns each box's centre of mass.
    fileprivate static func medianCut(
        _ cells: [Cell],
        limit: Int
    ) -> [(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)] {
        guard limit > 0, !cells.isEmpty else { return [] }
        var cells = cells
        var boxes = [measure(&cells, start: 0, end: cells.count)]
        while boxes.count < limit {
            // At most 256 boxes and 256 splits, so a linear scan for the best candidate is cheaper
            // than the heap that would replace it.
            var target = -1
            var best = 0.0
            for (index, box) in boxes.enumerated() where box.isSplittable && box.priority > best {
                best = box.priority
                target = index
            }
            guard target >= 0 else { break }
            let box = boxes[target]
            // Sorting only this range, only on the split channel, is what keeps the whole pass
            // linearithmic in the cells a sticker actually uses rather than in the lattice.
            let channel = box.channel
            cells[box.start..<box.end].sort { $0.channel(channel) < $1.channel(channel) }
            var running: Int64 = 0
            var split = box.start
            let half = box.count / 2
            // Stop one short of the end so both halves keep at least one cell.
            while split < box.end - 1, running + cells[split].count <= half {
                running += cells[split].count
                split += 1
            }
            // One cell heavier than the whole rest of the box leaves nothing behind it. A sticker's
            // flat background is exactly that cell, and letting the split collapse would spend the
            // slot on an empty box — which is a palette entry the image can never use.
            split = max(split, box.start + 1)
            boxes[target] = measure(&cells, start: box.start, end: split)
            boxes.append(measure(&cells, start: split, end: box.end))
        }
        return boxes.map { box in
            var red: Int64 = 0
            var green: Int64 = 0
            var blue: Int64 = 0
            var alpha: Int64 = 0
            var total: Int64 = 0
            for cell in cells[box.start..<box.end] {
                red += Int64(cell.red) * cell.count
                green += Int64(cell.green) * cell.count
                blue += Int64(cell.blue) * cell.count
                alpha += Int64(cell.alpha) * cell.count
                total += cell.count
            }
            guard total > 0 else { return (0, 0, 0, 0) }
            func average(_ sum: Int64) -> UInt8 { UInt8(min(255, max(0, (sum + total / 2) / total))) }
            // A box that only ever held opaque pixels has to stay exactly opaque: rounding it to 254
            // would drag the entry into `tRNS` and cost a byte per palette entry ahead of it.
            return (average(red), average(green), average(blue), average(alpha))
        }
    }

    private static func measure(_ cells: inout [Cell], start: Int, end: Int) -> Box {
        var lower: [Int32] = [255, 255, 255, 255]
        var upper: [Int32] = [0, 0, 0, 0]
        var count: Int64 = 0
        for cell in cells[start..<end] {
            count += cell.count
            for channel in 0..<4 {
                let value = cell.channel(channel)
                if value < lower[channel] { lower[channel] = value }
                if value > upper[channel] { upper[channel] = value }
            }
        }
        var channel = 0
        var extent: Int32 = -1
        for candidate in 0..<4 {
            let weight: Int32 = candidate == 3 ? alphaExtentWeight : 1
            let width = (upper[candidate] - lower[candidate]) * weight
            if width > extent {
                extent = width
                channel = candidate
            }
        }
        return Box(start: start, end: end, count: count, channel: channel, extent: max(0, extent))
    }

    // MARK: - Dithering

    /// The 8×8 ordered dither threshold matrix, in its usual recursive order.
    private static let bayer: [Int32] = [
        0, 32, 8, 40, 2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4, 36, 14, 46, 6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7, 39, 13, 45, 5, 37,
        63, 31, 55, 23, 61, 29, 53, 21,
    ]

    /// The offset each position in the 8×8 tile nudges a pixel's colour by before it is matched.
    ///
    /// Ordered rather than error-diffused, and that is not a quality compromise but a requirement of
    /// this encoder. Floyd–Steinberg carries its error forward across the whole image, so a single
    /// pixel moving between frames changes every index after it and `changedRect` widens to the full
    /// canvas — frame differencing, which is most of what buys the animation its byte budget, stops
    /// working. A Bayer offset depends only on `(x, y)`, so a pixel that did not move maps to the
    /// same index it did last frame and the changed rectangle stays honest. The periodic pattern
    /// also deflates far better than diffusion's noise, which matters when the budget is the point.
    ///
    /// The amplitude spans one gap between neighbouring palette entries: enough for two of them to
    /// straddle a ramp and average out to the shade in between, and no more.
    private static func ditherOffsets(spacing: Int32, lattice: Lattice) -> [Int32] {
        // Below the lattice's own step the palette already resolves the image more finely than the
        // census recorded it, so there is no banding left to break up — only noise to add.
        let latticeStep = Int32(255 / max(1, lattice.colorLevels - 1))
        guard spacing > latticeStep else { return [] }
        let amplitude = Double(min(spacing, 96))
        return bayer.map { Int32(((Double($0) + 0.5) / 64 - 0.5) * amplitude) }
    }

    /// The chosen colours, plus the lazily filled table that maps every lattice key onto one.
    ///
    /// The table is filled on demand rather than up front because the lattice has a quarter of a
    /// million keys and a sticker uses a few thousand of them: resolving only what the frames
    /// actually contain turns a fixed quarter-second of nearest-colour search into nothing.
    final class Palette {
        let lattice: Lattice
        let entries: [(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)]
        /// Bits a pixel: the smallest depth PNG offers that still indexes every entry.
        let bitDepth: Int
        private var table: [Int16]
        /// Per-position colour offsets applied before the lookup, or empty when not dithering.
        private let ditherOffsets: [Int32]

        init(
            lattice: Lattice,
            entries: [(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)],
            dithered: Bool = false
        ) {
            self.lattice = lattice
            self.entries = entries
            bitDepth = entries.count <= 2 ? 1 : entries.count <= 4 ? 2 : entries.count <= 16 ? 4 : 8
            table = [Int16](repeating: -1, count: lattice.keyCount)
            ditherOffsets = dithered
                ? IndexedPNGEncoder.ditherOffsets(spacing: Palette.spacing(of: entries), lattice: lattice)
                : []
        }

        /// The typical distance between a palette entry and its nearest neighbour.
        ///
        /// This is the size of the step a smooth ramp has to jump when it crosses from one entry to
        /// the next — the banding, measured. The median rather than the mean, because a sticker's
        /// flat art contributes a handful of isolated colours sitting far from everything else, and
        /// their distances would drag an average up until the dither turned into noise.
        private static func spacing(of entries: [(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)]) -> Int32 {
            guard entries.count > 1 else { return 0 }
            var distances: [Int32] = []
            distances.reserveCapacity(entries.count)
            for (index, entry) in entries.enumerated() {
                // Transparent entries have no colour to band; including them would measure the
                // distance to noise.
                guard entry.alpha > 0 else { continue }
                var nearest = Int32.max
                for (other, candidate) in entries.enumerated() where other != index && candidate.alpha > 0 {
                    let red = Int32(entry.red) - Int32(candidate.red)
                    let green = Int32(entry.green) - Int32(candidate.green)
                    let blue = Int32(entry.blue) - Int32(candidate.blue)
                    let alpha = Int32(entry.alpha) - Int32(candidate.alpha)
                    let distance = red * red + green * green + blue * blue + 4 * alpha * alpha
                    if distance < nearest { nearest = distance }
                }
                if nearest < Int32.max { distances.append(Int32(Double(nearest).squareRoot())) }
            }
            guard !distances.isEmpty else { return 0 }
            distances.sort()
            return distances[distances.count / 2]
        }

        /// How many leading entries `tRNS` has to describe. Zero means the sticker is fully opaque.
        var transparentEntryCount: Int {
            (entries.lastIndex { $0.alpha < 255 }).map { $0 + 1 } ?? 0
        }

        func index(forKey key: Int) -> UInt8 {
            if table[key] >= 0 { return UInt8(table[key]) }
            let wanted = lattice.color(forKey: key)
            var best = 0
            var bestDistance = Int.max
            for (index, entry) in entries.enumerated() {
                let deltaAlpha = Int(entry.alpha) - Int(wanted.alpha)
                let deltaRed = Int(entry.red) - Int(wanted.red)
                let deltaGreen = Int(entry.green) - Int(wanted.green)
                let deltaBlue = Int(entry.blue) - Int(wanted.blue)
                // Alpha is weighted above colour: a soft edge rendered opaque is a visible halo,
                // while a slightly wrong hue inside the shape is not.
                let distance = 4 * deltaAlpha * deltaAlpha
                    + deltaRed * deltaRed + deltaGreen * deltaGreen + deltaBlue * deltaBlue
                if distance < bestDistance {
                    bestDistance = distance
                    best = index
                }
            }
            table[key] = Int16(best)
            return UInt8(best)
        }

        func indices(for image: CGImage, width: Int, height: Int) -> [UInt8]? {
            guard let rgba = IndexedPNGEncoder.rgbaBytes(from: image, width: width, height: height),
                  rgba.width == width, rgba.height == height
            else { return nil }
            var output = [UInt8](repeating: 0, count: width * height)
            let offsets = ditherOffsets
            rgba.pixels.withUnsafeBufferPointer { pixels in
                for pixel in 0..<(width * height) {
                    let offset = pixel * 4
                    var red = pixels[offset]
                    var green = pixels[offset + 1]
                    var blue = pixels[offset + 2]
                    let alpha = pixels[offset + 3]
                    // One offset for all three channels, so the dither rides the brightness axis and
                    // never invents colour the frame did not have. Alpha is left alone: a dithered
                    // edge speckles rather than softens.
                    if !offsets.isEmpty, alpha > 0 {
                        let nudge = offsets[(pixel / width) % 8 * 8 + (pixel % width) % 8]
                        red = UInt8(min(255, max(0, Int32(red) + nudge)))
                        green = UInt8(min(255, max(0, Int32(green) + nudge)))
                        blue = UInt8(min(255, max(0, Int32(blue) + nudge)))
                    }
                    output[pixel] = index(forKey: lattice.key(
                        red: red,
                        green: green,
                        blue: blue,
                        alpha: alpha
                    ))
                }
            }
            return output
        }
    }

    // MARK: - Writing

    /// A single-frame palette PNG.
    static func encodeStill(_ image: CGImage, palette: Palette, dimension: Int) -> Data? {
        guard let indices = palette.indices(for: image, width: dimension, height: dimension) else { return nil }
        var data = Data()
        data.append(contentsOf: signature)
        data.append(header(width: dimension, height: dimension, bitDepth: palette.bitDepth))
        for paletteChunk in paletteChunks(palette) { data.append(paletteChunk) }
        data.append(chunk(
            "IDAT",
            deflate(scanlines(
                indices: indices,
                canvasWidth: dimension,
                rect: Rect(x: 0, y: 0, width: dimension, height: dimension),
                bitDepth: palette.bitDepth
            ))
        ))
        data.append(chunk("IEND", Data()))
        return data
    }

    /// Writes an APNG one frame at a time, abandoning itself the moment it outgrows its budget.
    ///
    /// The budget is what lets the export ladder try several palettes in a single rendering pass:
    /// the streams that overshoot stop accumulating and the largest palette that finished wins,
    /// without the frames having to be rendered once per candidate.
    final class AnimationStream {
        let palette: Palette
        private let dimension: Int
        private let byteBudget: Int
        private var body = Data()
        private var previous: [UInt8]?
        private var sequence: UInt32 = 0
        private var writtenFrames = 0
        private let expectedFrames: Int
        private let loopCount: Int
        private(set) var isAbandoned = false

        init(palette: Palette, dimension: Int, frameCount: Int, loopCount: Int, byteBudget: Int) {
            self.palette = palette
            self.dimension = dimension
            expectedFrames = frameCount
            self.loopCount = loopCount
            self.byteBudget = byteBudget
        }

        /// - Returns: whether the stream is still worth feeding.
        @discardableResult
        func append(frame: CGImage, delaySeconds: Double) -> Bool {
            guard !isAbandoned else { return false }
            guard let indices = palette.indices(for: frame, width: dimension, height: dimension) else {
                isAbandoned = true
                return false
            }
            let rect = IndexedPNGEncoder.changedRect(from: previous, to: indices, dimension: dimension)
            let payload = IndexedPNGEncoder.deflate(IndexedPNGEncoder.scanlines(
                indices: indices,
                canvasWidth: dimension,
                rect: rect,
                bitDepth: palette.bitDepth
            ))
            body.append(IndexedPNGEncoder.frameControl(
                sequence: sequence,
                rect: rect,
                delaySeconds: delaySeconds
            ))
            sequence += 1
            if previous == nil {
                body.append(IndexedPNGEncoder.chunk("IDAT", payload))
            } else {
                var fragment = Data()
                fragment.append(bigEndian: sequence)
                fragment.append(payload)
                body.append(IndexedPNGEncoder.chunk("fdAT", fragment))
                sequence += 1
            }
            previous = indices
            writtenFrames += 1
            if body.count > byteBudget {
                isAbandoned = true
                body = Data()
                previous = nil
                return false
            }
            return true
        }

        func finish() -> Data? {
            guard !isAbandoned, writtenFrames == expectedFrames, writtenFrames > 0 else { return nil }
            var data = Data()
            data.append(contentsOf: IndexedPNGEncoder.signature)
            data.append(IndexedPNGEncoder.header(width: dimension, height: dimension, bitDepth: palette.bitDepth))
            for paletteChunk in IndexedPNGEncoder.paletteChunks(palette) { data.append(paletteChunk) }
            var control = Data()
            control.append(bigEndian: UInt32(writtenFrames))
            control.append(bigEndian: UInt32(loopCount))
            data.append(IndexedPNGEncoder.chunk("acTL", control))
            data.append(body)
            data.append(IndexedPNGEncoder.chunk("IEND", Data()))
            return data.count <= byteBudget ? data : nil
        }
    }

    // MARK: - Chunks

    private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    struct Rect: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    private static func header(width: Int, height: Int, bitDepth: Int) -> Data {
        var payload = Data()
        payload.append(bigEndian: UInt32(width))
        payload.append(bigEndian: UInt32(height))
        payload.append(UInt8(bitDepth))
        payload.append(3)  // colour type 3: indexed
        payload.append(0)  // deflate
        payload.append(0)  // adaptive filtering
        payload.append(0)  // no interlacing
        return chunk("IHDR", payload)
    }

    /// `PLTE`, and `tRNS` when anything in the palette is not fully opaque.
    private static func paletteChunks(_ palette: Palette) -> [Data] {
        var plte = Data(capacity: palette.entries.count * 3)
        for entry in palette.entries {
            plte.append(entry.red)
            plte.append(entry.green)
            plte.append(entry.blue)
        }
        var chunks = [chunk("PLTE", plte)]
        let transparentCount = palette.transparentEntryCount
        if transparentCount > 0 {
            var trns = Data(capacity: transparentCount)
            for entry in palette.entries.prefix(transparentCount) { trns.append(entry.alpha) }
            chunks.append(chunk("tRNS", trns))
        }
        return chunks
    }

    /// `dispose_op` NONE with `blend_op` SOURCE: each frame overwrites its own rectangle and leaves
    /// the rest of the canvas standing, which keeps the canvas exactly equal to the current frame.
    ///
    /// The alternative — OVER blending, where transparent pixels mean "keep what was there" — packs
    /// better but cannot express a pixel becoming *more* transparent, which is precisely what the
    /// soft edge of a moving sticker does on the side it is moving away from.
    private static func frameControl(sequence: UInt32, rect: Rect, delaySeconds: Double) -> Data {
        var payload = Data()
        payload.append(bigEndian: sequence)
        payload.append(bigEndian: UInt32(rect.width))
        payload.append(bigEndian: UInt32(rect.height))
        payload.append(bigEndian: UInt32(rect.x))
        payload.append(bigEndian: UInt32(rect.y))
        // Milliseconds. The server recomputes a rendition's duration by summing these, so the
        // denominator has to be fine enough that rounding cannot drift the cycle off its grid.
        payload.append(bigEndian: UInt16(min(65535, max(0, (delaySeconds * 1000).rounded()))))
        payload.append(bigEndian: UInt16(1000))
        payload.append(0)  // dispose_op NONE
        payload.append(0)  // blend_op SOURCE
        return chunk("fcTL", payload)
    }

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var data = Data(capacity: payload.count + 12)
        data.append(bigEndian: UInt32(payload.count))
        let typed = Data(type.utf8) + payload
        data.append(typed)
        data.append(bigEndian: crc32(typed))
        return data
    }

    // MARK: - Pixels

    /// The rectangle whose indices differ from the previous frame.
    ///
    /// An unchanged frame still has to be written — the frame count is what carries the animation's
    /// timing — so it degenerates to a single pixel that repaints itself.
    static func changedRect(from previous: [UInt8]?, to current: [UInt8], dimension: Int) -> Rect {
        guard let previous, previous.count == current.count else {
            return Rect(x: 0, y: 0, width: dimension, height: dimension)
        }
        var minX = dimension
        var minY = dimension
        var maxX = -1
        var maxY = -1
        previous.withUnsafeBufferPointer { old in
            current.withUnsafeBufferPointer { new in
                for y in 0..<dimension {
                    let row = y * dimension
                    var changedInRow = false
                    for x in 0..<dimension where old[row + x] != new[row + x] {
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        changedInRow = true
                    }
                    if changedInRow {
                        if y < minY { minY = y }
                        maxY = y
                    }
                }
            }
        }
        guard maxX >= 0 else { return Rect(x: 0, y: 0, width: 1, height: 1) }
        return Rect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Filtered, bit-packed scanlines for one rectangle of the canvas.
    ///
    /// Every row is written with filter type 0. Palette indices are labels rather than magnitudes,
    /// so the delta filters PNG offers for true-colour images produce noise here rather than
    /// smaller output.
    static func scanlines(indices: [UInt8], canvasWidth: Int, rect: Rect, bitDepth: Int) -> [UInt8] {
        let rowBytes = (rect.width * bitDepth + 7) / 8
        var output = [UInt8](repeating: 0, count: rect.height * (rowBytes + 1))
        indices.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                var write = 0
                for row in 0..<rect.height {
                    destination[write] = 0
                    write += 1
                    let read = (rect.y + row) * canvasWidth + rect.x
                    if bitDepth == 8 {
                        for column in 0..<rect.width { destination[write + column] = source[read + column] }
                    } else {
                        let perByte = 8 / bitDepth
                        for column in 0..<rect.width {
                            let byte = write + column / perByte
                            let shift = 8 - bitDepth * (column % perByte + 1)
                            destination[byte] |= source[read + column] << UInt8(shift)
                        }
                    }
                    write += rowBytes
                }
            }
        }
        return output
    }

    /// Straight-alpha RGBA bytes. PNG stores colour unassociated with alpha, so the premultiplied
    /// pixels Core Graphics hands back have to be divided out or every soft edge darkens.
    static func rgbaBytes(
        from image: CGImage,
        width: Int? = nil,
        height: Int? = nil
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        let targetWidth = width ?? image.width
        let targetHeight = height ?? image.height
        guard targetWidth > 0, targetHeight > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: targetWidth,
                    height: targetHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: targetWidth * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            return true
        }
        guard success else { return nil }
        pixels.withUnsafeMutableBufferPointer { buffer in
            var offset = 0
            while offset + 3 < buffer.count {
                let alpha = buffer[offset + 3]
                if alpha == 0 {
                    buffer[offset] = 0
                    buffer[offset + 1] = 0
                    buffer[offset + 2] = 0
                } else if alpha < 255 {
                    for channel in 0..<3 {
                        buffer[offset + channel] = UInt8(min(255, Int(buffer[offset + channel]) * 255 / Int(alpha)))
                    }
                }
                offset += 4
            }
        }
        return (pixels, targetWidth, targetHeight)
    }

    // MARK: - zlib

    /// A zlib stream around Apple's raw DEFLATE encoder.
    ///
    /// `compression_encode_buffer` emits RFC 1951 DEFLATE with no wrapper, and PNG wants RFC 1950:
    /// the two-byte header and the trailing Adler-32 are added here. Data that will not compress
    /// falls back to stored blocks, so this never fails to produce a valid stream.
    static func deflate(_ bytes: [UInt8]) -> Data {
        var stream = Data([0x78, 0x01])
        stream.append(rawDeflate(bytes) ?? storedDeflate(bytes))
        stream.append(bigEndian: adler32(bytes))
        return stream
    }

    private static func rawDeflate(_ bytes: [UInt8]) -> Data? {
        guard !bytes.isEmpty else { return nil }
        let capacity = bytes.count + bytes.count / 2 + 1024
        var destination = [UInt8](repeating: 0, count: capacity)
        let written = destination.withUnsafeMutableBufferPointer { output -> Int in
            bytes.withUnsafeBufferPointer { input -> Int in
                compression_encode_buffer(
                    output.baseAddress!, capacity,
                    input.baseAddress!, bytes.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return Data(destination.prefix(written))
    }

    /// Uncompressed DEFLATE blocks — the format's own escape hatch for incompressible data.
    private static func storedDeflate(_ bytes: [UInt8]) -> Data {
        var data = Data()
        var offset = 0
        repeat {
            let length = min(65535, bytes.count - offset)
            let isFinal = offset + length >= bytes.count
            data.append(isFinal ? 1 : 0)
            data.append(UInt8(length & 0xFF))
            data.append(UInt8(length >> 8))
            data.append(UInt8(~length & 0xFF))
            data.append(UInt8((~length >> 8) & 0xFF))
            data.append(contentsOf: bytes[offset..<(offset + length)])
            offset += length
        } while offset < bytes.count
        return data
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value & 1) == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    nonisolated mutating func append(bigEndian value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    nonisolated mutating func append(bigEndian value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
