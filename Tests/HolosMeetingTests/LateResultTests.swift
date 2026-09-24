import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// A timed wait that gives up on an operation still has to release what that operation makes once it returns
// (docs/meeting-design.md §4.6): a speech session created after its time limit is cancelled, never left running.

@Test(.timeLimit(.minutes(1))) @MainActor
func awaitWithTimeoutDiscardsAValueThatArrivesAfterTheTimeout() async {
    let discarded = SharedValue<[Int]>([])
    let outcome = await awaitWithTimeout(.milliseconds(50), discardingLate: { value in
        discarded.update { $0.append(value) }
    }) {
        await recorderWaitIgnoringCancellation(0.3)
        return 7
    }
    guard case .timedOut = outcome else {
        Issue.record("Expected a timeout, got \(outcome).")
        return
    }
    #expect(await eventually { discarded.value == [7] }, "The late value is handed to discardingLate.")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func awaitWithTimeoutDiscardsAValueThatArrivesAfterTheCallerWasCancelled() async {
    let discarded = SharedValue<[Int]>([])
    let waiting = Task {
        await awaitWithTimeout(.seconds(30), discardingLate: { value in discarded.update { $0.append(value) } }) {
            await recorderWaitIgnoringCancellation(0.3)
            return 9
        }
    }
    try? await Task.sleep(for: .milliseconds(20))
    waiting.cancel()
    guard case .cancelled = await waiting.value else {
        Issue.record("Expected the wait to end cancelled.")
        return
    }
    #expect(await eventually { discarded.value == [9] })
}

@Test(.timeLimit(.minutes(1))) @MainActor
func awaitWithTimeoutKeepsAValueThatArrivesInTime() async throws {
    let discarded = SharedValue<[Int]>([])
    let outcome = await awaitWithTimeout(.seconds(30), discardingLate: { value in
        discarded.update { $0.append(value) }
    }) { 3 }
    guard case .finished(let result) = outcome else {
        Issue.record("Expected the value, got \(outcome).")
        return
    }
    #expect(try result.get() == 3)
    try await Task.sleep(for: .milliseconds(50))
    #expect(discarded.value.isEmpty, "A value the caller received is never discarded.")
}

/// A replay whose speech session is created only after the start limit (the factory ignores cancellation) reports
/// the timeout, and the session is cancelled when it finally arrives.
@Test(.timeLimit(.minutes(1))) @MainActor
func replayCancelsASessionCreatedAfterItsStartTimeout() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Replay", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    let writer = AudioChunkWriter(archive: archive)
    let frame = try PCMFrame(samples: [Float](repeating: 0.1, count: 8_000), sampleRate: 8_000, channels: 1,
                             startTime: 0)
    try await writer.append(CapturedAudio(track: "mic", frame: frame))
    try await writer.finish()
    try await archive.finish(status: ArchiveStatus.complete)
    let speech = FakeSpeechFactory()
    let timeouts = StopTimeouts(speechFinishBase: .milliseconds(100), speechFinishPerAudioSecond: 0)
    do {
        let segments = try await TrackReplayer.replay(directory: archive.directory, track: "mic", locale: "en-CA",
                                                      backend: .speech,
                                                      makeSpeech: recorderLateSpeechFactory(speech, after: 0.4),
                                                      timeouts: timeouts)
        Issue.record("The replay returned \(segments.map(\.text)) instead of timing out.")
    } catch let partial as ReplayIncomplete {
        #expect(partial.message.hasPrefix("Speech did not start within 0.1 s"))
    }
    #expect(await eventually { speech.sessions.count == 1 }, "The factory does return, late.")
    let late = try #require(speech.sessions.first)
    #expect(await recorderEventually { await late.cancelled }, "The late session is cancelled, not left running.")
}

/// A live track cancelled while its speech factory is still making a session (and ignoring the cancellation)
/// cancels that session when it arrives, instead of feeding and finishing it.
@Test(.timeLimit(.minutes(1))) @MainActor
func liveTrackCancelsASessionCreatedAfterTheTrackWasCancelled() async throws {
    let speech = FakeSpeechFactory()
    let track = LiveTrack(track: "mic", locale: "en-CA", backend: .speech, contextualStrings: [],
                          makeSpeech: recorderLateSpeechFactory(speech, after: 0.4), events: { _, _ in },
                          reporter: CollectingReporter(), timeouts: StopTimeouts(speechFinishBase: .milliseconds(50)))
    // No prepared session: the speech task makes one for this frame.
    track.push(try PCMFrame(samples: [Float](repeating: 0.1, count: 1_600), sampleRate: 16_000, channels: 1,
                            startTime: 0), epoch: 0)
    // Waits at most 50 ms for the speech task, which is still inside the factory.
    await track.cancel()
    #expect(await eventually { speech.sessions.count == 1 }, "The factory does return, late.")
    let late = try #require(speech.sessions.first)
    #expect(await recorderEventually { await late.cancelled }, "The late session is cancelled.")
    #expect(await late.frameStarts.isEmpty, "Nothing is fed to it.")
}
