import Foundation
import UIKit

/// The pet's places as the mock server keeps them: two everyday places it can go now, one closed at
/// this hour, and a trip that has already expired.
extension MockStickerAPIClient {
    static let sampleThemes: [PetTheme] = {
        let discovered = Date(timeIntervalSince1970: 1_790_000_000)
        func theme(
            _ id: String, _ title: String, _ description: String, _ category: PetThemeCategory,
            effects: PetRoom.Effects, rules: PetTheme.Rules = .init(), limited: Bool = false,
            expired: Bool = false, unavailableReason: String? = nil, minutesLeftToday: Int? = nil
        ) -> PetTheme {
            PetTheme(
                id: id, title: title, description: description, category: category, limited: limited, effects: effects,
                rules: rules, artKey: id, expiresAt: limited ? discovered.addingTimeInterval(72 * 60 * 60) : nil,
                expired: expired, available: !expired && unavailableReason == nil,
                unavailableReason: expired ? "This was a one-time place, and it has passed." : unavailableReason,
                minutesLeftToday: minutesLeftToday, discoveredAt: discovered,
                fixtures: mockRoomFixtures(hue: themeHue(id))
            )
        }
        return [
            theme("mock-theme-cafe", "Corner Café", "A warm café where your pet gets a treat.", .restaurant,
                  effects: .init(happiness: 2, hp: 1, energy: 3), rules: .init(dailyMinutes: 90), minutesLeftToday: 90),
            theme("mock-theme-park", "Sunny Park", "Grass and puddles to run through.", .nature,
                  effects: .init(happiness: 3, hp: 0, energy: -1)),
            theme("mock-theme-market", "Night Market", "Lanterns and snacks after dark.", .outdoor,
                  effects: .init(happiness: 4, hp: 0, energy: -2), rules: .init(hours: .init(from: 18, to: 24)),
                  unavailableReason: "Open 18:00–00:00 your time."),
            theme("mock-theme-kyoto", "Kyoto Streets", "Temples and tea on your trip.", .travel,
                  effects: .init(happiness: 4, hp: 0, energy: -2),
                  rules: .init(place: .init(label: "Kyoto", radiusKm: 60)), limited: true, expired: true)
        ]
    }()

    private var mockThemes: PetThemes {
        PetThemes(
            activeThemeId: adoptedPet?.theme?.id, themes: petThemeList,
            discovering: false, traveling: false, hasLocation: true
        )
    }

    func petThemes() async throws -> PetThemes { mockThemes }

    func setPetTheme(themeID: String?) async throws -> PetThemeChangeResponse {
        guard var pet = adoptedPet else {
            throw APIErrorEnvelope(error: .init(code: "PET_NOT_FOUND", message: "Choose a pet first.", requestId: "mock-pet", details: nil))
        }
        if let themeID {
            guard let theme = petThemeList.first(where: { $0.id == themeID }) else {
                throw APIErrorEnvelope(error: .init(
                    code: "PET_THEME_NOT_FOUND", message: "Your pet does not know this place.", requestId: "mock-pet", details: nil
                ))
            }
            guard theme.available else {
                throw APIErrorEnvelope(error: .init(
                    code: theme.expired ? "PET_THEME_EXPIRED" : "PET_THEME_UNAVAILABLE",
                    message: theme.unavailableReason ?? "Your pet cannot go there now.", requestId: "mock-pet", details: nil
                ))
            }
            pet.theme = theme.ref
        } else {
            pet.theme = nil
        }
        adoptedPet = pet
        return PetThemeChangeResponse(pet: pet, themes: mockThemes)
    }

    /// Each mock place's own colour, for its ground and the frames of its clock and boards.
    private static func themeHue(_ id: String) -> CGFloat {
        ["mock-theme-cafe": 0.08, "mock-theme-park": 0.28, "mock-theme-market": 0.75, "mock-theme-kyoto": 0.95][id] ?? 0.08
    }

    /// A sky over the ground in a colour of the place's own, portrait like the server's drawings, with
    /// a clock, a weather board and a status board left blank where `mockRoomFixtures` says.
    func petThemeArt(themeID: String) async throws -> Data {
        guard petThemeList.contains(where: { $0.id == themeID }) else { throw StickerAPIError.invalidResponse }
        let hue = Self.themeHue(themeID)
        let bounds = CGRect(x: 0, y: 0, width: 384, height: 576)
        return UIGraphicsImageRenderer(bounds: bounds).pngData { context in
            UIColor(hue: 0.57, saturation: 0.25, brightness: 0.97, alpha: 1).setFill()
            context.fill(bounds)
            UIColor(hue: hue, saturation: 0.45, brightness: 0.75, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: bounds.height * 0.62, width: bounds.width, height: bounds.height * 0.38))
            UIColor(hue: hue, saturation: 0.5, brightness: 0.35, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 53, y: 95, width: 53, height: 55))
            context.fill(CGRect(x: 291, y: 190, width: 76, height: 59))
            context.fill(CGRect(x: 82, y: 339, width: 220, height: 104))
            UIColor(red: 0.95, green: 0.92, blue: 0.86, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 59, y: 101, width: 41, height: 43))
            context.fill(CGRect(x: 297, y: 196, width: 64, height: 47))
            context.fill(CGRect(x: 88, y: 345, width: 208, height: 92))
        }
    }
}
