import SwiftUI

enum ExportBackgroundChoice: String, CaseIterable, Identifiable {
    case white, midnight, sunrise, ocean
    var id: Self { self }
    static func choice(for background: StickerMP4BackgroundV1) -> Self? {
        allCases.first { $0.background == background }
    }
    var label: String {
        switch self { case .white: "White"; case .midnight: "Midnight"; case .sunrise: "Sunrise gradient"; case .ocean: "Ocean gradient" }
    }
    var background: StickerMP4BackgroundV1 {
        switch self {
        case .white: .solid("#FFFFFF")
        case .midnight: .solid("#16141D")
        case .sunrise: .linearGradient(colors: ["#FFE7A3", "#FF8FA3"], angleDegrees: 35)
        case .ocean: .linearGradient(colors: ["#74D4FF", "#7267FF"], angleDegrees: 140)
        }
    }
}

struct ExportBackgroundSwatch: View {
    let choice: ExportBackgroundChoice

    private var colors: [Color] {
        switch choice {
        case .white:
            [.white, .white]
        case .midnight:
            [Color(red: 0.086, green: 0.078, blue: 0.114), Color(red: 0.086, green: 0.078, blue: 0.114)]
        case .sunrise:
            [Color(red: 1, green: 0.906, blue: 0.639), Color(red: 1, green: 0.561, blue: 0.639)]
        case .ocean:
            [Color(red: 0.455, green: 0.831, blue: 1), Color(red: 0.447, green: 0.404, blue: 1)]
        }
    }

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Circle()
                    .stroke(.primary.opacity(0.12), lineWidth: 1)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
    }
}
