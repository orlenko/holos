import Foundation
import FoundationModels
import HolosAudio
import HolosCore
import HolosSpeech

/// Apple Intelligence's fix of misheard words, as dictation uses it (the app's `DictationFixPipeline`) and as Run Again
/// uses it: Apple's on-device model, a fresh session per chunk, greedy sampling, and the chunk timeout.
public enum OnDeviceFix {
    /// How long a chunk waits for its fix before it is kept as recognized. Fixes took 0.35–0.55 s per chunk on an
    /// M-series Mac once the model was loaded.
    public static let chunkTimeout: Duration = .milliseconds(1500)

    /// Nil when Apple's on-device model can be used; otherwise why not, for Settings.
    public static var unavailableReason: String? {
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

    /// Like `unavailableReason`, for dictation in `language` (a locale identifier). Only English and French have been
    /// tried: the model fixed misheard French words as well as English ones, and the guard refused the replies that
    /// translated or answered the text. Other languages stay off until someone tries them.
    public static func unavailableReason(language: String) -> String? {
        if let reason = unavailableReason { return reason }
        let name = DictationLanguage.name(of: language)
        guard SystemLanguageModel.default.supportsLocale(Locale(identifier: language)) else {
            return "Apple Intelligence does not support \(name)"
        }
        guard ["en", "fr"].contains(DictationLanguage.languageCode(of: language)) else {
            return "not yet tried with \(name) dictation"
        }
        return nil
    }

    /// The model the fix runs. The default guardrails refused about half of ordinary dictated sentences ("We should
    /// develop a plan for the windows laptop." threw "May contain unsafe content"); fixing the speaker's own words is
    /// a content transformation, which these guardrails are for. A reply that still throws leaves the chunk as
    /// recognized.
    static var model: SystemLanguageModel { SystemLanguageModel(guardrails: .permissiveContentTransformations) }

    /// Loads the model, so the first chunk does not wait for it.
    public static func prewarm() {
        LanguageModelSession(model: model, instructions: TranscriptFixer.instructions(reference: [])).prewarm()
    }

    /// The fixer for dictation in `language` (a locale identifier; its function words and homophones count): a
    /// quarter of the model's context for learned corrections leaves ample room for the chunk and the reply.
    public static func fixer(corrections: CorrectionList, timeout: Duration = chunkTimeout,
                             language: String? = nil) -> TranscriptFixer {
        let model = model
        return TranscriptFixer(corrections: corrections, referenceBudget: model.contextSize / 4,
                               timeout: timeout, language: language) { instructions, prompt in
            // A fresh session per chunk: earlier chunks must not steer this one, and the context stays small.
            let session = LanguageModelSession(model: model, instructions: instructions)
            return try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy)).content
        }
    }

    /// Spoken paths and commands written as code for dictation in `language`: with Apple's on-device model (the same
    /// model, guardrails, greedy sampling and a fresh session per chunk as the fix) when it can be used, else runs
    /// found without it (`SpokenCode.fallback`). `backticks`: off for a terminal.
    public static func spokenCode(corrections: CorrectionList, language: String, backticks: Bool,
                                  timeout: Duration = chunkTimeout) -> SpokenCodeFormatter {
        guard unavailableReason(language: language) == nil else {
            return SpokenCodeFormatter(backticks: backticks, language: language, corrections: corrections,
                                       timeout: timeout, model: nil)
        }
        let model = model
        return SpokenCodeFormatter(backticks: backticks, language: language, corrections: corrections,
                                   timeout: timeout) { instructions, prompt in
            let session = LanguageModelSession(model: model, instructions: instructions)
            return try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy)).content
        }
    }
}

/// The dictation settings the app saves (its UserDefaults domain), which Run Again uses: the language, filler
/// removal, spoken code, and Apple Intelligence's fix.
public struct DictationPreferences: Sendable, Equatable {
    /// The app's defaults domain, which `voiceislocal history rerun` reads.
    public static let appDomain = "ca.orlenko.holos.app"
    public static let languageKey = "dictationLocale"
    public static let removeFillersKey = "removeFillers"
    public static let aiFixKey = "aiFixMisheard"
    public static let spokenCodeKey = "spokenCode"
    public static let spokenCodeBackticksKey = "spokenCodeBackticks"

    /// The language chosen in Settings; nil when none was (the app then uses the supported one closest to the user's
    /// languages).
    public var language: String?
    public var removeFillers: Bool
    public var aiFix: Bool
    /// Write spoken paths and commands as code, and wrap them in backticks (never in a terminal).
    public var spokenCode: Bool
    public var spokenCodeBackticks: Bool

    public init(language: String?, removeFillers: Bool, aiFix: Bool, spokenCode: Bool = true,
                spokenCodeBackticks: Bool = true) {
        self.language = language
        self.removeFillers = removeFillers
        self.aiFix = aiFix
        self.spokenCode = spokenCode
        self.spokenCodeBackticks = spokenCodeBackticks
    }

    /// The settings saved in `defaults`, with the app's defaults for those never set (fillers removed, fix off,
    /// spoken code on, in backticks).
    public static func saved(in defaults: UserDefaults?) -> Self {
        Self(language: defaults?.string(forKey: languageKey).flatMap { $0.isEmpty ? nil : $0 },
             removeFillers: defaults?.object(forKey: removeFillersKey) as? Bool ?? true,
             aiFix: defaults?.bool(forKey: aiFixKey) ?? false,
             spokenCode: defaults?.object(forKey: spokenCodeKey) as? Bool ?? true,
             spokenCodeBackticks: defaults?.object(forKey: spokenCodeBackticksKey) as? Bool ?? true)
    }
}

/// Run Again (docs/design.md "Dictation audio and Run Again"): recognizes a saved dictation's audio as live dictation
/// recognizes the microphone (the same recognizer, locale, and vocabulary, fed the saved frames in order), then runs
/// the text steps of live dictation with the current settings, and compares the result with what History kept.
/// Nothing is written into any app and nothing is copied.
public enum DictationRerun {
    /// The text steps for the current settings, and, when the fix was asked for but cannot run, why not.
    /// `spokenCode` writes spoken paths and commands as code, in backticks when `backticks` (never for a dictation
    /// typed into a terminal: `run`).
    public static func pipeline(language: String, removeFillers: Bool, corrections: CorrectionList,
                                aiFix: Bool, spokenCode: Bool = false, backticks: Bool = true)
        -> (pipeline: DictationTextPipeline, aiNote: String?) {
        var note: String?
        var fixer: TranscriptFixer?
        if aiFix {
            if let reason = OnDeviceFix.unavailableReason(language: language) {
                note = "unavailable: \(reason)"
            } else {
                OnDeviceFix.prewarm()
                fixer = OnDeviceFix.fixer(corrections: corrections, language: language)
            }
        }
        let coder = spokenCode
            ? OnDeviceFix.spokenCode(corrections: corrections, language: language, backticks: backticks) : nil
        return (DictationTextPipeline(language: language, removeFillers: removeFillers, corrections: corrections,
                                      fixer: fixer, coder: coder), note)
    }

    /// The recognizer's results for the audio at `url`, in order: the speech transcriber live dictation uses, with
    /// `vocabulary` as its contextual strings, fed the file as 0.1 s frames.
    public static func recognize(_ url: URL, locale: String, vocabulary: [String]) async throws -> [String] {
        let frames = try DictationAudioFile.frames(of: url)
        let session = try await AppleSpeechSession.make(locale: locale, backend: .speech,
                                                        contextualStrings: vocabulary) { _ in }
        do {
            for frame in frames {
                try Task.checkCancellation()
                try await session.append(frame)
            }
            try Task.checkCancellation()
            return try await session.finish().sorted { $0.start < $1.start }.map(\.text)
        } catch {
            await session.cancel()
            throw error
        }
    }

    /// Runs `record`'s audio (`url`) again through the recognizer and `pipeline`, and compares.
    /// A dictation for a terminal (`DictationRecord.terminal`, or for older records `SpokenCode.isTerminal`) gets its
    /// code tokens without backticks, as live dictation types them.
    public static func run(_ record: DictationRecord, audio url: URL, pipeline: DictationTextPipeline,
                           aiNote: String? = nil) async throws -> DictationRerunReport {
        var pipeline = pipeline
        if record.terminal == true || SpokenCode.isTerminal(appName: record.app) { pipeline.coder?.backticks = false }
        let segments = try await recognize(url, locale: pipeline.language,
                                           vocabulary: pipeline.corrections.vocabulary(language: pipeline.language))
        let output = await pipeline.run(segments: segments)
        return DictationRerunReport(record: record, output: output, pipeline: pipeline, aiNote: aiNote)
    }

    /// The record as Update History keeps it: the new text as heard and as written, the fixes, and the language; the
    /// rest (date, app, outcome, audio) stays. The part not written of a partly written dictation no longer applies.
    public static func updated(_ record: DictationRecord, with report: DictationRerunReport) -> DictationRecord {
        var updated = DictationRecord(
            id: record.id, date: record.date, app: record.app, language: report.languageNow, text: report.written.now,
            heard: report.heard.now.isEmpty ? report.written.now : report.heard.now, fixes: report.fixes,
            outcome: record.outcome, seconds: record.seconds, audio: record.audio, terminal: record.terminal)
        updated.schemaVersion = record.schemaVersion
        return updated
    }
}
