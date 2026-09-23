import Foundation

/// A creation attempt that did not make it to the server, kept so a failure costs nothing to retry.
///
/// Written when generating fails and read the next time the form opens — across launches, since
/// the failure that loses a draft is as likely to be the app being closed on a bad connection as
/// the sheet being dismissed. A successful create clears it.
nonisolated struct CreationDraft: Codable, Equatable, Sendable {
    struct Reference: Codable, Equatable, Sendable {
        /// The file inside the draft's folder holding the normalized bytes.
        var file: String
        var filename: String
        var mimeType: String
        var sequence: SequenceMetadata?
    }

    var prompt: String
    var kind: StickerKind
    var controllable: Bool
    var motion: Bool
    var posePreset: PosePreset
    var selections: [String: [String]]
    var animationReviewed: Bool
    var references: [Reference]
}

/// Keeps one `CreationDraft` per signed-in account, in Application Support.
///
/// Files rather than `UserDefaults`: up to eight normalized reference photos are far larger than
/// anything preferences are meant to hold, and they are what makes a draft worth restoring.
nonisolated struct CreationDraftStore: Sendable {
    let accountID: String
    var root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CreationDraft", isDirectory: true)

    private var folder: URL {
        // The subject is an opaque identifier that may contain path separators.
        let safe = accountID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "local"
        return root.appendingPathComponent(safe, isDirectory: true)
    }
    private var manifest: URL { folder.appendingPathComponent("draft.json") }

    func load() -> (draft: CreationDraft, references: [PendingMediaAttachment])? {
        guard let data = try? Data(contentsOf: manifest),
              let draft = try? JSONDecoder().decode(CreationDraft.self, from: data) else { return nil }
        let references = draft.references.compactMap { reference -> PendingMediaAttachment? in
            guard let bytes = try? Data(contentsOf: folder.appendingPathComponent(reference.file)) else { return nil }
            return PendingMediaAttachment(
                data: bytes, filename: reference.filename, mimeType: reference.mimeType, sequence: reference.sequence
            )
        }
        return (draft, references)
    }

    func save(
        prompt: String, kind: StickerKind, controllable: Bool, motion: Bool, posePreset: PosePreset,
        selections: [String: Set<String>], animationReviewed: Bool, references: [PendingMediaAttachment]
    ) throws {
        clear()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var stored: [CreationDraft.Reference] = []
        for (index, reference) in references.enumerated() {
            let file = "reference-\(index)"
            try reference.data.write(to: folder.appendingPathComponent(file), options: .atomic)
            stored.append(.init(file: file, filename: reference.filename, mimeType: reference.mimeType, sequence: reference.sequence))
        }
        let draft = CreationDraft(
            prompt: prompt, kind: kind, controllable: controllable, motion: motion, posePreset: posePreset,
            selections: selections.mapValues { $0.sorted() }, animationReviewed: animationReviewed, references: stored
        )
        try JSONEncoder().encode(draft).write(to: manifest, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: folder)
    }
}
