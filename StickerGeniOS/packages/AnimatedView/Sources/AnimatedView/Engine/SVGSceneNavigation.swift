import Foundation

/// A bounded navigation grid with clearance, independent of SpriteKit and device frame rate.
public struct SVGSceneNavigation: Sendable {
    public let scene: SVGSceneDocument
    public init(scene: SVGSceneDocument) { self.scene = scene }
    public static func contains(_ point: SVGPoint, polygon: [SVGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
    public func canStand(_ point: SVGPoint) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        let footprint = [SVGPoint(x: point.x - 0.025, y: point.y - 0.015),
                         .init(x: point.x + 0.025, y: point.y - 0.015),
                         .init(x: point.x + 0.025, y: point.y + 0.015),
                         .init(x: point.x - 0.025, y: point.y + 0.015)]
        // Test the whole footprint, including thin obstacles between sampled points.
        guard footprint.allSatisfy({ Self.contains($0, polygon: scene.walkable) }),
              !Self.edgesIntersect(footprint, scene.walkable) else { return false }
        return !scene.obstacles.contains { obstacle in
            guard obstacle.contains(where: { $0.x >= point.x - 0.025 && $0.x <= point.x + 0.025
                && $0.y >= point.y - 0.015 && $0.y <= point.y + 0.015 })
                    || Self.edgesIntersect(footprint, obstacle)
                    || Self.contains(point, polygon: obstacle) else { return false }
            return true
        }
    }
    private static func edgesIntersect(_ a: [SVGPoint], _ b: [SVGPoint]) -> Bool {
        for i in a.indices {
            for j in b.indices where segmentsIntersect(a[i], a[(i + 1) % a.count], b[j], b[(j + 1) % b.count]) { return true }
        }
        return false
    }
    static func segmentsIntersect(_ a: SVGPoint, _ b: SVGPoint, _ c: SVGPoint, _ d: SVGPoint) -> Bool {
        guard max(a.x, b.x) >= min(c.x, d.x), max(c.x, d.x) >= min(a.x, b.x),
              max(a.y, b.y) >= min(c.y, d.y), max(c.y, d.y) >= min(a.y, b.y) else { return false }
        func cross(_ a: SVGPoint, _ b: SVGPoint, _ c: SVGPoint) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        return cross(a, b, c) * cross(a, b, d) <= 0 && cross(c, d, a) * cross(c, d, b) <= 0
    }
    public func canTravel(from a: SVGPoint, to b: SVGPoint) -> Bool {
        guard [a.x, a.y, b.x, b.y].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
        let count = max(1, Int(ceil(hypot(b.x - a.x, b.y - a.y) / 0.005)))
        return (0...count).allSatisfy { step in
            let t = Double(step) / Double(count)
            return canStand(.init(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
    }
    public func path(from start: SVGPoint, to destination: SVGPoint) -> [SVGPoint] {
        let side = 48
        func point(_ index: Int) -> SVGPoint { .init(x: (Double(index % side) + 0.5) / Double(side), y: (Double(index / side) + 0.5) / Double(side)) }
        let allowed = (0..<(side * side)).filter { canStand(point($0)) }
        func nearest(_ p: SVGPoint) -> Int? { allowed.min { a, b in
            let x = point(a), y = point(b)
            return hypot(x.x - p.x, x.y - p.y) < hypot(y.x - p.x, y.y - p.y)
        } }
        guard let first = nearest(start), let last = nearest(destination),
              canTravel(from: start, to: point(first)),
              hypot(point(last).x - destination.x, point(last).y - destination.y) < 0.12 else { return [] }
        let passable = Set(allowed)
        var queue = [first], cursor = 0, previous = [first: first]
        while cursor < queue.count {
            let current = queue[cursor]; cursor += 1
            if current == last { break }
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let x = current % side + dx, y = current / side + dy
                guard (0..<side).contains(x), (0..<side).contains(y) else { continue }
                let next = y * side + x
                if previous[next] == nil, passable.contains(next), canTravel(from: point(current), to: point(next)) {
                    previous[next] = current
                    queue.append(next)
                }
            }
        }
        guard previous[last] != nil else { return [] }
        var result: [SVGPoint] = [], current = last
        while current != first { result.append(point(current)); current = previous[current]! }
        result.append(point(first))
        var route = Array(result.reversed())
        if canTravel(from: point(last), to: destination) { route.append(destination) }
        return route
    }
}
