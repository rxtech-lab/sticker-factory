import SwiftUI

/// An interactive inspector for a document: scrub time, change speed, toggle layers, and switch the
/// backdrop between transparent, light, and dark.
///
/// Public because it is genuinely useful outside previews — an app debugging why a sticker looks
/// wrong wants exactly this, and rebuilding it per-app is how two renderers start to disagree.
///
/// This is a read-mostly inspector, and cross-platform. For actually authoring a document — layers,
/// keyframes, canvas size, per-kind properties — use `AnimatedIconEditor`, which is iOS-only.
public struct AnimatedIconGallery: View {
    public var title: String
    @State private var document: AnimatedDocument
    @State private var isPlaying = true
    @State private var scrubTime: Double = 0
    @State private var speed: Double = 1
    @State private var backdrop = Backdrop.checkerboard
    private let assets: any AnimatedAssetProvider

    public init(
        _ title: String,
        document: AnimatedDocument,
        assets: any AnimatedAssetProvider = EmptyAnimatedAssets()
    ) {
        self.title = title
        self._document = State(initialValue: document)
        self.assets = assets
    }

    enum Backdrop: String, CaseIterable, Identifiable {
        case checkerboard, light, dark
        var id: Self { self }
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)

            stage

            if document.kind == .animated {
                controls
            }

            layerToggles
        }
        .padding(20)
        .frame(minWidth: 340)
    }

    private var stage: some View {
        ZStack {
            switch backdrop {
            case .checkerboard: AnimatedCheckerboard()
            case .light: Color(white: 0.97)
            case .dark: Color(white: 0.10)
            }

            if isPlaying {
                AnimatedIconView(document: document, assets: assets, speed: speed, repeats: true)
            } else {
                AnimatedIconScrubber(document: document, assets: assets, time: $scrubTime)
            }
        }
        .frame(width: 280, height: 280 / max(document.canvas.aspectRatio, 0.2))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Button(isPlaying ? "Pause" : "Play") { isPlaying.toggle() }
                Picker("", selection: $backdrop) {
                    ForEach(Backdrop.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if !isPlaying {
                LabeledContent("Time") {
                    Slider(value: $scrubTime, in: 0...max(document.renderedCycleDuration, 0.01))
                }
                Text(String(format: "%.2f s of %.2f s", scrubTime, document.renderedCycleDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Speed") {
                Slider(value: $speed, in: 0.25...4, step: 0.25)
            }
            Text(String(format: "%.2f×  ·  %d fps  ·  %@", speed, document.fps, document.loop.rawValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var layerToggles: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(document.layers.enumerated()), id: \.element.id) { index, layer in
                Toggle(isOn: Binding(
                    get: { !document.layers[index].hidden },
                    set: { document.layers[index].base.hidden = !$0 }
                )) {
                    Text("\(layer.name)  ·  \(layer.type.rawValue)")
                        .font(.caption)
                }
                .toggleStyle(.switch)
            }
        }
    }
}

/// A row of documents shown side by side, for previews that compare variants.
public struct AnimatedIconStrip: View {
    public var title: String
    public var items: [(label: String, document: AnimatedDocument)]
    public var size: CGFloat
    public var onDark: Bool
    private let assets: any AnimatedAssetProvider

    public init(
        _ title: String,
        items: [(label: String, document: AnimatedDocument)],
        size: CGFloat = 150,
        onDark: Bool = false,
        assets: any AnimatedAssetProvider = EmptyAnimatedAssets()
    ) {
        self.title = title
        self.items = items
        self.size = size
        self.onDark = onDark
        self.assets = assets
    }

    public var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.headline)
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 6) {
                        ZStack {
                            if onDark { Color(white: 0.10) } else { AnimatedCheckerboard(squareSize: 10) }
                            AnimatedIconView(document: item.document, assets: assets, repeats: true)
                        }
                        .frame(width: size, height: size / max(item.document.canvas.aspectRatio, 0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text(item.label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
    }
}
