import Foundation
import Testing
@testable import HolosStorage

@Test func sessionPathsFollowTheDocumentedLayout() {
    let session = URL(fileURLWithPath: "/data/3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10.holos", isDirectory: true)
    func relative(_ url: URL) -> String {
        String(url.path.dropFirst(session.path.count + 1))
    }
    let expected: [(URL, String)] = [
        (SessionPaths.manifest(session), "manifest.json"),
        (SessionPaths.events(session), "events.jsonl"),
        (SessionPaths.meetingInfo(session), "meeting.json"),
        (SessionPaths.vocabulary(session), "vocabulary.json"),
        (SessionPaths.status(session), "status.json"),
        (SessionPaths.controlDirectory(session), "control"),
        (SessionPaths.postprocess(session), "postprocess.json"),
        (SessionPaths.audioDeleted(session), "audio-deleted.json"),
        (SessionPaths.transcripts(session), "transcripts"),
        (SessionPaths.transcript("T1", in: session), "transcripts/T1.json"),
        (SessionPaths.transcriptPointer(session), "transcripts/current.json"),
        (SessionPaths.pendingTranscript(session), "transcripts/current.pending"),
        (SessionPaths.runs(session), "speakers/runs"),
        (SessionPaths.run("R1", in: session), "speakers/runs/R1.json"),
        (SessionPaths.head(session), "speakers/head.json"),
        (SessionPaths.edits(session), "speakers/edits.jsonl"),
        (SessionPaths.voiceDirectory(session), "speakers/voice"),
        (SessionPaths.voiceData("R1", in: session), "speakers/voice/R1.json"),
        (SessionPaths.recognition("R1", in: session), "speakers/recognition/R1.json"),
        (SessionPaths.exports(session), "exports"),
        (SessionPaths.export("md", in: session), "exports/transcript.md"),
        (SessionPaths.generatedExports(session), "exports/.generated.json"),
        (SessionPaths.derived(session), "derived"),
        (SessionPaths.render(track: "system", in: session), "derived/system-16k.caf"),
    ]
    for (url, path) in expected {
        #expect(relative(url) == path)
    }
    #expect(SessionPaths.controlDirectory(session).hasDirectoryPath)
    #expect(!SessionPaths.manifest(session).hasDirectoryPath)
}
