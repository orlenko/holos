import Foundation
import HolosCore
import HolosMeeting
import HolosStorage
import HolosTestSupport
import Testing

private struct ComparisonRecognizer: DeepTranscriber {
    let engine = "fixture"
    func promptTokenCount(_ text: String) async throws -> Int { 0 }
    func transcribe(_ request: DeepTranscriptionRequest,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [DeepTranscribedSegment] {
        #expect(request.language == "en")
        #expect(request.prompt.isEmpty && request.recordedWords.isEmpty)
        #expect(!request.samples.isEmpty)
        return [.init(text: "candidate words", start: 0.1, end: 0.8)]
    }
}

@Test func comparisonReadsSavedAudioAndPreservesEveryArchiveFileIncludingSpeakerEdits() async throws {
    let temp = try TemporaryDirectory("comparison")
    defer { temp.remove() }
    let (session, transcript, _) = try await SessionFixtures.labelledSession(in: temp.url, duration: 5)
    try SessionFixtures.appendEdits([.rename(speakerID: "system:S1", name: "Fixture")], session: session)
    let before = SessionFixtures.files(in: session)
    let result = try await SessionCompareRecognitionCommand.run(session: session) { ComparisonRecognizer() }
    #expect(result.current == transcript.text)
    #expect(result.candidate == "system\ncandidate words")
    #expect(SessionFixtures.files(in: session) == before)
    #expect(!ForgetResumeScope.applies(to: ["session", "compare-recognition", session.path, "--json"]))
}

@Test func comparisonRejectsAnUnfinishedArchiveBeforeLoadingAModel() async throws {
    let temp = try TemporaryDirectory("unfinished-comparison")
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Generated", source: .microphone,
                                           locale: "en-US", backend: .speech)
    await #expect(throws: HolosError.self) {
        try await SessionCompareRecognitionCommand.run(session: archive.directory) {
            Issue.record("Loaded a model while recording")
            return ComparisonRecognizer()
        }
    }
    try await archive.finish(status: ArchiveStatus.audioOnly)
}
