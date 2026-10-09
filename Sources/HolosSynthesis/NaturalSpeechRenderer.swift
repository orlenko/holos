import AVFAudio
import AudioToolbox
import Foundation
import HolosCore
import os
import Synchronization

/// Hears a rendered paragraph back, for the per-paragraph check (see `SpeechChunkCheck`).
public protocol SpeechChunkChecker: Sendable {
    /// What a speech recognizer hears in `samples`; nil when none is available for `language` here (the check is
    /// skipped).
    func transcript(of samples: [Float], sampleRate: Double, language: String) async throws -> String?
}

/// Speaks a paragraph with a system voice when the natural voice keeps failing the check.
@MainActor public protocol ParagraphFallback {
    /// The system voice it reads `language` with now.
    func defaultVoice(language: String) -> String?
    /// The paragraph spoken by the system voice `voice` (else the default one for `language`), as mono samples at
    /// `sampleRate`; also the voice's name.
    func samples(for text: String, voice: String?, language: String, sampleRate: Double) async throws
        -> (samples: [Float], voice: String)
}

/// What a natural rendering depends on besides its voice, text, and speed: the system voice a failed paragraph is
/// read with, and whether paragraphs are checked. A reading keeps them in its manifest when it starts
/// (`ReadingManifest.rendererSettings`) and gives them back for every part (`render(…settings:)`; the app's parts pass
/// them as `say --fallback-voice`, `--check`), so a resumed reading does not mix fallback voices or check policies.
public struct NaturalRenderSettings: Codable, Sendable, Equatable {
    public var fallbackVoice: String?
    public var checked: Bool

    public init(fallbackVoice: String?, checked: Bool) {
        self.fallbackVoice = fallbackVoice
        self.checked = checked
    }

    /// As strings, to keep with a caller's own data.
    public var values: [String: String] {
        var values = ["check": checked ? "on" : "off"]
        if let fallbackVoice { values["fallbackVoice"] = fallbackVoice }
        return values
    }

    public init(values: [String: String]) {
        self.init(fallbackVoice: values["fallbackVoice"], checked: values["check"] != "off")
    }
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
        /// The paragraph of the part it comes from, counted from 0: the groups of a long paragraph share it.
        public let paragraph: Int
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
        // A blank line may hold spaces or tabs (a no-break space too).
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: /\n[ \t\u{00A0}]*\n/, omittingEmptySubsequences: false)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return paragraphs.enumerated().flatMap { index, paragraph -> [Block] in
            let last = index == paragraphs.count - 1
            let heading = index == 0 && !last && looksLikeHeading(paragraph)
            let pause = last ? 0 : heading ? headingPause : paragraphPause
            let groups = split(paragraph, maximumLength: maximumBlockLength)
            return groups.enumerated().map { groupIndex, group in
                Block(text: group, pauseAfter: groupIndex == groups.count - 1 ? pause : 0, isHeading: heading,
                      paragraph: index)
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
                // Each cut starts where the last ended: one pass over the piece.
                var cuts: [String] = []
                var from = piece.startIndex
                while from < piece.endIndex {
                    let to = piece.index(from, offsetBy: maximumLength, limitedBy: piece.endIndex) ?? piece.endIndex
                    cuts.append(String(piece[from..<to]))
                    from = to
                }
                return cuts
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

/// What happened to one paragraph of a natural rendering.
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

/// Renders text with a natural voice into one audio file (`voiceislocal say`, a part of `voiceislocal read`; the app's
/// parts go through `say`), paragraph by paragraph (see
/// `NaturalSpeechPlan`), each with the same fixed seed so the same text always sounds the same.
/// Each paragraph is heard back (`SpeechChunkCheck`) when a checker is given: one that fails is rendered again with
/// another seed, and one that fails again is read by a system voice (`ParagraphFallback`), and logged.
///
/// Invariants:
/// 1. One render at a time: `render` fails at once while another render of this renderer runs (`rendering`), so
///    `lastStats`, `onEvent`'s events, and `uncheckable` always belong to a single render in progress or just ended.
/// 2. `lastStats` is set once, when a render has published its file; a failed or cancelled render leaves the
///    previous one.
/// 3. `uncheckable` only grows: a language found without a recognizer is not probed again by this renderer.
/// 4. `confirmedPacks` only grows: a render looks at a pack's files once per renderer, off the main actor, so a book's
///    hundreds of parts do not rescan them (a pack removed meanwhile fails when its models load).
@MainActor public final class NaturalSpeechRenderer {
    nonisolated public static let sampleRate = NaturalSpeechFormat.sampleRate
    /// Every paragraph's first take uses this seed; the re-render uses the next one.
    nonisolated public static let seed = NaturalSpeechFormat.seed

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "reading")

    private let backend: any NaturalSpeechBackend
    private let checker: (any SpeechChunkChecker)?
    /// Whether a rendering without saved settings is checked (`HOLOS_NATURAL_CHECK=0` turns it off in the tool). The
    /// checker is there either way, so settings given with the check on are honoured whatever the default is.
    private let checksByDefault: Bool
    private let fallback: any ParagraphFallback
    private let installedPacks: @Sendable () -> Set<NaturalVoicePack>
    private let exclusiveRename: ExclusivePublisher.ExclusiveRename
    /// Called on the main actor for each check, re-render, and fallback.
    public var onEvent: ((NaturalSpeechEvent) -> Void)?
    public private(set) var lastStats = NaturalSpeechStats()
    /// Languages found to have no recognizer: not checked again for this renderer's life (a book's hundreds of parts
    /// probe and say so once).
    private var uncheckable: Set<String> = []
    /// Whether a render runs now (invariant 1).
    private var rendering = false
    /// Packs found installed by a render (invariant 4).
    private var confirmedPacks: Set<NaturalVoicePack> = []

    public init(backend: any NaturalSpeechBackend, checker: (any SpeechChunkChecker)?, checksByDefault: Bool = true,
                fallback: any ParagraphFallback, installedPacks: @escaping @Sendable () -> Set<NaturalVoicePack> = {
                    NaturalVoiceModels.installedPacks()
                },
                exclusiveRename: @escaping ExclusivePublisher.ExclusiveRename = ExclusivePublisher.systemExclusiveRename) {
        self.backend = backend
        self.checker = checker
        self.checksByDefault = checksByDefault
        self.fallback = fallback
        self.installedPacks = installedPacks
        self.exclusiveRename = exclusiveRename
    }

    /// Fails unless `identifier` is an offered natural voice whose pack is installed.
    public func checkVoice(_ identifier: String) throws {
        _ = try voice(identifier, installed: installedPacks())
    }

    /// The voice for a render: its pack is looked at off the main actor, once per renderer (invariant 4).
    private func confirmedVoice(_ identifier: String) async throws -> NaturalVoice {
        if let voice = NaturalVoiceCatalog.voice(id: identifier), confirmedPacks.contains(voice.pack) { return voice }
        let installedPacks = installedPacks
        let installed = await Task.detached(priority: .userInitiated) { installedPacks() }.value
        let voice = try voice(identifier, installed: installed)
        confirmedPacks.insert(voice.pack)
        return voice
    }

    private func voice(_ identifier: String, installed: Set<NaturalVoicePack>) throws -> NaturalVoice {
        guard let voice = NaturalVoiceCatalog.voice(id: identifier) else {
            throw HolosError.unavailable("Speech voice is unavailable: \(identifier)")
        }
        guard installed.contains(voice.pack) else {
            throw HolosError.unavailable("The \(voice.pack.languageName) natural voices are not installed. Download "
                + "them in Settings › Reading, or run voiceislocal setup --natural-voices"
                + (voice.pack == .english ? "" : " --language \(voice.pack.languageCode)") + ".")
        }
        return voice
    }

    /// The settings a rendering with `voiceIdentifier` gets now (see `NaturalRenderSettings`).
    public func settings(for voiceIdentifier: String) -> NaturalRenderSettings? {
        guard let voice = NaturalVoiceCatalog.voice(id: voiceIdentifier) else { return nil }
        return NaturalRenderSettings(fallbackVoice: fallback.defaultVoice(language: voice.pack.languageCode),
                                     checked: checker != nil && checksByDefault)
    }

    public func render(text: String, voiceIdentifier: String?, rate: Float?, to output: URL)
        async throws -> RenderedAudio {
        try await render(text: text, voiceIdentifier: voiceIdentifier, rate: rate, settings: nil, to: output)
    }

    /// `settings`: those a caller kept from an earlier run (nil: the current ones, `settings(for:)`).
    public func render(text: String, voiceIdentifier: String?, rate: Float?, settings: NaturalRenderSettings?,
                       to output: URL) async throws -> RenderedAudio {
        guard let voiceIdentifier else { throw HolosError.invalidInput("A natural voice must be named.") }
        // Invariant 1: a second render while one runs is refused, never interleaved.
        guard !rendering else { throw HolosError.unavailable("This natural voice renderer is already rendering.") }
        rendering = true
        defer { rendering = false }
        let voice = try await confirmedVoice(voiceIdentifier)
        let settings = settings ?? self.settings(for: voiceIdentifier)
        let blocks = NaturalSpeechPlan.blocks(text)
        guard !blocks.isEmpty else { throw HolosError.invalidInput("Speech text is empty.") }
        guard output.isFileURL else { throw HolosError.invalidInput("Speech output must be a file URL.") }
        let ext = output.pathExtension.lowercased()
        guard ["wav", "caf", "m4a"].contains(ext) else {
            throw HolosError.invalidInput("Unsupported speech output format .\(ext); use wav, caf, or m4a.")
        }
        try SpeechRate.validate(rate)
        let speed = NaturalSpeechSpeed.factor(rate: rate)
        var stats = NaturalSpeechStats()
        var checking = checker != nil && settings?.checked != false && !uncheckable.contains(voice.pack.languageCode)
        // Each paragraph goes to the file as soon as it is made, so a long text never holds more than one paragraph's
        // samples; the file is written beside the output and published once whole.
        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(".holos-\(UUID().uuidString).\(ext)")
        defer { _ = unlink(temporary.path) }
        // The file is written, and each paragraph time-stretched, off the main actor (`NaturalSpeechSink`).
        let sink = try await NaturalSpeechSink.open(temporary, refusing: output, sampleRate: Self.sampleRate)
        for block in blocks {
            try Task.checkCancellation()
            // Events and the log name the part's paragraph (a long one's groups share its number).
            let speech = try await paragraph(block.text, index: block.paragraph, voice: voice,
                                             fallbackVoice: settings?.fallbackVoice, checking: &checking,
                                             stats: &stats)
            try await sink.add(speech, rate: speed, pauseAfter: block.pauseAfter)
        }
        let frames = await sink.close()
        stats.paragraphs = Set(blocks.map(\.paragraph)).count
        stats.audioSeconds = Double(frames) / Self.sampleRate
        guard frames > 0 else { throw HolosError.incomplete("The natural voice produced no audio.") }
        try Task.checkCancellation()
        let rename = exclusiveRename
        // Off the main actor: on a volume that cannot rename exclusively the file is copied. A Stop meanwhile reaches
        // the copy (between its chunks), which then leaves nothing at the output.
        let stop = PublicationStop()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try ExclusivePublisher.publish(temporary, to: output, exclusiveRename: rename,
                                               existing: "Speech output already exists",
                                               isCancelled: { stop.requested })
            }.value
        } onCancel: {
            stop.request()
        }
        lastStats = stats  // invariant 2: published
        return RenderedAudio(url: output, duration: Double(frames) / Self.sampleRate, frameCount: frames,
                             sampleRate: Self.sampleRate)
    }

    /// One paragraph: rendered, checked, rendered again once with the next seed, else read by a system voice.
    private func paragraph(_ text: String, index: Int, voice: NaturalVoice, fallbackVoice: String?,
                           checking: inout Bool, stats: inout NaturalSpeechStats) async throws -> [Float] {
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
                uncheckable.insert(voice.pack.languageCode)
                onEvent?(.checkUnavailable(language: voice.pack.languageCode))
                return speech
            }
            let verdict = SpeechChunkCheck.evaluate(expected: text, heard: heard,
                                                   language: voice.pack.languageCode)
            onEvent?(.checked(paragraph: index + 1, take: take, verdict: verdict, seconds: seconds))
            if verdict.passed { return speech }
            reason = String(format: "it was heard with %.0f%% of its words wrong", verdict.wordErrorRate * 100)
            Self.log.notice("Paragraph \(index + 1, privacy: .public) failed its check (take \(take, privacy: .public), WER \(verdict.wordErrorRate, privacy: .public))")
            if take == 1 { stats.rerenders += 1 }
        }
        let fallen = try await fallback.samples(for: text, voice: fallbackVoice, language: voice.pack.languageCode,
                                                sampleRate: Self.sampleRate)
        stats.fallbacks += 1
        onEvent?(.fellBack(paragraph: index + 1, voice: fallen.voice, reason: reason))
        Self.log.notice("Paragraph \(index + 1, privacy: .public) read by \(fallen.voice, privacy: .public) instead")
        return fallen.samples
    }
}

/// Whether the render publishing a file was cancelled: set by its cancellation handler, read by the copy.
///
/// Invariants:
/// 1. The flag only goes from false to true, once; nothing clears it.
/// 2. The cancellation handler is the one writer (`request`); the detached publication only reads it (`requested`),
///    before the exclusive rename and between the copy's chunks.
private final class PublicationStop: Sendable {
    private let flag = Mutex(false)
    var requested: Bool { flag.withLock { $0 } }
    func request() { flag.withLock { $0 = true } }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Reads a paragraph with the best system voice for its language, converted to the natural voice's format.
@MainActor public final class NativeParagraphFallback: ParagraphFallback {
    /// Where its temporary folders go: the folder `say --scratch-directory` names, so deleting that folder leaves
    /// nothing behind.
    private let temporaryRoot: URL

    public init(temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.temporaryRoot = temporaryRoot
    }

    public func defaultVoice(language: String) -> String? {
        NativeSpeechRenderer.bestVoice(language: language)?.id
    }

    /// The voice asked for (the caller's settings), else the best one for `language` now. A voice asked for that is no
    /// longer installed fails, naming it: a render never switches its fallback voice silently.
    public func samples(for text: String, voice chosen: String?, language: String, sampleRate: Double) async throws
        -> (samples: [Float], voice: String) {
        let installed = NativeSpeechRenderer.voices()
        if let chosen, !installed.contains(where: { $0.id == chosen }) {
            throw HolosError.unavailable("A paragraph the natural voice could not read needs the system voice "
                + "\(chosen), which is not installed any more. Install it again in System Settings › Accessibility › "
                + "Spoken Content.")
        }
        guard let voice = chosen.flatMap({ id in installed.first { $0.id == id } })
                ?? NativeSpeechRenderer.bestVoice(language: language) else {
            throw HolosError.unavailable("No system voice speaks \(language) to read a paragraph the natural voice "
                + "could not.")
        }
        // The folder is made and removed, and the speech read and resampled, off the main actor. The removal is
        // awaited before this returns or throws, so a short `say --output` cannot exit and leave the folder behind.
        let folder = temporaryRoot.appendingPathComponent("holos-fallback-\(UUID().uuidString)", isDirectory: true)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }.value
        let outcome: Result<[Float], any Error>
        do {
            let rendered = try await NativeSpeechRenderer().render(text: text, voiceIdentifier: voice.id, rate: nil,
                                                                   to: folder.appendingPathComponent("speech.caf"))
            outcome = .success(try await Task.detached(priority: .userInitiated) {
                try AudioSamples.mono(from: rendered.url, sampleRate: sampleRate)
            }.value)
        } catch {
            outcome = .failure(error)
        }
        await Self.remove(folder)
        return (try outcome.get(), voice.name)
    }

    /// Removes a fallback folder off the main actor; a failure is logged, since the samples are already read.
    private static func remove(_ folder: URL) async {
        await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                Logger(subsystem: "ca.orlenko.holos.app", category: "reading")
                    .error("Could not remove a fallback folder: \(error.localizedDescription, privacy: .public)")
            }
        }.value
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

/// Temporary folders a natural voice's work leaves behind when its process is killed before its cleanup runs (a crash,
/// a SIGKILL): removed once they are a day old, so a folder in use is never removed. `voiceislocal` sweeps whenever it
/// makes a natural voice renderer (`NaturalVoicesCLI.renderer`).
public enum NaturalVoiceTemporaries {
    /// The prefixes of natural voices' temporary folders (`voiceislocal`'s own, and its callers' scratch folders).
    public static let prefixes = ["holos-natural-", "holos-preview-", "holos-check-", "holos-fallback-"]
    public static let maximumAge: TimeInterval = 24 * 60 * 60

    /// Removes the folders in `folder` whose names start with one of `prefixes` and that have not changed for
    /// `maximumAge`; returns their names. Links and files are left alone.
    @discardableResult
    public static func sweep(in folder: URL = FileManager.default.temporaryDirectory, now: Date = Date())
        -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var removed: [String] = []
        for name in names.sorted() where prefixes.contains(where: name.hasPrefix) {
            let url = folder.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attributes[.type] as? FileAttributeType) == .typeDirectory,
                  let changed = attributes[.modificationDate] as? Date,
                  now.timeIntervalSince(changed) > maximumAge else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed.append(name) }
        }
        return removed
    }
}
