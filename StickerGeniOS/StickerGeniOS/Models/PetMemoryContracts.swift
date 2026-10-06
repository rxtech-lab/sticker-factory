import Foundation

/// One thing the pet remembers, kept up to date on the server by its memory agent from every
/// moment with its owner.
nonisolated struct PetMemory: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var content: String
    /// `owner`, `bond`, `experience`, `place` or `feeling`.
    var category: String
    /// 1 a passing detail, 5 something the pet should never forget.
    var importance: Int
    var updatedAt: Date
}

nonisolated struct PetMemoriesResponse: Codable, Equatable, Sendable {
    var memories: [PetMemory]
}

/// What the owner said to their pet aloud and what it answered on the phone, for it to remember.
nonisolated struct RememberPetTalkRequest: Codable, Equatable, Sendable {
    var words: String
    var reply: String?
}

nonisolated struct RememberPetTalkResponse: Codable, Equatable, Sendable {
    var accepted: Bool
}
