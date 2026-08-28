import CoreGraphics
import CoreImage
import Foundation
import Vision
import os

/// Where a subject sits in an image, in normalized coordinates.
///
/// Carried out of the interactive pick and updated as tracking walks through the footage. It is the
/// only thing tying "the subject the user tapped" to "the subject in this frame".
nonisolated struct SubjectAnchorDescriptor: Sendable, Equatable {
    /// Normalized, origin top-left.
    var bounds: CGRect
    var centroid: CGPoint
    var areaFraction: Double

    init(bounds: CGRect, centroid: CGPoint? = nil, areaFraction: Double? = nil) {
        self.bounds = bounds
        self.centroid = centroid ?? CGPoint(x: bounds.midX, y: bounds.midY)
        self.areaFraction = areaFraction ?? Double(bounds.width * bounds.height)
    }
}

/// Cuts a chosen subject out of a still, and out of every frame of a Live Photo.
///
/// **There is no stable instance identity across frames.** Vision re-segments each image from
/// scratch, and the instance indices it returns are derived per image — they are not object ids.
/// Anything built on "keep instance 2" drifts onto a different subject the moment the count changes,
/// and does so silently. So the subject is re-identified per frame by matching geometry against the
/// previous accepted frame, walking outward from the anchor where the user's own choice is exact.
nonisolated struct SubjectSegmenter {
    var settings: SubjectLiftSettings

    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// One cut-out subject and where it was found.
    struct Lift: Sendable {
        var image: CGImage
        var descriptor: SubjectAnchorDescriptor
    }

    /// A subject offered to the user to choose between, with enough detail to hit-test a touch.
    struct Detection: Sendable, Identifiable {
        let id = UUID()
        /// Full-frame: the same dimensions as the segmented image, transparent outside the subject.
        /// Drawing it over the photo at the same rect therefore lines up exactly, with no geometry
        /// to get wrong.
        var cutout: CGImage
        var descriptor: SubjectAnchorDescriptor
        var hitMask: HitMask
        /// False for the merged everything-in-the-foreground candidate, which is offered for
        /// hit-testing but must not be counted as a subject the user can see.
        var isInstance: Bool
    }

    /// A coarse alpha map, for asking "is the subject under this finger?" without a per-touch draw.
    struct HitMask: Sendable {
        var width: Int
        var height: Int
        var alpha: [UInt8]

        /// `point` is normalized, origin top-left — the same space as `SubjectAnchorDescriptor`.
        func isOpaque(at point: CGPoint, threshold: UInt8 = 64) -> Bool {
            guard width > 0, height > 0 else { return false }
            let x = Int((point.x * CGFloat(width)).rounded(.down))
            let y = Int((point.y * CGFloat(height)).rounded(.down))
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            return alpha[y * width + x] >= threshold
        }
    }

    // MARK: - Interactive detection

    /// Every subject in the image, for the user to pick between.
    ///
    /// This is what the lift sheet runs on, and it is Vision rather than VisionKit on purpose.
    /// `ImageAnalysisInteraction.subjects` resolves against a live view's geometry and returns an
    /// empty set for reasons the app cannot see or fix — which is exactly what it did here, on
    /// photos the Photos app lifts without complaint. `GenerateForegroundInstanceMaskRequest` takes
    /// pixels and returns instances, with nothing in between to go wrong.
    func detect(in image: CGImage) async throws -> [Detection] {
        let source = prepared(image)
        SubjectLiftLog.logger.info(
            "segment: detecting in \(source.width, privacy: .public)x\(source.height, privacy: .public) (source \(image.width, privacy: .public)x\(image.height, privacy: .public))"
        )
        let handler = ImageRequestHandler(source)
        guard let observation = try await handler.perform(GenerateForegroundInstanceMaskRequest()) else {
            SubjectLiftLog.logger.info("segment: Vision returned no observation")
            return []
        }
        SubjectLiftLog.logger.info(
            "segment: Vision found \(observation.allInstances.count, privacy: .public) instance(s)"
        )

        let found = try candidates(in: observation, of: source, handler: handler)
        SubjectLiftLog.logger.info(
            "segment: \(found.count, privacy: .public) candidate(s) above the minimum area"
        )

        var detections: [Detection] = []
        for candidate in found {
            guard let mask = Self.hitMask(candidate.image) else { continue }
            let bounds = candidate.descriptor.bounds
            SubjectLiftLog.logger.debug(
                "segment: candidate area=\(candidate.descriptor.areaFraction, privacy: .public) bounds=(\(bounds.minX, privacy: .public), \(bounds.minY, privacy: .public), \(bounds.width, privacy: .public), \(bounds.height, privacy: .public))"
            )
            detections.append(Detection(
                cutout: candidate.image,
                descriptor: candidate.descriptor,
                hitMask: mask,
                isInstance: candidate.instances.count == 1 || found.count == 1
            ))
        }
        // Smallest first, so hit-testing prefers the tightest thing under the finger. Touching a
        // person standing in front of a merged foreground should pick the person.
        return detections.sorted { $0.descriptor.areaFraction < $1.descriptor.areaFraction }
    }

    /// Which subject is under a touch. `point` is normalized, origin top-left.
    ///
    /// Alpha first, because a bounding box for anything not rectangular claims a great deal of
    /// space its subject does not occupy — the gap between two people reads as both of them. The
    /// box is only consulted when no mask is opaque, as a near-miss forgiveness for a finger that
    /// landed just off an edge.
    static func subject(at point: CGPoint, among detections: [Detection]) -> Detection? {
        if let hit = detections.first(where: { $0.hitMask.isOpaque(at: point) }) { return hit }
        return detections.first { $0.descriptor.bounds.insetBy(dx: -0.02, dy: -0.02).contains(point) }
    }

    /// A coarse alpha map of a cut-out.
    ///
    /// Deliberately tiny: it answers a yes/no question about a fingertip, which is some 44 points
    /// across, so resolving it more finely than this would cost memory to describe a precision no
    /// touch can express.
    static func hitMask(_ image: CGImage, longEdge: Int = 256) -> HitMask? {
        let scale = min(1, CGFloat(longEdge) / CGFloat(max(image.width, image.height, 1)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // Row 0 of the buffer is the image's top row — the same fact `describe` depends on, and the
        // same place a y-flip would look obviously right and be wrong.
        var alpha = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            alpha[index] = rgba[index * 4 + 3]
        }
        return HitMask(width: width, height: height, alpha: alpha)
    }

    // MARK: - Single image

    /// Lifts the subject nearest `anchor`, or the largest one when there is no anchor.
    func lift(from image: CGImage, near anchor: SubjectAnchorDescriptor?) async throws -> Lift? {
        let source = prepared(image)
        let handler = ImageRequestHandler(source)
        // The request has nothing to configure — no threshold, no subject hint, no quality. Every
        // knob in `SubjectLiftSettings` is our own policy applied around it, which is worth knowing
        // before going looking for the Vision API that backs them.
        let request = GenerateForegroundInstanceMaskRequest()
        guard let observation = try await handler.perform(request) else { return nil }

        let candidates = try candidates(in: observation, of: source, handler: handler)
        guard let chosen = choose(from: candidates, near: anchor) else { return nil }
        return chosen
    }

    /// The image the segmenter actually runs on.
    ///
    /// `Quality.segmentationLongEdge` documented a downscale that nothing applied, so every lift
    /// ran at full camera resolution — the single biggest cost in the pipeline, paid once per frame
    /// of a Live Photo, for a mask that ends up in a 640px tile.
    private func prepared(_ image: CGImage) -> CGImage {
        guard let longEdge = settings.quality.segmentationLongEdge else { return image }
        let current = CGFloat(max(image.width, image.height))
        guard current > longEdge else { return image }
        let scale = longEdge / current
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    // MARK: - Frame sequence

    /// Lifts the same subject out of every frame, in the order given.
    ///
    /// `anchorIndex` is the frame the descriptor was taken on. Frames are processed outward from it
    /// — forward to the end, then backward from the anchor to the start — because that is the order
    /// in which each frame most resembles the last one that was accepted. Processing front-to-back
    /// instead would start at the frame furthest from the user's choice and drift from there.
    func lift(
        frames: [CGImage],
        anchor: SubjectAnchorDescriptor?,
        anchorIndex: Int
    ) async throws -> [CGImage?] {
        guard !frames.isEmpty else { return [] }
        var results = [CGImage?](repeating: nil, count: frames.count)
        let start = min(max(anchorIndex, 0), frames.count - 1)

        var forward = anchor
        for index in start..<frames.count {
            let lifted = try await step(frames[index], previous: &forward, last: results[safe: index - 1] ?? nil)
            results[index] = lifted
        }
        var backward = anchor
        for index in stride(from: start - 1, through: 0, by: -1) {
            let lifted = try await step(frames[index], previous: &backward, last: results[safe: index + 1] ?? nil)
            results[index] = lifted
        }
        return results
    }

    /// One frame's worth of work: segment, choose, and fall back rather than leave a hole.
    private func step(
        _ frame: CGImage,
        previous: inout SubjectAnchorDescriptor?,
        last: CGImage?
    ) async throws -> CGImage? {
        if let lift = try await lift(from: frame, near: previous) {
            previous = lift.descriptor
            return lift.image
        }
        // A stale mask beats a hole. A frame that suddenly loses its subject reads as the sticker
        // flickering out of existence; the same subject held for one extra frame reads as nothing.
        return last
    }

    // MARK: - Candidates

    private struct Candidate {
        var instances: IndexSet
        var descriptor: SubjectAnchorDescriptor
        var image: CGImage
    }

    private func candidates(
        in observation: InstanceMaskObservation,
        of image: CGImage,
        handler: ImageRequestHandler
    ) throws -> [Candidate] {
        let all = observation.allInstances
        guard !all.isEmpty else { return [] }

        var found: [Candidate] = []
        for instance in all {
            let set = IndexSet(integer: instance)
            if let candidate = try candidate(observation, instances: set, of: image, handler: handler) {
                found.append(candidate)
            }
        }
        // The union too. A person holding a cup is often two instances, and the subject the user
        // lifted was both — scoring the union lets it win when it fits the anchor better than any
        // single piece does.
        if all.count > 1, let union = try candidate(observation, instances: all, of: image, handler: handler) {
            found.append(union)
        }
        return found.filter { $0.descriptor.areaFraction >= settings.minimumInstanceAreaFraction }
    }

    private func candidate(
        _ observation: InstanceMaskObservation,
        instances: IndexSet,
        of image: CGImage,
        handler: ImageRequestHandler
    ) throws -> Candidate? {
        guard let masked = try? observation.generateMaskedImage(
            for: instances,
            imageFrom: handler,
            croppedToInstancesExtent: false
        ) else { return nil }
        let cutout = CIImage(cvPixelBuffer: masked)
        guard let rendered = Self.context.createCGImage(polished(cutout), from: cutout.extent) else { return nil }
        guard let descriptor = Self.describe(rendered) else { return nil }
        return Candidate(instances: instances, descriptor: descriptor, image: rendered)
    }

    /// Softens the alpha edge without touching colour.
    ///
    /// A close (dilate then erode) fills the single-pixel gaps that make an edge crawl between
    /// frames, and a small blur takes the hard stair-step off it. Applied to alpha only: blurring
    /// the colour channels too would bleed background into the subject's outline.
    private func polished(_ image: CIImage) -> CIImage {
        guard settings.edgeFeatherPixels > 0 else { return image }
        let radius = Float(settings.edgeFeatherPixels)
        let closed = image
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": radius])
            .applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": radius])
        let softened = closed.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * 0.6])
        return softened.cropped(to: image.extent)
    }

    // MARK: - Choosing

    private func choose(from candidates: [Candidate], near anchor: SubjectAnchorDescriptor?) -> Lift? {
        guard !candidates.isEmpty else { return nil }
        guard let anchor, settings.instanceSelection == .tapped else {
            let largest = candidates.max { $0.descriptor.areaFraction < $1.descriptor.areaFraction }
            return largest.map { Lift(image: $0.image, descriptor: $0.descriptor) }
        }

        let scored = candidates
            .map { (candidate: $0, score: Self.score($0.descriptor, against: anchor)) }
            .sorted { $0.score > $1.score }
        if let best = scored.first, best.score >= 0.35 {
            return Lift(image: best.candidate.image, descriptor: best.candidate.descriptor)
        }
        // Nothing matched well. Prefer something that at least overlaps where the subject was over
        // something that merely happens to be big.
        let overlapping = candidates
            .filter { $0.descriptor.bounds.intersects(anchor.bounds) }
            .max { $0.descriptor.areaFraction < $1.descriptor.areaFraction }
        return overlapping.map { Lift(image: $0.image, descriptor: $0.descriptor) }
    }

    /// How much a candidate looks like the subject we are following. 0...1, higher is better.
    ///
    /// Weighted toward overlap because that is the most reliable signal frame to frame; centroid
    /// distance disambiguates two similarly-sized subjects side by side; the area term punishes a
    /// candidate that suddenly swallowed the background.
    static func score(_ candidate: SubjectAnchorDescriptor, against previous: SubjectAnchorDescriptor) -> Double {
        let overlap = intersectionOverUnion(candidate.bounds, previous.bounds)
        let drift = hypot(
            candidate.centroid.x - previous.centroid.x,
            candidate.centroid.y - previous.centroid.y
        )
        let proximity = 1 - min(1, Double(drift) / 0.5)
        let areaDelta = abs(candidate.areaFraction - previous.areaFraction) / max(previous.areaFraction, 1e-4)
        let similarity = 1 - min(1, areaDelta)
        return 0.55 * overlap + 0.30 * proximity + 0.15 * similarity
    }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let overlap = Double(intersection.width * intersection.height)
        let union = Double(a.width * a.height + b.width * b.height) - overlap
        return union > 0 ? overlap / union : 0
    }

    // MARK: - Describing

    /// The alpha-weighted bounds, centroid, and coverage of a cut-out.
    ///
    /// Sampled on a grid rather than every pixel: this runs once per candidate per frame, and the
    /// numbers only feed a similarity score, where a coarse estimate is indistinguishable from an
    /// exact one.
    static func describe(_ image: CGImage, stride sampleStride: Int = 4) -> SubjectAnchorDescriptor? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let described: SubjectAnchorDescriptor? = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

            var minX = width, minY = height, maxX = -1, maxY = -1
            var weight = 0.0
            var sumX = 0.0
            var sumY = 0.0
            for y in Swift.stride(from: 0, to: height, by: sampleStride) {
                for x in Swift.stride(from: 0, to: width, by: sampleStride) {
                    let alpha = Double(buffer[(y * width + x) * 4 + 3]) / 255
                    guard alpha > 0.15 else { continue }
                    minX = Swift.min(minX, x); maxX = Swift.max(maxX, x)
                    minY = Swift.min(minY, y); maxY = Swift.max(maxY, y)
                    weight += alpha
                    sumX += Double(x) * alpha
                    sumY += Double(y) * alpha
                }
            }
            guard maxX >= minX, maxY >= minY, weight > 0 else { return nil }

            // No y-flip. A `CGBitmapContext`'s user-space origin is bottom-left, but its *memory*
            // starts at the top-left pixel, and `draw` puts the image the right way up — so buffer
            // row 0 is the image's top row, which is already the space every consumer wants. The
            // flip that looks obviously necessary here is the bug.
            let w = Double(width), h = Double(height)
            let bounds = CGRect(
                x: Double(minX) / w,
                y: Double(minY) / h,
                width: Double(maxX - minX + sampleStride) / w,
                height: Double(maxY - minY + sampleStride) / h
            )
            let samples = Double((width / sampleStride) * (height / sampleStride))
            return SubjectAnchorDescriptor(
                bounds: bounds,
                centroid: CGPoint(x: sumX / weight / w, y: sumY / weight / h),
                areaFraction: samples > 0 ? weight / samples : 0
            )
        }
        return described
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
