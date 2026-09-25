import AVFAudio
import AudioToolbox
import Darwin
import Foundation
import HolosCore

public struct VoiceDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let language: String
    public let quality: String

    public init(id: String, name: String, language: String, quality: String) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
    }
}

public struct RenderedAudio: Codable, Sendable, Equatable {
    public let url: URL
    public let duration: Double
    public let frameCount: Int64
    public let sampleRate: Double

    public init(url: URL, duration: Double, frameCount: Int64, sampleRate: Double) {
        self.url = url
        self.duration = duration
        self.frameCount = frameCount
        self.sampleRate = sampleRate
    }
}

@MainActor public final class NativeSpeechRenderer {
    public init() {}

    public static func voices() -> [VoiceDescriptor] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            let quality: String
            switch voice.quality {
            case .default: quality = "default"
            case .enhanced: quality = "enhanced"
            case .premium: quality = "premium"
            @unknown default: quality = "unknown"
            }
            return VoiceDescriptor(id: voice.identifier, name: voice.name,
                                   language: voice.language, quality: quality)
        }
    }

    public static func defaultVoiceIdentifier() throws -> String {
        let preferred = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let language = preferred.hasPrefix("en-") ? preferred : "en-US"
        guard let selected = AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: "en-US") else {
            throw HolosError.unavailable("No installed English speech voice is available.")
        }
        return selected.identifier
    }

    public func render(text: String, voiceIdentifier: String? = nil, rate: Float? = nil,
                       to output: URL) async throws -> RenderedAudio {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HolosError.invalidInput("Speech text is empty.")
        }
        guard output.isFileURL else { throw HolosError.invalidInput("Speech output must be a file URL.") }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw HolosError.invalidInput("Speech output already exists: \(output.path)")
        }
        let ext = output.pathExtension.lowercased()
        guard ["wav", "caf", "m4a"].contains(ext) else {
            throw HolosError.invalidInput("Unsupported speech output format .\(ext); use wav, caf, or m4a.")
        }
        if let rate {
            guard rate.isFinite, rate >= AVSpeechUtteranceMinimumSpeechRate,
                  rate <= AVSpeechUtteranceMaximumSpeechRate else {
                throw HolosError.invalidInput("Speech rate must be between \(AVSpeechUtteranceMinimumSpeechRate) and \(AVSpeechUtteranceMaximumSpeechRate).")
            }
        }
        let voice: AVSpeechSynthesisVoice
        if let voiceIdentifier {
            guard let selected = AVSpeechSynthesisVoice(identifier: voiceIdentifier) else {
                throw HolosError.unavailable("Speech voice is unavailable: \(voiceIdentifier)")
            }
            voice = selected
        } else {
            guard let selected = AVSpeechSynthesisVoice(identifier: try Self.defaultVoiceIdentifier()) else {
                throw HolosError.unavailable("No installed English speech voice is available.")
            }
            voice = selected
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        if let rate { utterance.rate = rate }
        let synthesizer = AVSpeechSynthesizer()
        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(".holos-\(UUID().uuidString).\(ext == "m4a" ? "caf" : ext)")
        let operation = RenderOperation(synthesizer: synthesizer, utterance: utterance, temporary: temporary,
                                        output: output, fileExtension: ext)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard operation.start(continuation: continuation) else {
                    // Cancelled before write: AVFoundation holds no work for this synthesizer.
                    operation.releaseSynthesizer()
                    return
                }
                synthesizer.write(utterance) { [weak operation] buffer in
                    operation?.accept(buffer)
                }
            }
        } onCancel: {
            operation.cancel()
            Task { @MainActor in operation.stopSynthesizer() }
        }
    }
}

private final class RenderDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let operation: RenderOperation

    init(operation: RenderOperation) { self.operation = operation }

    // didFinish and didCancel are the synthesizer's terminal callbacks. Release it on a later
    // main-actor turn, never from inside the callback that is still messaging this delegate.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        let operation = self.operation
        Task { @MainActor in
            operation.finish()
            operation.releaseSynthesizer()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        let operation = self.operation
        Task { @MainActor in
            operation.cancel()
            operation.releaseSynthesizer()
        }
    }
}

/// AVFoundation callbacks may arrive outside the main actor. This lock owns all writer and
/// continuation state; AVSpeechSynthesizer itself is only touched on the main actor.
///
/// Completing the render (success, failure, or cancellation) resumes the caller but does not
/// release the synthesizer, its utterance, or its delegate. `AVSpeechSynthesizer.delegate` does
/// not retain the delegate, so this operation's strong reference is all that keeps it alive, and
/// the synthesizer's pointer is not safely zeroed when it is freed. TextToSpeech keeps main-queue
/// work in flight that messages the delegate after a cancel: a stopped buffer render still runs
/// to the end of the utterance, then reports didFinish. Freeing the delegate at cancellation
/// crashed in `objc_retain`. They are released, and the operation <-> delegate cycle broken,
/// only by `releaseSynthesizer()`, which clears `synthesizer.delegate` first: after the terminal
/// didFinish or didCancel callback, or by the idle safety net that `stopSynthesizer()` arms in
/// case neither arrives.
final class RenderOperation: @unchecked Sendable {
    /// How long a stopped synthesizer must go without any callback before the safety net
    /// releases it. It only bounds a leak when no terminal callback ever arrives, so it is
    /// generous; any buffer callback restarts the wait.
    static let terminalCallbackGrace: Duration = .seconds(60)

    private let lock = NSLock()
    private var synthesizer: AVSpeechSynthesizer?
    private var utterance: AVSpeechUtterance?
    private var delegate: RenderDelegate?
    private var callbacks: UInt64 = 0
    private var stopping = false
    private var continuation: CheckedContinuation<RenderedAudio, Error>?
    private var writer: AVAudioFile?
    private var sampleRate: Double = 0
    private var frameCount: Int64 = 0
    private var completed = false
    private let temporary: URL
    private let output: URL
    private let fileExtension: String

    init(synthesizer: AVSpeechSynthesizer, utterance: AVSpeechUtterance,
         temporary: URL, output: URL,
         fileExtension: String) {
        self.synthesizer = synthesizer
        self.utterance = utterance
        self.temporary = temporary
        self.output = output
        self.fileExtension = fileExtension
        let delegate = RenderDelegate(operation: self)
        self.delegate = delegate
        synthesizer.delegate = delegate
    }

    func start(continuation: CheckedContinuation<RenderedAudio, Error>) -> Bool {
        lock.lock()
        if completed {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func accept(_ audioBuffer: AVAudioBuffer) {
        lock.lock()
        callbacks &+= 1
        lock.unlock()
        guard let buffer = audioBuffer as? AVAudioPCMBuffer else {
            fail(HolosError.io("Speech renderer emitted an unsupported buffer type."))
            return
        }
        // The zero-frame sentinel can precede the synthesizer's didFinish callback, so it is
        // not terminal: the synthesizer, utterance, and delegate stay alive until that callback.
        if buffer.frameLength == 0 { return }
        lock.lock()
        guard !completed else { lock.unlock(); return }
        do {
            let format = buffer.format
            guard format.sampleRate.isFinite, format.sampleRate > 0,
                  format.channelCount > 0 else {
                throw HolosError.io("Speech renderer emitted an invalid audio format.")
            }
            if writer == nil {
                sampleRate = format.sampleRate
                var settings: [String: Any] = [
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: Int(format.channelCount),
                ]
                switch fileExtension {
                case "wav", "caf", "m4a":
                    settings[AVFormatIDKey] = kAudioFormatLinearPCM
                    settings[AVLinearPCMBitDepthKey] = 16
                    settings[AVLinearPCMIsFloatKey] = false
                    settings[AVLinearPCMIsBigEndianKey] = false
                    settings[AVAudioFileTypeKey] = fileExtension == "wav" ? kAudioFileWAVEType : kAudioFileCAFType
                default: preconditionFailure("Validated file extension")
                }
                writer = try AVAudioFile(forWriting: temporary, settings: settings,
                                         commonFormat: format.commonFormat,
                                         interleaved: format.isInterleaved)
            } else if sampleRate != format.sampleRate ||
                        writer?.processingFormat.channelCount != format.channelCount ||
                        writer?.processingFormat.commonFormat != format.commonFormat ||
                        writer?.processingFormat.isInterleaved != format.isInterleaved {
                throw HolosError.io("Speech renderer changed PCM format mid-utterance.")
            }
            try writer?.write(from: buffer)
            frameCount += Int64(buffer.frameLength)
            lock.unlock()
        } catch {
            lock.unlock()
            fail(error)
        }
    }

    func finish() {
        complete(error: nil)
    }

    func cancel() {
        complete(error: CancellationError())
    }

    func fail(_ error: Error) {
        complete(error: error)
        Task { @MainActor in stopSynthesizer() }
    }

    private func complete(error: Error?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        writer?.close()
        writer = nil
        let frames = frameCount
        let rate = sampleRate
        var resultError = error
        let encoded = temporary.deletingPathExtension().appendingPathExtension("m4a")
        var published = temporary
        if resultError == nil {
            if frames == 0 || !rate.isFinite || rate <= 0 {
                resultError = HolosError.incomplete("Speech renderer produced no audio frames.")
            } else if fileExtension == "m4a" {
                do {
                    try encodeM4A(from: temporary, to: encoded, sampleRate: rate)
                    published = encoded
                } catch {
                    resultError = error
                }
            }
            if resultError == nil && link(published.path, output.path) != 0 {
                resultError = HolosError.io("Could not publish speech output: \(String(cString: strerror(errno)))")
            }
        }
        _ = unlink(temporary.path)
        if fileExtension == "m4a" { _ = unlink(encoded.path) }
        lock.unlock()
        if let resultError { continuation?.resume(throwing: resultError) }
        else { continuation?.resume(returning: RenderedAudio(url: output, duration: Double(frames) / rate,
                                                             frameCount: frames, sampleRate: rate)) }
    }

    /// Stops speech but keeps the synthesizer and delegate alive for the terminal callback.
    @MainActor func stopSynthesizer() {
        lock.lock()
        let active = synthesizer
        let first = !stopping
        stopping = true
        lock.unlock()
        guard let active, first else { return }
        _ = active.stopSpeaking(at: .immediate)
        releaseWhenIdle()
    }

    /// Safety net: release once no callback has arrived for `terminalCallbackGrace`.
    @MainActor private func releaseWhenIdle() {
        lock.lock()
        let seen = callbacks
        lock.unlock()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.terminalCallbackGrace)
            self?.releaseIfIdle(since: seen)
        }
    }

    @MainActor private func releaseIfIdle(since seen: UInt64) {
        lock.lock()
        let retained = synthesizer != nil
        let idle = callbacks == seen
        lock.unlock()
        guard retained else { return }
        if idle { releaseSynthesizer() } else { releaseWhenIdle() }
    }

    /// Breaks the operation <-> delegate cycle once AVFoundation is done with the synthesizer.
    @MainActor func releaseSynthesizer() {
        lock.lock()
        let active = synthesizer
        let delegate = self.delegate
        synthesizer = nil
        utterance = nil
        self.delegate = nil
        lock.unlock()
        active?.delegate = nil
        withExtendedLifetime(delegate) {} // Deallocate outside the lock.
    }

    private func encodeM4A(from pcmURL: URL, to encodedURL: URL,
                           sampleRate: Double) throws {
        let source = try AVAudioFile(forReading: pcmURL)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(source.processingFormat.channelCount),
            AVEncoderBitRateKey: 64_000,
            AVAudioFileTypeKey: kAudioFileM4AType,
        ]
        let encoded = try AVAudioFile(forWriting: encodedURL, settings: settings,
                                      commonFormat: source.processingFormat.commonFormat,
                                      interleaved: source.processingFormat.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat,
                                            frameCapacity: 8_192) else {
            throw HolosError.io("Could not allocate speech encoding buffer.")
        }
        while source.framePosition < source.length {
            let remaining = source.length - source.framePosition
            try source.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining)))
            guard buffer.frameLength > 0 else {
                throw HolosError.incomplete("Speech PCM ended before its declared frame count.")
            }
            try encoded.write(from: buffer)
        }
        encoded.close()
        guard try AVAudioFile(forReading: encodedURL).length > 0 else {
            throw HolosError.incomplete("AAC encoder produced no audio frames.")
        }
    }
}
