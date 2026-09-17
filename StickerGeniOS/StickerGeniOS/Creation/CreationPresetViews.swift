import ImageIO
import SwiftUI
import UIKit

private actor CreationPreviewCache {
    static let shared = CreationPreviewCache()
    private let cache = NSCache<NSURL, NSData>()
    init() { cache.totalCostLimit = 24 * 1024 * 1024 }
    func data(for url: URL) async throws -> Data {
        if let data = cache.object(forKey: url as NSURL) { return data as Data }
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let response: URLResponse
            (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                data.count <= 8 * 1024 * 1024
            else { throw StickerAPIError.invalidResponse }
        }
        cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        return data
    }
}

private struct CreationPreviewMedia: @unchecked Sendable {
    var image: UIImage
    var animation: StickerAnimation?
    nonisolated static func decode(_ data: Data, id: String, animated: Bool, size: Int) -> Self? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Reduced motion still shows a representative pose instead of every loop's shared rest frame.
        let frameIndex = animated ? 0 : CGImageSourceGetCount(source) / 3
        guard let frame = CGImageSourceCreateThumbnailAtIndex(
                source, frameIndex,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: size,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary)
        else { return nil }
        return .init(
            image: UIImage(cgImage: frame),
            animation: animated
                ? StickerAnimationDecoder.decode(data, id: id, maxPixelSize: size, byteBudget: 12 * 1024 * 1024) : nil)
    }
}

struct CreationPresetImage: View {
    let url: URL?
    var animated = true
    var size = 480
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool {
        systemReduceMotion
            || (ProcessInfo.processInfo.arguments.contains("--ui-testing")
                && ProcessInfo.processInfo.arguments.contains("--reduce-motion"))
    }
    @State private var media: CreationPreviewMedia?
    @State private var failed = false
    @State private var attempt = 0
    private var identity: String { "\(url?.absoluteString ?? "missing")-\(animated && !reduceMotion)-\(size)-\(attempt)" }
    var body: some View {
        Group {
            if let media {
                if animated && !reduceMotion, let animation = media.animation {
                    AnimatedStickerImage(animation: animation).id(animation.id)
                } else {
                    Image(uiImage: media.image).resizable().scaledToFit()
                }
            } else if failed {
                Button {
                    attempt += 1
                } label: {
                    Label("Retry preview", systemImage: "arrow.clockwise")
                }
                .font(.caption).buttonStyle(.plain)
            } else {
                ProgressView().tint(AppColors.ink)
            }
        }
        .task(id: identity) {
            media = nil; failed = false
            guard let url else { failed = true; return }
            do {
                let data = try await CreationPreviewCache.shared.data(for: url)
                let shouldAnimate = animated && !reduceMotion
                let decoded = await Task.detached(priority: .utility) {
                    CreationPreviewMedia.decode(data, id: url.absoluteString, animated: shouldAnimate, size: size)
                }.value
                guard !Task.isCancelled else { return }
                media = decoded; failed = decoded == nil
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct CreationPresetChips: View {
    let presets: CreationPresetDisplay
    @Environment(\.locale) private var locale
    var body: some View {
        // Chips sit above the trailing-aligned user bubble, so wrapped rows hug the trailing edge.
        TrailingFlowLayout(spacing: 6) { content }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("creation-preset-chips")
    }
    private var content: some View {
        ForEach(presets.selections) { group in
            ForEach(group.options) { option in
                Text("\(group.title.localized(locale)): \(option.title.localized(locale))")
                    .accessibilityIdentifier("creation-preset-chip-\(group.groupId)-\(option.id)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppColors.ink)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(AppColors.paper, in: Capsule())
                    .overlay(Capsule().stroke(AppColors.ink.opacity(0.2), lineWidth: 1))
            }
        }
    }
}

/// Lays subviews out in rows, wrapping when a row runs out of width, with each row aligned trailing.
private struct TrailingFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, maxWidth: bounds.width) {
            var x = bounds.maxX - row.width
            for index in row.indices {
                var size = subviews[index].sizeThatFits(.unspecified)
                size.width = min(size.width, bounds.width)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            // Clamp so a single chip wider than the container still gets its own row.
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, maxWidth)
            let proposedWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty && proposedWidth > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

struct CreationPresetPage: View {
    let group: CreationPresetGroup
    @Binding var flow: CreationWizardState
    var animated = false
    @Environment(\.locale) private var locale
    private var chosen: Set<String> { flow.selections[group.id] ?? [] }
    private var previews: [CreationPresetOption] {
        let selected = group.options.filter { chosen.contains($0.id) }
        return selected.isEmpty ? Array(group.options.prefix(1)) : selected
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(group.title.localized(locale)).font(.posterDisplay(26, weight: .heavy))
            Text(group.description.localized(locale)).foregroundStyle(AppColors.muted)
            if !group.isSupported {
                ErrorBanner(message: String(localized: "Update the app to use these sticker options."))
            } else {
                HStack(spacing: 12) {
                    ForEach(previews) { option in
                        CreationPresetImage(url: animated ? option.preview?.url ?? option.cover : option.cover, animated: animated)
                            .frame(maxWidth: .infinity).frame(height: 220)
                            .accessibilityLabel(option.title.localized(locale))
                    }
                }
                .padding(18).frame(maxWidth: .infinity)
                .posterSurface(cornerRadius: Poster.tileRadius, fill: AppColors.paper)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("preset-preview-\(group.id)")
                Text(
                    group.minSelections == 0
                        ? String(localized: "Optional · choose up to \(group.maxSelections)")
                        : group.minSelections == group.maxSelections
                            ? String(localized: "Choose \(group.minSelections)")
                            : String(localized: "Choose \(group.minSelections)–\(group.maxSelections)")
                )
                .font(.subheadline.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 12)], spacing: 12) {
                    ForEach(group.options) { option in
                        let selected = chosen.contains(option.id)
                        Button {
                            flow.toggle(option.id, in: group); Haptics.selection()
                        } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                CreationPresetImage(url: option.cover, animated: false, size: 256)
                                    .frame(height: 112).frame(maxWidth: .infinity).allowsHitTesting(false)
                                HStack(alignment: .top, spacing: 6) {
                                    Text(option.title.localized(locale)).font(.system(size: 14, weight: .bold, design: .rounded))
                                    Spacer(minLength: 0)
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                }
                                .foregroundStyle(AppColors.ink)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .posterSurface(
                                cornerRadius: Poster.tileRadius,
                                fill: selected ? AppColors.accentSoft : AppColors.paper,
                                lineWidth: selected ? 2 : Poster.hairline, offset: .zero)
                        }
                        .buttonStyle(.plain)
                        .disabled(!selected && group.maxSelections > 1 && chosen.count >= group.maxSelections)
                        .accessibilityLabel(option.title.localized(locale))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("preset-option-\(group.id)-\(option.id)")
                    }
                }
            }
        }
    }
}
