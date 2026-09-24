import AnimatedView
import CryptoKit
import Foundation
import ImageIO
import UIKit

/// Where a Clip viewer reads a sticker's poses from.
enum ClipPlaybackSource {
    /// Anyone holding the pack link. Artwork arrives as signed URLs, so no account is needed.
    case publicPack(slug: String)
    /// The signed-in owner, through the same playback route the full app uses.
    case owned(revisionID: String, client: QuickModeModel)
}

/// The Clip's slice of the playback bundle. Public-pack responses add a signed `url` per asset.
nonisolated struct ClipPlaybackBundle: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let id: String
        let mimeType: String
        let byteSize: Int
        let sha256: String
        let width: Int
        let height: Int
        let url: URL?
    }
    let stickerId: String
    let revisionId: String
    let version: Int
    let document: AnimatedDocument
    let assets: [Asset]
}

/// Fetches a published pose bundle and decodes the artwork a pose needs, verifying every file
/// against the bundle's checksum. A trimmed port of the Messages extension's playback service:
/// the Clip has no App Group, so everything is held in memory for the life of the viewer.
@MainActor
final class ClipPlaybackLoader {
    private let stickerID: String
    private let source: ClipPlaybackSource
    private var images: [String: UIImage] = [:]
    private(set) var bundle: ClipPlaybackBundle?

    init(stickerID: String, source: ClipPlaybackSource) {
        self.stickerID = stickerID
        self.source = source
    }

    func load() async throws -> ClipPlaybackBundle {
        if let bundle { return bundle }
        let data: Data
        switch source {
        case .publicPack(let slug):
            let url = try MessagesAPIConfiguration.baseURL()
                .appending(path: "api/v1/public/packs").appending(path: slug)
                .appending(path: "stickers").appending(path: stickerID).appending(path: "playback")
            var request = URLRequest(url: url)
            request.setValue(String(AnimatedDocument.currentVersion), forHTTPHeaderField: "X-Sticker-Contract")
            let (body, response) = try await Self.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ClipPlaybackError.unavailable }
            data = body
        case .owned(let revisionID, let client):
            data = try await client.get(
                "api/v1/stickers/\(stickerID)/playback",
                queryItems: [URLQueryItem(name: "revisionId", value: revisionID)],
                headers: ["X-Sticker-Contract": String(AnimatedDocument.currentVersion)]
            )
        }
        let decoded = try JSONDecoder().decode(ClipPlaybackBundle.self, from: data)
        guard decoded.stickerId == stickerID, decoded.version == 1, decoded.document.configuration != nil else {
            throw ClipPlaybackError.unavailable
        }
        _ = try decoded.document.validated()
        bundle = decoded
        return decoded
    }

    /// The decoded artwork for these resolved poses, downloading only what is not held yet.
    func assets(for documents: [AnimatedDocument]) async throws -> StickerRenderAssets {
        let bundle = try await load()
        var required = Set(documents.flatMap(\.layers).filter { !$0.hidden }.flatMap { layer -> [String] in
            if case .sequence(let sequence) = layer { return [sequence.assetId] }
            return layer.referencedImageAssetIDs
        })
        for document in documents {
            if case .image(let id, _) = document.background { required.insert(id) }
        }
        let descriptors = bundle.assets.filter { required.contains($0.id) }
        let sized = descriptors.allSatisfy { $0.width > 0 && $0.height > 0 && $0.width <= 8192 && $0.height <= 8192 }
        guard descriptors.count == required.count, sized,
              descriptors.reduce(0, { $0 + $1.byteSize }) <= 128 * 1024 * 1024 else { throw ClipPlaybackError.unavailable }
        // Same decoded-memory budget as Messages: large sheets are downsampled rather than refused.
        let fullCost = bundle.assets.reduce(0.0) { $0 + Double($1.width) * Double($1.height) * 4 }
        let scale = min(1, sqrt(48 * 1024 * 1024 / max(1, fullCost)))
        for asset in descriptors where images[asset.id] == nil {
            try Task.checkCancellation()
            let data = try await download(asset)
            guard Self.verified(data, asset: asset),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(64, Int(Double(max(asset.width, asset.height)) * scale)),
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw ClipPlaybackError.unavailable }
            images[asset.id] = UIImage(cgImage: image)
        }
        return StickerRenderAssets(images: images.filter { required.contains($0.key) })
    }

    private func download(_ asset: ClipPlaybackBundle.Asset) async throws -> Data {
        let url: URL
        switch source {
        case .publicPack:
            guard let signed = asset.url else { throw ClipPlaybackError.unavailable }
            url = signed
        case .owned(_, let client):
            struct Download: Decodable { let url: URL }
            url = try JSONDecoder().decode(Download.self, from: await client.get("api/v1/assets/\(asset.id)/download")).url
        }
        guard url.scheme == "https" else { throw ClipPlaybackError.unavailable }
        let (data, response) = try await Self.session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ClipPlaybackError.unavailable }
        return data
    }

    private static func verified(_ data: Data, asset: ClipPlaybackBundle.Asset) -> Bool {
        data.count == asset.byteSize && data.count < 25 * 1024 * 1024 && asset.mimeType == "image/png"
            && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == asset.sha256.lowercased()
    }

    private static var session: URLSession {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return ClipPlaybackFixtures.session }
        #endif
        return .shared
    }
}

enum ClipPlaybackError: LocalizedError {
    case unavailable
    var errorDescription: String? { String(localized: "This sticker's poses are not available right now.") }
}

#if DEBUG
/// A controllable fixture for UI tests: the server's v5 document with Mood and Pose choices, served
/// with artwork generated on the fly so checksums always match.
nonisolated enum ClipPlaybackFixtures {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClipPlaybackFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }()

    /// The server's v5 fixture trimmed to one layer: a Mood choice that swaps artwork and a Pose
    /// choice that swaps motion.
    static let document = #"""
        {
          "version": 5,
          "canvas": {
            "width": 1024,
            "height": 1024,
            "coordinateSpace": "normalized",
            "transparent": true
          },
          "layers": [
            {
              "id": "hero",
              "name": "Pet",
              "hidden": false,
              "anchor": {
                "position": {
                  "x": 0.5,
                  "y": 0.5
                },
                "scale": {
                  "x": 1,
                  "y": 1
                },
                "rotationDegrees": 0,
                "opacity": 1,
                "trim": {
                  "start": 0,
                  "end": 1
                }
              },
              "animations": [],
              "animation": {
                "position": [],
                "scale": [],
                "rotation": [],
                "opacity": [],
                "effects": [],
                "trim": [],
                "wipe": [],
                "sheen": [],
                "glow": []
              },
              "blendMode": "normal",
              "type": "image",
              "assetId": "11111111-1111-4111-8111-111111111111",
              "contentMode": "fit"
            }
          ],
          "background": {
            "type": "none"
          },
          "kind": "animated",
          "durationSeconds": 2,
          "fps": 24,
          "loop": "loop",
          "speed": 1,
          "configuration": {
            "controls": [
              {
                "id": "mood",
                "type": "choice",
                "label": "Mood",
                "defaultValue": "happy",
                "options": [
                  {
                    "id": "happy",
                    "label": "Happy"
                  },
                  {
                    "id": "sad",
                    "label": "Sad"
                  }
                ]
              },
              {
                "id": "pose",
                "type": "choice",
                "label": "Pose",
                "defaultValue": "rest",
                "options": [
                  {
                    "id": "rest",
                    "label": "Rest"
                  },
                  {
                    "id": "hop",
                    "label": "Hop"
                  }
                ]
              }
            ],
            "variants": [
              {
                "id": "happy",
                "selections": {
                  "mood": "happy"
                },
                "layers": [
                  {
                    "layerId": "hero",
                    "source": {
                      "kind": "base"
                    }
                  }
                ]
              },
              {
                "id": "sad",
                "selections": {
                  "mood": "sad"
                },
                "layers": [
                  {
                    "layerId": "hero",
                    "source": {
                      "kind": "image",
                      "assetId": "22222222-2222-4222-8222-222222222222"
                    }
                  }
                ]
              },
              {
                "id": "rest",
                "selections": {
                  "pose": "rest"
                },
                "layers": [
                  {
                    "layerId": "hero",
                    "animations": []
                  }
                ]
              },
              {
                "id": "hop",
                "selections": {
                  "pose": "hop"
                },
                "layers": [
                  {
                    "layerId": "hero",
                    "animations": [
                      {
                        "type": "bounce",
                        "height": 0.1,
                        "bounces": 2,
                        "delay": 0,
                        "duration": 0.6,
                        "easing": "easeInOut"
                      }
                    ]
                  }
                ]
              }
            ]
          }
        }
        """#
    static let assetIDs = ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"]

    static func bundle(stickerID: String, assetURL: (String) -> String?) -> [String: Any] {
        [
            "stickerId": stickerID, "revisionId": "fixture-revision", "version": 1,
            "document": (try? JSONSerialization.jsonObject(with: Data(document.utf8))) ?? [:],
            "assets": assetIDs.map { id -> [String: Any] in
                let data = artwork(id)
                var asset: [String: Any] = [
                    "id": id, "mimeType": "image/png", "byteSize": data.count, "width": 64, "height": 64,
                    "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                ]
                if let url = assetURL(id) { asset["url"] = url }
                return asset
            }
        ]
    }

    static func artwork(_ assetID: String) -> Data {
        let color: UIColor = assetID.hasSuffix("1") ? .systemOrange : .systemTeal
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
        }()).pngData { context in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: 4, y: 4, width: 56, height: 56)).fill()
            _ = context
        }
    }
}

private nonisolated final class ClipPlaybackFixtureProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let parts = url.pathComponents
        let data: Data
        let type: String
        if url.path.hasPrefix("/fixture-playback/") {
            data = ClipPlaybackFixtures.artwork(url.lastPathComponent); type = "image/png"
        } else if parts.count == 9, parts[1...4] == ["api", "v1", "public", "packs"], parts[6] == "stickers", parts[8] == "playback" {
            let body = ClipPlaybackFixtures.bundle(stickerID: parts[7]) { "https://clip-fixtures.invalid/fixture-playback/\($0)" }
            data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data(); type = "application/json"
        } else {
            data = Data(); type = "application/json"
        }
        let response = HTTPURLResponse(url: url, statusCode: data.isEmpty ? 404 : 200, httpVersion: nil,
                                       headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
