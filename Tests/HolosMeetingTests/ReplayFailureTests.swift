import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// A replay that fails after partial progress keeps what it already transcribed (docs/meeting-design.md §4.6).

/// A finished archive with mic audio at 0–2 s and 4–6 s (two chunks, a 2 s gap between them, so replay uses two speech
/// sessions). At 8 kHz a replay buffer is 0.512 s.
private func gappedArchive(in root: URL) async throws -> SessionArchive {
    let archive = try SessionArchive.create(root: root, name: "Replay", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    let writer = AudioChunkWriter(archive: archive)
    for second in [0, 1, 4, 5] {
        let frame = try PCMFrame(samples: [Float](repeating: 0.1, count: 8_000), sampleRate: 8_000, channels: 1,
                                 startTime: Double(second))
        try await writer.append(CapturedAudio(track: "mic", frame: frame))
    }
    try await writer.finish()
    try await archive.finish(status: ArchiveStatus.complete)
    return archive
}

/// Replays the mic track and returns the `ReplayIncomplete` it must throw.
private func incompleteReplay(_ archive: SessionArchive, _ speech: FakeSpeechFactory,
                              timeouts: StopTimeouts? = nil) async throws -> ReplayIncomplete {
    do {
        let segments = try await TrackReplayer.replay(directory: archive.directory, track: "mic", locale: "en-CA",
                                                      backend: .speech, makeSpeech: speech.factory, timeouts: timeouts)
        Issue.record("The replay returned \(segments.map(\.text)) instead of failing.")
    } catch let partial as ReplayIncomplete {
        return partial
    }
    throw CancellationError()
}

@Test(.timeLimit(.minutes(1)))
func replayKeepsEarlierSessionsWhenTheNextCannotStart() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let archive = try await gappedArchive(in: temp.url)
    let speech = FakeSpeechFactory([
        FakeSpeechScript(segments: [TranscriptSegment(start: 0.2, end: 0.5, text: "Before the gap")]),
        FakeSpeechScript(makeError: .unavailable("Speech assets were removed.")),
    ])
    let partial = try await incompleteReplay(archive, speech)
    #expect(partial.segments.map(\.text) == ["Before the gap"])
    #expect(partial.segments.map(\.start) == [0.2])
    #expect(partial.segments.allSatisfy { $0.track == "mic" })
    #expect(partial.message == HolosError.unavailable("Speech assets were removed.").localizedDescription)
}

@Test(.timeLimit(.minutes(1)))
func replayKeepsReportedFinalsWhenAppendFails() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let archive = try await gappedArchive(in: temp.url)
    // "Roll call" is final after the first buffer; the third append fails.
    let speech = FakeSpeechFactory([
        FakeSpeechScript(segments: [TranscriptSegment(start: 0.1, end: 0.4, text: "Roll call"),
                                    TranscriptSegment(start: 1.6, end: 1.9, text: "Never reached")],
                         appendError: .io("The speech service stopped."), appendErrorAfter: 1.0),
    ])
    let partial = try await incompleteReplay(archive, speech)
    #expect(partial.segments.map(\.text) == ["Roll call"])
    #expect(partial.segments.map(\.start) == [0.1])
    #expect(partial.message == HolosError.io("The speech service stopped.").localizedDescription)
    #expect(await speech.sessions.first?.cancelled == true, "The failed session is cancelled.")
}

@Test(.timeLimit(.minutes(1)))
func replayKeepsEarlierSessionsAndReportedFinalsWhenFinishFails() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let archive = try await gappedArchive(in: temp.url)
    let speech = FakeSpeechFactory([
        FakeSpeechScript(segments: [TranscriptSegment(start: 0.2, end: 0.5, text: "First session")]),
        // "Seconded" is final while fed; "Carried" would come only from finish(), which fails.
        FakeSpeechScript(segments: [TranscriptSegment(start: 0.1, end: 0.4, text: "Seconded"),
                                    TranscriptSegment(start: 1.9, end: 2.5, text: "Carried")],
                         finishError: .io("Recognition failed.")),
    ])
    let partial = try await incompleteReplay(archive, speech)
    #expect(partial.segments.map(\.text) == ["First session", "Seconded"])
    #expect(partial.segments.map(\.start) == [0.2, 4.1], "The failed session's finals are on the session timeline.")
}

@Test(.timeLimit(.minutes(1)))
func replayKeepsReportedFinalsWhenFinishTimesOut() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let archive = try await gappedArchive(in: temp.url)
    let speech = FakeSpeechFactory([
        FakeSpeechScript(segments: [TranscriptSegment(start: 0.1, end: 0.4, text: "Roll call")], finishHangs: true),
    ])
    let timeouts = StopTimeouts(speechFinishBase: .milliseconds(200), speechFinishPerAudioSecond: 0)
    let partial = try await incompleteReplay(archive, speech, timeouts: timeouts)
    #expect(partial.segments.map(\.text) == ["Roll call"])
    #expect(partial.message.hasPrefix("Speech did not respond within 0.2 s"))
}

@Test(.timeLimit(.minutes(1)))
func finishedReplayCountsFinalsOnce() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let archive = try await gappedArchive(in: temp.url)
    let speech = FakeSpeechFactory([
        FakeSpeechScript(segments: [TranscriptSegment(start: 0.1, end: 0.4, text: "One")]),
        FakeSpeechScript(segments: [TranscriptSegment(start: 0.1, end: 0.4, text: "Two")]),
    ])
    let segments = try await TrackReplayer.replay(directory: archive.directory, track: "mic", locale: "en-CA",
                                                  backend: .speech, makeSpeech: speech.factory)
    #expect(segments.map(\.text) == ["One", "Two"])
    #expect(segments.map(\.start) == [0.1, 4.1])
}
