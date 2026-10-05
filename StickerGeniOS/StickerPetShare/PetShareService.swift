import Foundation

enum PetShareServiceError: LocalizedError {
    case invalidConfiguration
    case unauthorized
    case noPet
    case rejected(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Sticker Factory's server address is unavailable."
        case .unauthorized: "Open Sticker Factory and sign in before sharing with your pet."
        case .noPet: "Choose a pet in Sticker Factory before sharing."
        case .rejected(let message): message
        case .invalidResponse: "The share response could not be read."
        }
    }
}

actor PetShareService {
    private let broker: SharedTokenBroker
    private let endpoint: URL

    init(bundle: Bundle = .main) throws {
        broker = SharedTokenBroker(configuration: try SharedAuthConfiguration(bundle: bundle))
        guard let address = bundle.object(forInfoDictionaryKey: "StickerFactoryAPIBaseURL") as? String,
              !address.contains("$("), let base = URL(string: address),
              ["http", "https"].contains(base.scheme ?? "") else {
            throw PetShareServiceError.invalidConfiguration
        }
        endpoint = base.appending(path: "api/v1/pet/content")
    }

    func send(_ payload: PetSharePayload) async throws {
        let session = try await broker.authenticatedSession()
        do {
            try await post(payload, token: session.accessToken)
        } catch PetShareServiceError.unauthorized {
            let refreshed = try await broker.authenticatedSession(forceRefresh: true)
            guard refreshed.subject == session.subject else { throw PetShareServiceError.unauthorized }
            try await post(payload, token: refreshed.accessToken)
        }
    }

    private func post(_ payload: PetSharePayload, token: String) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PetShareServiceError.invalidResponse }
        if response.statusCode == 401 { throw PetShareServiceError.unauthorized }
        if response.statusCode == 404 { throw PetShareServiceError.noPet }
        guard response.statusCode == 202 else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error.message
            throw PetShareServiceError.rejected(message ?? "Your share couldn't be sent. Try again.")
        }
        guard (try? JSONDecoder().decode(AcceptedShare.self, from: data))?.accepted == true else {
            throw PetShareServiceError.invalidResponse
        }
    }
}

private struct AcceptedShare: Decodable { let accepted: Bool }
private struct ServerError: Decodable { let error: Detail
    struct Detail: Decodable { let message: String }
}
