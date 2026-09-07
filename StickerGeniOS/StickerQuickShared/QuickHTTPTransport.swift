import Foundation

nonisolated struct StickerHTTPResult: @unchecked Sendable {
    let data: Data
    let response: HTTPURLResponse
}

nonisolated protocol StickerHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> StickerHTTPResult
}

nonisolated struct URLSessionStickerHTTPTransport: StickerHTTPTransport {
    let session: URLSession

    func data(for request: URLRequest) async throws -> StickerHTTPResult {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MessagesStickerCreationError.invalidResponse
        }
        return .init(data: data, response: response)
    }
}
