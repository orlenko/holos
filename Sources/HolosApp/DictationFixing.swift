import Foundation
import FoundationModels
import HolosCore
import os

/// The Setup option "Fix misheard words with Apple Intelligence", off by default.
enum AIFixSetting {
    static let key = "aiFixMisheard"

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Nil when Apple's on-device model can be used; otherwise why not, for Setup.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: "this Mac does not support Apple Intelligence"
            case .appleIntelligenceNotEnabled: "turn on Apple Intelligence in System Settings"
            case .modelNotReady: "the model is still downloading"
            @unknown default: "the on-device model is not available"
            }
        }
    }
}

/// Fixes each committed dictation chunk with Apple's on-device model before Holos writes it, one chunk at a time
/// and in order: chunk N+1 is never written before chunk N. A chunk whose fix is slow, refused or failed is written
/// as recognized. Transcript text is private, so only outcome categories and timings are logged.
@MainActor
final class DictationFixPipeline {
    /// How long a chunk waits for its fix before it is written as recognized. Fixes took 0.35–0.55 s per chunk on
    /// an M-series Mac once the model was loaded.
    static let chunkTimeout: Duration = .milliseconds(1500)

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "ai-fix")
    private let fixer: TranscriptFixer
    /// Writes a chunk (`text` is its fix, or the chunk itself); false when streaming has stopped.
    private let deliver: (_ chunk: String, _ text: String) -> Bool
    private var pending: [String] = []
    private var worker: Task<Void, Never>?
    private var stopped = false
    /// Recognized text handed to the pipeline so far; the next chunk starts after it.
    private(set) var submitted = ""
    /// The chunks written so far, as recognized and as written.
    private(set) var writtenOriginal = ""
    private(set) var written = ""
    /// The chunk whose write failed, as recognized and as fixed; nothing after it was written.
    private(set) var failedWrite: (chunk: String, text: String)?
    /// Set once the key is released, while the last chunks are fixed and written; dictation counts as busy.
    var finishing = false

    /// A pipeline when the Setup option is on and the model is available; nil otherwise, so dictation runs exactly
    /// as it does without the option.
    static func make(corrections: CorrectionList,
                     deliver: @escaping (_ chunk: String, _ text: String) -> Bool) -> DictationFixPipeline? {
        guard AIFixSetting.isOn, AIFixSetting.unavailableReason == nil else { return nil }
        let model = SystemLanguageModel.default
        // Loads the model while the user starts speaking, so the first chunk does not wait for it.
        LanguageModelSession(model: model, instructions: TranscriptFixer.instructions(reference: [])).prewarm()
        // A quarter of the context for learned corrections leaves ample room for the chunk and the reply.
        let fixer = TranscriptFixer(corrections: corrections, referenceBudget: model.contextSize / 4,
                                    timeout: chunkTimeout) { instructions, prompt in
            // A fresh session per chunk: earlier chunks must not steer this one, and the context stays small.
            let session = LanguageModelSession(model: model, instructions: instructions)
            return try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy)).content
        }
        return DictationFixPipeline(fixer: fixer, deliver: deliver)
    }

    init(fixer: TranscriptFixer, deliver: @escaping (_ chunk: String, _ text: String) -> Bool) {
        self.fixer = fixer
        self.deliver = deliver
    }

    /// Queues newly committed text; chunks queued while the model is busy are fixed together.
    func submit(_ chunk: String) {
        guard !stopped else { return }
        submitted += chunk
        pending.append(chunk)
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.run() }
    }

    /// Fixes the text after the last chunk, at the end of the dictation.
    func fix(_ text: String, isFinal: Bool) async -> TranscriptFixer.Result {
        let started = ContinuousClock.now
        let result = await fixer.fix(text, isFinal: isFinal)
        let elapsed = started.duration(to: .now)
        Self.log.notice("""
            Chunk fix: \(result.outcome.rawValue, privacy: .public)\
            \(result.rejection.map { " (\($0.rawValue))" } ?? "", privacy: .public) in \
            \(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000) ms, \
            \(AIFixGuard.words(in: text).count) words\(isFinal ? ", final" : "", privacy: .public)
            """)
        return result
    }

    /// Records a chunk written, as recognized and as written.
    private func didWrite(_ chunk: String, as text: String) {
        writtenOriginal += chunk
        written += text
    }

    /// Returns once every queued chunk has been written or dropped.
    func idle() async {
        while let worker { await worker.value }
    }

    /// Drops queued chunks and the fix in progress: the dictation was cancelled or streaming stopped.
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
                // offers the fix Holos tried to write.
                failedWrite = (chunk, result.text)
                stopped = true
                pending.removeAll()
                break
            }
            didWrite(chunk, as: result.text)
        }
        worker = nil
    }
}
