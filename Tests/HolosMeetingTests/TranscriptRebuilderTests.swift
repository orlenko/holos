import Darwin
import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// TranscriptRebuilder and the `holos session recover` chain (docs/meeting-design.md §5.6 PR3).

// MARK: - Helpers

/// `transcriptFinalized` details as LiveTrack journals them; `words: false` gives the pre-PR2 form (no segmentID, no
/// words).
private func rebuilderFinal(_ segment: TranscriptSegment, track: String, words: Bool = true) throws -> [String: String] {
    var details = ["track": track, "text": segment.text, "start": String(segment.start), "end": String(segment.end)]
    if words {
        details["segmentID"] = segment.id
        details["words"] = String(decoding: try HolosJSON.encoder(pretty: false).encode(segment.words), as: UTF8.self)
    }
    return details
}

/// A segment with the given words, each 0.3 s long, their offsets into the space-joined text.
private func rebuilderSegment(_ words: [(String, Double)], start: Double, end: Double,
                              id: String = UUID().uuidString) -> TranscriptSegment {
    var text = ""
    var timed: [TimedWord] = []
    for (word, at) in words {
        if !text.isEmpty { text += " " }
        timed.append(TimedWord(text: word, start: at, end: at + 0.3, utf16Offset: text.utf16.count,
                               utf16Length: word.utf16.count))
        text += word
    }
    return TranscriptSegment(id: id, start: start, end: end, text: text, words: timed)
}

/// A session in `root` whose recorder wrote `audio` seconds per track (constant quiet 16 kHz audio in 30 s chunks)
/// and journaled `events`, then stopped: with `finish` nil it is left as a recorder that died leaves it (manifest
/// `recording`, no lock held); otherwise the archive is finished with that status.
private func rebuilderSession(in root: URL, source: AudioSource = .microphone, audio: [String: Double] = [:],
                              rate: Double = 16_000, events: [(String, [String: String])] = [],
                              meeting: MeetingMode? = nil,
                              finish: String? = ArchiveStatus.interrupted) async throws -> URL {
    let archive = try SessionArchive.create(root: root, name: "Council", source: source, locale: "en-CA",
                                            backend: .speech)
    if let meeting {
        try AtomicFile.writeJSON(MeetingInfo(sessionID: archive.id, mode: meeting, othersInRoom: false),
                                 to: SessionPaths.meetingInfo(archive.directory))
    }
    let writer = AudioChunkWriter(archive: archive)
    for (track, seconds) in audio.sorted(by: { $0.key < $1.key }) {
        var start = 0.0
        while seconds - start > 1e-9 {
            let length = min(30, seconds - start)
            let samples = [Float](repeating: 0.01, count: Int((length * rate).rounded()))
            let frame = try PCMFrame(samples: samples, sampleRate: rate, channels: 1, startTime: start)
            try await writer.append(CapturedAudio(track: track, frame: frame))
            start += length
        }
    }
    try await writer.finish()
    for (kind, details) in events { try await archive.recordEvent(kind: kind, details: details) }
    if let finish { try await archive.finish(status: finish) }
    return archive.directory
}

private func rebuilderFinals(_ segments: [TranscriptSegment], track: String = "mic",
                             words: Bool = true) throws -> [(String, [String: String])] {
    try segments.map { (MeetingEventKind.transcriptFinalized, try rebuilderFinal($0, track: track, words: words)) }
}

/// The current transcript revision.
private func rebuilderCurrent(_ session: URL) throws -> Transcript {
    let id = try #require(try SessionArchive.currentTranscriptID(at: session))
    return try AtomicFile.readJSON(Transcript.self, from: SessionPaths.transcript(id, in: session))
}

private func rebuilderEvents(_ session: URL, _ kind: String) throws -> [ArchiveEvent] {
    try SessionArchive.readEvents(at: session).events.filter { $0.kind == kind }
}

/// Transcript revision files (not the pointer).
private func rebuilderRevisions(_ session: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: SessionPaths.transcripts(session).path)
        .filter { $0.hasSuffix(".json") && $0 != "current.json" }
}

private func rebuilderAppendRaw(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
}

/// Runs a rebuild under a lease of its own, released afterwards.
private func rebuilderRun(_ session: URL, force: Bool = false, transcribe: Bool = false,
                          speech: FakeSpeechFactory = FakeSpeechFactory()) async throws -> RebuildReport {
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    return try await TranscriptRebuilder.rebuild(session: session, lease: lease, force: force, transcribe: transcribe,
                                                 makeSpeech: speech.factory)
}

private func isHolosError(_ error: HolosError?, _ kind: String) -> Bool {
    switch error {
    case .unavailable?: kind == "unavailable"
    case .invalidInput?: kind == "invalidInput"
    case .incomplete?: kind == "incomplete"
    default: false
    }
}

// MARK: - Journal

@Test func rebuildUsesJournalWordsAndSegmentIDs() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let segments = [
        SessionFixtures.segment(["one", "two", "three"], track: "mic", start: 1),
        SessionFixtures.segment(["four", "five"], track: "mic", start: 5),
        SessionFixtures.segment(["six"], track: "mic", start: 9),
    ]
    // The second phrase is journaled twice (an exact duplicate): it is kept once.
    let events = try rebuilderFinals(segments) + rebuilderFinals([segments[1]])
    let session = try await rebuilderSession(in: temp.url, events: events)

    let report = try await rebuilderRun(session)
    let transcript = try rebuilderCurrent(session)
    #expect(transcript.id == report.transcriptID)
    #expect(transcript.segments.map(\.id) == segments.map(\.id))
    #expect(transcript.segments.map(\.words) == segments.map(\.words))
    #expect(transcript.segments.map(\.text) == segments.map(\.text))
    #expect(transcript.segments.allSatisfy { $0.track == "mic" })
    #expect(transcript.locale == "en-CA" && transcript.backend == .speech)
    #expect(report.journalSegments == 3)
    #expect(!report.reused)
    #expect(try SessionArchive.readManifest(at: session).status == ArchiveStatus.recovered)
    let rebuilt = try #require(try rebuilderEvents(session, MeetingEventKind.transcriptRebuilt).last)
    #expect(rebuilt.details["transcriptID"] == transcript.id)
    #expect(rebuilt.details["journalSegments"] == "3")
    #expect(rebuilt.details["replayedSeconds"] == "0.0")
}

@Test func legacyEventsProduceUntimedSegments() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let segments = [SessionFixtures.segment(["hello", "there"], track: "mic", start: 2),
                    SessionFixtures.segment(["again"], track: "mic", start: 6)]
    let session = try await rebuilderSession(in: temp.url, events: try rebuilderFinals(segments, words: false))
    let report = try await rebuilderRun(session)
    let transcript = try rebuilderCurrent(session)
    #expect(report.journalSegments == 2)
    #expect(transcript.segments.map(\.text) == ["hello there", "again"])
    #expect(transcript.segments.map(\.start) == [2, 6])
    #expect(transcript.segments.allSatisfy { $0.words.isEmpty })
    #expect(Set(transcript.segments.map(\.id)).count == 2)
    #expect(transcript.segments.allSatisfy { UUID(uuidString: $0.id) != nil })
}

@Test func tornJournalTailIsTolerated() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let segments = [SessionFixtures.segment(["kept"], track: "mic", start: 1),
                    SessionFixtures.segment(["also", "kept"], track: "mic", start: 4)]
    // The recorder died in the middle of a journal write.
    let session = try await rebuilderSession(in: temp.url, events: try rebuilderFinals(segments), finish: nil)
    try rebuilderAppendRaw(#"{"at":"2026-09-24T10:00:00Z","details":{"text":"lost"#, to: SessionPaths.events(session))
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    await #expect(throws: HolosError.self) {
        try await TranscriptRebuilder.rebuild(session: session, lease: lease, transcribe: false)
    }
    let recovery = try await SessionArchive.recover(at: session, lease: lease)
    #expect(recovery.manifest?.status == ArchiveStatus.interrupted)
    #expect(!recovery.tornFinalJournalLine)
    let report = try await TranscriptRebuilder.rebuild(session: session, lease: lease, transcribe: false)
    #expect(report.journalSegments == 2)
    #expect(try rebuilderCurrent(session).segments.map(\.text) == ["kept", "also kept"])
    let backups = try FileManager.default.contentsOfDirectory(atPath: session.path)
        .filter { $0.hasPrefix("events.before-recovery-") }
    #expect(backups.count == 1, "Recovery keeps the torn journal as a backup.")
}

@Test func corruptMiddleLineIsTolerated() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let first = SessionFixtures.segment(["before"], track: "mic", start: 1)
    let second = SessionFixtures.segment(["after"], track: "mic", start: 5)
    let archive = try SessionArchive.create(root: temp.url, name: "Council", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    let session = archive.directory
    try await archive.recordEvent(kind: MeetingEventKind.transcriptFinalized, details: try rebuilderFinal(first, track: "mic"))
    try rebuilderAppendRaw("this line is garbage\n", to: SessionPaths.events(session))
    try await archive.recordEvent(kind: MeetingEventKind.transcriptFinalized, details: try rebuilderFinal(second, track: "mic"))
    try await archive.finish(status: ArchiveStatus.interrupted)
    #expect(try SessionArchive.readEvents(at: session).unreadableLines == 1)

    let report = try await rebuilderRun(session)
    #expect(report.journalSegments == 2)
    #expect(try rebuilderCurrent(session).segments.map(\.id) == [first.id, second.id])
}

// MARK: - Coverage and replay

@Test func coverageIsLastFinalizedEnd() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let segments = [rebuilderSegment([("a", 35.2), ("b", 39.5)], start: 35, end: 40.0),
                    rebuilderSegment([("c", 50.1), ("d", 54.8)], start: 50, end: 55.2)]
    let session = try await rebuilderSession(in: temp.url, source: .microphoneAndSystem,
                                             events: try rebuilderFinals(segments))
    let report = try await rebuilderRun(session)
    #expect(report.coverageEnd == ["mic": 55.2, "system": 0])
    #expect(report.replayedSeconds == ["mic": 0, "system": 0])
}

@Test func coverageStopsAtBehindEvent() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let segments = [rebuilderSegment([("a", 10.1)], start: 10, end: 12),
                    rebuilderSegment([("b", 50.1), ("c", 54.8)], start: 50, end: 55.2)]
    let events = try rebuilderFinals(segments) + [
        (MeetingEventKind.transcriptionBehind, ["track": "mic", "from": "40.0", "reason": "journalFull"]),
        (MeetingEventKind.transcriptionBehind, ["track": "mic", "from": "30.0", "reason": "overflow"]),
    ]
    let session = try await rebuilderSession(in: temp.url, events: events)
    let report = try await rebuilderRun(session)
    #expect(report.coverageEnd == ["mic": 30])
    // Without transcription nothing replaces the phrases after the hole, so they are all kept.
    #expect(try rebuilderCurrent(session).segments.count == 2)
}

@Test func uncoveredTailIsReplayedAtWordLevel() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let journal = [rebuilderSegment([("x", 40.2), ("y", 44.1)], start: 40, end: 45),
                   rebuilderSegment([("a", 50.2), ("b", 52.0), ("c", 54.8)], start: 50, end: 55.2)]
    let session = try await rebuilderSession(in: temp.url, audio: ["mic": 60], events: try rebuilderFinals(journal))
    // Replay starts 2 s before coverage (53.2); the fake reports times from its own first frame.
    let replayed = rebuilderSegment([("alpha", 0.4), ("bravo", 1.6), ("charlie", 2.2), ("delta", 3.8)],
                                    start: 0.3, end: 4.8)
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: [replayed])])

    let report = try await rebuilderRun(session, transcribe: true, speech: speech)
    #expect(report.coverageEnd == ["mic": 55.2])
    #expect(abs((report.replayedSeconds["mic"] ?? 0) - 6.8) < 1e-6)
    #expect(speech.calls.count == 1)
    let frames = try #require(await speech.sessions.first?.frameStarts)
    #expect(frames.first == 0, "Speech sessions are rebased to 0.")

    let transcript = try rebuilderCurrent(session)
    let words = transcript.segments.flatMap(\.words)
    #expect(words.map(\.text) == ["x", "y", "a", "b", "c", "charlie", "delta"], "Only 55.4 and 57.0 are added.")
    let starts = words.map(\.start)
    #expect(abs(starts[5] - 55.4) < 1e-6 && abs(starts[6] - 57.0) < 1e-6)
    #expect(zip(starts, starts.dropFirst()).allSatisfy { $0 < $1 }, "No word appears twice.")
    let tail = try #require(transcript.segments.last)
    #expect(tail.text == "charlie delta")
    #expect(tail.words.map(\.utf16Offset) == [0, 8])
    #expect(tail.id != replayed.id, "The cut-off part of a replayed segment gets a new ID.")
    #expect(transcript.segments.prefix(2).map(\.id) == journal.map(\.id))
}

@Test func rebuildPassesTheSessionVocabulary() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let session = try await rebuilderSession(in: temp.url, audio: ["mic": 5])
    try AtomicFile.writeJSON(MeetingVocabulary(strings: ["Maria Chen"]), to: SessionPaths.vocabulary(session))
    let speech = FakeSpeechFactory()
    let report = try await rebuilderRun(session, transcribe: true, speech: speech)
    #expect(speech.calls.map(\.contextualStrings) == [["Maria Chen"]])
    #expect(report.coverageEnd == ["mic": 0])
    #expect(abs((report.replayedSeconds["mic"] ?? 0) - 5) < 1e-6, "No phrase was journaled: all of it is replayed.")
}

@Test func replayedSecondsCountOverlappingChunksOnce() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let journal = [SessionFixtures.segment(["early"], track: "mic", start: 11.5)]
    let session = try await rebuilderSession(in: temp.url, audio: ["mic": 60], events: try rebuilderFinals(journal))
    // An older archive: the second 30 s chunk overlaps the first, at 15–45.
    var manifest = try SessionArchive.readManifest(at: session)
    let second = try #require(manifest.chunks.firstIndex { $0.start == 30 })
    manifest.chunks[second].start = 15
    manifest.chunks[second].end = 45
    try AtomicFile.writeJSON(manifest, to: SessionPaths.manifest(session))
    #expect(manifest.savedSeconds == 45, "Time both chunks hold is saved once.")
    #expect(manifest.audioSeconds(track: "mic", from: 10) == 35)

    let speech = FakeSpeechFactory()
    let report = try await rebuilderRun(session, transcribe: true, speech: speech)
    // Coverage 12: replay from 10 feeds 10–30, then 30–45 of the overlapping chunk.
    #expect(report.coverageEnd == ["mic": 12])
    var fed = 0.0
    for session in speech.sessions { fed += await session.fedSeconds }
    #expect(abs(fed - 35) < 1e-3, "The replayer skips the overlap.")
    #expect(abs((report.replayedSeconds["mic"] ?? 0) - 35) < 1e-6, "Not 20 + 30.")
    let event = try #require(try rebuilderEvents(session, MeetingEventKind.transcriptRebuilt).last)
    #expect(event.details["replayedSeconds"].flatMap(Double.init).map { abs($0 - 35) < 1e-6 } == true)
}

@Test func failedReplayPublishesNothing() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let journal = [SessionFixtures.segment(["kept"], track: "mic", start: 1)]
    let session = try await rebuilderSession(in: temp.url, audio: ["mic": 4], events: try rebuilderFinals(journal))
    let speech = FakeSpeechFactory([FakeSpeechScript(appendError: .unavailable("Speech assets are missing."))])
    #expect(isHolosError(await #expect(throws: HolosError.self) {
        try await rebuilderRun(session, transcribe: true, speech: speech)
    }, "incomplete"))
    #expect(try SessionArchive.currentTranscriptID(at: session) == nil)
    #expect(try SessionArchive.readManifest(at: session).status == ArchiveStatus.interrupted)
    #expect(try rebuilderEvents(session, MeetingEventKind.transcriptRebuilt).isEmpty)
    #expect(try !SessionArchive.isActive(at: session))
    // The saved phrases alone still make a transcript.
    let report = try await rebuilderRun(session, transcribe: false)
    #expect(report.journalSegments == 1)
}

@Test func rebuildAfterDeletedAudioUsesTheJournalOnly() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let journal = [SessionFixtures.segment(["only", "words"], track: "mic", start: 1)]
    let session = try await rebuilderSession(in: temp.url, audio: ["mic": 4], events: try rebuilderFinals(journal))
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    try SessionDeletion.deleteAudio(session: session, lease: lease)
    lease.release()
    let speech = FakeSpeechFactory()
    let report = try await rebuilderRun(session, transcribe: true, speech: speech)
    #expect(speech.calls.isEmpty, "There is no audio to transcribe.")
    #expect(report.replayedSeconds == ["mic": 0])
    #expect(try rebuilderCurrent(session).segments.map(\.id) == journal.map(\.id))
}

// MARK: - Locks and idempotence

@Test func rebuildSavesWhileHoldingItsOwnLease() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let session = try await rebuilderSession(in: temp.url, events: try rebuilderFinals(
        [SessionFixtures.segment(["hi"], track: "mic", start: 1)]))
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    let report = try await TranscriptRebuilder.rebuild(session: session, lease: lease, transcribe: false)
    #expect(try SessionArchive.currentTranscriptID(at: session) == report.transcriptID)
    #expect(try !SessionArchive.isActive(at: session), "The writer lock is free afterwards.")
    #expect(try SessionArchive.isProcessing(at: session), "The caller's lease is still held.")
    lease.release()
    #expect(try !SessionArchive.isProcessing(at: session))
}

@Test func recoveryIsIdempotent() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let session = try await rebuilderSession(in: temp.url, source: .microphoneAndSystem, events: try rebuilderFinals(
        [rebuilderSegment([("a", 1.1)], start: 1, end: 2)]))
    let first = try await rebuilderRun(session)
    let second = try await rebuilderRun(session)
    #expect(!first.reused)
    #expect(second.reused)
    #expect(second.transcriptID == first.transcriptID)
    #expect(second.journalSegments == first.journalSegments)
    #expect(second.coverageEnd == first.coverageEnd)
    #expect(second.replayedSeconds == first.replayedSeconds)
    #expect(try rebuilderEvents(session, MeetingEventKind.transcriptRebuilt).count == 1)
    #expect(try rebuilderRevisions(session).count == 1)

    // --force rebuilds again; a later recovery makes the next rebuild real too.
    let forced = try await rebuilderRun(session, force: true)
    #expect(!forced.reused && forced.transcriptID != first.transcriptID)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    let maintenance = try SessionArchive.openForMaintenance(at: session, lease: lease)
    try await maintenance.recordEvent(kind: MeetingEventKind.archiveRecovered, details: [:])
    try await maintenance.finish(status: ArchiveStatus.interrupted)
    lease.release()
    let afterRecovery = try await rebuilderRun(session)
    #expect(!afterRecovery.reused)
    #expect(try rebuilderEvents(session, MeetingEventKind.transcriptRebuilt).count == 3)
    #expect(try rebuilderRevisions(session).count == 3)
}

@Test func rebuildWithoutTranscriptionIsNotReusedWhenTranscriptionIsAsked() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let session = try await rebuilderSession(in: temp.url, audio: ["mic": 4], events: try rebuilderFinals(
        [rebuilderSegment([("a", 1.1)], start: 1, end: 1.5)]))
    let phrasesOnly = try await rebuilderRun(session, transcribe: false)
    #expect(try rebuilderEvents(session, MeetingEventKind.transcriptRebuilt).last?.details["transcribed"] == "false")
    // Speech is available now: the uncovered audio is transcribed after all.
    let speech = FakeSpeechFactory()
    let transcribed = try await rebuilderRun(session, transcribe: true, speech: speech)
    #expect(!transcribed.reused && transcribed.transcriptID != phrasesOnly.transcriptID)
    #expect(speech.calls.count == 1)
    #expect((transcribed.replayedSeconds["mic"] ?? 0) > 3)
    // A transcribed rebuild answers both kinds of request.
    #expect(try await rebuilderRun(session, transcribe: true, speech: speech).reused)
    #expect(try await rebuilderRun(session, transcribe: false).reused)
    #expect(speech.calls.count == 1)
}

@Test func rebuildRefusesActiveRecording() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Live", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    let session = archive.directory
    let status = RecorderStatus(sessionID: archive.id, name: "Live", pid: getpid(), phase: .recording, sequence: 3,
                                startedAt: Date().addingTimeInterval(-60), updatedAt: Date(), source: .microphone)
    try AtomicFile.writeJSON(status, to: SessionPaths.status(session))
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    #expect(isHolosError(await #expect(throws: HolosError.self) {
        try await TranscriptRebuilder.rebuild(session: session, lease: lease, transcribe: false)
    }, "unavailable"))
    #expect(try SessionArchive.currentTranscriptID(at: session) == nil)
    #expect(try RecorderChannel.readStatus(session: session)?.phase == .recording, "A live recorder's status stays.")
    try await archive.finish(status: ArchiveStatus.complete)
}

@Test func rebuildRefusesAnArchiveThatIsNotRecovered() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let session = try await rebuilderSession(in: temp.url, events: try rebuilderFinals(
        [SessionFixtures.segment(["hi"], track: "mic", start: 1)]), finish: nil)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    #expect(isHolosError(await #expect(throws: HolosError.self) {
        try await TranscriptRebuilder.rebuild(session: session, lease: lease, transcribe: false)
    }, "invalidInput"))
    #expect(try SessionArchive.readManifest(at: session).status == ArchiveStatus.recording)
    #expect(try SessionArchive.currentTranscriptID(at: session) == nil)
}

// MARK: - The recover chain

/// A thread-safe log of what a step callback saw.
private struct RecoveryProbe: Sendable, Equatable {
    var step: SessionRecoveryCommand.Step
    var leaseRefused: Bool
    var processing: Bool
}

/// An in-person meeting whose recorder died: 20 s of mic audio and four journaled phrases of two speakers, with a
/// status.json the dead recorder left.
private func rebuilderDeadMeeting(in root: URL) async throws -> URL {
    let phrases = SessionFixtures.alternatingSegments(track: "mic")
    let session = try await rebuilderSession(in: root, audio: ["mic": 20], events: try rebuilderFinals(phrases),
                                             meeting: .inPerson, finish: nil)
    let id = session.deletingPathExtension().lastPathComponent
    let stale = Date().addingTimeInterval(-120)
    try AtomicFile.writeJSON(RecorderStatus(sessionID: id, name: "Council", pid: Int32.max, phase: .recording,
                                            sequence: 40, startedAt: stale, updatedAt: stale, source: .microphone),
                             to: SessionPaths.status(session))
    return session
}

private func rebuilderDiarizer() -> FakeDiarizer {
    FakeDiarizer(outputs: ["mic": SessionFixtures.alternatingOutput()])
}

@Test(.timeLimit(.minutes(1)))
func recoverRebuildAndPostProcessUnderOneLease() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let session = try await rebuilderDeadMeeting(in: temp.url)
    let probes = SharedValue<[RecoveryProbe]>([])
    let outcome = try await SessionRecoveryCommand.run(
        SessionRecoveryCommand.Request(session: session), diarizer: rebuilderDiarizer(),
        makeSpeech: FakeSpeechFactory().factory, freeSpace: FixedFreeSpace(.max),
        step: { step in
            // Another descriptor tries the lease after each step.
            let refused = (try? SessionArchive.acquireProcessingLease(at: session, retry: .zero)) == nil
            let processing = (try? SessionArchive.isProcessing(at: session)) ?? false
            probes.update { $0.append(RecoveryProbe(step: step, leaseRefused: refused, processing: processing)) }
        })

    #expect(probes.value.map(\.step) == [.recovered, .rebuilt, .postProcessed])
    #expect(probes.value.allSatisfy { $0.leaseRefused && $0.processing }, "Every attempt is refused.")
    #expect(try !SessionArchive.isProcessing(at: session), "The lease is released at the end.")
    #expect(try !SessionArchive.isActive(at: session))

    #expect(outcome.exitCode == 0)
    #expect(outcome.warnings.isEmpty)
    #expect(outcome.recovery.manifest?.status == ArchiveStatus.interrupted)
    #expect(outcome.status == ArchiveStatus.recovered, "The outcome reports the status at the end of the chain.")
    let rebuild = try #require(outcome.rebuild)
    #expect(rebuild.journalSegments == 4)
    let record = try #require(outcome.postProcessing)
    #expect(record.state == .succeeded)
    #expect(record.transcriptID == rebuild.transcriptID)
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID == record.runID)
    #expect(try SessionArchive.readManifest(at: session).status == ArchiveStatus.recovered)
    #expect(try RecorderChannel.readStatus(session: session)?.phase == .exited, "The dead recorder is marked exited.")
    #expect(try RecorderChannel.readStatus(session: session)?.exit?.archiveStatus == ArchiveStatus.interrupted)
    #expect(outcome.summary.hasPrefix("Recovered 1 chunk (0:00:20). Transcript rebuilt from 4 saved phrases; transcribed"))
    #expect(outcome.summary.hasSuffix("Speaker labels: 2 speakers."))
    for ext in ["md", "json", "txt"] {
        #expect(FileManager.default.fileExists(atPath: SessionPaths.export(ext, in: session).path))
    }
}

@Test(.timeLimit(.minutes(1)))
func recoverTwiceChangesNothing() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let session = try await rebuilderDeadMeeting(in: temp.url)
    let request = SessionRecoveryCommand.Request(session: session)
    let first = try await SessionRecoveryCommand.run(request, diarizer: rebuilderDiarizer(),
                                                     makeSpeech: FakeSpeechFactory().factory,
                                                     freeSpace: FixedFreeSpace(.max))
    let files = SessionFixtures.files(in: session).filter { !$0.key.hasPrefix(".") && $0.key != "status.json" }
    let steps = SharedValue<[SessionRecoveryCommand.Step]>([])
    let second = try await SessionRecoveryCommand.run(request, diarizer: rebuilderDiarizer(),
                                                      makeSpeech: FakeSpeechFactory().factory,
                                                      freeSpace: FixedFreeSpace(.max),
                                                      step: { step in steps.update { $0.append(step) } })
    #expect(first.exitCode == 0 && second.exitCode == 0)
    #expect(second.rebuild?.reused == true)
    #expect(second.rebuild?.transcriptID == first.rebuild?.transcriptID)
    #expect(second.postProcessing == nil, "Labels of the same transcript are not made again.")
    #expect(steps.value == [.recovered, .rebuilt])
    #expect(second.summary.contains("The transcript was already rebuilt from 4 saved phrases."))
    #expect(second.summary.hasSuffix("Speaker labels are up to date."))
    #expect(SessionFixtures.files(in: session).filter { !$0.key.hasPrefix(".") && $0.key != "status.json" } == files)
}

@Test(.timeLimit(.minutes(1)))
func recoverRelabelsWhenTheSavedLabelsAreUnusable() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let session = try await rebuilderDeadMeeting(in: temp.url)
    let request = SessionRecoveryCommand.Request(session: session)
    let first = try await SessionRecoveryCommand.run(request, diarizer: rebuilderDiarizer(),
                                                     makeSpeech: FakeSpeechFactory().factory,
                                                     freeSpace: FixedFreeSpace(.max))
    let transcriptID = try #require(first.rebuild?.transcriptID)
    #expect(first.postProcessing?.runID != nil)

    // postprocess.json still says the labels of this transcript succeeded, but the saved labels are not usable.
    let damages: [(String, () throws -> Void)] = [
        ("the head is missing", {
            try FileManager.default.removeItem(at: SessionPaths.head(session))
        }),
        ("the head's run file is damaged", {
            let runID = try #require(try SessionSpeakerStore.readHead(session: session)?.runID)
            let url = SessionPaths.run(runID, in: session)
            try FileManager.default.removeItem(at: url)
            try Data("not json".utf8).write(to: url)
        }),
        ("the head's run belongs to another transcript", {
            let runID = try #require(try SessionSpeakerStore.readHead(session: session)?.runID)
            var other = try SessionSpeakerStore.readRun(id: runID, session: session)
            other.id = UUID().uuidString
            other.transcriptID = UUID().uuidString
            try SessionArchive.withSpeakerLock(at: session) {
                try SessionSpeakerStore.writeRun(other, session: session)
                try SessionSpeakerStore.writeHead(SpeakerHead(runID: other.id), session: session)
            }
        }),
    ]
    for (damage, apply) in damages {
        try apply()
        let steps = SharedValue<[SessionRecoveryCommand.Step]>([])
        let outcome = try await SessionRecoveryCommand.run(request, diarizer: rebuilderDiarizer(),
                                                           makeSpeech: FakeSpeechFactory().factory,
                                                           freeSpace: FixedFreeSpace(.max),
                                                           step: { step in steps.update { $0.append(step) } })
        #expect(outcome.rebuild?.reused == true, "\(damage)")
        #expect(steps.value == [.recovered, .rebuilt, .postProcessed], "\(damage): the speakers are labelled again.")
        #expect(!outcome.summary.contains("up to date"), "\(damage)")
        #expect(outcome.summary.hasSuffix("Speaker labels: 2 speakers."), "\(damage)")
        let head = try #require(try SessionSpeakerStore.readHead(session: session), "\(damage)")
        #expect(try SessionSpeakerStore.readRun(id: head.runID, session: session).transcriptID == transcriptID,
                "\(damage): the new head labels the current transcript.")
    }
}

@Test(.timeLimit(.minutes(1)))
func recoverLeavesACompleteSessionAlone() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic"))
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: transcript)
    let outcome = try await SessionRecoveryCommand.run(SessionRecoveryCommand.Request(session: session),
                                                       diarizer: rebuilderDiarizer(),
                                                       makeSpeech: FakeSpeechFactory().factory,
                                                       freeSpace: FixedFreeSpace(.max))
    #expect(outcome.exitCode == 0)
    #expect(outcome.rebuild == nil && outcome.postProcessing == nil)
    #expect(outcome.summary == "Recovered 1 chunk (0:00:20). Nothing to rebuild: the meeting is complete. "
        + "Use --force to rebuild its transcript anyway.")
    #expect(try SessionArchive.currentTranscriptID(at: session) == transcript.id)
    #expect(try SessionArchive.readManifest(at: session).status == ArchiveStatus.complete)
    #expect(!FileManager.default.fileExists(atPath: SessionPaths.postprocess(session).path))
}

@Test(.timeLimit(.minutes(1)))
func recoverWithoutSpeakerModelsStillSucceeds() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let session = try await rebuilderDeadMeeting(in: temp.url)
    let outcome = try await SessionRecoveryCommand.run(SessionRecoveryCommand.Request(session: session, transcribe: false),
                                                       diarizer: nil, freeSpace: FixedFreeSpace(.max))
    #expect(outcome.exitCode == 0)
    #expect(outcome.rebuild?.replayedSeconds == ["mic": 0])
    #expect(outcome.summary.contains("Transcript rebuilt from 4 saved phrases. No speaker labels: speaker models are not installed."))
    #expect(outcome.postProcessing?.runID == nil)
}

@Test(.timeLimit(.minutes(1)))
func recoverTwiceWithoutSpeakerModelsChangesNothing() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let session = try await rebuilderDeadMeeting(in: temp.url)
    let request = SessionRecoveryCommand.Request(session: session, transcribe: false)
    let first = try await SessionRecoveryCommand.run(request, diarizer: nil, freeSpace: FixedFreeSpace(.max))
    #expect(first.postProcessing?.runID == nil)
    let files = SessionFixtures.files(in: session).filter { !$0.key.hasPrefix(".") && $0.key != "status.json" }
    let second = try await SessionRecoveryCommand.run(request, diarizer: nil, freeSpace: FixedFreeSpace(.max))
    #expect(second.exitCode == 0)
    #expect(second.postProcessing == nil, "Post-processing does not run again while nothing can label.")
    let message = try #require(first.postProcessing?.message)
    #expect(message.hasPrefix("No speaker labels: speaker models are not installed."))
    #expect(second.summary.hasSuffix(message), "The reason (with the setup hint) is repeated.")
    #expect(SessionFixtures.files(in: session).filter { !$0.key.hasPrefix(".") && $0.key != "status.json" } == files,
            "postprocess.json is not rewritten.")
    // With a diarizer the same meeting is labelled after all.
    let third = try await SessionRecoveryCommand.run(request, diarizer: rebuilderDiarizer(),
                                                     freeSpace: FixedFreeSpace(.max))
    #expect(third.postProcessing?.runID != nil)
}

/// A recording that stopped with transcription unfinished: the recorder saved a transcript of `saved` and journaled
/// `journal`, with live transcription behind from 6 s.
private func rebuilderTranscriptionIncomplete(in root: URL, saved: [TranscriptSegment]?,
                                              journal: [TranscriptSegment]) async throws -> URL {
    let archive = try SessionArchive.create(root: root, name: "Council", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    let writer = AudioChunkWriter(archive: archive)
    let frame = try PCMFrame(samples: [Float](repeating: 0.01, count: 16_000 * 20), sampleRate: 16_000, channels: 1,
                             startTime: 0)
    try await writer.append(CapturedAudio(track: "mic", frame: frame))
    try await writer.finish()
    for (kind, details) in try rebuilderFinals(journal) { try await archive.recordEvent(kind: kind, details: details) }
    try await archive.recordEvent(kind: MeetingEventKind.transcriptionBehind,
                                  details: ["track": "mic", "from": "6.0", "reason": "overflow"])
    if let saved {
        try await archive.saveTranscript(Transcript(source: archive.directory.path, locale: "en-CA", backend: .speech,
                                                    segments: saved), writeLegacyExports: false)
    }
    try await archive.finish(status: ArchiveStatus.transcriptionIncomplete)
    return archive.directory
}

@Test(.timeLimit(.minutes(1)))
func recoverKeepsTheTranscriptSavedAtStop() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let journal = [SessionFixtures.segment(["one", "two"], track: "mic", start: 1),
                   SessionFixtures.segment(["three"], track: "mic", start: 4)]
    let saved = journal + [SessionFixtures.segment(["partially", "replayed"], track: "mic", start: 8)]
    let session = try await rebuilderTranscriptionIncomplete(in: temp.url, saved: saved, journal: journal)
    let before = try rebuilderCurrent(session)

    let outcome = try await SessionRecoveryCommand.run(
        SessionRecoveryCommand.Request(session: session, transcribe: false, postProcess: false), diarizer: nil)
    #expect(outcome.exitCode == 0)
    #expect(outcome.rebuild == nil)
    #expect(outcome.summary.contains("Nothing to rebuild: the meeting is transcriptionIncomplete and keeps the "
        + "transcript saved when it stopped."))
    #expect(try rebuilderCurrent(session) == before)
    #expect(try rebuilderCurrent(session).segments.map(\.text) == ["one two", "three", "partially replayed"])
    #expect(try SessionArchive.readManifest(at: session).status == ArchiveStatus.transcriptionIncomplete)
    #expect(outcome.status == ArchiveStatus.transcriptionIncomplete)

    // --force still rebuilds it from the saved phrases.
    let forced = try await SessionRecoveryCommand.run(
        SessionRecoveryCommand.Request(session: session, transcribe: false, postProcess: false, force: true),
        diarizer: nil)
    #expect(forced.rebuild?.journalSegments == 2)
    #expect(try rebuilderCurrent(session).segments.map(\.text) == ["one two", "three"])
}

@Test(.timeLimit(.minutes(1)))
func recoverRebuildsATranscriptionIncompleteSessionWithoutATranscript() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let journal = [SessionFixtures.segment(["one", "two"], track: "mic", start: 1)]
    let session = try await rebuilderTranscriptionIncomplete(in: temp.url, saved: nil, journal: journal)
    let outcome = try await SessionRecoveryCommand.run(
        SessionRecoveryCommand.Request(session: session, transcribe: false, postProcess: false), diarizer: nil)
    #expect(outcome.rebuild?.journalSegments == 1)
    #expect(try rebuilderCurrent(session).segments.map(\.text) == ["one two"])
    #expect(outcome.status == ArchiveStatus.recovered)
}

/// A recorder that stopped capturing and died before `finish`: 20 s of mic audio, the first two phrases of
/// `SessionFixtures.alternatingSegments` journaled, manifest `processing`, no lock held. With `saveAll` it had saved
/// the transcript of all four phrases (text transcribed at stop that the journal lacks); returns that transcript.
private func rebuilderDiedWhileProcessing(in root: URL, saveAll: Bool = true) async throws -> (URL, Transcript?) {
    let archive = try SessionArchive.create(root: root, name: "Council", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    try AtomicFile.writeJSON(MeetingInfo(sessionID: archive.id, mode: .inPerson, othersInRoom: false),
                             to: SessionPaths.meetingInfo(archive.directory))
    let writer = AudioChunkWriter(archive: archive)
    let frame = try PCMFrame(samples: [Float](repeating: 0.01, count: 16_000 * 20), sampleRate: 16_000, channels: 1,
                             startTime: 0)
    try await writer.append(CapturedAudio(track: "mic", frame: frame))
    try await writer.finish()
    let phrases = SessionFixtures.alternatingSegments(track: "mic")
    for (kind, details) in try rebuilderFinals(Array(phrases.prefix(2))) {
        try await archive.recordEvent(kind: kind, details: details)
    }
    try await archive.setStatus(ArchiveStatus.processing)
    var saved: Transcript?
    if saveAll {
        let transcript = Transcript(source: archive.directory.path, locale: "en-CA", backend: .speech, segments: phrases)
        try await archive.saveTranscript(transcript, writeLegacyExports: false)
        saved = transcript
    }
    return (archive.directory, saved)
    // The archive is released here, which lets its writer lock go without finishing it.
}

@Test(.timeLimit(.minutes(1)), arguments: [true, false])
func recoverKeepsTheTranscriptSavedBeforeFinish(transcribe: Bool) async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let (session, saved) = try await rebuilderDiedWhileProcessing(in: temp.url)
    let before = try rebuilderCurrent(session)
    #expect(before.id == saved?.id)
    let request = SessionRecoveryCommand.Request(session: session, transcribe: transcribe, postProcess: false)

    let outcome = try await SessionRecoveryCommand.run(request, diarizer: nil, makeSpeech: FakeSpeechFactory().factory)
    #expect(outcome.exitCode == 0)
    #expect(outcome.rebuild == nil, "The transcript saved at stop is kept, not rebuilt from 2 saved phrases.")
    #expect(outcome.summary.contains("Nothing to rebuild: the recorder was interrupted after it stopped capturing "
        + "and keeps the transcript saved when it stopped."))
    #expect(try rebuilderCurrent(session) == before)
    #expect(try rebuilderRevisions(session).count == 1)
    #expect(outcome.status == ArchiveStatus.interrupted)
    let recovered = try #require(try rebuilderEvents(session, MeetingEventKind.archiveRecovered).last)
    #expect(recovered.details["previousStatus"] == ArchiveStatus.processing)

    // Run again: the manifest now says interrupted, and the journal still says it was processing.
    let again = try await SessionRecoveryCommand.run(request, diarizer: nil, makeSpeech: FakeSpeechFactory().factory)
    #expect(again.rebuild == nil)
    #expect(try rebuilderCurrent(session) == before)

    // --force rebuilds it from the saved phrases.
    let forced = try await SessionRecoveryCommand.run(
        SessionRecoveryCommand.Request(session: session, transcribe: transcribe, postProcess: false, force: true),
        diarizer: nil, makeSpeech: FakeSpeechFactory().factory)
    #expect(forced.rebuild?.journalSegments == 2)
    #expect(try rebuilderCurrent(session).segments.count == 2)
    #expect(forced.status == ArchiveStatus.recovered)
}

@Test(.timeLimit(.minutes(1)))
func recoverLabelsTheTranscriptSavedBeforeFinish() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let (session, saved) = try await rebuilderDiedWhileProcessing(in: temp.url)
    let savedID = try #require(saved?.id)
    let steps = SharedValue<[SessionRecoveryCommand.Step]>([])
    let outcome = try await SessionRecoveryCommand.run(
        SessionRecoveryCommand.Request(session: session), diarizer: rebuilderDiarizer(),
        makeSpeech: FakeSpeechFactory().factory, freeSpace: FixedFreeSpace(.max),
        step: { step in steps.update { $0.append(step) } })
    #expect(outcome.exitCode == 0)
    #expect(outcome.rebuild == nil)
    #expect(steps.value == [.recovered, .postProcessed], "Its post-processing never ran, so recover labels it.")
    #expect(outcome.postProcessing?.transcriptID == savedID)
    #expect(outcome.summary.hasSuffix("Speaker labels: 2 speakers."))
    #expect(try SessionArchive.currentTranscriptID(at: session) == savedID)

    let second = try await SessionRecoveryCommand.run(
        SessionRecoveryCommand.Request(session: session, transcribe: false), diarizer: rebuilderDiarizer(),
        freeSpace: FixedFreeSpace(.max))
    #expect(second.rebuild == nil && second.postProcessing == nil, "Labels of the same transcript are kept.")
    #expect(second.summary.hasSuffix("Speaker labels are up to date."))
}

@Test(.timeLimit(.minutes(1)))
func recoverRebuildsAProcessingSessionWithoutATranscript() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let (session, _) = try await rebuilderDiedWhileProcessing(in: temp.url, saveAll: false)
    let outcome = try await SessionRecoveryCommand.run(
        SessionRecoveryCommand.Request(session: session, transcribe: false, postProcess: false), diarizer: nil)
    #expect(outcome.rebuild?.journalSegments == 2)
    #expect(try rebuilderCurrent(session).segments.count == 2)
    #expect(outcome.status == ArchiveStatus.recovered)
}

@Test func stoppedCapturingReadsTheRecoveryThatMarkedTheStatus() throws {
    func recovered(_ sequence: Int, _ previous: String) throws -> ArchiveEvent {
        let line = #"{"sequence":\#(sequence),"at":"2026-09-24T10:00:00Z","kind":"\#(MeetingEventKind.archiveRecovered)","#
            + #""details":{"chunks":"","unrecovered":"","previousStatus":"\#(previous)"}}"#
        return try HolosJSON.decoder().decode(ArchiveEvent.self, from: Data(line.utf8))
    }
    #expect(SessionRecoveryCommand.stoppedCapturing([try recovered(1, ArchiveStatus.processing)]))
    #expect(SessionRecoveryCommand.stoppedCapturing([try recovered(1, ArchiveStatus.processing),
                                                     try recovered(2, ArchiveStatus.interrupted)]),
            "A later recovery that found it interrupted does not hide why.")
    #expect(!SessionRecoveryCommand.stoppedCapturing([try recovered(1, ArchiveStatus.recording)]))
    #expect(!SessionRecoveryCommand.stoppedCapturing([]))
}

@Test func rebuildThatCannotBeRecordedKeepsTheTranscript() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let journal = [SessionFixtures.segment(["kept"], track: "mic", start: 1)]
    let session = try await rebuilderSession(in: temp.url, events: try rebuilderFinals(journal))
    // The manifest is replaced through a new file in the session folder; a read-only folder makes that fail, while
    // transcripts/ and the existing journal stay writable.
    // The lease is taken first: its lock file is new.
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    #expect(chmod(session.path, 0o500) == 0)
    let report: RebuildReport
    do {
        defer {
            chmod(session.path, 0o700)
            lease.release()
        }
        report = try await TranscriptRebuilder.rebuild(session: session, lease: lease, transcribe: false)
    }
    #expect(report.recordingError != nil)
    #expect(try SessionArchive.currentTranscriptID(at: session) == report.transcriptID, "The transcript is current.")
    #expect(try SessionArchive.readManifest(at: session).status == ArchiveStatus.interrupted)
    #expect(try !SessionArchive.isActive(at: session), "The writer lock is let go.")
    // Nothing recorded the rebuild, so the next one is done again.
    let again = try await rebuilderRun(session)
    #expect(!again.reused && again.recordingError == nil)
    #expect(try SessionArchive.readManifest(at: session).status == ArchiveStatus.recovered)
}

@Test(.timeLimit(.minutes(1)))
func recoverRefusedWhileAnotherProcessHoldsTheLease() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let session = try await rebuilderDeadMeeting(in: temp.url)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    #expect(isHolosError(await #expect(throws: HolosError.self) {
        try await SessionRecoveryCommand.run(SessionRecoveryCommand.Request(session: session), diarizer: nil)
    }, "unavailable"))
    #expect(try SessionArchive.readManifest(at: session).status == ArchiveStatus.recording, "Nothing changed.")
}

// MARK: - Unreadable and newer files

/// Replaces the file at `url` (transcript revisions are read-only) with `data`.
private func rebuilderReplace(_ url: URL, with data: Data) throws {
    try? FileManager.default.removeItem(at: url)
    try data.write(to: url)
}

/// Rewrites the JSON object at `url` as a newer Holos would: `schemaVersion` 2 and a field this build does not know.
/// Returns the new bytes.
@discardableResult
private func rebuilderMakeNewer(_ url: URL) throws -> Data {
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    object["schemaVersion"] = 2
    object["newerField"] = "kept"
    let data = try JSONSerialization.data(withJSONObject: object)
    try rebuilderReplace(url, with: data)
    return data
}

/// Damages the transcript revision `transcriptID`: "truncated" (cut in half), "garbage" (not JSON), or "otherID"
/// (valid, but it names another revision).
private func rebuilderDamage(_ session: URL, transcriptID: String, _ damage: String) throws {
    let url = SessionPaths.transcript(transcriptID, in: session)
    let data = try Data(contentsOf: url)
    switch damage {
    case "truncated":
        try rebuilderReplace(url, with: data.prefix(data.count / 2))
    case "garbage":
        try rebuilderReplace(url, with: Data("not json".utf8))
    default:
        var transcript = try HolosJSON.decoder().decode(Transcript.self, from: data)
        transcript.id = UUID().uuidString
        try rebuilderReplace(url, with: try HolosJSON.encoder().encode(transcript))
    }
}

@Test(arguments: ["truncated", "garbage", "otherID"])
func rebuildReplacesAnUnreadableCurrentRevision(damage: String) async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let session = try await rebuilderSession(in: temp.url, events: try rebuilderFinals(
        [rebuilderSegment([("a", 1.1)], start: 1, end: 2)]))
    let first = try await rebuilderRun(session)
    try rebuilderDamage(session, transcriptID: first.transcriptID, damage)
    // The pointer and the rebuild event still name the damaged revision.
    #expect(try SessionArchive.currentTranscriptID(at: session) == first.transcriptID)

    let second = try await rebuilderRun(session)
    #expect(!second.reused, "A \(damage) current revision is not reused.")
    #expect(second.transcriptID != first.transcriptID)
    #expect(try rebuilderCurrent(session).id == second.transcriptID)
    #expect(try SessionFiles.readableCurrentTranscriptID(session: session) == second.transcriptID)
    #expect(try rebuilderEvents(session, MeetingEventKind.transcriptRebuilt).count == 2)
    #expect(try await rebuilderRun(session).reused, "The readable rebuild is reused again.")
}

@Test(.timeLimit(.minutes(1)))
func recoverWithoutPostProcessingRepairsAnUnreadableRebuiltTranscript() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let session = try await rebuilderDeadMeeting(in: temp.url)
    let request = SessionRecoveryCommand.Request(session: session, transcribe: false, postProcess: false)
    let first = try await SessionRecoveryCommand.run(request, diarizer: nil)
    let firstID = try #require(first.rebuild?.transcriptID)
    try rebuilderDamage(session, transcriptID: firstID, "truncated")

    let second = try await SessionRecoveryCommand.run(request, diarizer: nil)
    #expect(second.exitCode == 0)
    #expect(second.rebuild?.reused == false)
    #expect(second.rebuild?.transcriptID != firstID)
    #expect(try rebuilderCurrent(session).segments.count == 4, "The session has a readable transcript again.")
}

@Test(arguments: ["pointer", "revision"], [false, true])
func rebuildRefusesANewerCurrentTranscript(file: String, force: Bool) async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let session = try await rebuilderSession(in: temp.url, events: try rebuilderFinals(
        [rebuilderSegment([("a", 1.1)], start: 1, end: 2)]))
    let first = try await rebuilderRun(session)
    let url = file == "pointer" ? SessionPaths.transcriptPointer(session)
        : SessionPaths.transcript(first.transcriptID, in: session)
    let newer = try rebuilderMakeNewer(url)
    let pointer = try Data(contentsOf: SessionPaths.transcriptPointer(session))

    let error = await #expect(throws: HolosError.self) { try await rebuilderRun(session, force: force) }
    #expect(isHolosError(error, "unavailable"), "A newer \(file) is refused, force \(force).")
    #expect(error?.localizedDescription.contains("newer Holos") == true)
    #expect(try Data(contentsOf: url) == newer, "The newer file is not replaced.")
    #expect(try Data(contentsOf: SessionPaths.transcriptPointer(session)) == pointer, "The pointer is not moved.")
    #expect(try rebuilderRevisions(session).count == 1)
    #expect(try rebuilderEvents(session, MeetingEventKind.transcriptRebuilt).count == 1)
}

@Test func rebuildRefusesANewerVocabulary() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let session = try await rebuilderSession(in: temp.url, audio: ["mic": 5])
    try AtomicFile.writeJSON(MeetingVocabulary(strings: ["Maria Chen"]), to: SessionPaths.vocabulary(session))
    let newer = try rebuilderMakeNewer(SessionPaths.vocabulary(session))
    let speech = FakeSpeechFactory()
    #expect(isHolosError(await #expect(throws: HolosError.self) {
        try await rebuilderRun(session, transcribe: true, speech: speech)
    }, "unavailable"))
    #expect(speech.calls.isEmpty, "Nothing is transcribed without the vocabulary.")
    #expect(try SessionArchive.currentTranscriptID(at: session) == nil)
    #expect(try Data(contentsOf: SessionPaths.vocabulary(session)) == newer)
    // A damaged vocabulary only loses its hints.
    try rebuilderReplace(SessionPaths.vocabulary(session), with: Data("not json".utf8))
    #expect(try TranscriptRebuilder.sessionVocabulary(session).isEmpty)
    // Without transcription the vocabulary is not read at all.
    try rebuilderReplace(SessionPaths.vocabulary(session), with: newer)
    #expect(try await !rebuilderRun(session, transcribe: false).reused)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func recoverRefusesANewerPostProcessingRecord(force: Bool) async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let session = try await rebuilderDeadMeeting(in: temp.url)
    let first = try await SessionRecoveryCommand.run(
        SessionRecoveryCommand.Request(session: session), diarizer: rebuilderDiarizer(),
        makeSpeech: FakeSpeechFactory().factory, freeSpace: FixedFreeSpace(.max))
    #expect(first.postProcessing?.state == .succeeded)
    let newer = try rebuilderMakeNewer(SessionPaths.postprocess(session))
    let head = try Data(contentsOf: SessionPaths.head(session))

    // Without force the rebuild is reused and the record read; with force a new transcript would be labelled.
    let steps = SharedValue<[SessionRecoveryCommand.Step]>([])
    let error = await #expect(throws: HolosError.self) {
        try await SessionRecoveryCommand.run(
            SessionRecoveryCommand.Request(session: session, force: force), diarizer: rebuilderDiarizer(),
            makeSpeech: FakeSpeechFactory().factory, freeSpace: FixedFreeSpace(.max),
            step: { step in steps.update { $0.append(step) } })
    }
    #expect(isHolosError(error, "unavailable"))
    #expect(error?.localizedDescription.contains("newer Holos") == true)
    #expect(error?.localizedDescription.hasPrefix("The archive was recovered") == true)
    #expect(!steps.value.contains(.postProcessed))
    #expect(try Data(contentsOf: SessionPaths.postprocess(session)) == newer, "postprocess.json is never overwritten.")
    #expect(try Data(contentsOf: SessionPaths.head(session)) == head)
    #expect(try !SessionArchive.isProcessing(at: session), "The lease is released.")
}

@Test(.timeLimit(.minutes(1)))
func postProcessingRefusesANewerRecordAndReplacesADamagedOne() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic"))
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: transcript)
    let url = SessionPaths.postprocess(session)
    try AtomicFile.writeJSON(PostProcessingRecord(sessionID: try SessionArchive.readManifest(at: session).id,
                                                  state: .succeeded, pid: 1, startedAt: Date(), updatedAt: Date()),
                             to: url)
    let newer = try rebuilderMakeNewer(url)
    let processor = MeetingPostProcessor(diarizer: rebuilderDiarizer(), freeSpace: FixedFreeSpace(.max))
    #expect(isHolosError(await #expect(throws: HolosError.self) {
        try await processor.run(session: session, lease: nil)
    }, "unavailable"))
    #expect(try Data(contentsOf: url) == newer)
    #expect(try SessionSpeakerStore.readHead(session: session) == nil, "Nothing was labelled.")

    try rebuilderReplace(url, with: Data("not json".utf8))
    let record = try await processor.run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(try SessionFiles.postProcessingRecord(session: session)?.state == .succeeded)
}

@Test(.timeLimit(.minutes(1)))
func recoverRebuildsAnUnreadableTranscriptSavedBeforeFinish() async throws {
    let temp = try TemporaryDirectory("rebuild")
    defer { temp.remove() }
    let (session, saved) = try await rebuilderDiedWhileProcessing(in: temp.url)
    try rebuilderDamage(session, transcriptID: try #require(saved?.id), "garbage")
    let request = SessionRecoveryCommand.Request(session: session, transcribe: false, postProcess: false)
    let outcome = try await SessionRecoveryCommand.run(request, diarizer: nil)
    #expect(outcome.rebuild?.reused == false, "A damaged transcript saved at stop is not kept.")
    #expect(outcome.rebuild?.journalSegments == 2)
    #expect(try rebuilderCurrent(session).segments.count == 2)

    // One from a newer Holos is refused and left as it is; the archive recovery stays.
    let (other, otherSaved) = try await rebuilderDiedWhileProcessing(in: temp.url)
    let revision = SessionPaths.transcript(try #require(otherSaved?.id), in: other)
    let newer = try rebuilderMakeNewer(revision)
    let pointer = try Data(contentsOf: SessionPaths.transcriptPointer(other))
    #expect(isHolosError(await #expect(throws: HolosError.self) {
        try await SessionRecoveryCommand.run(
            SessionRecoveryCommand.Request(session: other, transcribe: false, postProcess: false), diarizer: nil)
    }, "unavailable"))
    #expect(try Data(contentsOf: revision) == newer)
    #expect(try Data(contentsOf: SessionPaths.transcriptPointer(other)) == pointer)
    #expect(try SessionArchive.readManifest(at: other).status == ArchiveStatus.interrupted)
}
