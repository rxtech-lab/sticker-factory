import AnimatedView
import Foundation

extension MockStickerAPIClient {
    func animationEngine() async throws -> ControllableEngineID { selectedAnimationEngine }
    func setAnimationEngine(_ engine: ControllableEngineID) async throws { selectedAnimationEngine = engine }

    func petScene(id: String, isTheme: Bool) async throws -> SVGSceneDocument? {
        guard ProcessInfo.processInfo.arguments.contains("--ui-svg-world") else { return nil }
        func group(_ id: String, _ shapes: String, when: [String: [Any]] = [:], depth: Any = NSNull()) -> [String: Any] {
            ["id": id, "markup": "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"600\" height=\"400\" viewBox=\"0 0 600 400\">\(shapes)</svg>",
             "pivot": ["x": 0.5, "y": 0.5], "when": when, "tracks": [], "colors": [], "depth": depth]
        }
        let data: [String: Any] = [
            "version": 1, "engine": "svg", "indoor": false,
            "rig": ["version": 1, "width": 600, "height": 400,
                    "defaults": ["weather": "rainy", "night": true, "emotion": "content", "sheltered": false], "emotions": [:],
                    "groups": [
                        group("park", "<rect width=\"600\" height=\"400\" fill=\"#DBEAD0\"/>" +
                            "<rect y=\"180\" width=\"600\" height=\"220\" fill=\"#81A37A\"/>"),
                        group("bench", "<rect x=\"270\" y=\"210\" width=\"70\" height=\"30\" rx=\"6\" fill=\"#6A4939\"/>", depth: 0.6),
                        group("lamps", "<circle cx=\"100\" cy=\"100\" r=\"32\" fill=\"#FFD785\"/>", when: ["night": [true]]),
                        group("umbrella", "<path d=\"M420 130Q470 50 520 130Z\" fill=\"#C37F70\"/>" +
                            "<path d=\"M470 100V205\" stroke=\"#6A4939\" stroke-width=\"6\"/>",
                            when: ["weather": ["rainy", "stormy"]])]],
            "spawn": ["x": 0.3, "y": 0.75],
            "walkable": [["x": 0.05, "y": 0.5], ["x": 0.95, "y": 0.5], ["x": 0.95, "y": 0.98], ["x": 0.05, "y": 0.98]],
            "obstacles": [[["x": 0.45, "y": 0.53], ["x": 0.57, "y": 0.53], ["x": 0.57, "y": 0.6], ["x": 0.45, "y": 0.6]]],
            "shelters": [], "fixtures": ["clock": ["x": 0.2, "y": 0.1], "weather": ["x": 0.5, "y": 0.1], "status": ["x": 0.7, "y": 0.25]]
        ]
        return try JSONDecoder().decode(SVGSceneDocument.self, from: JSONSerialization.data(withJSONObject: data))
    }
}
