import Foundation

/// The caller's pet as `GET /api/v1/pet` describes it, reduced to what the Messages Pet page draws.
///
/// Decoded permissively and kept separate from `StickerPetShared`'s `PetSnapshot`: that type is the
/// widget's distilled copy and is not compiled into this extension, and this one has to survive a
/// server that is newer than the binary. Anything optional on the wire is optional here, and the
/// parts the page can do without (identity, signals, status) never fail the whole decode.
struct MessagesPet: Decodable, Equatable, Sendable {
    struct Stats: Decodable, Equatable, Sendable {
        var happiness: Int
        var hp: Int
        var energy: Int
    }

    struct Identity: Decodable, Equatable, Sendable {
        var petClass: String
        var personality: String
        var maxHp: Int?

        private enum CodingKeys: String, CodingKey {
            case petClass = "class"
            case personality
            case maxHp
        }
    }

    struct Weather: Decodable, Equatable, Sendable {
        var kind: String
        var temperatureC: Double
        var isDay: Bool
    }

    struct Signals: Decodable, Equatable, Sendable {
        var weather: Weather?
        var stepsToday: Int?
    }

    var stickerID: String
    var title: String
    var caption: String?
    var stats: Stats
    var identity: Identity?
    var signals: Signals?

    /// The HP bar's ceiling. The class sets it at adoption; before an older pet's identity is
    /// written the server's own default ceiling of 100 is the honest guess.
    var maxHp: Int { max(identity?.maxHp ?? 100, 1) }

    private enum CodingKeys: String, CodingKey { case sticker, status, stats, identity, signals }
    private enum StickerKeys: String, CodingKey { case id, title }
    private enum StatusKeys: String, CodingKey { case caption }

    init(
        stickerID: String,
        title: String,
        caption: String?,
        stats: Stats,
        identity: Identity?,
        signals: Signals?
    ) {
        self.stickerID = stickerID
        self.title = title
        self.caption = caption
        self.stats = stats
        self.identity = identity
        self.signals = signals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sticker = try container.nestedContainer(keyedBy: StickerKeys.self, forKey: .sticker)
        stickerID = try sticker.decode(String.self, forKey: .id)
        let title = try sticker.decodeIfPresent(String.self, forKey: .title)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = (title?.isEmpty == false ? title : nil) ?? String(localized: "Your Pet")
        if let status = try? container.nestedContainer(keyedBy: StatusKeys.self, forKey: .status) {
            let caption = try? status.decodeIfPresent(String.self, forKey: .caption)
            self.caption = caption.flatMap { $0.isEmpty ? nil : $0 }
        } else {
            caption = nil
        }
        stats = try container.decode(Stats.self, forKey: .stats)
        identity = try? container.decodeIfPresent(Identity.self, forKey: .identity)
        signals = try? container.decodeIfPresent(Signals.self, forKey: .signals)
    }
}

/// `{ pet: … | null }`.
struct MessagesPetEnvelope: Decodable, Sendable {
    let pet: MessagesPet?
}

/// `POST /api/v1/pet/shares`: whether showing the pet moved its stats, and the pet after it did.
struct MessagesPetShare: Decodable, Sendable {
    let accepted: Bool
    let pet: MessagesPet?
}

extension MessagesPet {
    /// The class as a reader sees it. The server sends a fixed vocabulary in English; anything
    /// newer than this binary is shown capitalised rather than hidden.
    static func displayName(forClass petClass: String) -> String {
        switch petClass {
        case "guardian": String(localized: "Guardian")
        case "explorer": String(localized: "Explorer")
        case "dreamer": String(localized: "Dreamer")
        case "trickster": String(localized: "Trickster")
        case "scholar": String(localized: "Scholar")
        case "athlete": String(localized: "Athlete")
        default: petClass.capitalized
        }
    }

    /// An SF Symbol for each weather kind the server names.
    static func weatherSymbol(_ kind: String, isDay: Bool) -> String {
        switch kind {
        case "sunny": isDay ? "sun.max.fill" : "moon.stars.fill"
        case "cloudy": "cloud.fill"
        case "rainy": "cloud.rain.fill"
        case "snowy": "cloud.snow.fill"
        case "stormy": "cloud.bolt.rain.fill"
        case "foggy": "cloud.fog.fill"
        case "windy": "wind"
        default: "cloud.sun.fill"
        }
    }
}
