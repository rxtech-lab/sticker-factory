import AnimatedView
import Foundation

/// The controllable sticker this account has adopted as its pet — what the watch and widget show.
///
/// The sticker is the same summary the library lists, so it draws with the same thumbnail and
/// carries the `playbackRevisionId` its poses are fetched from. It need not be the user's own: a
/// member of an installed pack can be adopted too.
nonisolated struct Pet: Codable, Equatable, Sendable {
    var sticker: Sticker
    var selectedAt: Date
    /// How the pet looks right now, read by the server from the stickers this account sends. Nil
    /// until a send has been read since this pet was chosen; draw the controls' defaults until then.
    var status: PetStatus?
    var stats: PetStats = .initial
    var actions: [PetAction]?
    var items: PetItems?
    /// Who the pet is: its class, temperament and the world it was born into. Fixed at adoption.
    /// Nil for a moment after adopting, until the server has written it — and from older servers.
    var identity: PetIdentity?
    /// The latest weather, steps and headlines the pet has read. Nil until it has read any.
    var signals: PetSignals?
    /// When the server's life workflow will next drop by with something special for the pet.
    var nextEventAt: Date?
    /// The pet growing a new mood or look on its own, or how its last growth ended. Nil when it
    /// never has, and from older servers.
    var evolution: PetEvolution?
    /// The weather in `signals`, drawn by the server in the pet's own art style. Nil while there is
    /// no weather or it is still being drawn, and from older servers.
    var weatherArt: PetWeatherArt?
    /// Today's encounter while it waits for the owner's choice. Nil once chosen or expired, on days
    /// without one, and from older servers.
    var encounter: PetEncounter?
    /// A friend the pet made on its own — now a controllable sticker in the library — until the owner
    /// has been welcomed to it. Nil when there is none, and from older servers.
    var friend: PetFriend?
    /// What the pet is ill with. Nil while it is well.
    var illness: PetIllness?
    /// Doses of medicine the pet has, won from its encounters or bought. One cures an illness.
    var medicine: Int = 0
    /// What a dose costs in the item shop, which always has some. Nil from older servers, which
    /// do not sell it.
    var medicinePrice: Int?
    /// Food and tickets bought from the item shop to use later.
    var bag: [PetBagEntry] = []
    /// The room the pet lives in, drawn behind it on the tab. Nil on the plain page, and from older servers.
    var room: PetRoomRef?
    /// The sky outside the room's window for the weather in `signals`, drawn by the server in the
    /// pet's style as a 2×2 sheet of pieces the tab animates: sun or moon, wide cloud, small cloud and
    /// one particle. Nil with no weather or room, while it is drawn, and from older servers.
    var windowWeatherArt: PetWeatherArt?
    /// The place the pet has gone, drawn behind it in place of its room. Nil while it is at home,
    /// and from older servers.
    var theme: PetThemeRef?

    /// The HP gauge's ceiling: the class sets it, and a pet without an identity yet uses the old 100.
    var maxHp: Int { identity?.maxHp ?? 100 }
}

nonisolated extension Pet {
    /// Written out so every field after `selectedAt` may be missing: fixtures, tests and older
    /// servers all build pets without the newer parts, and none of them should fail to decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sticker = try container.decode(Sticker.self, forKey: .sticker)
        selectedAt = try container.decode(Date.self, forKey: .selectedAt)
        status = try container.decodeIfPresent(PetStatus.self, forKey: .status)
        stats = try container.decodeIfPresent(PetStats.self, forKey: .stats) ?? .initial
        actions = try container.decodeIfPresent([PetAction].self, forKey: .actions)
        items = try container.decodeIfPresent(PetItems.self, forKey: .items)
        identity = try container.decodeIfPresent(PetIdentity.self, forKey: .identity)
        signals = try container.decodeIfPresent(PetSignals.self, forKey: .signals)
        nextEventAt = try container.decodeIfPresent(Date.self, forKey: .nextEventAt)
        evolution = try container.decodeIfPresent(PetEvolution.self, forKey: .evolution)
        weatherArt = try container.decodeIfPresent(PetWeatherArt.self, forKey: .weatherArt)
        encounter = try container.decodeIfPresent(PetEncounter.self, forKey: .encounter)
        friend = try container.decodeIfPresent(PetFriend.self, forKey: .friend)
        illness = try container.decodeIfPresent(PetIllness.self, forKey: .illness)
        medicine = try container.decodeIfPresent(Int.self, forKey: .medicine) ?? 0
        medicinePrice = try container.decodeIfPresent(Int.self, forKey: .medicinePrice)
        bag = try container.decodeIfPresent([PetBagEntry].self, forKey: .bag) ?? []
        room = try container.decodeIfPresent(PetRoomRef.self, forKey: .room)
        windowWeatherArt = try container.decodeIfPresent(PetWeatherArt.self, forKey: .windowWeatherArt)
        theme = try container.decodeIfPresent(PetThemeRef.self, forKey: .theme)
    }
}

/// Names the room the pet lives in; its drawing is fetched with `petRoomArt(roomID:)`.
nonisolated struct PetRoomRef: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var artKey: String
    /// Where its drawing shows the time and the weather. Nil for rooms drawn before they had places for them.
    var fixtures: PetRoomFixtures?
}

/// Where a room's or place's drawing has a clock face, a weather board and a status board for the
/// app to write on. Any is nil when the drawing has no place for it, and the tab keeps that one in
/// its own chip or card.
nonisolated struct PetRoomFixtures: Codable, Equatable, Sendable {
    var clock: PetRoomFixture?
    var weather: PetRoomFixture?
    /// Where the pet's stats are written. Nil for drawings made before status boards.
    var status: PetRoomFixture?
}

/// A blank surface drawn into a room: a box as fractions of the room's drawing, its outline, the
/// colour the server painted it, and the ink that reads on it.
nonisolated struct PetRoomFixture: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var shape: Shape
    /// `#RRGGBB`.
    var face: String
    /// `#RRGGBB`.
    var ink: String

    nonisolated enum Shape: String, Codable, Sendable {
        case round, rect
    }
}

/// A room the owner's pets can live in, drawn by the pet's agent. Living there does `effects` to
/// the pet once a day; `price` is what it cost, or costs while it is still in the shop.
nonisolated struct PetRoom: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var description: String
    var effects: Effects
    var price: Int
    var artKey: String
    var owned: Bool
    var fixtures: PetRoomFixtures?

    nonisolated struct Effects: Codable, Equatable, Sendable {
        var happiness: Int
        var hp: Int
        var energy: Int
    }

    var ref: PetRoomRef { PetRoomRef(id: id, title: title, artKey: artKey, fixtures: fixtures) }
}

/// The rooms the owner has, the shop's offers, and the room the pet lives in.
nonisolated struct PetRooms: Codable, Equatable, Sendable {
    var activeRoomId: String?
    var owned: [PetRoom]
    var offers: [PetRoom]
    /// When the shop puts up new rooms. Nil before it has offered any.
    var offersRefreshAt: Date?
    /// True while the pet's agent is designing and drawing the shop's next rooms.
    var drawing: Bool
}

nonisolated struct PetRoomsResponse: Codable, Sendable { var rooms: PetRooms }

/// Names the place the pet has gone; its drawing is fetched with `petThemeArt(themeID:)`.
nonisolated struct PetThemeRef: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var artKey: String
    var category: PetThemeCategory
    /// Where its drawing shows the time, weather and stats. Nil for places drawn before they had them.
    var fixtures: PetRoomFixtures?
}

/// The kinds of place a pet can go. Unknown kinds from a newer server still decode.
nonisolated struct PetThemeCategory: RawRepresentable, Codable, Hashable, Sendable {
    var rawValue: String

    static let indoor = PetThemeCategory(rawValue: "indoor")
    static let outdoor = PetThemeCategory(rawValue: "outdoor")
    static let restaurant = PetThemeCategory(rawValue: "restaurant")
    static let nature = PetThemeCategory(rawValue: "nature")
    static let travel = PetThemeCategory(rawValue: "travel")
    static let event = PetThemeCategory(rawValue: "event")
    static let accident = PetThemeCategory(rawValue: "accident")

    var displayName: String {
        switch self {
        case .indoor: String(localized: "Indoor")
        case .outdoor: String(localized: "Outdoor")
        case .restaurant: String(localized: "Restaurant")
        case .nature: String(localized: "Nature")
        case .travel: String(localized: "Trip")
        case .event: String(localized: "Special Event")
        case .accident: String(localized: "Accident")
        default: rawValue.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .indoor: "sofa.fill"
        case .outdoor: "building.2.fill"
        case .restaurant: "fork.knife"
        case .nature: "leaf.fill"
        case .travel: "airplane"
        case .event: "party.popper.fill"
        case .accident: "cross.case.fill"
        default: "mappin"
        }
    }
}

/// A place the pet can go, discovered by its agent from its owner's world. Being there does
/// `effects` on each of the pet's visits. A `limited` place — a trip, an event, an accident — is
/// gone for good once `expired`; the others can be gone back to whenever their rules allow.
nonisolated struct PetTheme: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var description: String
    var category: PetThemeCategory
    var limited: Bool
    var effects: PetRoom.Effects
    var rules: Rules
    var artKey: String
    var expiresAt: Date?
    var expired: Bool
    var available: Bool
    /// Why the pet cannot go right now, in a sentence. Nil when it can.
    var unavailableReason: String?
    /// Minutes the pet may still spend here today, when the place limits them.
    var minutesLeftToday: Int?
    var discoveredAt: Date
    /// Where its drawing shows the time, weather and stats. Nil for places drawn before they had them.
    var fixtures: PetRoomFixtures?

    nonisolated struct Rules: Codable, Equatable, Sendable {
        /// The most minutes a day the pet may spend here. Nil for no limit.
        var dailyMinutes: Int?
        /// The owner's local hours it is open, `to` exclusive; may run through midnight.
        var hours: Hours?
        /// Only in these kinds of weather.
        var weather: [String]?
        /// Only while the owner is within `radiusKm` of this place.
        var place: Place?

        nonisolated struct Hours: Codable, Equatable, Sendable {
            var from: Int
            var to: Int
        }

        nonisolated struct Place: Codable, Equatable, Sendable {
            var label: String
            /// Where the owner was when the place was found. Nil from servers that kept it to themselves.
            var latitude: Double?
            var longitude: Double?
            var radiusKm: Double
        }

        var isEmpty: Bool { dailyMinutes == nil && hours == nil && (weather ?? []).isEmpty && place == nil }
    }

    var ref: PetThemeRef { PetThemeRef(id: id, title: title, artKey: artKey, category: category, fixtures: fixtures) }
}

/// The places the pet knows, which one it is at, and whether its agent is finding more.
nonisolated struct PetThemes: Codable, Equatable, Sendable {
    /// Nil while the pet is at home.
    var activeThemeId: String?
    var themes: [PetTheme]
    /// True while the pet's agent is discovering and drawing new places.
    var discovering: Bool
    /// True while the owner is far from home.
    var traveling: Bool
    /// False when the server has no location for the owner.
    var hasLocation: Bool
}

nonisolated struct PetThemesResponse: Codable, Sendable { var themes: PetThemes }

/// A trip somewhere or back home: the pet after it, and its places as they now stand.
nonisolated struct PetThemeChangeResponse: Codable, Sendable {
    var pet: Pet?
    var themes: PetThemes
}

/// `themeId` nil brings the pet home; it is sent as JSON `null`, not left out.
nonisolated struct SetPetThemeRequest: Codable, Sendable {
    var themeId: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(themeId, forKey: .themeId)
    }
}

/// A purchase or a move: the pet after it, and the rooms as they now stand.
nonisolated struct PetRoomChangeResponse: Codable, Sendable {
    var pet: Pet?
    var rooms: PetRooms
}

nonisolated struct PurchasePetRoomRequest: Codable, Sendable { var roomId: String }

/// `roomId` nil moves the pet back onto the plain page; it is sent as JSON `null`, not left out.
nonisolated struct SetPetRoomRequest: Codable, Sendable {
    var roomId: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(roomId, forKey: .roomId)
    }
}

/// Something the pet ran into that needs its owner to decide. Which choice is right, and what each
/// leads to, stays on the server until one is picked.
nonisolated struct PetEncounter: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var prompt: String
    var choices: [Choice]
    var expiresAt: Date

    nonisolated struct Choice: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var title: String
        var description: String
    }
}

/// What a pick led to: whether it was right, what the pet says happened, and what it won or lost.
nonisolated struct PetEncounterOutcome: Codable, Equatable, Sendable {
    var choiceId: String
    var correct: Bool
    var text: String
    var effects: PetActionEffects
    var medicine: Int
    var sickened: Bool
}

/// Someone the pet met while its owner was away, grown out of the weather, the place, its memories
/// and its mood, and made into a controllable sticker of their own.
nonisolated struct PetFriend: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    /// How the two met, in the pet's words.
    var story: String
    /// What the pet says to introduce its friend.
    var greeting: String
    /// The friend's own sticker, in the owner's library.
    var sticker: Sticker
    var metAt: Date
}

nonisolated struct MarkPetFriendSeenRequest: Codable, Sendable {
    var friendId: String
}

nonisolated struct ResolvePetEncounterRequest: Codable, Sendable {
    var encounterId: String
    var choiceId: String
}

nonisolated struct ResolvePetEncounterResponse: Codable, Sendable {
    var outcome: PetEncounterOutcome
    var pet: Pet?
}

/// What the pet is ill with, and since when. It drains the pet until medicine cures it, or it gets
/// over it on its own after a few days.
nonisolated struct PetIllness: Codable, Equatable, Sendable {
    var name: String
    var since: Date
}

/// The item shop: what is on the shelf, each leaving at its own `leavesAt`. The pet's agent adds a
/// few new things once a day. `artKey` changes whenever the shelf does; each item's picture is
/// fetched by its id with `petItemArt(itemID:size:)`.
nonisolated struct PetItems: Codable, Equatable, Sendable {
    var actions: [PetAction]
    var artKey: String
}

/// Something in the pet's bag, bought from the item shop to use later: how many are left, and when
/// the first of them expires — nil when none of them ever do. Using one uses the one expiring soonest.
nonisolated struct PetBagEntry: Codable, Equatable, Identifiable, Sendable {
    var item: PetAction
    var count: Int
    var expiresAt: Date?

    var id: String { item.id }
}

/// What an item is. Open-ended, so a kind a newer server adds still decodes.
nonisolated struct PetItemKind: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    var rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let food = PetItemKind(rawValue: "food")
    static let ticket = PetItemKind(rawValue: "ticket")
    static let toy = PetItemKind(rawValue: "toy")
}

/// Names the server's drawing of the pet's weather, fetched with `petWeatherArt(size:)`. A new
/// `key` means the drawing changed and has to be fetched again.
nonisolated struct PetWeatherArt: Codable, Equatable, Sendable {
    var kind: PetWeatherKind
    var isDay: Bool
    var key: String
}

/// The pet growing a new mood, property or look on its own sticker. The server plans, builds and
/// publishes it in the background, then the pet says what it learned and a notification follows.
nonisolated struct PetEvolution: Codable, Equatable, Sendable {
    var state: State
    var startedAt: Date
    var finishedAt: Date?

    /// Open like `PetClass`, so a stage the server adds later still decodes.
    nonisolated struct State: RawRepresentable, Codable, Hashable, Sendable {
        var rawValue: String

        static let planning = State(rawValue: "planning")
        static let building = State(rawValue: "building")
        static let publishing = State(rawValue: "publishing")
        static let ready = State(rawValue: "ready")
        static let failed = State(rawValue: "failed")
    }

    var isGrowing: Bool { [.planning, .building, .publishing].contains(state) }
}

/// The class a pet is born into. Each sets its HP ceiling and how much its activities tire it.
///
/// A struct over the raw string rather than an enum, so a class the server adds later decodes as
/// itself instead of failing the whole pet; it just draws with a generic symbol until the app knows it.
nonisolated struct PetClass: RawRepresentable, Codable, Hashable, Sendable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let guardian = PetClass(rawValue: "guardian")
    static let explorer = PetClass(rawValue: "explorer")
    static let dreamer = PetClass(rawValue: "dreamer")
    static let trickster = PetClass(rawValue: "trickster")
    static let scholar = PetClass(rawValue: "scholar")
    static let athlete = PetClass(rawValue: "athlete")

    var displayName: String {
        switch self {
        case .guardian: String(localized: "Guardian")
        case .explorer: String(localized: "Explorer")
        case .dreamer: String(localized: "Dreamer")
        case .trickster: String(localized: "Trickster")
        case .scholar: String(localized: "Scholar")
        case .athlete: String(localized: "Athlete")
        default: rawValue.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .guardian: "shield.fill"
        case .explorer: "map.fill"
        case .dreamer: "moon.stars.fill"
        case .trickster: "theatermasks.fill"
        case .scholar: "book.fill"
        case .athlete: "figure.run"
        default: "pawprint.fill"
        }
    }
}

/// The kinds of weather the server reads, and the kind a pet likes best. Open like `PetClass`.
nonisolated struct PetWeatherKind: RawRepresentable, Codable, Hashable, Sendable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let sunny = PetWeatherKind(rawValue: "sunny")
    static let cloudy = PetWeatherKind(rawValue: "cloudy")
    static let rainy = PetWeatherKind(rawValue: "rainy")
    static let snowy = PetWeatherKind(rawValue: "snowy")
    static let stormy = PetWeatherKind(rawValue: "stormy")
    static let foggy = PetWeatherKind(rawValue: "foggy")
    static let windy = PetWeatherKind(rawValue: "windy")

    var displayName: String {
        switch self {
        case .sunny: String(localized: "Sunny")
        case .cloudy: String(localized: "Cloudy")
        case .rainy: String(localized: "Rainy")
        case .snowy: String(localized: "Snowy")
        case .stormy: String(localized: "Stormy")
        case .foggy: String(localized: "Foggy")
        case .windy: String(localized: "Windy")
        default: rawValue.capitalized
        }
    }

    /// The symbol for this weather; a clear night draws the moon rather than the sun.
    func symbol(isDay: Bool = true) -> String {
        PetSnapshotWeather.symbol(kind: rawValue, isDay: isDay)
    }
}

nonisolated struct PetWeather: Codable, Equatable, Sendable {
    var kind: PetWeatherKind
    var temperatureC: Double
    var isDay: Bool
}

/// What the outside world looked like at one moment, as far as the pet can tell. Every part is
/// optional: a user who shares no location still has a pet, it just never feels the rain.
nonisolated struct PetSignals: Codable, Equatable, Sendable {
    var weather: PetWeather?
    var stepsToday: Int?
    var headlines: [String] = []
    /// Tomorrow's forecast where the owner is; the pet reads it in the evening to remind them of a
    /// coat or an umbrella. Absent from servers and snapshots that predate it.
    var tomorrow: PetForecast?

    init(weather: PetWeather? = nil, stepsToday: Int? = nil, headlines: [String] = [], tomorrow: PetForecast? = nil) {
        self.weather = weather
        self.stepsToday = stepsToday
        self.headlines = headlines
        self.tomorrow = tomorrow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weather = try container.decodeIfPresent(PetWeather.self, forKey: .weather)
        stepsToday = try container.decodeIfPresent(Int.self, forKey: .stepsToday)
        headlines = try container.decodeIfPresent([String].self, forKey: .headlines) ?? []
        tomorrow = try? container.decodeIfPresent(PetForecast.self, forKey: .tomorrow)
    }
}

/// Tomorrow's weather, as a day: its kind, low and high, and the chance of rain.
nonisolated struct PetForecast: Codable, Equatable, Sendable {
    var kind: PetWeatherKind
    var minC: Double
    var maxC: Double
    var precipitationChance: Int?
}

/// The world on the day the pet was adopted: the same signals, and when they were read.
nonisolated struct PetBirth: Codable, Equatable, Sendable {
    var weather: PetWeather?
    var stepsToday: Int?
    var headlines: [String] = []
    var at: Date

    init(weather: PetWeather? = nil, stepsToday: Int? = nil, headlines: [String] = [], at: Date) {
        self.weather = weather
        self.stepsToday = stepsToday
        self.headlines = headlines
        self.at = at
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weather = try container.decodeIfPresent(PetWeather.self, forKey: .weather)
        stepsToday = try container.decodeIfPresent(Int.self, forKey: .stepsToday)
        headlines = try container.decodeIfPresent([String].self, forKey: .headlines) ?? []
        at = try container.decode(Date.self, forKey: .at)
    }

    var signals: PetSignals { PetSignals(weather: weather, stepsToday: stepsToday, headlines: headlines) }
}

/// Who this pet is. Fixed at adoption, so the same pet behaves the same way all its life.
nonisolated struct PetIdentity: Codable, Equatable, Sendable {
    /// `class` on the wire; renamed here so it does not need backticks everywhere it is read.
    var petClass: PetClass
    var personality: String
    var likes: [String]
    var dislikes: [String]
    var favoriteWeather: PetWeatherKind
    /// The HP gauge's ceiling, 50–200.
    var maxHp: Int
    /// Multiplies the energy every activity costs. Below 1 is tireless, above 1 tires easily.
    var energyMultiplier: Double
    var birth: PetBirth

    enum CodingKeys: String, CodingKey {
        case petClass = "class"
        case personality, likes, dislikes, favoriteWeather, maxHp, energyMultiplier, birth
    }
}

/// What caused one line of the pet's diary. Open like `PetClass`, so a new kind still lists.
nonisolated struct PetEventKind: RawRepresentable, Codable, Hashable, Sendable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let adopted = PetEventKind(rawValue: "adopted")
    static let send = PetEventKind(rawValue: "send")
    static let interaction = PetEventKind(rawValue: "interaction")
    static let random = PetEventKind(rawValue: "random")
    static let special = PetEventKind(rawValue: "special")
    static let share = PetEventKind(rawValue: "share")
    static let photo = PetEventKind(rawValue: "photo")
    static let content = PetEventKind(rawValue: "content")
    static let sticker = PetEventKind(rawValue: "sticker")
    static let evolved = PetEventKind(rawValue: "evolved")
    static let encounter = PetEventKind(rawValue: "encounter")
    static let illness = PetEventKind(rawValue: "illness")
    static let medicine = PetEventKind(rawValue: "medicine")
    static let room = PetEventKind(rawValue: "room")
    static let theme = PetEventKind(rawValue: "theme")
    static let purchase = PetEventKind(rawValue: "purchase")
    static let friend = PetEventKind(rawValue: "friend")

    var displayName: String {
        switch self {
        case .adopted: String(localized: "Adopted")
        case .send: String(localized: "Sticker sent")
        case .interaction: String(localized: "Time together")
        case .random: String(localized: "Something happened")
        case .special: String(localized: "Special visit")
        case .share: String(localized: "Shared")
        case .photo: String(localized: "Picture shown")
        case .content: String(localized: "Read a share")
        case .sticker: String(localized: "New sticker seen")
        case .evolved: String(localized: "Grew something new")
        case .encounter: String(localized: "Needed you")
        case .illness: String(localized: "Health")
        case .medicine: String(localized: "Medicine")
        case .room: String(localized: "Room")
        case .theme: String(localized: "Places")
        case .purchase: String(localized: "Shopping")
        case .friend: String(localized: "New friend")
        default: rawValue.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .adopted: "heart.circle.fill"
        case .send: "paperplane.fill"
        case .interaction: "pawprint.fill"
        case .random: "dice.fill"
        case .special: "sparkles"
        case .share: "square.and.arrow.up.fill"
        case .photo: "photo.fill"
        case .content: "text.book.closed.fill"
        case .sticker: "eye.fill"
        case .evolved: "wand.and.stars"
        case .encounter: "exclamationmark.bubble.fill"
        case .illness: "thermometer.medium"
        case .medicine: "pills.fill"
        case .theme: "map.fill"
        case .purchase: "bag.fill"
        case .friend: "person.2.fill"
        default: "circle.fill"
        }
    }
}

/// One line of the pet's diary: what happened, what it did to the stats, and what the server knew
/// at the time. `debug` is free-form and exists to answer "why did my pet do that?".
nonisolated struct PetEvent: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: PetEventKind
    var title: String
    var detail: String
    var effects: PetActionEffects
    var statsBefore: PetStats
    var statsAfter: PetStats
    var signals: PetSignals?
    var debug: [String: JSONValue] = [:]
    var createdAt: Date

    init(
        id: String, kind: PetEventKind, title: String, detail: String, effects: PetActionEffects,
        statsBefore: PetStats, statsAfter: PetStats, signals: PetSignals? = nil,
        debug: [String: JSONValue] = [:], createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.effects = effects
        self.statsBefore = statsBefore
        self.statsAfter = statsAfter
        self.signals = signals
        self.debug = debug
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(PetEventKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        effects = try container.decode(PetActionEffects.self, forKey: .effects)
        statsBefore = try container.decode(PetStats.self, forKey: .statsBefore)
        statsAfter = try container.decode(PetStats.self, forKey: .statsAfter)
        signals = try container.decodeIfPresent(PetSignals.self, forKey: .signals)
        debug = try container.decodeIfPresent([String: JSONValue].self, forKey: .debug) ?? [:]
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

/// A page of the diary, newest first. `nextCursor` is nil on the last page.
nonisolated struct PetEventsResponse: Codable, Equatable, Sendable {
    var events: [PetEvent]
    var nextCursor: String?
}

/// Coarse context the phone hands the server: where, how many steps today, and which time zone
/// "today" is in. Every field is optional and left out of the JSON when nil, so a permission the
/// user never granted is simply unknown rather than zero. Latitude and longitude travel together.
nonisolated struct PetContextPayload: Codable, Equatable, Sendable {
    var latitude: Double?
    var longitude: Double?
    var stepsToday: Int?
    var timeZone: String?
    /// False when the owner turned location tracking off: the server forgets where they were. Never
    /// sent together with a location; left out while tracking is on.
    var trackLocation: Bool?

    var hasLocation: Bool { latitude != nil && longitude != nil }
    var isEmpty: Bool { !hasLocation && stepsToday == nil && timeZone == nil && trackLocation == nil }
}

/// Whether the server kept the context — false when there is no pet to keep it for — and what the
/// owner's walk paid the pet if these steps paid it out. `walk` is absent from older servers.
nonisolated struct PetContextStoredResponse: Codable, Equatable, Sendable {
    var stored: Bool
    var walk: PetWalkReward?
}

/// What the owner's walk just gave the pet: the energy and gold it actually gained, after topping out.
nonisolated struct PetWalkReward: Codable, Equatable, Sendable {
    var steps: Int
    var energy: Int
    var gold: Int
}

nonisolated struct PetStats: Codable, Equatable, Sendable {
    var happiness: Int
    var hp: Int
    var energy: Int
    /// What the pet has to spend on actions that cost gold. Absent from servers before gold.
    var gold: Int = 0

    static let initial = PetStats(happiness: 80, hp: 100, energy: 80, gold: 20)
}

extension PetStats {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        happiness = try container.decode(Int.self, forKey: .happiness)
        hp = try container.decode(Int.self, forKey: .hp)
        energy = try container.decode(Int.self, forKey: .energy)
        gold = try container.decodeIfPresent(Int.self, forKey: .gold) ?? 0
    }
}

nonisolated struct PetAction: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var description: String
    var effects: PetActionEffects
    /// Set on items only. Nil on actions and on items from older servers.
    var kind: PetItemKind?
    /// Shop items only: when it leaves the shelf. Nil on items from older servers.
    var leavesAt: Date?
    /// Items only: hours one keeps in the bag once bought. Nil when it never expires, and on actions.
    var keepsHours: Int?
}

nonisolated struct PetActionEffects: Codable, Equatable, Sendable {
    var happiness: Int
    var hp: Int
    var energy: Int
    /// Negative is what the action costs, refused while the pet has less; positive is what it earns.
    var gold: Int = 0

    /// The gold this action takes from the pet, or 0 when it is free or earns some.
    var price: Int { max(0, -gold) }
}

extension PetActionEffects {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        happiness = try container.decode(Int.self, forKey: .happiness)
        hp = try container.decode(Int.self, forKey: .hp)
        energy = try container.decode(Int.self, forKey: .energy)
        gold = try container.decodeIfPresent(Int.self, forKey: .gold) ?? 0
    }
}

nonisolated struct PetInteractionRequest: Codable, Sendable {
    var actionId: String
    /// Uses one from the bag, already paid for, rather than buying it from the shop.
    var fromBag: Bool?
}

nonisolated struct PurchasePetItemRequest: Codable, Sendable { var itemId: String }

/// A picture the owner shows their pet, uploaded first as an unbound `reference` asset.
nonisolated struct SendPetPhotoRequest: Codable, Sendable { var assetId: String }

/// A pose for the pet's own controls, and a few words in its voice about it.
///
/// `values` are already normalized against the pet's playback document — every control has one —
/// so they can be handed to the renderer as they are.
nonisolated struct PetStatus: Codable, Equatable, Sendable {
    var values: [String: AnimatedControlValue]
    var caption: String
    var updatedAt: Date
    /// How often the pet plays its animation through once, chosen by its agent with the pose. Nil
    /// from statuses written before the agent chose it; the tab uses `PetBrain.defaultAnimationInterval`.
    var animateEverySeconds: Int?
    /// What the pet says next on its own, each `afterMinutes` after the line before, the first
    /// counted from `updatedAt`. Nil from statuses written before the agent queued any.
    var musings: [PetMusing]?

    /// What the pet is saying at `date`: its caption, or the last of its musings due by then.
    func caption(at date: Date) -> String {
        PetMusing.line(caption: caption, musings: musings ?? [], since: updatedAt, at: date)
    }

    /// The moments the pet's line changes, for a `TimelineView` to redraw at.
    var captionDates: [Date] { [updatedAt] + PetMusing.dates(of: musings ?? [], since: updatedAt) }
}

/// `pet` is nil when none is chosen, or when the chosen one stopped being posable — unpublished,
/// or its pack uninstalled.
nonisolated struct PetResponse: Codable, Sendable { var pet: Pet? }

nonisolated struct SetPetRequest: Codable, Sendable {
    var stickerId: String
    /// Recorded as the world the pet was born into. Left out of the JSON when nil.
    var context: PetContextPayload?
}
