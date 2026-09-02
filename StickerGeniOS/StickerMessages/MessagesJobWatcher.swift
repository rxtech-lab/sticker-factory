import Foundation
import os

/// One `progress` frame from the server: where the job has got to, and how far along it is.
///
/// The server reports progress two different ways and a turn is mostly made of the second one:
/// a handful of frames name a `stage` and carry a fraction, while every tool the agent runs
/// announces itself with a `toolName` and no stage at all. A reader that waits for stages sits on
/// its first message through the entire planning phase, which is the longest part of a turn.
struct MessagesJobProgress: Sendable {
    /// The server's stage token, e.g. `generating_image`.
    let stage: String?
    /// The tool being run, e.g. `plan-sticker`. Repeats within a turn are suffixed — `create_plan #2`.
    let tool: String?
    /// The transcript row this frame is about. One step is announced twice — once streaming, once
    /// complete — so this is what lets a reader update a row instead of appending a second one.
    let toolCallID: String?
    /// `streaming`, `complete` or `failed`.
    let toolStatus: String?
    /// 0…1. Absent on every tool-call frame.
    let fraction: Double?
}

/// How a generation or publish job ended.
enum MessagesJobOutcome: Sendable, Equatable {
    case succeeded
    /// The server's own words. Written to be shown: `failJob` fills it with a public reason when it
    /// has one, and a generic retryable sentence when it does not.
    case failed(String)
    case cancelled
}

/// Watches one job to its end over the server's SSE stream.
///
/// Polling was the obvious alternative and is the wrong one here. There is no `GET /jobs/{id}`;
/// the state lives behind the event stream, which also carries the progress stages the create
/// screen shows and the failure message it prints. The stream is the built endpoint, so this reads
/// it rather than inventing a second protocol out of the sticker's own row.
///
/// The server closes each connection after about 25 seconds — a deliberate ceiling, not a fault —
/// so a long generation is watched across several connections, each resumed from the last event id
/// exactly as SSE prescribes. `URLSession.bytes` rather than the shared `StickerHTTPTransport`
/// because that protocol buffers a whole response, which a stream never finishes producing.
struct MessagesJobWatcher: Sendable {
    /// Long enough for an image model plus the server-side export ladder, short enough that a
    /// wedged job eventually says so rather than spinning until the drawer closes.
    static let deadline: TimeInterval = 8 * 60

    private let baseURL: URL
    private let session: URLSession
    /// Quick mode's whole flow hangs off this stream, and a failure here surfaces to the user as one
    /// sentence with no way to tell a refused job from an unreachable server. The console line is
    /// what makes the next report actionable.
    private let logger = Logger(subsystem: "app.rxlab.stickerfactory.message", category: "job")

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// - Parameter onProgress: every progress frame, for the screen's status line and bar.
    func watch(
        jobID: String,
        accessToken: String,
        onProgress: @Sendable @escaping (MessagesJobProgress) -> Void
    ) async throws -> MessagesJobOutcome {
        var cursor = 0
        let startedAt = Date()

        while Date().timeIntervalSince(startedAt) < Self.deadline {
            try Task.checkCancellation()
            var request = URLRequest(url: baseURL
                .appending(path: "api/v1/jobs")
                .appending(path: jobID)
                .appending(path: "events")
                .appending(queryItems: [URLQueryItem(name: "after", value: String(cursor))]))
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 60
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MessagesStickerCreationError.invalidResponse
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw MessagesStickerCreationError.unauthorized
            }
            logger.log("""
                job=\(jobID, privacy: .public) after=\(cursor) \
                status=\(http.statusCode) state=\(http.value(forHTTPHeaderField: "x-job-state") ?? "-", privacy: .public)
                """)
            guard (200 ..< 300).contains(http.statusCode) else {
                // The body of a refused stream is an ordinary JSON error envelope. Reading it is
                // what separates "this job is not yours" from "the sticker service is down"; without
                // it every failure here reaches the user as the same anonymous sentence.
                throw MessagesStickerCreationError.server(
                    statusCode: http.statusCode,
                    message: await Self.errorMessage(from: bytes)
                )
            }
            // The stream states the job's state in a header before its first frame, so a job that
            // was already over when this connected is answered without reading the body at all.
            switch Self.terminalOutcome(http.value(forHTTPHeaderField: "x-job-state")) {
            case .some(.succeeded): return .succeeded
            case .some(.cancelled): return .cancelled
            // A failure's own words are in the body — the first connection replays from event 0, so
            // they are still there to read — and a generic sentence is a poor substitute.
            case .some(.failed), .none: break
            }

            var event = ""
            var data = ""
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if line.isEmpty {
                    if let outcome = Self.outcome(event: event, data: data, onProgress: onProgress) {
                        return outcome
                    }
                    event = ""
                    data = ""
                    continue
                }
                if line.hasPrefix(":") { continue }
                if let value = line.dropPrefix("id: ") { cursor = Int(value) ?? cursor }
                else if let value = line.dropPrefix("event: ") { event = value }
                else if let value = line.dropPrefix("data: ") { data = value }
            }
            // The connection closed on the server's own window without a terminal frame. Reconnect
            // from `cursor`; nothing is replayed and nothing is lost.
        }
        logger.error("job=\(jobID, privacy: .public) gave up after \(Self.deadline)s at cursor \(cursor)")
        throw MessagesStickerCreationError.timedOut
    }

    /// The `error.message` of a refused response, read off the head of its body.
    ///
    /// Bounded: this is an error path on a connection opened as a stream, and a body that never
    /// ends must not hang the read.
    private static func errorMessage(from bytes: URLSession.AsyncBytes) async -> String? {
        var body = Data()
        do {
            for try await byte in bytes.prefix(4_096) { body.append(byte) }
        } catch {
            return nil
        }
        struct Envelope: Decodable {
            struct Details: Decodable { let message: String }
            let error: Details
        }
        return (try? JSONDecoder().decode(Envelope.self, from: body))?.error.message
    }

    private static func terminalOutcome(_ state: String?) -> MessagesJobOutcome? {
        switch state {
        case "succeeded": .succeeded
        case "failed": .failed(String(localized: "That didn't finish. Try again."))
        case "cancelled": .cancelled
        default: nil
        }
    }

    /// Interprets one complete SSE frame, returning non-nil once the job is over.
    private static func outcome(
        event: String,
        data: String,
        onProgress: @Sendable (MessagesJobProgress) -> Void
    ) -> MessagesJobOutcome? {
        let frame = data.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        // A frame replayed from the events table arrives as the whole serialized row — its real
        // payload nested under `data` — while the stream's own trailing `end` frame is written
        // flat. Unwrapping with a fallback reads both without having to know which is which.
        let payload = (frame["data"] as? [String: Any]) ?? frame
        switch event {
        case "progress":
            let stage = payload["stage"] as? String
            let tool = payload["toolName"] as? String
            if stage != nil || tool != nil {
                onProgress(MessagesJobProgress(
                    stage: stage,
                    tool: tool,
                    toolCallID: payload["toolCallId"] as? String,
                    toolStatus: payload["toolStatus"] as? String,
                    fraction: payload["progress"] as? Double
                ))
            }
            return nil
        case "failed":
            let message = payload["message"] as? String
            return .failed(message ?? String(localized: "That didn't finish. Try again."))
        case "end":
            // The stream's trailing frame, which is how a job that ended before this connection
            // opened — or between two of them — is reported.
            return terminalOutcome(payload["jobState"] as? String)
        default:
            return nil
        }
    }
}

private extension String {
    /// The remainder after `prefix`, or nil when the line is something else.
    ///
    /// SSE also permits a field with no space after the colon; both spellings are accepted because
    /// the value is what matters and a missed `id:` would restart a reconnect from the wrong place.
    func dropPrefix(_ prefix: String) -> String? {
        if hasPrefix(prefix) { return String(dropFirst(prefix.count)) }
        let compact = prefix.replacingOccurrences(of: " ", with: "")
        if hasPrefix(compact) { return String(dropFirst(compact.count)) }
        return nil
    }
}
