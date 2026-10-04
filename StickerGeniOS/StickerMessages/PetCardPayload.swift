import Foundation

/// The pet card one person sends another, carried entirely in an `MSMessage`'s URL.
///
/// The URL *is* the payload: Messages delivers it to the recipient's copy of this extension
/// verbatim, and the recipient is not the pet's owner, so there is nothing they could fetch with it
/// even if they wanted to — `/api/v1/pet` only ever answers about the caller's own pet. A snapshot
/// in the URL is also what a card should be: what the pet looked like when it was shown, not what
/// it looks like now.
///
/// Format (all query items, `v` first):
///
///     https://sticker.rxlab.app/pet-card?v=1&name=…&class=…&personality=…&caption=…
///         &happiness=0…100&hp=0…200&maxHp=1…200&energy=0…100&stickerId=…
///
/// An `https` URL rather than a custom scheme because Messages hands it to Safari when the
/// recipient has no copy of the app (on a Mac, say), and a page can answer there; a custom scheme
/// would just fail to open.
///
/// Parsing is defensive by construction — the URL arrives from someone else's device — so
/// `init?(url:)` rejects anything that is not this card, clamps every number to the server's own
/// ranges and truncates every string, rather than trusting any of it.
struct PetCardPayload: Equatable, Sendable {
    static let version = "1"
    static let host = "sticker.rxlab.app"
    static let path = "/pet-card"

    /// Ceilings well inside what Messages will carry. A card URL that grows without bound is one
    /// a long caption could push past the transport's limit, and the send would fail silently.
    static let maximumNameLength = 80
    static let maximumClassLength = 32
    static let maximumPersonalityLength = 80
    static let maximumCaptionLength = 280
    static let maximumStickerIDLength = 64

    var name: String
    var petClass: String?
    var personality: String?
    var caption: String?
    var happiness: Int
    var hp: Int
    var maxHp: Int
    var energy: Int
    var stickerID: String?

    init(
        name: String,
        petClass: String? = nil,
        personality: String? = nil,
        caption: String? = nil,
        happiness: Int,
        hp: Int,
        maxHp: Int,
        energy: Int,
        stickerID: String? = nil
    ) {
        self.name = Self.clean(name, limit: Self.maximumNameLength) ?? String(localized: "Pet")
        self.petClass = Self.clean(petClass, limit: Self.maximumClassLength)
        self.personality = Self.clean(personality, limit: Self.maximumPersonalityLength)
        self.caption = Self.clean(caption, limit: Self.maximumCaptionLength)
        self.maxHp = min(max(maxHp, 1), 200)
        self.happiness = min(max(happiness, 0), 100)
        self.hp = min(max(hp, 0), self.maxHp)
        self.energy = min(max(energy, 0), 100)
        self.stickerID = Self.clean(stickerID, limit: Self.maximumStickerIDLength)
    }

    init(pet: MessagesPet) {
        self.init(
            name: pet.title,
            petClass: pet.identity?.petClass,
            personality: pet.identity?.personality,
            caption: pet.caption,
            happiness: pet.stats.happiness,
            hp: pet.stats.hp,
            maxHp: pet.maxHp,
            energy: pet.stats.energy,
            stickerID: pet.stickerID
        )
    }

    /// `nil` for anything that is not a version-1 pet card: another host, another path, another
    /// version, no name, or stats that are missing or not integers.
    init?(url: URL?) {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == Self.host,
              components.path == Self.path
        else { return nil }

        // First occurrence wins, so a duplicated key appended by someone else cannot override.
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where values[item.name] == nil {
            if let value = item.value { values[item.name] = value }
        }
        guard values["v"] == Self.version,
              let name = Self.clean(values["name"], limit: Self.maximumNameLength),
              let happiness = values["happiness"].flatMap(Int.init),
              let hp = values["hp"].flatMap(Int.init),
              let energy = values["energy"].flatMap(Int.init)
        else { return nil }
        // An older or hand-made card without a ceiling still draws, against the default one.
        let maxHp = values["maxHp"].flatMap(Int.init) ?? max(100, hp)

        self.init(
            name: name,
            petClass: values["class"],
            personality: values["personality"],
            caption: values["caption"],
            happiness: happiness,
            hp: hp,
            maxHp: maxHp,
            energy: energy,
            stickerID: values["stickerId"]
        )
    }

    /// The card as a URL. Nil fields are left out rather than sent empty.
    var url: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = Self.path
        var items = [
            URLQueryItem(name: "v", value: Self.version),
            URLQueryItem(name: "name", value: name)
        ]
        if let petClass { items.append(URLQueryItem(name: "class", value: petClass)) }
        if let personality { items.append(URLQueryItem(name: "personality", value: personality)) }
        if let caption { items.append(URLQueryItem(name: "caption", value: caption)) }
        items += [
            URLQueryItem(name: "happiness", value: String(happiness)),
            URLQueryItem(name: "hp", value: String(hp)),
            URLQueryItem(name: "maxHp", value: String(maxHp)),
            URLQueryItem(name: "energy", value: String(energy))
        ]
        if let stickerID { items.append(URLQueryItem(name: "stickerId", value: stickerID)) }
        components.queryItems = items
        // `URLQueryItem` leaves `+` alone, and many readers decode it as a space. Encoding it here
        // keeps "C++ fan" a C++ fan on the other side.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        // Every part above is a constant or percent-encoded by `URLComponents`, so this cannot fail.
        return components.url!
    }

    /// "Explorer · Curious and kind", or whichever half exists.
    var classLine: String? {
        let parts = [petClass.map(MessagesPet.displayName(forClass:)), personality].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The compact stat line the message bubble shows beneath the caption.
    var statLine: String {
        "♥ \(happiness) · HP \(hp)/\(maxHp) · ⚡ \(energy)"
    }

    private static func clean(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        // Control characters have no business in a card and could break the bubble's layout.
        let scalars = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }
}
