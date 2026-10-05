import SwiftUI

/// The Rooms tab of the time-together sheet: the rooms the owner has, and the room shop's offers,
/// each dreamed up and drawn by the pet's agent. Tapping a room hands it to `open`, which shows it in
/// its own sheet, where it is bought or moved into.
struct PetRoomsList: View {
    @Bindable var model: PetModel
    /// Opens a room, with its thumbnail if it has loaded.
    let open: (PetRoom, UIImage?) -> Void
    @State private var thumbnails: [String: UIImage] = [:]

    /// How many times the tab looks again for a shop still being drawn before it waits for the owner.
    private static let drawingChecks = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rooms your pet dreamed up. Each is good for your pet in its own way, every day it lives there.")
                .foregroundStyle(AppColors.muted)
            if let rooms = model.rooms {
                if !rooms.owned.isEmpty {
                    section(String(localized: "Your Rooms"), rooms: rooms.owned, activeID: rooms.activeRoomId)
                }
                shop(rooms)
            } else {
                ProgressView("Opening the room shop…")
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .padding()
        .task {
            for _ in 0..<Self.drawingChecks {
                await model.refreshRooms()
                await loadThumbnails()
                guard !Task.isCancelled, model.rooms?.drawing == true else { return }
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
            }
        }
    }

    @ViewBuilder
    private func shop(_ rooms: PetRooms) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Room Shop").font(.system(size: 16, weight: .heavy, design: .monospaced))
                Spacer(minLength: 8)
                if let refreshAt = rooms.offersRefreshAt, refreshAt > .now, !rooms.drawing {
                    Text("New rooms \(refreshAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(AppColors.muted)
                }
            }
            if rooms.drawing && rooms.offers.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Your pet is dreaming up and drawing some rooms…")
                        .font(.footnote)
                        .foregroundStyle(AppColors.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
                .accessibilityIdentifier("pet-rooms-drawing")
            } else if rooms.offers.isEmpty {
                Text("You bought everything on offer. New rooms arrive soon.")
                    .font(.footnote)
                    .foregroundStyle(AppColors.muted)
            } else {
                ForEach(rooms.offers) { room in roomButton(room, isActive: false) }
            }
        }
    }

    private func section(_ title: String, rooms: [PetRoom], activeID: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 16, weight: .heavy, design: .monospaced))
            ForEach(rooms) { room in roomButton(room, isActive: room.id == activeID) }
        }
    }

    private func roomButton(_ room: PetRoom, isActive: Bool) -> some View {
        Button {
            Haptics.tap(.light)
            open(room, thumbnails[room.id])
        } label: {
            HStack(spacing: 14) {
                PetRoomThumbnail(image: thumbnails[room.id])
                    .frame(width: 64, height: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text(room.title).font(.headline)
                    Text(room.description)
                        .font(.caption)
                        .foregroundStyle(AppColors.muted)
                        .lineLimit(2)
                    PetEffectsRow(effects: room.dailyEffects)
                    if isActive {
                        Label("Living here", systemImage: "house.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.green)
                    } else if !room.owned {
                        PetGoldChip(change: -room.price)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.posterCard)
        .disabled(model.activity != nil)
        .accessibilityIdentifier("pet-room-\(room.id)")
    }

    private func loadThumbnails() async {
        guard let rooms = model.rooms else { return }
        for room in rooms.owned + rooms.offers where thumbnails[room.id] == nil {
            guard !Task.isCancelled else { return }
            if let image = try? await PetArtworkImageCache.shared.loadRoom(roomID: room.id, artKey: room.artKey, api: model.api) {
                thumbnails[room.id] = image
            }
        }
    }
}

/// One room up close: its drawing, what living there does each day, and buying it or moving in.
struct PetRoomDetailSheet: View {
    @Bindable var model: PetModel
    let roomID: String
    @State private var image: UIImage?
    @State private var confirmingPurchase = false
    @Environment(\.dismiss) private var dismiss

    init(model: PetModel, roomID: String, preview: UIImage?) {
        self.model = model
        self.roomID = roomID
        _image = State(initialValue: preview)
    }

    /// Read from the model, so a purchase made here shows as owned at once.
    private var room: PetRoom? {
        guard let rooms = model.rooms else { return nil }
        return (rooms.owned + rooms.offers).first { $0.id == roomID }
    }

    private var isActive: Bool { model.rooms?.activeRoomId == roomID }

    var body: some View {
        NavigationStack {
            Group {
                if let room {
                    ScrollView { details(room) }
                        .safeAreaInset(edge: .bottom) {
                            primaryButton(room)
                                .padding(.horizontal)
                                .padding(.bottom, 12)
                        }
                } else {
                    ContentUnavailableView(
                        "Room Unavailable", systemImage: "house.slash",
                        description: Text("The shop has moved on from this room.")
                    )
                }
            }
            .navigationTitle(room?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PetGoldBadge(gold: model.pet?.stats.gold ?? 0)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Haptics.tap(.light); dismiss() }
                        .disabled(model.activity != nil)
                }
            }
            .safeAreaInset(edge: .top) {
                if let errorMessage = model.errorMessage {
                    ErrorBanner(message: errorMessage).padding(.horizontal)
                }
            }
        }
        .overlay {
            if let activity = model.activity { PetActivityOverlay(activity: activity) }
        }
        .animation(.snappy(duration: 0.2), value: model.activity)
        .interactiveDismissDisabled(model.activity != nil)
        .task {
            guard image == nil, let room else { return }
            image = try? await PetArtworkImageCache.shared.loadRoom(roomID: room.id, artKey: room.artKey, api: model.api)
        }
    }

    private func details(_ room: PetRoom) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            PetRoomThumbnail(image: image)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: 320)
                .frame(maxWidth: .infinity)
            Text(room.description)
            VStack(alignment: .leading, spacing: 8) {
                Text("Every day your pet lives here")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                PetEffectsRow(effects: room.dailyEffects)
            }
            if !room.owned {
                HStack(spacing: 8) {
                    Text("Price")
                        .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    PetGoldChip(change: -room.price)
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private func primaryButton(_ room: PetRoom) -> some View {
        if !room.owned {
            let affordable = model.canAfford(room)
            VStack(spacing: 6) {
                Button {
                    Haptics.tap(.medium)
                    confirmingPurchase = true
                } label: {
                    Label("Buy for \(room.price) Gold", systemImage: "cart.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.poster)
                .disabled(!affordable || model.activity != nil)
                .accessibilityIdentifier("pet-room-buy")
                .confirmationDialog(
                    "Buy This Room?",
                    isPresented: $confirmingPurchase,
                    titleVisibility: .visible
                ) {
                    Button("Buy for \(room.price) Gold") {
                        Haptics.tap(.heavy)
                        Task { if await model.purchaseRoom(room) { dismiss() } }
                    }
                    .accessibilityIdentifier("pet-room-purchase-confirm")
                    Button("Cancel", role: .cancel) { Haptics.tap(.light) }
                } message: {
                    Text("Your pet moves into \(room.title) right away. You keep the room, and can move back any time.")
                }
                if !affordable {
                    Text("You need \(room.price - (model.pet?.stats.gold ?? 0)) more gold. Walks and new stickers earn it.")
                        .font(.caption)
                        .foregroundStyle(AppColors.muted)
                        .multilineTextAlignment(.center)
                }
            }
        } else if isActive {
            Button {
                Haptics.tap(.medium)
                Task { if await model.moveIntoRoom(nil) { dismiss() } }
            } label: {
                Label("Move Out", systemImage: "door.left.hand.open")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.posterSecondary)
            .disabled(model.activity != nil)
            .accessibilityIdentifier("pet-room-move-out")
        } else {
            Button {
                Haptics.tap(.medium)
                Task { if await model.moveIntoRoom(room) { dismiss() } }
            } label: {
                Label("Move In", systemImage: "house.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.poster)
            .disabled(model.activity != nil)
            .accessibilityIdentifier("pet-room-move-in")
        }
    }
}

/// A room's drawing, or a placeholder of the same shape while it loads.
struct PetRoomThumbnail: View {
    let image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(AppColors.card)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    Image(systemName: "house")
                        .font(.title3)
                        .foregroundStyle(AppColors.muted)
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(AppColors.ink, lineWidth: 2) }
            .animation(.snappy(duration: 0.25), value: image)
            .accessibilityHidden(true)
    }
}

extension PetRoom {
    /// What living here does each day, in the shape the effect chips draw.
    var dailyEffects: PetActionEffects {
        PetActionEffects(happiness: effects.happiness, hp: effects.hp, energy: effects.energy, gold: 0)
    }
}
