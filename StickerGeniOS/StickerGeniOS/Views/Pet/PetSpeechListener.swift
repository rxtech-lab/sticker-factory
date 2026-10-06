import AVFoundation
import Observation
import os
import Speech
import UIKit

/// Hears the owner through the microphone and writes down what they say, entirely on the phone.
///
/// Transcription runs on Apple's on-device speech model (`SpeechAnalyzer` with a `SpeechTranscriber`),
/// so nothing the owner says leaves the phone to be written down. The model for their language is
/// downloaded the first time it is needed and kept by the system after that.
@MainActor
@Observable
final class PetSpeechListener {
    enum State: Equatable {
        case idle
        /// Asking for the microphone, or fetching the speech model for the owner's language.
        case preparing
        case listening
        /// The microphone is off; the last words are still being written down.
        case finishing
    }

    /// Why listening could not start.
    enum Problem: Error, Equatable {
        case microphoneDenied
        case unsupported
        case failed(String)

        var message: String {
            switch self {
            case .microphoneDenied:
                String(localized: "Your pet can't hear you. Allow the microphone in Settings to talk to your pet.")
            case .unsupported:
                String(localized: "Talking to your pet isn't available in your language on this iPhone yet.")
            case .failed(let reason): reason
            }
        }
    }

    private(set) var state: State = .idle
    /// What the model has settled on so far.
    private(set) var settledText = ""
    /// The tail the model is still unsure of; it is rewritten as the owner keeps talking.
    private(set) var tentativeText = ""
    var problem: Problem?
    /// How loud the microphone has been lately, oldest first, each from 0 (silence) to 1; drawn as
    /// the soundwave while listening.
    private(set) var levels = PetSpeechListener.silence

    static let levelCount = 28
    private static let silence = [Float](repeating: 0, count: levelCount)

    /// Everything heard so far, settled and tentative.
    var transcript: String { (settledText + tentativeText).trimmingCharacters(in: .whitespacesAndNewlines) }

    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var feed: PetAudioFeed?
    @ObservationIgnored private var results: Task<Void, Never>?

    private static let log = Logger(subsystem: "app.rxlab.sticker-factory", category: "pet-speech")

    /// Turns the microphone on and starts writing down what it hears, replacing anything heard before.
    func start() async {
        guard state == .idle else { return }
        state = .preparing
        settledText = ""
        tentativeText = ""
        problem = nil
        levels = Self.silence
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw Problem.microphoneDenied }
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { throw Problem.unsupported }
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )
            // The first time only: the system downloads the model for this language and keeps it.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw Problem.unsupported
            }
            // Cancelled while the model was on its way.
            guard state == .preparing else { return }

            let (input, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            results = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self else { return }
                        let text = String(result.text.characters)
                        if result.isFinal {
                            self.settledText += text
                            self.tentativeText = ""
                        } else {
                            self.tentativeText = text
                        }
                    }
                } catch {
                    Self.log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            try await analyzer.start(inputSequence: input)
            // Cancelled while the analyzer started: the microphone must not come on behind a closed sheet.
            guard state == .preparing else {
                await analyzer.cancelAndFinishNow()
                return
            }
            let feed = PetAudioFeed(format: format, continuation: continuation) { [weak self] level in
                Task { @MainActor in self?.hear(level) }
            }
            try feed.start()
            self.analyzer = analyzer
            self.feed = feed
            state = .listening
            Haptics.tap(.medium)
        } catch {
            await tearDown()
            problem = (error as? Problem) ?? .failed(error.localizedDescription)
            Haptics.failure()
        }
    }

    private func hear(_ level: Float) {
        guard state == .listening else { return }
        levels.removeFirst()
        levels.append(level)
    }

    /// Turns the microphone off and waits for the last words to be written down.
    func stop() async {
        guard state == .listening else { return }
        state = .finishing
        feed?.stop()
        feed = nil
        levels = Self.silence
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Self.log.error("Finishing transcription failed: \(error.localizedDescription, privacy: .public)")
        }
        await results?.value
        results = nil
        analyzer = nil
        // Whatever was still tentative is the best guess there is.
        settledText = transcript
        tentativeText = ""
        state = .idle
        Haptics.tap(.light)
    }

    /// Stops at once and forgets what was heard; used when the sheet goes away.
    func cancel() async {
        await tearDown()
        settledText = ""
        tentativeText = ""
    }

    private func tearDown() async {
        feed?.stop()
        feed = nil
        results?.cancel()
        results = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        levels = Self.silence
        state = .idle
    }
}

/// Feeds the microphone into the speech analyzer, converted to the format the model wants.
///
/// Lives off the main actor: the audio engine calls the tap on its own real-time thread.
nonisolated final class PetAudioFeed: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    /// Told how loud each buffer was, from 0 to 1, on the audio thread.
    private let onLevel: @Sendable (Float) -> Void
    private var converter: AVAudioConverter?

    init(
        format: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        self.format = format
        self.continuation = continuation
        self.onLevel = onLevel
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        if inputFormat != format { converter = AVAudioConverter(from: inputFormat, to: format) }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.feed(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        onLevel(Self.level(of: buffer))
        guard let converted = convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    /// The buffer's loudness, mapped from -50 dB (quiet room) to 0 dB (shouting) onto 0...1.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(max((decibels + 50) / 50, 0), 1)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard capacity > 0, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var handedOver = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if handedOver {
                inputStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : output
    }
}
