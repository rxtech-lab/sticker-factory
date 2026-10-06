import UIKit

/// A local-time approximation: sunrise on the left, noon overhead, sunset on the right.
/// The moon follows the same arc through the night, continuously across midnight.
enum PetSkyOrbit {
    static func isDay(at date: Date, calendar: Calendar = .current) -> Bool {
        (6..<19).contains(calendar.component(.hour, from: date))
    }

    static func position(at date: Date, isDay: Bool, in bounds: CGRect, calendar: Calendar = .current) -> CGPoint {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600
        // Weather can report night before 19:00: keep that early moon at the rising end.
        let elapsed = isDay ? hour - 6 : (hour >= 12 ? hour - 19 : hour + 5)
        let progress = min(1, max(0, elapsed / (isDay ? 13 : 11)))
        return CGPoint(x: bounds.minX + bounds.width * (0.1 + progress * 0.8),
                       y: bounds.minY + bounds.height * (0.65 - sin(progress * .pi) * 0.45))
    }
}

struct PetSkyPlacement {
    let center: CGPoint
    let side: Double
}

/// Cached safe squares in the room's actual transparent glass, after aspect-fill and fixture shift.
/// Testing the whole square keeps the body clear of curved edges, mullions and opaque room art.
struct PetWindowOpeningLayout {
    private(set) var bounds: CGRect = .zero
    private var candidates: [PetSkyPlacement] = []
    private var glass: [Bool] = []
    private var columns = 0
    private var rows = 0
    private var cellSize = CGSize.zero

    init(image: UIImage, drawn: CGRect, bounds screen: CGSize) {
        guard let image = image.cgImage, screen.width > 0, screen.height > 0 else { return }
        let scale = 192 / max(screen.width, screen.height)
        let width = max(1, Int(ceil(screen.width * scale)))
        let height = max(1, Int(ceil(screen.height * scale)))
        let cellX = screen.width / Double(width)
        let cellY = screen.height / Double(height)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            // Read the bitmap's rows directly; a UIKit-style Y flip would mirror the alpha map.
            context.scaleBy(x: Double(width) / screen.width, y: Double(height) / screen.height)
            context.setBlendMode(.copy)
            context.interpolationQuality = .high
            let bitmapRect = CGRect(x: drawn.minX, y: screen.height - drawn.maxY,
                                    width: drawn.width, height: drawn.height)
            context.draw(image, in: bitmapRect)
            return true
        }
        guard rendered else { return }
        columns = width
        rows = height
        cellSize = CGSize(width: cellX, height: cellY)
        glass = (0..<(width * height)).map { pixels[$0 * 4 + 3] <= 12 }

        // Summed opaque pixels let each candidate test its entire area in constant time.
        let stride = width + 1
        var opaque = [Int](repeating: 0, count: stride * (height + 1))
        var glassBounds = CGRect.null
        for y in 0..<height {
            for x in 0..<width {
                let blocked = pixels[(y * width + x) * 4 + 3] > 12
                opaque[(y + 1) * stride + x + 1] = (blocked ? 1 : 0)
                    + opaque[y * stride + x + 1] + opaque[(y + 1) * stride + x] - opaque[y * stride + x]
                if !blocked {
                    glassBounds = glassBounds.union(CGRect(x: Double(x) * cellX, y: Double(y) * cellY,
                                                          width: cellX, height: cellY))
                }
            }
        }
        guard !glassBounds.isNull else { return }
        bounds = glassBounds
        for side in [180.0, 150, 120, 96, 84, 72, 60, 48, 32, 20] {
            // One cell of clearance also covers interpolation at the window's edge.
            let rx = Int(ceil(side / 2 / cellX)) + 1
            let ry = Int(ceil(side / 2 / cellY)) + 1
            guard rx * 2 < width, ry * 2 < height else { continue }
            for y in Swift.stride(from: ry, to: height - ry, by: 2) {
                for x in Swift.stride(from: rx, to: width - rx, by: 2) {
                    let left = x - rx, right = x + rx + 1
                    let top = y - ry, bottom = y + ry + 1
                    let count = opaque[bottom * stride + right] - opaque[top * stride + right]
                        - opaque[bottom * stride + left] + opaque[top * stride + left]
                    if count == 0 {
                        candidates.append(PetSkyPlacement(center: CGPoint(x: (Double(x) + 0.5) * cellX,
                                                                         y: (Double(y) + 0.5) * cellY), side: side))
                    }
                }
            }
        }
    }

    /// Favor the real-time position, shrinking the body when a nearby pane needs a smaller one.
    func placement(near target: CGPoint, preferredSide: Double) -> PetSkyPlacement? {
        return candidates.lazy.filter { $0.side <= preferredSide }.min { score($0) < score($1) }
        func score(_ placement: PetSkyPlacement) -> Double {
            let dx = placement.center.x - target.x
            let dy = placement.center.y - target.y
            let shrink = preferredSide - placement.side
            return dx * dx + dy * dy + shrink * shrink * 2
        }
    }

    /// Move a fixed-size moon, testing its visible artwork rather than its transparent cell padding.
    /// If a room has no pane big enough, keep its size and choose the least obstructed position.
    func fixedPlacement(near target: CGPoint, side: Double, footprint: [CGPoint]) -> PetSkyPlacement? {
        guard !footprint.isEmpty, glass.contains(true) else { return nil }
        var best: CGPoint?
        var bestBlocked = Int.max
        var bestDistance = Double.infinity
        for y in Swift.stride(from: 0, to: rows, by: 2) {
            for x in Swift.stride(from: 0, to: columns, by: 2) where glass[y * columns + x] {
                let center = CGPoint(x: (Double(x) + 0.5) * cellSize.width,
                                     y: (Double(y) + 0.5) * cellSize.height)
                let distance = pow(center.x - target.x, 2) + pow(center.y - target.y, 2)
                if bestBlocked == 0 && distance >= bestDistance { continue }
                var blocked = 0
                for point in footprint {
                    let px = Int(floor((center.x + point.x * side) / cellSize.width))
                    let py = Int(floor((center.y + point.y * side) / cellSize.height))
                    if px < 0 || px >= columns || py < 0 || py >= rows || !glass[py * columns + px] {
                        blocked += 1
                    }
                    if blocked > bestBlocked { break }
                }
                if blocked < bestBlocked || (blocked == bestBlocked && distance < bestDistance) {
                    best = center
                    bestBlocked = blocked
                    bestDistance = distance
                }
            }
        }
        return best.map { PetSkyPlacement(center: $0, side: side) }
    }
}

/// Opaque cells of a sky sprite, normalized around its centre for fixed-size placement.
enum PetSkyFootprint {
    static let moon: [CGPoint] = (0..<32).flatMap { y in
        (0..<32).compactMap { x in
            let point = CGPoint(x: (Double(x) + 0.5) / 32 - 0.5, y: (Double(y) + 0.5) / 32 - 0.5)
            return point.x * point.x + point.y * point.y <= 0.25 ? point : nil
        }
    }

    static func points(in image: UIImage) -> [CGPoint] {
        guard let image = image.cgImage else { return [] }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return [] }
        return (0..<(side * side)).flatMap { index -> [CGPoint] in
            guard pixels[index * 4 + 3] > 4 else { return [] }
            let x = Double(index % side) / Double(side) - 0.5
            let y = Double(index / side) / Double(side) - 0.5
            // Test the cell's corners as well as its centre, including faint outline pixels.
            let cell = 1 / Double(side)
            return [CGPoint(x: x, y: y), CGPoint(x: x + cell, y: y),
                    CGPoint(x: x, y: y + cell), CGPoint(x: x + cell, y: y + cell),
                    CGPoint(x: x + cell / 2, y: y + cell / 2)]
        }
    }
}
