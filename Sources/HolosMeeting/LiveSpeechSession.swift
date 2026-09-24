import HolosCore
import HolosSpeech

/// A streaming speech session fed by one track. Only one task appends at a time.
public protocol LiveSpeechSession: Sendable {
    func append(_ frame: PCMFrame) async throws
    func finish() async throws -> [TranscriptSegment]
    func cancel() async
}

extension AppleSpeechSession: LiveSpeechSession {}

/// Creates one speech session. `contextualStrings` is the meeting vocabulary (docs/meeting-design.md §4.12);
/// `onUpdate` receives volatile and final results from any thread.
public typealias LiveSpeechFactory = @Sendable (_ locale: String, _ backend: SpeechBackend,
    _ contextualStrings: [String],
    _ onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void) async throws -> any LiveSpeechSession

/// `AppleSpeechSession.make` as a `LiveSpeechFactory`: the default outside tests.
let appleSpeechFactory: LiveSpeechFactory = { locale, backend, contextualStrings, onUpdate in
    try await AppleSpeechSession.make(locale: locale, backend: backend, contextualStrings: contextualStrings,
                                      onUpdate: onUpdate)
}
