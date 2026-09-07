import Combine
import RxSubscriptionIOS
import SwiftUI

/// Sticker Factory's branded credit controls.
///
/// The subscription package owns the catalog and purchase behavior. This view only owns the
/// presentation so a top-up feels like the rest of the app instead of a generic store row.
struct StickerCreditsView<Header: View>: View {
    private enum Section: String, CaseIterable, Identifiable {
        case topUps
        case balance

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .topUps: "Top-ups"
            case .balance: "Balance"
            }
        }
    }

    let client: Client
    let header: Header
    @State private var selection = Section.topUps

    init(client: Client, @ViewBuilder header: () -> Header) {
        self.client = client
        self.header = header()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Picker("Credit section", selection: $selection) {
                ForEach(Section.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .accessibilityIdentifier("credits-section-picker")

            switch selection {
            case .topUps:
                StickerTopUpView(client: client)
            case .balance:
                StickerBalanceView(client: client)
            }
        }
        .background(AppColors.paper)
    }
}

private struct StickerTopUpView: View {
    @StateObject private var model: StickerTopUpViewModel
    @Environment(\.openURL) private var openURL

    init(client: Client) {
        _model = StateObject(wrappedValue: StickerTopUpViewModel(client: client))
    }

    var body: some View {
        ZStack {
            ScrollView {
                content
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
            }
            .refreshable { await model.load(force: true) }
            .task { await model.load() }

            if model.processingID != nil {
                processingOverlay
            }
        }
        .alert("Top Up", isPresented: $model.showingMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.topUps.isEmpty {
            PosterProgress(message: String(localized: "Loading top-ups…"))
                .padding(.top, 24)
        } else if let error = model.error, model.topUps.isEmpty {
            VStack(spacing: 16) {
                ErrorBanner(message: error)
                Button {
                    Task { await model.load(force: true) }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.posterSecondary)
            }
        } else if model.topUps.isEmpty {
            EmptyStateView(
                title: String(localized: "No top-ups available"),
                message: String(localized: "Points packs will appear here when they are available."),
                icon: PosterIcon.credits,
                accent: AppColors.peach
            )
        } else {
            topUpList
        }
    }

    private var topUpList: some View {
        let eligible = model.topUps.filter { $0.eligible != false }
        let unavailable = model.topUps.filter { $0.eligible == false }

        return VStack(alignment: .leading, spacing: 22) {
            if !eligible.isEmpty {
                topUpSection(
                    title: String(localized: "Choose a points pack"),
                    subtitle: String(localized: "A one-time purchase that leaves your plan unchanged."),
                    items: eligible
                )
            }

            if !unavailable.isEmpty {
                topUpSection(
                    title: String(localized: "Unavailable"),
                    subtitle: nil,
                    items: unavailable
                )
            }
        }
    }

    private func topUpSection(title: String, subtitle: String?, items: [TopUpProduct]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            PosterSectionHeader(title: title, subtitle: subtitle, highlight: AppColors.peach)

            ForEach(items) { topUp in
                StickerTopUpCard(
                    topUp: topUp,
                    price: model.price(for: topUp),
                    isProcessing: model.processingID == topUp.id,
                    isDisabled: model.processingID != nil
                ) {
                    Task {
                        if let url = await model.purchase(topUp) {
                            openURL(url)
                        }
                    }
                }
            }
        }
    }

    private var processingOverlay: some View {
        ZStack {
            AppColors.ink.opacity(0.18).ignoresSafeArea()
            PosterProgress(message: String(localized: "Completing purchase…"))
        }
        .accessibilityIdentifier("topup-processing")
    }
}

private struct StickerTopUpCard: View {
    let topUp: TopUpProduct
    let price: String
    let isProcessing: Bool
    let isDisabled: Bool
    let action: () -> Void

    private var isEligible: Bool { topUp.eligible != false }

    var body: some View {
        PosterCard(padding: 18, cornerRadius: Poster.tileRadius, shadow: Poster.smallShadow) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 14) {
                    StickerBlobIcon(icon: PosterIcon.credits, fill: AppColors.peach, tilt: -4)
                        .frame(width: 54, height: 54)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(TopUpPresentation.title(for: topUp))
                            .font(.posterDisplay(21, weight: .bold))
                            .foregroundStyle(AppColors.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        Text(isEligible ? "One-time purchase" : TopUpPresentation.eligibilityText(for: topUp))
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(AppColors.muted)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)
                }

                Button(action: action) {
                    if isProcessing {
                        HStack(spacing: 8) {
                            ProgressView().tint(AppColors.card)
                            Text("Purchasing…")
                        }
                        .frame(maxWidth: .infinity)
                    } else if isEligible {
                        Label("Buy for \(price)", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Unavailable", systemImage: "lock.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.poster)
                .disabled(isDisabled || !isEligible)
                .accessibilityIdentifier("topup-buy-\(topUp.id)")
            }
        }
        .opacity(isEligible ? 1 : 0.62)
        .accessibilityIdentifier("topup-card-\(topUp.id)")
    }
}

nonisolated enum TopUpPresentation {
    static func title(for topUp: TopUpProduct) -> String {
        let unit = topUp.unit?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayUnit = unit.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "points")
        return "\(topUp.amount.formatted()) \(displayUnit.localizedCapitalized)"
    }

    static func eligibilityText(for topUp: TopUpProduct) -> String {
        let rules = topUp.blockedBy?.map(\.ruleType) ?? []
        if rules.contains("purchase_limit") { return String(localized: "Purchase limit reached") }
        if rules.contains("requires_role") { return String(localized: "Membership required") }
        if rules.contains("requires_active_plan") { return String(localized: "Specific plan required") }
        if rules.contains("requires_any_plan") { return String(localized: "Active plan required") }
        return String(localized: "Not currently available")
    }
}

@MainActor
private final class StickerTopUpViewModel: ObservableObject {
    @Published var topUps: [TopUpProduct] = []
    @Published var products: [String: StoreProductInfo] = [:]
    @Published var isLoading = false
    @Published var processingID: String?
    @Published var error: String?
    @Published var message: String?
    @Published var showingMessage = false

    private let client: Client

    init(client: Client) {
        self.client = client
    }

    func load(force: Bool = false) async {
        guard force || topUps.isEmpty else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let catalog = try await client.catalog()
            topUps = catalog.topups

            let productIDs = catalog.topups
                .flatMap(\.purchaseOptions)
                .filter { $0.provider == .appleAppStore && $0.flow == .storeKit }
                .compactMap(\.productID)
            let storeProducts = productIDs.isEmpty
                ? []
                : try await client.storeProducts(productIDs: productIDs)
            products = Dictionary(uniqueKeysWithValues: storeProducts.map { ($0.id, $0) })
        } catch {
            self.error = error.localizedDescription
        }
    }

    func price(for topUp: TopUpProduct) -> String {
        if let productID = appleOption(for: topUp)?.productID,
           let storeProduct = products[productID] {
            return storeProduct.displayPrice
        }
        return SubscriptionFormatting.price(cents: topUp.priceAmountCents, currency: topUp.currency)
    }

    func purchase(_ topUp: TopUpProduct) async -> URL? {
        guard topUp.eligible != false else { return nil }
        processingID = topUp.id
        defer { processingID = nil }

        do {
            if let productID = appleOption(for: topUp)?.productID {
                switch try await client.purchaseApple(productID: productID) {
                case .completed:
                    show(String(localized: "Points added to your balance."))
                    await load(force: true)
                case .pending:
                    show(String(localized: "The purchase is pending approval."))
                case .cancelled:
                    break
                }
                return nil
            }

            return try await client.checkoutTopUp(id: topUp.id).checkoutURL
        } catch {
            show(error.localizedDescription)
            return nil
        }
    }

    private func appleOption(for topUp: TopUpProduct) -> PurchaseOption? {
        topUp.purchaseOptions.first {
            $0.provider == .appleAppStore && $0.flow == .storeKit
        }
    }

    private func show(_ message: String) {
        self.message = message
        showingMessage = true
    }
}
