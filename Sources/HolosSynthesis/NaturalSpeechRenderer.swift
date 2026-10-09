import AVFAudio
import AudioToolbox
import Foundation
import HolosCore
import os

/// Makes speech with a natural (neural) voice: 24 kHz mono samples for one paragraph. The `voiceislocal` tool's
/// implementation is FluidAudio's Pocket TTS (`HolosPocket`); tests pass a fake.
public protocol NaturalSpeechBackend: Sendable {
    /// The paragraph `text` spoken by `voice`, generated with `seed` (the same seed gives the same take).
    func synthesize(_ text: String, voice: NaturalVoice, seed: UInt64) async throws -> [Float]
}

/// Hears a rendered paragraph back, for the per-paragraph check (see `SpeechChunkCheck`).
public protocol SpeechChunkChecker: Sendable {
    /// What a speech recognizer hears in `samples`; nil when none is available for `language` here (the check is
    /// skipped).
    func transcript(of samples: [Float], sampleRate: Double, language: String) async throws -> String?
}

/// Speaks a paragraph with a system voice when the natural voice keeps failing the check.
@MainActor public protocol ParagraphFallback {
    /// The paragraph spoken by a system voice for `language`, as mono samples at `sampleRate`; also the voice's name.
    func samples(for text: String, language: String, sampleRate: Double) async throws -> (samples: [Float], voice: String)
}

/// How a part is fed to the natural voice: one paragraph at a time (Pocket TTS splits a paragraph into sentences
/// itself), with explicit pauses between paragraphs and after a heading. The pipeline's own gaps go between parts. A
/// paragraph longer than `maximumBlockLength` (a text without blank lines is one paragraph) is fed in groups of whole
/// sentences of at most that length, with no pause between them but the voice's own, so no block's speech is long:
/// each block's samples are held, checked, and written before the next one is made.
public enum NaturalSpeechPlan {
    public struct Block: Sendable, Equatable {
        public let text: String
        /// Silence after this block, in seconds (none after the last block of a part).
        public let pauseAfter: Double
        public let isHeading: Bool
    }

    public static let paragraphPause = 0.6
    public static let headingPause = 0.9
    /// The longest first block taken for a heading.
    static let headingMaximumLength = 100
    /// The longest block, in characters (about a minute of speech).
    public static let maximumBlockLength = 1_000

    /// The part's paragraphs (blocks between blank lines; line breaks inside one read as spaces). A first block
    /// followed by others that is short, one line, and ends without sentence punctuation is a heading (a part that
    /// starts a section starts with its heading; see `ReadingScript`).
    public static func blocks(_ text: String) -> [Block] {
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return paragraphs.enumerated().flatMap { index, paragraph -> [Block] in
            let last = index == paragraphs.count - 1
            let heading = index == 0 && !last && looksLikeHeading(paragraph)
            let pause = last ? 0 : heading ? headingPause : paragraphPause
            let groups = split(paragraph, maximumLength: maximumBlockLength)
            return groups.enumerated().map { groupIndex, group in
                Block(text: group, pauseAfter: groupIndex == groups.count - 1 ? pause : 0, isHeading: heading)
            }
        }
    }

    /// `text` in pieces of at most `maximumLength` characters: whole sentences grouped, a longer sentence split after
    /// its clauses (, ; :), and a longer clause between words (a word longer than that alone is cut).
    static func split(_ text: String, maximumLength: Int) -> [String] {
        guard text.count > maximumLength else { return [text] }
        let sentences = pieces(of: text, after: ".!?…")
            .flatMap { $0.count > maximumLength ? pieces(of: $0, after: ",;:") : [$0] }
            .flatMap { $0.count > maximumLength ? $0.split(separator: " ").map(String.init) : [$0] }
            .flatMap { piece -> [String] in
                guard piece.count > maximumLength else { return [piece] }
                return stride(from: 0, to: piece.count, by: maximumLength).map { start in
                    let from = piece.index(piece.startIndex, offsetBy: start)
                    let to = piece.index(from, offsetBy: min(maximumLength, piece.count - start))
                    return String(piece[from..<to])
                }
            }
        var groups: [String] = []
        var current = ""
        for sentence in sentences {
            let joined = current.isEmpty ? sentence : current + " " + sentence
            if joined.count <= maximumLength {
                current = joined
            } else {
                if !current.isEmpty { groups.append(current) }
                current = sentence
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// `text` cut after each run of `marks` that a space follows (or the end), trimmed.
    private static func pieces(of text: String, after marks: String) -> [String] {
        var result: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            current.append(character)
            let next = text.index(after: index)
            if marks.contains(character), next == text.endIndex || text[next] == " " {
                let piece = current.trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { result.append(piece) }
                current = ""
            }
            index = next
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    static func looksLikeHeading(_ text: String) -> Bool {
        guard text.count <= headingMaximumLength, let last = text.last else { return false }
        return !".!?…;:,".contains(last)
    }
}

/// The check of a rendered paragraph against its text: the words a recognizer hears compared with the words written,
/// case, accents, and punctuation ignored, and numbers left out on both sides, whichever way they are written: digits
/// ("2015", "3.5", "2nd", "1er") and number words ("twenty fifteen", "three point five", "second", "deux mille
/// quinze", "trois virgule cinq", "deuxième"). A voice reads "2015" as words that a recognizer may write as digits or
/// spell out, so neither side's numbers are compared. It fails when the edits needed exceed 15 % of the paragraph's
/// words (at least 2), or when the lengths differ by more than 8 words (a cut-off or a run-on take).
public enum SpeechChunkCheck {
    public struct Verdict: Sendable, Equatable {
        public let passed: Bool
        /// Word edits (substitutions, insertions, deletions) over the written words.
        public let wordErrorRate: Double
        public let expectedWords: Int
        public let heardWords: Int
    }

    public static let maximumWordErrorRate = 0.15
    public static let minimumAllowedEdits = 2
    public static let maximumLengthDifference = 8

    public static func evaluate(expected: String, heard: String) -> Verdict {
        let reference = words(expected), hypothesis = words(heard)
        let edits = editDistance(reference, hypothesis)
        let rate = reference.isEmpty ? (hypothesis.isEmpty ? 0 : 1) : Double(edits) / Double(reference.count)
        let allowed = max(minimumAllowedEdits, Int((maximumWordErrorRate * Double(reference.count)).rounded(.down)))
        let passed = edits <= allowed && abs(reference.count - hypothesis.count) <= maximumLengthDifference
            && !(hypothesis.isEmpty && !reference.isEmpty)
        return Verdict(passed: passed, wordErrorRate: rate, expectedWords: reference.count,
                       heardWords: hypothesis.count)
    }

    /// Lowercased, accent-free words of letters and digits, numbers left out: every word with a digit, every number
    /// word (English and French cardinals, ordinals, and their parts), and a joining word between two of them ("and",
    /// "point", "et", "pour" in "cinquante pour cent").
    static func words(_ text: String) -> [String] {
        let tokens = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let numeric = tokens.map { $0.rangeOfCharacter(from: .decimalDigits) != nil || numberWords.contains($0) }
        return tokens.indices.compactMap { index in
            if numeric[index] { return nil }
            if numberJoiners.contains(tokens[index]), index > 0, index + 1 < tokens.count,
               numeric[index - 1], numeric[index + 1] { return nil }
            return tokens[index]
        }
    }

    /// Number words, folded (no accents).
    static let numberWords: Set<String> = Set([
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "hundreds", "thousand", "thousands",
        "million", "millions", "billion", "billions", "first", "second", "third", "fourth", "fifth", "sixth",
        "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth",
        "sixteenth", "seventeenth", "eighteenth", "nineteenth", "twentieth", "thirtieth", "fortieth", "fiftieth",
        "sixtieth", "seventieth", "eightieth", "ninetieth", "hundredth", "thousandth", "millionth", "percent", "un",
        "une", "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf", "dix", "onze", "douze", "treize",
        "quatorze", "quinze", "seize", "vingt", "vingts", "trente", "quarante", "cinquante", "soixante", "cent",
        "cents", "mille", "million", "milliard", "milliards", "virgule", "premier", "premiere", "premiers",
        "premieres", "seconde", "deuxieme", "troisieme", "quatrieme", "cinquieme", "sixieme", "septieme", "huitieme",
        "neuvieme", "dixieme", "onzieme", "douzieme", "treizieme", "quatorzieme", "quinzieme", "seizieme",
        "vingtieme", "trentieme", "centieme", "millieme",
    ])

    /// Words that join the parts of a number.
    static let numberJoiners: Set<String> = ["and", "point", "dot", "et", "pour"]

    static func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                current[j] = lhs[i - 1] == rhs[j - 1] ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}

/// The Speed setting for a natural voice. Pocket TTS has no speed control, so the speech is time-stretched after it
/// is made (`TimeStretch`, pitch kept). The factor is the one the Reading section's slider shows (the inverse of
/// `ReadingSpeed.rate(for:)`), continued linearly for `--rate` values outside the slider, within 0.5×–2×.
public enum NaturalSpeechSpeed {
    public static let range: ClosedRange<Double> = 0.5...2.0

    public static func factor(rate: Float?) -> Double {
        guard let rate, rate.isFinite else { return 1 }
        let normal = Double(ReadingSpeed.normalRate)
        let value = Double(rate)
        let speed: Double
        if value < normal {
            speed = 1 - (normal - value) / (normal - Double(ReadingSpeed.slowRate))
                * (ReadingSpeed.standard - ReadingSpeed.range.lowerBound)
        } else {
            speed = 1 + (value - normal) / (Double(ReadingSpeed.fastRate) - normal)
                * (ReadingSpeed.range.upperBound - ReadingSpeed.standard)
        }
        return min(range.upperBound, max(range.lowerBound, speed))
    }
}

/// Changes the speed of mono speech without changing its pitch: `AVAudioUnitTimePitch`, rendered offline.
public enum TimeStretch {
    public static func apply(_ samples: [Float], sampleRate: Double, rate: Double) throws -> [Float] {
        guard rate.isFinite, rate > 0, abs(rate - 1) > 0.001, !samples.isEmpty else { return samples }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw HolosError.io("Could not prepare the speech for its speed change.")
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            input.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = Float(rate)
        engine.attach(player)
        engine.attach(pitch)
        try engine.connectNode(player, to: pitch, format: format)
        try engine.connectNode(pitch, to: engine.mainMixerNode, format: format)
        let chunk: AVAudioFrameCount = 4_096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(input, completionHandler: nil)
        try player.playAudio()
        guard let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk) else {
            throw HolosError.io("Could not prepare the speech for its speed change.")
        }
        // The time-pitch unit delays its output by its latency: that much more is rendered, and dropped from the start.
        let latency = Int((pitch.latency * sampleRate).rounded())
        let wanted = Int((Double(samples.count) / rate).rounded()) + latency
        var result: [Float] = []
        result.reserveCapacity(wanted)
        while result.count < wanted {
            let frames = AVAudioFrameCount(min(Int(chunk), wanted - result.count))
            switch try engine.renderOffline(frames, to: output) {
            case .success:
                let channel = output.floatChannelData![0]
                result.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw HolosError.io("The speech could not be sped up or slowed down.")
            @unknown default:
                throw HolosError.io("The speech could not be sped up or slowed down.")
            }
        }
        return Array(result.dropFirst(min(latency, result.count)))
    }
}

/// What happened to one paragraph of a natural reading.
public enum NaturalSpeechEvent: Sendable, Equatable {
    /// The paragraph passed (or failed) the check; `take` 1 is the first render, 2 the re-render.
    case checked(paragraph: Int, take: Int, verdict: SpeechChunkCheck.Verdict, seconds: Double)
    /// No recognizer is available for the language: paragraphs are not checked.
    case checkUnavailable(language: String)
    /// The recognizer failed on this paragraph: its take is kept, unchecked.
    case checkFailed(paragraph: Int, reason: String)
    /// The paragraph failed twice (or could not be made) and was read by a system voice instead.
    case fellBack(paragraph: Int, voice: String, reason: String)
}

/// Timings of the last render, for the log and for measuring the check's cost.
public struct NaturalSpeechStats: Sendable, Equatable {
    public var paragraphs = 0
    public var audioSeconds = 0.0
    public var synthesisSeconds = 0.0
    public var checkSeconds = 0.0
    public var rerenders = 0
    public var fallbacks = 0
}

/// Renders text with a natural voice into one audio file (a reading's part, or `voiceislocal say -o`), paragraph by
/// paragraph (see `NaturalSpeechPlan`), each with the same fixed seed so a resumed reading sounds as it would have.
/// Each paragraph is heard back (`SpeechChunkCheck`) when a checker is given: one that fails is rendered again with
/// another seed, and one that fails again is read by a system voice (`ParagraphFallback`), and logged.
@MainActor public final class NaturalSpeechRenderer {
    nonisolated public static let sampleRate = 24_000.0
    /// Every paragraph's first take uses this seed; the re-render uses the next one.
    nonisolated public static let seed: UInt64 = 0x5645_4C4F_4341_4C31

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "reading")

    private let backend: any NaturalSpeechBackend
    private let checker: (any SpeechChunkChecker)?
    private let fallback: any ParagraphFallback
    private let installedPacks: @Sendable () -> Set<NaturalVoicePack>
    private let exclusiveRename: ExclusivePublisher.ExclusiveRename
    /// Called on the main actor for each check, re-render, and fallback.
    public var onEvent: ((NaturalSpeechEvent) -> Void)?
    public private(set) var lastStats = NaturalSpeechStats()

    public init(backend: any NaturalSpeechBackend, checker: (any SpeechChunkChecker)?, fallback: any ParagraphFallback,
                installedPacks: @escaping @Sendable () -> Set<NaturalVoicePack> = {
                    NaturalVoiceModels.installedPacks()
                },
                exclusiveRename: @escaping ExclusivePublisher.ExclusiveRename = ExclusivePublisher.systemExclusiveRename) {
        self.backend = backend
        self.checker = checker
        self.fallback = fallback
        self.installedPacks = installedPacks
        self.exclusiveRename = exclusiveRename
    }

    /// Fails unless `identifier` is an offered natural voice whose pack is installed.
    public func checkVoice(_ identifier: String) throws {
        _ = try voice(identifier)
    }

    private func voice(_ identifier: String) throws -> NaturalVoice {
        guard let voice = NaturalVoiceCatalog.voice(id: identifier) else {
            throw HolosError.unavailable("Speech voice is unavailable: \(identifier)")
        }
        guard installedPacks().contains(voice.pack) else {
            throw HolosError.unavailable("The \(voice.pack.languageName) natural voices are not installed. Download "
                + "them in Settings › Reading, or run voiceislocal setup --natural-voices"
                + (voice.pack == .english ? "" : " --language \(voice.pack.languageCode)") + ".")
        }
        return voice
    }

    public func render(text: String, voiceIdentifier: String?, rate: Float?, to output: URL)
        async throws -> RenderedAudio {
        guard let voiceIdentifier else { throw HolosError.invalidInput("A natural voice must be named.") }
        let voice = try voice(voiceIdentifier)
        let blocks = NaturalSpeechPlan.blocks(text)
        guard !blocks.isEmpty else { throw HolosError.invalidInput("Speech text is empty.") }
        guard output.isFileURL else { throw HolosError.invalidInput("Speech output must be a file URL.") }
        let ext = output.pathExtension.lowercased()
        guard ["wav", "caf", "m4a"].contains(ext) else {
            throw HolosError.invalidInput("Unsupported speech output format .\(ext); use wav, caf, or m4a.")
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw HolosError.invalidInput("Speech output already exists: \(output.path)")
        }
        try SpeechRate.validate(rate)
        let speed = NaturalSpeechSpeed.factor(rate: rate)
        var stats = NaturalSpeechStats()
        var checking = checker != nil
        // Each paragraph goes to the file as soon as it is made, so a long text never holds more than one paragraph's
        // samples; the file is written beside the output and published once whole.
        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(".holos-\(UUID().uuidString).\(ext)")
        defer { _ = unlink(temporary.path) }
        let writer = try NaturalSpeechFileWriter(url: temporary, sampleRate: Self.sampleRate)
        for (index, block) in blocks.enumerated() {
            try Task.checkCancellation()
            var speech = try await paragraph(block.text, index: index, voice: voice, checking: &checking,
                                             stats: &stats)
            speech = try TimeStretch.apply(speech, sampleRate: Self.sampleRate, rate: speed)
            try writer.append(speech)
            try writer.appendSilence(seconds: block.pauseAfter)
        }
        writer.close()
        let frames = writer.frames
        stats.paragraphs = blocks.count
        stats.audioSeconds = Double(frames) / Self.sampleRate
        lastStats = stats
        guard frames > 0 else { throw HolosError.incomplete("The natural voice produced no audio.") }
        try Task.checkCancellation()
        let rename = exclusiveRename
        // Off the main actor: on a volume that cannot rename exclusively the file is copied.
        try await Task.detached(priority: .userInitiated) {
            try ExclusivePublisher.publish(temporary, to: output, exclusiveRename: rename,
                                           existing: "Speech output already exists")
        }.value
        return RenderedAudio(url: output, duration: Double(frames) / Self.sampleRate, frameCount: frames,
                             sampleRate: Self.sampleRate)
    }

    /// One paragraph: rendered, checked, rendered again once with the next seed, else read by a system voice.
    private func paragraph(_ text: String, index: Int, voice: NaturalVoice, checking: inout Bool,
                           stats: inout NaturalSpeechStats) async throws -> [Float] {
        var reason = ""
        for take in 1...2 {
            try Task.checkCancellation()
            let started = ContinuousClock.now
            let speech: [Float]
            do {
                speech = try await backend.synthesize(text, voice: voice, seed: Self.seed &+ UInt64(take - 1))
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                reason = "the voice failed (\(error.localizedDescription))"
                Self.log.error("Natural voice failed on paragraph \(index + 1, privacy: .public), take \(take, privacy: .public)")
                stats.synthesisSeconds += (ContinuousClock.now - started).seconds
                if take == 1 { stats.rerenders += 1 }
                continue
            }
            stats.synthesisSeconds += (ContinuousClock.now - started).seconds
            guard !speech.isEmpty else {
                reason = "the voice made no sound"
                if take == 1 { stats.rerenders += 1 }
                continue
            }
            guard checking, let checker else { return speech }
            let checkStarted = ContinuousClock.now
            let heard: String?
            do {
                heard = try await checker.transcript(of: speech, sampleRate: Self.sampleRate,
                                                     language: voice.pack.languageCode)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                // A recognizer that fails says nothing about the speech: the take is kept, unchecked.
                Self.log.error("Paragraph check failed to run: \(error.localizedDescription, privacy: .public)")
                stats.checkSeconds += (ContinuousClock.now - checkStarted).seconds
                onEvent?(.checkFailed(paragraph: index + 1, reason: error.localizedDescription))
                return speech
            }
            let seconds = (ContinuousClock.now - checkStarted).seconds
            stats.checkSeconds += seconds
            guard let heard else {
                checking = false
                onEvent?(.checkUnavailable(language: voice.pack.languageCode))
                return speech
            }
            let verdict = SpeechChunkCheck.evaluate(expected: text, heard: heard)
            onEvent?(.checked(paragraph: index + 1, take: take, verdict: verdict, seconds: seconds))
            if verdict.passed { return speech }
            reason = String(format: "it was heard with %.0f%% of its words wrong", verdict.wordErrorRate * 100)
            Self.log.notice("Paragraph \(index + 1, privacy: .public) failed its check (take \(take, privacy: .public), WER \(verdict.wordErrorRate, privacy: .public))")
            if take == 1 { stats.rerenders += 1 }
        }
        let fallen = try await fallback.samples(for: text, language: voice.pack.languageCode,
                                                sampleRate: Self.sampleRate)
        stats.fallbacks += 1
        onEvent?(.fellBack(paragraph: index + 1, voice: fallen.voice, reason: reason))
        Self.log.notice("Paragraph \(index + 1, privacy: .public) read by \(fallen.voice, privacy: .public) instead")
        return fallen.samples
    }
}

/// Mono float samples written as an audio file, a piece at a time: 16-bit PCM in .wav and .caf, AAC (64 kbit/s) in
/// .m4a.
public final class NaturalSpeechFileWriter {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let sampleRate: Double
    /// The frames written so far.
    public private(set) var frames: Int64 = 0

    public init(url: URL, sampleRate: Double) throws {
        let fileExtension = url.pathExtension.lowercased()
        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1]
        switch fileExtension {
        case "m4a":
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 64_000
            settings[AVAudioFileTypeKey] = kAudioFileM4AType
        case "wav", "caf":
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVAudioFileTypeKey] = fileExtension == "wav" ? kAudioFileWAVEType : kAudioFileCAFType
        default:
            throw HolosError.invalidInput("Unsupported speech output format .\(fileExtension); use wav, caf, or m4a.")
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw HolosError.io("Could not prepare the speech file.")
        }
        self.format = format
        self.sampleRate = sampleRate
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    public func append(_ samples: [Float]) throws {
        let chunk = 65_536
        var offset = 0
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                throw HolosError.io("Could not prepare the speech file.")
            }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress! + offset, count: count)
            }
            try file.write(from: buffer)
            offset += count
        }
        frames += Int64(samples.count)
    }

    public func appendSilence(seconds: Double) throws {
        var remaining = Int((seconds * sampleRate).rounded())
        while remaining > 0 {
            let count = min(remaining, 65_536)
            try append([Float](repeating: 0, count: count))
            remaining -= count
        }
    }

    /// Finishes the file (an AAC file's last packets are written here).
    public func close() { file.close() }
}

/// A whole file of mono float samples (see `NaturalSpeechFileWriter`).
public enum NaturalSpeechFile {
    public static func write(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let writer = try NaturalSpeechFileWriter(url: url, sampleRate: sampleRate)
        try writer.append(samples)
        writer.close()
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Reads a paragraph with the best system voice for its language, converted to the natural voice's format.
@MainActor public final class NativeParagraphFallback: ParagraphFallback {
    public init() {}

    public func samples(for text: String, language: String, sampleRate: Double) async throws
        -> (samples: [Float], voice: String) {
        guard let voice = NativeSpeechRenderer.bestVoice(language: language) else {
            throw HolosError.unavailable("No system voice speaks \(language) to read a paragraph the natural voice "
                + "could not.")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("holos-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let rendered = try await NativeSpeechRenderer().render(text: text, voiceIdentifier: voice.id, rate: nil,
                                                               to: folder.appendingPathComponent("speech.caf"))
        return (try AudioSamples.mono(from: rendered.url, sampleRate: sampleRate), voice.name)
    }
}

/// Mono float samples of an audio file at a chosen sample rate.
public enum AudioSamples {
    public static func mono(from url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw HolosError.io("Could not convert \(url.lastPathComponent).")
        }
        let capacity: AVAudioFrameCount = 8_192
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity),
              let output = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(Double(capacity) * sampleRate / file.processingFormat.sampleRate) + 64)
        else { throw HolosError.io("Could not convert \(url.lastPathComponent).") }
        var result: [Float] = []
        var finished = false
        var readError: (any Error)?
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if finished || file.framePosition >= file.length {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: capacity)
                } catch {
                    readError = error
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if input.frameLength == 0 {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if let readError { throw readError }
            if status == .error { throw conversionError ?? HolosError.io("Could not convert \(url.lastPathComponent).") }
            result.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0],
                                                          count: Int(output.frameLength)))
            if status == .endOfStream || (status == .inputRanDry && finished)
                || (output.frameLength == 0 && finished) { break }
        }
        return result
    }
}
