import Observation
import SwiftUI
import UIKit

struct StickerScene: View {
    let document: StickerDocumentV1
    let time: Double
    var assets: [String: UIImage] = [:]

    /// The base box every layer's content is fitted into before its own scale is applied.
    ///
    /// One factor for all layer kinds, so a layer's `scale` means the same thing whether it is an
    /// image, a glyph, or a shape. The planner, the plan card's layout schematic, and this renderer
    /// all read it the same way; they disagreed while text and shapes had boxes of their own.
    static let layerFit: CGFloat = 0.86

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(document.layers) { layer in
                    if !layer.hidden {
                        layerView(layer, canvasSize: geometry.size)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .background(.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sticker preview")
    }

    @ViewBuilder
    private func layerView(_ layer: StickerLayerV1, canvasSize: CGSize) -> some View {
        let state = StickerInterpolator.state(for: layer, at: time, in: document)
        // Glyphs are fitted, never stretched. Squashing a photo is a legitimate effect; squashing
        // letters just looks broken, and a per-element text layout naturally asks for a narrow slot
        // and a tall one, which non-uniform scaling would render as slivers. Taking the smaller
        // factor keeps the type undistorted and inside the slot it was given.
        let scale = layer.isText
            ? CGSize(width: min(state.scale.x, state.scale.y), height: min(state.scale.x, state.scale.y))
            : CGSize(width: state.scale.x, height: state.scale.y)
        layerContent(layer, canvasSize: canvasSize)
            .scaleEffect(x: scale.width, y: scale.height)
            .rotationEffect(.degrees(state.rotationDegrees))
            .opacity(state.opacity)
            .blur(radius: state.effects.blurRadius)
            .hueRotation(.degrees(state.effects.hueDegrees))
            .saturation(state.effects.saturation)
            .position(
                x: state.position.x * canvasSize.width,
                y: state.position.y * canvasSize.height
            )
    }

    @ViewBuilder
    private func layerContent(_ layer: StickerLayerV1, canvasSize: CGSize) -> some View {
        switch layer {
        case .image(let imageLayer):
            if let image = assets[imageLayer.assetId] {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: imageLayer.contentMode == .fit ? .fit : .fill)
                    .frame(width: canvasSize.width * Self.layerFit, height: canvasSize.height * Self.layerFit)
                    .clipped()
                    .mask {
                        if let maskID = imageLayer.maskAssetId, let mask = assets[maskID] {
                            Image(uiImage: mask).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            Rectangle()
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: canvasSize.width * 0.12, style: .continuous)
                    .fill(.purple.gradient)
                    .overlay {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: canvasSize.width * 0.24, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: canvasSize.width * 0.64, height: canvasSize.height * 0.64)
            }
        case .text(let textLayer):
            // Sized to fill the same base box as every other layer kind rather than pinned to a
            // fixed font size. A fixed size made `scale` mean something different for text than for
            // images: a planner asking for a letter at scale 0.1 got 0.1 of a already-small font,
            // roughly one percent of the canvas, instead of a letter a tenth of the canvas wide.
            // The huge base size never renders as-is; `minimumScaleFactor` shrinks it to the box.
            Text(textLayer.text)
                .font(font(textLayer, canvasSize: canvasSize))
                .foregroundStyle(Color(stickerHex: textLayer.color))
                .multilineTextAlignment(textAlignment(textLayer.alignment))
                .lineLimit(3)
                .minimumScaleFactor(0.01)
                .frame(width: canvasSize.width * Self.layerFit, height: canvasSize.height * Self.layerFit)
        case .shape(let shapeLayer):
            StickerShape(shape: shapeLayer.shape, cornerRadius: shapeLayer.cornerRadius)
                .fill(Color(stickerHex: shapeLayer.fill))
                .overlay {
                    if let stroke = shapeLayer.stroke, shapeLayer.strokeWidth > 0 {
                        StickerShape(shape: shapeLayer.shape, cornerRadius: shapeLayer.cornerRadius)
                            .stroke(Color(stickerHex: stroke), lineWidth: shapeLayer.strokeWidth * canvasSize.width)
                    }
                }
                .frame(width: canvasSize.width * Self.layerFit, height: canvasSize.height * Self.layerFit)
        case .particle(let particleLayer):
            StickerParticleCanvas(
                layer: particleLayer,
                time: StickerInterpolator.mappedTime(time, document: document),
                duration: max(document.durationSeconds, 1)
            )
                .frame(width: canvasSize.width, height: canvasSize.height)
        }
    }

    private func font(_ layer: StickerTextLayerV1, canvasSize: CGSize) -> Font {
        // Deliberately larger than the box: it is an upper bound that `minimumScaleFactor` shrinks
        // until the text fits, which is what makes a text layer fill its box the way an image does.
        let size = canvasSize.width * Self.layerFit
        let weight: Font.Weight = switch layer.weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
        return switch layer.font {
        case .rounded: .system(size: size, weight: weight, design: .rounded)
        case .serif: .system(size: size, weight: weight, design: .serif)
        case .monospaced: .system(size: size, weight: weight, design: .monospaced)
        case .system: .system(size: size, weight: weight)
        }
    }

    private func textAlignment(_ value: StickerTextAlignment) -> TextAlignment {
        switch value { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
}

struct StickerPlayer: View {
    let document: StickerDocumentV1
    var assets: [String: UIImage] = [:]
    var repeats = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var origin = Date()

    private var shouldReduceMotion: Bool {
        reduceMotion || ProcessInfo.processInfo.arguments.contains("--reduce-motion")
    }

    private var playbackDocument: StickerDocumentV1 {
        guard repeats, document.kind == .animated, document.loop == .once else { return document }
        var repeatingDocument = document
        repeatingDocument.loop = .loop
        return repeatingDocument
    }

    var body: some View {
        if playbackDocument.kind == .animated && !shouldReduceMotion {
            TimelineView(.animation(minimumInterval: 1 / Double(max(playbackDocument.fps, 1)))) { context in
                StickerScene(document: playbackDocument, time: context.date.timeIntervalSince(origin), assets: assets)
            }
        } else {
            StickerScene(
                document: playbackDocument,
                time: playbackDocument.kind == .static ? 0 : playbackDocument.durationSeconds,
                assets: assets
            )
        }
    }
}

@MainActor
@Observable
final class StickerAssetStore {
    private(set) var images: [String: UIImage] = [:]
    private(set) var verifiedAssetIDs: Set<String> = []
    private var loading: Set<String> = []

    func preload(document: StickerDocumentV1, api: StickerAPIClientProtocol) async {
        let ids = document.layers.compactMap { layer -> [String]? in
            guard case .image(let image) = layer else { return nil }
            return [image.assetId, image.maskAssetId].compactMap { $0 }
        }.flatMap { $0 }
        for id in Set(ids) { await load(assetID: id, api: api) }
    }

    func load(assetID: String, api: StickerAPIClientProtocol) async {
        guard images[assetID] == nil, !loading.contains(assetID) else { return }
        loading.insert(assetID)
        defer { loading.remove(assetID) }
        do {
            let result = try await StickerImageCache.load(assetID: assetID, api: api)
            if result.isVerified { verifiedAssetIDs.insert(assetID) }
            images[assetID] = result.image
        } catch {
            // The scene keeps its deterministic placeholder and can retry when
            // it becomes visible again or connectivity returns.
        }
    }
}

private struct StickerShape: Shape {
    let shape: StickerShapeKind
    let cornerRadius: Double

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .circle: return Path(ellipseIn: rect)
        case .roundedRectangle: return Path(roundedRect: rect, cornerRadius: rect.width * cornerRadius)
        case .star: return radialPath(in: rect, points: 5, innerRatio: 0.42)
        case .heart: return heartPath(in: rect)
        case .burst: return radialPath(in: rect, points: 12, innerRatio: 0.7)
        }
    }

    private func radialPath(in rect: CGRect, points: Int, innerRatio: CGFloat) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        for index in 0..<(points * 2) {
            let radius = index.isMultiple(of: 2) ? outer : outer * innerRatio
            let angle = -CGFloat.pi / 2 + CGFloat(index) * .pi / CGFloat(points)
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    private func heartPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.height * 0.32),
            control1: CGPoint(x: rect.width * 0.16, y: rect.height * 0.78),
            control2: CGPoint(x: rect.minX, y: rect.height * 0.55)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.height * 0.22),
            control1: CGPoint(x: rect.minX, y: 0),
            control2: CGPoint(x: rect.width * 0.36, y: 0)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.height * 0.32),
            control1: CGPoint(x: rect.width * 0.64, y: 0),
            control2: CGPoint(x: rect.maxX, y: 0)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.height * 0.55),
            control2: CGPoint(x: rect.width * 0.84, y: rect.height * 0.78)
        )
        return path
    }
}

private struct StickerParticleCanvas: View {
    let layer: StickerParticleLayerV1
    let time: Double
    let duration: Double

    var body: some View {
        Canvas { context, size in
            for index in 0..<layer.count {
                let seed = UInt64(layer.seed) &+ UInt64(index &* 1_103_515_245)
                let x = unit(seed ^ 0x9E3779B97F4A7C15)
                let baseY = unit(seed ^ 0xD1B54A32D192ED03)
                let phase = (baseY + time / duration).truncatingRemainder(dividingBy: 1)
                let y = layer.preset == .snow || layer.preset == .bubbles ? phase : baseY
                let radius = size.width * (0.009 + unit(seed ^ 0x94D049BB133111EB) * 0.016)
                let rect = CGRect(x: x * size.width - radius, y: y * size.height - radius, width: radius * 2, height: radius * 2)
                let color = Color(stickerHex: layer.color).opacity(0.45 + unit(seed ^ 0xBF58476D1CE4E5B9) * 0.55)
                context.fill(particlePath(in: rect), with: .color(color))
            }
        }
    }

    private func particlePath(in rect: CGRect) -> Path {
        switch layer.preset {
        case .sparkles:
            return StickerShape(shape: .star, cornerRadius: 0).path(in: rect)
        case .confetti:
            return Path(roundedRect: rect, cornerRadius: rect.width * 0.2)
        case .hearts:
            return StickerShape(shape: .heart, cornerRadius: 0).path(in: rect)
        case .bubbles, .snow:
            return Path(ellipseIn: rect)
        }
    }

    private func unit(_ value: UInt64) -> Double {
        var z = value &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z & 0xFFFFFF) / Double(0x1000000)
    }
}

extension Color {
    init(stickerHex: String) {
        let clean = stickerHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        let hasAlpha = clean.count == 8
        let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
