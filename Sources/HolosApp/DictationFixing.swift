import Foundation
import HolosDictation
import HolosCore
import os

/// The Setup option "Fix misheard words with Apple Intelligence", off by default.
enum AIFixSetting {
    static let key = DictationPreferences.aiFixKey

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Nil when Apple's on-device model can be used for dictation in `language`; otherwise why not, for Settings
    /// (`OnDeviceFix`, shared with Run Again).
    static func unavailableReason(language: String) -> String? {
        OnDeviceFix.unavailableReason(language: language)
    }
}

/// Settings › Dictation › "Write spoken paths and commands as code" and "Wrap them in backticks", both on by default.
enum SpokenCodeSetting {
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: DictationPreferences.spokenCodeKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: DictationPreferences.spokenCodeKey) }
    }

    /// Never for a terminal, where the token itself is typed (`DictationFixPipeline.make`).
    static var backticks: Bool {
        get { UserDefaults.standard.object(forKey: DictationPreferences.spokenCodeBackticksKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: DictationPreferences.spokenCodeBackticksKey) }
    }
}

/// Runs each committed dictation chunk through spoken code, then Apple's on-device fix, before Holos writes it, one
/// chunk at a time and in order: chunk N+1 is never written before chunk N. A step that is slow, refused or failed
/// leaves the chunk as it was given to it. Transcript text is private, so only outcome categories and timings are
/// logged.
@MainActor
final class DictationFixPipeline {
    /// How long a chunk waits for each step's model before it goes on without it. Fixes took 0.35–0.55 s per chunk
    /// on an M-series Mac once the model was loaded.
    static let chunkTimeout = OnDeviceFix.chunkTimeout

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "ai-fix")
    private let fixer: TranscriptFixer?
    private let coder: SpokenCodeFormatter?
    /// Writes a chunk (`text` is its result, or the chunk itself); false when streaming has stopped.
    private let deliver: (_ chunk: String, _ text: String) -> Bool
    private var pending: [String] = []
    private var worker: Task<Void, Never>?
    private var stopped = false
    /// Recognized text handed to the pipeline so far; the next chunk starts after it.
    private(set) var submitted = ""
    /// The chunks written so far: as recognized, after spoken code alone, and as written.
    private(set) var writtenOriginal = ""
    private(set) var writtenCoded = ""
    private(set) var written = ""
    /// Code spans in the chunks written.
    private(set) var writtenCodeSpans = 0
    /// The chunk whose write failed, as recognized and as its result; nothing after it was written.
    private(set) var failedWrite: (chunk: String, text: String)?
    /// That chunk after spoken code alone, and its code spans.
    private(set) var failedCoded: (text: String, spans: Int)?
    /// Set once the key is released, while the last chunks are processed and written; dictation counts as busy.
    var finishing = false

    /// Whether spoken code runs: streaming then holds back a trailing spoken path (`SpokenCode`).
    var formatsCode: Bool { coder != nil }

    /// A pipeline when spoken code is on, or Apple Intelligence's fix is on and its model is available for dictation
    /// in `language`; nil otherwise, so dictation runs exactly as it does without them. `terminal`: the dictation is
    /// typed into a terminal, where code tokens are never wrapped in backticks.
    static func make(corrections: CorrectionList, language: String, terminal: Bool,
                     deliver: @escaping (_ chunk: String, _ text: String) -> Bool) -> DictationFixPipeline? {
        let fixes = AIFixSetting.isOn && AIFixSetting.unavailableReason(language: language) == nil
        let coder = SpokenCodeSetting.isOn
            ? OnDeviceFix.spokenCode(corrections: corrections, language: language,
                                     backticks: SpokenCodeSetting.backticks && !terminal, timeout: chunkTimeout)
            : nil
        guard fixes || coder != nil else { return nil }
        // Loads the model while the user starts speaking, so the first chunk does not wait for it.
        if fixes || coder?.hasModel == true { OnDeviceFix.prewarm() }
        // The same model, guardrails, sessions, and timeout Run Again uses (`OnDeviceFix`).
        let fixer = fixes ? OnDeviceFix.fixer(corrections: corrections, timeout: chunkTimeout, language: language) : nil
        return DictationFixPipeline(fixer: fixer, coder: coder, deliver: deliver)
    }

    init(fixer: TranscriptFixer?, coder: SpokenCodeFormatter? = nil,
         deliver: @escaping (_ chunk: String, _ text: String) -> Bool) {
        self.fixer = fixer
        self.coder = coder
        self.deliver = deliver
    }

    /// Queues newly committed text; chunks queued while the model is busy are processed together.
    func submit(_ chunk: String) {
        guard !stopped else { return }
        submitted += chunk
        pending.append(chunk)
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.run() }
    }

    /// Runs `text` through spoken code, then the fix; at the end of the dictation, the text after the last chunk.
    func fix(_ text: String, isFinal: Bool) async -> DictationTextPipeline.ChunkResult {
        let started = ContinuousClock.now
        let result = await DictationTextPipeline.process(text, isFinal: isFinal, coder: coder, fixer: fixer)
        let elapsed = started.duration(to: .now)
        Self.log.notice("""
            Chunk: code \(result.codeOutcome?.rawValue ?? "off", privacy: .public) (\(result.codeSpans) spans), \
            fix \(result.fixOutcome?.rawValue ?? "off", privacy: .public) in \
            \(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000) ms, \
            \(AIFixGuard.words(in: text).count) words\(isFinal ? ", final" : "", privacy: .public)
            """)
        return result
    }

    /// Records a chunk written, as recognized, after spoken code, and as written.
    private func didWrite(_ chunk: String, as result: DictationTextPipeline.ChunkResult) {
        writtenOriginal += chunk
        writtenCoded += result.coded
        written += result.text
        writtenCodeSpans += result.codeSpans
    }

    /// Whether a step changed the chunks written, or `offered` (what was written or offered for the rest) differs
    /// from `recognized`: spoken code (`coded` against the rest as recognized) and the fix (`offered` against
    /// `coded`).
    func changes(offered: String = "", coded: String = "", recognized: String = "") -> (code: Bool, fix: Bool) {
        (writtenCoded != writtenOriginal || coded != recognized, written != writtenCoded || offered != coded)
    }

    /// Returns once every queued chunk has been written or dropped.
    func idle() async {
        while let worker { await worker.value }
    }

    /// Drops queued chunks and the work in progress: the dictation was cancelled or streaming stopped.
    func cancel() {
        stopped = true
        pending.removeAll()
        worker?.cancel()
        worker = nil
    }

    private func run() async {
        while !stopped, !pending.isEmpty {
            let chunk = pending.joined()
            pending.removeAll()
            let result = await fix(chunk, isFinal: false)
            guard !stopped else { break }
            guard deliver(chunk, result.text) else {
                // Streaming stopped (the app or field changed, for example): nothing more is written. Copy Result
                // offers what Holos tried to write.
                failedWrite = (chunk, result.text)
                failedCoded = (result.coded, result.codeSpans)
                stopped = true
                pending.removeAll()
                break
            }
            didWrite(chunk, as: result)
        }
        worker = nil
    }
}

/// What a dictation's result message says a step changed, and where Copy Original stands.
enum PipelineChangeText {
    /// "Apple Intelligence fixed misheard words", "Spoken paths and commands were written as code", or both.
    static func what(code: Bool, fix: Bool) -> String {
        switch (code, fix) {
        case (true, true): "Apple Intelligence fixed misheard words and spoken paths were written as code"
        case (true, false): "Spoken paths and commands were written as code"
        default: "Apple Intelligence fixed misheard words"
        }
    }

    /// "Apple Intelligence's fix", "spoken code", or both: what Copy Original's text comes before.
    static func steps(code: Bool, fix: Bool) -> String {
        switch (code, fix) {
        case (true, true): "spoken code and Apple Intelligence's fix"
        case (true, false): "spoken code"
        default: "Apple Intelligence's fix"
        }
    }
}
