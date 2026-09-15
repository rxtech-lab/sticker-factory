import AnimatedView
import SwiftUI
import TipKit
import UIKit

struct ChatErrorAlert: ViewModifier {
    let message: String?
    let onDismiss: () -> Void

    private var isPresented: Binding<Bool> {
        Binding(
            get: { message != nil },
            set: { if !$0 { onDismiss() } }
        )
    }

    func body(content: Content) -> some View {
        content.alert("Couldn’t Complete Action", isPresented: isPresented) {
            Button("OK", role: .cancel) { Haptics.tap(.light) }
        } message: {
            Text(message ?? "")
        }
    }
}

struct ChatBubble: View {
    var configurationSettings: StickerControlSettings?
    let message: ChatMessage
    let sticker: AnimatedDocument?
    let assets: [String: UIImage]
    var videos: [String: KeyedVideoFrames] = [:]
    var toolAPI: (any StickerAPIClientProtocol)?
    let onOpenSticker: (AnimatedDocument) -> Void

    @ViewBuilder
    var body: some View {
        if message.role == .system && message.kind == .status {
            // Phase rows never reach here — `conversation` filters those out and the title chip
            // shows the live one. What is left is the model's own tool calls.
            ToolCallRow(message: message, api: toolAPI)
        } else if message.role == .user {
            HStack {
                Spacer(minLength: 44)
                messageContent
                    .foregroundStyle(AppColors.ink)
                    .padding(12)
                    .posterSurface(
                        cornerRadius: Poster.tileRadius,
                        fill: AppColors.accentSoft,
                        lineWidth: Poster.hairline,
                        offset: Poster.smallShadow
                    )
                    // Room for the bubble's own shadow, which is drawn outside its box.
                    .padding(.trailing, Poster.smallShadow.width)
                    .padding(.bottom, Poster.smallShadow.height)
                    .contextMenu {
                        if !message.content.isEmpty {
                            Button {
                                Haptics.tap(.light)
                                UIPasteboard.general.string = message.content
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                    }
            }
            .accessibilityLabel("user: \(message.content)")
        } else {
            HStack {
                messageContent
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                Spacer(minLength: 44)
            }
            .accessibilityLabel("assistant: \(message.content)")
        }
    }

    private var messageContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.content.isEmpty {
                // Assistant prose is written as Markdown; what the user typed is taken literally,
                // so an underscore in their own words never turns into italics behind their back.
                if message.role == .user {
                    Text(message.content)
                } else {
                    MarkdownText(markdown: message.content)
                }
            }

            if !message.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(message.attachments) { attachment in
                            ChatAttachmentThumbnail(attachment: attachment, image: assets[attachment.assetId])
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.never)
            }

            if let sticker {
                Button { onOpenSticker(sticker) } label: {
                    StickerAttachment(document: sticker, assets: assets, videos: videos, settings: configurationSettings)
                }
                .buttonStyle(.posterPlain)
                .accessibilityIdentifier("show-sticker-attachment")
            }
        }
    }
}

/// Placeholder bubbles for a transcript that has not arrived yet.
///
/// Laid out like the real thing — alternating sides, uneven widths, one tall row where a sticker
/// will land — so the transcript settles into place instead of appearing out of a blank screen.
/// The pulse is staggered per row, which reads as loading rather than as a control.
struct TranscriptSkeleton: View {
    @State private var animate = false

    private struct Row: Identifiable {
        let id: Int
        let isUser: Bool
        let widthFraction: CGFloat
        let height: CGFloat
    }

    private static let rows: [Row] = [
        .init(id: 0, isUser: true, widthFraction: 0.52, height: 40),
        .init(id: 1, isUser: false, widthFraction: 0.78, height: 58),
        .init(id: 2, isUser: false, widthFraction: 0.62, height: 190),
        .init(id: 3, isUser: true, widthFraction: 0.40, height: 40),
        .init(id: 4, isUser: false, widthFraction: 0.72, height: 58)
    ]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Self.rows) { row in
                HStack(spacing: 0) {
                    if row.isUser { Spacer(minLength: 44) }
                    RoundedRectangle(cornerRadius: Poster.tileRadius, style: .continuous)
                        .fill(AppColors.ink.opacity(animate ? 0.14 : 0.05))
                        .frame(height: row.height)
                        .containerRelativeFrame(.horizontal) { width, _ in width * row.widthFraction }
                        .animation(
                            .easeInOut(duration: 0.9)
                                .repeatForever(autoreverses: true)
                                .delay(Double(row.id) * 0.12),
                            value: animate
                        )
                    if !row.isUser { Spacer(minLength: 44) }
                }
            }
        }
        .padding(.horizontal, 16)
        .onAppear { animate = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading conversation")
        .accessibilityIdentifier("transcript-loading")
    }
}

/// A break in the transcript for something that happened to the sticker rather than something
/// anyone said — an edit saved in the editor. Centred and ruled on both sides so it reads as a
/// timeline marker at a glance, and never as a bubble waiting for a reply.
struct TranscriptDivider: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            rule
            PosterSymbolLabel(verbatim: text, posterSymbol: "pencil.and.outline")
                .posterLabelStyle(9, color: AppColors.ink)
                .lineLimit(1)
                .layoutPriority(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .posterCapsule(fill: AppColors.highlight, lineWidth: 1, offset: .zero)
            rule
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        .accessibilityIdentifier("transcript-divider")
    }

    private var rule: some View {
        Rectangle()
            .fill(AppColors.line)
            .frame(height: 1.5)
    }
}

private struct ToolCallRow: View {
    let message: ChatMessage
    let api: (any StickerAPIClientProtocol)?
    @State private var previewAssets = StickerAssetStore()
    @State private var previewFinished = false
    @State private var showingDetails = false

    private var color: Color {
        switch message.status {
        case .streaming: AppColors.sky
        case .complete: AppColors.mint
        case .failed: AppColors.coral
        }
    }

    var body: some View {
        Button {
            showingDetails = true
        } label: {
            chip
        }
        .buttonStyle(.posterPlain)
        .accessibilityLabel("Tool \(message.content), \(message.status.label)")
        .accessibilityHint("Shows the tool result or error")
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(message.content).font(.headline)
                        Label(message.status.label, systemImage: message.status == .failed ? "exclamationmark.circle" : "info.circle")
                            .foregroundStyle(AppColors.muted)
                        if let assetID = message.toolPreviewAssetID, let api {
                            if let image = previewAssets.images[assetID] {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .accessibilityIdentifier("tool-result-image")
                            } else if previewFinished {
                                ContentUnavailableView("Preview unavailable", systemImage: "photo")
                                Button("Retry") {
                                    Haptics.tap(.light)
                                    Task {
                                        previewFinished = false
                                        await previewAssets.load(assetID: assetID, api: api)
                                        previewFinished = true
                                    }
                                }
                            } else {
                                ProgressView("Loading preview…")
                            }
                        } else {
                            Text(message.toolDetails ?? fallbackDetails)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppColors.paper)
                .navigationTitle(message.status == .failed ? "Tool Error" : "Tool Result")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            Haptics.tap(.light)
                            showingDetails = false
                        }
                    }
                }
            }
            .task(id: message.toolPreviewAssetID) {
                guard let assetID = message.toolPreviewAssetID, let api else { return }
                previewFinished = false
                await previewAssets.load(assetID: assetID, api: api)
                previewFinished = true
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(AppColors.paper)
        }
    }

    private var fallbackDetails: String {
        switch message.status {
        case .streaming: String(localized: "This tool is still running. Its result will appear here when available.")
        case .complete: String(localized: "This tool completed. No result details were recorded.")
        case .failed: String(localized: "This tool failed. No error details were recorded.")
        }
    }

    private var chip: some View {
        HStack(spacing: 0) {
            UnevenRoundedRectangle(
                topLeadingRadius: Poster.chipRadius - 2,
                bottomLeadingRadius: Poster.chipRadius - 2,
                style: .continuous
            )
            .fill(color)
            .frame(width: 8)

            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(color)
                        .overlay(Circle().strokeBorder(AppColors.ink, lineWidth: 1.5))
                        .frame(width: 26, height: 26)
                    switch message.status {
                    case .streaming:
                        ProgressView().controlSize(.small).scaleEffect(0.7).tint(AppColors.ink)
                    case .complete:
                        PosterSymbol("checkmark").font(.caption.weight(.black)).foregroundStyle(AppColors.ink)
                    case .failed:
                        PosterSymbol("xmark").font(.caption.weight(.black)).foregroundStyle(AppColors.card)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(message.content)
                        .font(.caption.weight(.bold).monospaced())
                        .foregroundStyle(AppColors.ink)
                    if message.status == .streaming {
                        Text("Running…").posterLabelStyle(9, color: AppColors.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .posterSurface(cornerRadius: Poster.chipRadius, lineWidth: Poster.hairline, offset: CGSize(width: 2, height: 2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Tool \(message.content), \(message.status.label)")
    }
}

struct AssistantTypingIndicator: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(AppColors.coral)
                    .frame(width: 8, height: 8)
                    .scaleEffect(animate ? 1 : 0.5)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .posterCapsule(offset: Poster.smallShadow)
        .onAppear { animate = true }
        .accessibilityLabel(
            String(localized: "\(AppConfiguration.defaultAppName) is responding")
        )
    }
}

private struct ChatAttachmentThumbnail: View {
    let attachment: ChatAttachment
    let image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                PosterSymbol(attachment.kind == .mask ? "circle.lefthalf.filled" : "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 82, height: 82)
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .posterSurface(
            cornerRadius: 14,
            fill: AppColors.paper,
            lineWidth: Poster.hairline,
            offset: CGSize(width: 2, height: 2)
        )
        .accessibilityLabel(attachment.kind == .mask ? "Mask attachment" : "Reference image attachment")
    }
}

struct StickerAttachment: View {
    let document: AnimatedDocument
    let assets: [String: UIImage]
    var videos: [String: KeyedVideoFrames] = [:]

    var settings: StickerControlSettings?

    var body: some View {
        ZStack {
            // A checkerboard says "this artwork is transparent". Drawn in paper and ink so it
            // belongs to the same printed surface as everything around it.
            Canvas { context, size in
                let cell = size.width / 12
                for row in 0..<12 {
                    for column in 0..<12 where (row + column).isMultiple(of: 2) {
                        context.fill(
                            Path(CGRect(x: Double(column) * cell, y: Double(row) * cell, width: cell, height: cell)),
                            with: .color(AppColors.ink.opacity(0.05))
                        )
                    }
                }
            }
            .clipShape(.rect(cornerRadius: Poster.tileRadius, style: .continuous))

            StickerPlayer(document: document, assets: assets, videos: videos, repeats: true, settings: settings)
                .padding(10)
        }
        // Square first, then capped: a list row proposes no height, and `aspectRatio` fills a
        // missing dimension from the other one. Capping the width before the ratio is applied
        // keeps the tile at most 240 tall; capping it after let the ratio see the row's full
        // width first, which on iPad reserved a screen-tall column for a 240pt sticker.
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 240)
        .posterSurface(cornerRadius: Poster.tileRadius, fill: AppColors.paper, offset: Poster.smallShadow)
        .padding(.trailing, Poster.smallShadow.width)
        .padding(.bottom, Poster.smallShadow.height)
        .accessibilityLabel(document.kind == .animated ? "Animated sticker attachment" : "Sticker attachment")
    }
}

struct ComposerMediaChip: View {
    let media: PendingMediaAttachment
    /// Tapping the thumbnail reopens the lift flow on it. Nil hides the affordance entirely.
    var lift: (() -> Void)?
    /// Set on the one chip that should explain the tap. Nil on every other.
    var tip: LiftSubjectTip?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button {
                lift?()
            } label: {
                if let image = UIImage(data: media.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 34, height: 34)
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay(alignment: .bottomTrailing) {
                            // A capture is already cut out, so its thumbnail is mostly transparent
                            // and reads as a failed load without a badge. A plain reference gets one
                            // too, because nothing else says that tapping it lifts a subject.
                            if lift != nil {
                                PosterSymbol(media.sequence != nil ? "livephoto" : "person.and.background.dotted")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(2)
                                    .background(AppColors.card, in: Circle())
                                    .overlay(Circle().strokeBorder(AppColors.ink, lineWidth: 1))
                            }
                        }
                }
            }
            .buttonStyle(.posterPlain)
            .disabled(lift == nil)
            // The chips sit directly above the keyboard, so the popover has to open upward.
            .popoverTip(tip, arrowEdge: .bottom)
            .accessibilityLabel(media.sequence != nil
                ? "Lifted subject. Tap to choose a different one."
                : "Reference photo. Tap to lift a subject out of it.")

            Text(media.filename)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(AppColors.ink)
                .lineLimit(1)
            Button(action: remove) {
                PosterSymbol("xmark.circle.fill")
                    .foregroundStyle(AppColors.ink)
            }
            .accessibilityLabel("Remove \(media.filename)")
        }
        .padding(6)
        .padding(.trailing, 4)
        .posterCapsule(offset: CGSize(width: 2, height: 2))
    }
}

nonisolated extension ChatMessage {
    var toolPreviewAssetID: String? {
        guard status == .complete,
              let data = toolDetails?.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assetID = result["previewAssetId"] as? String, !assetID.isEmpty
        else { return nil }
        return assetID
    }
}
