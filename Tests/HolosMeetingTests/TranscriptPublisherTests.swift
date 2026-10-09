import Foundation
import HolosCore
@testable import HolosMeeting
import HolosStorage
import HolosTestSupport
import Testing

// `TranscriptPublisher` failing at each step, for each kind of publication the stages and Review make. The expected
// state after each failure follows the write order those callers rely on (the staged run, the rebased revision and its
// event, the publication's event, the pointer, the head), stopping at the first step that throws, and which failures
// each caller reports as published. Transcripts are invented word lists.

/// The publications that go through `TranscriptPublisher`, as each caller makes them.
enum PublisherKind: String, CaseIterable, Sendable {
    /// `LanguageStage`: `languagesDetected`, no head, saved directly.
    case languages
    /// `DeepTranscriptionStage`: `deepTranscribed`, no head, saved directly.
    case deep
    /// `WordFixStage`: `wordsFixed`, the head carried over, saved directly.
    case wordFix
    /// `LiveHintStage`: the rebased revision and its `liveHintsApplied` first, then `liveHintsApplied`, the head
    /// carried over, saved directly.
    case liveHints
    /// `SessionWordFixRevert`: `wordsFixed`, the head carried over, saved through `TranscriptPointerSave`.
    case revert
    /// `SessionWordEdit.run`: the new base revision and its `transcriptEdited` first, then `transcriptEdited`, the head
    /// carried over, saved through `TranscriptPointerSave`.
    case wordEdit
    /// Every head repair: the head carried over to the transcript already current.
    case repair

    var eventKind: String? {
        switch self {
        case .languages: MeetingEventKind.languagesDetected
        case .deep: MeetingEventKind.deepTranscribed
        case .wordFix, .revert: MeetingEventKind.wordsFixed
        case .liveHints: MeetingEventKind.liveHintsApplied
        case .wordEdit: MeetingEventKind.transcriptEdited
        case .repair: nil
        }
    }

    var retargets: Bool { self != .languages && self != .deep }
    var hasRevision: Bool { self == .liveHints || self == .wordEdit }
    var savesThroughPointer: Bool { self == .revert || self == .wordEdit }
}

/// Where a publication fails: a step `TranscriptPublisher.beforeStep` names, a save that throws after the pointer was
/// renamed (`TranscriptPointerSave.afterSave`), or a head written before its folder sync failed
/// (`SpeakerTranscriptRetarget.afterHeadWritten`).
enum PublisherFault: String, CaseIterable, Sendable {
    case none, stage, revision, event, save, afterSave, head, afterHeadWritten

    func applies(to kind: PublisherKind) -> Bool {
        switch self {
        case .none: true
        case .stage, .head, .afterHeadWritten: kind.retargets
        case .revision: kind.hasRevision
        case .event, .save: kind != .repair
        case .afterSave: kind.savesThroughPointer
        }
    }
}

struct PublisherCase: Sendable, CustomTestStringConvertible {
    var kind: PublisherKind
    var fault: PublisherFault
    var testDescription: String { "\(kind.rawValue) failing at \(fault.rawValue)" }

    static let all: [PublisherCase] = PublisherKind.allCases.flatMap { kind in
        PublisherFault.allCases.filter { $0.applies(to: kind) }.map { PublisherCase(kind: kind, fault: $0) }
    }
}

/// The session after a publication, and how it ended.
private struct PublisherState: Equatable, CustomStringConvertible {
    enum Ending: Equatable { case published, thrown, committed, headFailed }
    var staged: Bool
    var revisionSaved: Bool
    /// The journal's new events: kind and transcript.
    var events: [String]
    var pointerIsNew: Bool
    var headIsNew: Bool
    var ending: Ending
    var description: String {
        "staged \(staged), revision \(revisionSaved), events \(events), pointer new \(pointerIsNew), "
            + "head new \(headIsNew), \(ending)"
    }
}

private struct InjectedFault: Error {}
private struct CommittedFailure: Error { var underlying: any Error }
private struct HeadFailure: Error { var underlying: any Error }

/// The session after `fault` (see the comment at the top). A repair writes only the run and the head, and its errors
/// are thrown as they are.
private func expected(_ kind: PublisherKind, _ fault: PublisherFault, revision: String, published: String)
    -> PublisherState {
    // [staged, revision and its event, event, pointer, head]
    let done: [Bool]
    let ending: PublisherState.Ending
    switch fault {
    case .none: (done, ending) = ([true, true, true, true, true], .published)
    case .stage: (done, ending) = ([false, false, false, false, false], .thrown)
    case .revision: (done, ending) = ([true, false, false, false, false], .thrown)
    case .event: (done, ending) = ([true, true, false, false, false], .thrown)
    case .save: (done, ending) = ([true, true, true, false, false], .thrown)
    case .afterSave: (done, ending) = ([true, true, true, true, false], .committed)
    case .head: (done, ending) = ([true, true, true, true, false], kind == .repair ? .thrown : .headFailed)
    case .afterHeadWritten: (done, ending) = ([true, true, true, true, true], kind == .repair ? .thrown : .headFailed)
    }
    var events: [String] = []
    if kind.hasRevision, done[1], let event = kind.eventKind { events.append("\(event) \(revision)") }
    if done[2], let event = kind.eventKind { events.append("\(event) \(published)") }
    return PublisherState(staged: kind.retargets && done[0], revisionSaved: kind.hasRevision && done[1],
                          events: events, pointerIsNew: kind == .repair || done[3],
                          headIsNew: kind.retargets && done[4], ending: ending)
}

@Test(.timeLimit(.minutes(1)), arguments: PublisherCase.all)
func publicationFailingAtEachStepStopsThereAndReportsWhatWasPublished(_ test: PublisherCase) async throws {
    let temp = try TemporaryDirectory("publisher")
    defer { temp.remove() }
    let (session, old, run) = try await SessionFixtures.labelledSession(in: temp.url)
    let new = SessionFixtures.transcript(old.segments)
    let revision = SessionFixtures.transcript(old.segments)
    var carried = run
    carried.id = UUID().uuidString
    carried.transcriptID = new.id
    let plan = SpeakerTranscriptRetarget.Plan(run: carried, edits: [], recognition: nil, voiceData: nil)
    if test.kind == .repair { try await SessionFixtures.saveTranscript(new, in: session) }
    let eventsBefore = try SessionArchive.readEvents(at: session).events.count

    let kind = test.kind
    let fault = test.fault
    let decision: TranscriptPublisher.Decision<Void>
    if kind == .repair {
        decision = .repairHead(plan, now: SessionFixtures.date, ())
    } else {
        let eventKind = try #require(kind.eventKind)
        var change = TranscriptPublisher.Change(
            transcript: new, event: .init(kind: eventKind, details: ["transcriptID": new.id, "base": old.id]),
            retarget: kind.retargets ? plan : nil, now: SessionFixtures.date,
            headFailed: { HeadFailure(underlying: $0) })
        if kind.hasRevision {
            change.revision = (revision, .init(kind: eventKind, details: ["transcriptID": revision.id, "base": old.id]))
        }
        if kind.savesThroughPointer { change.committed = { CommittedFailure(underlying: $0) } }
        decision = .publish(change, ())
    }

    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let step: TranscriptPublisher.Step? = switch fault {
    case .stage: .stage
    case .revision: .revision
    case .event: .event
    case .save: .save
    case .head: .head
    case .none, .afterSave, .afterHeadWritten: nil
    }
    var ending = PublisherState.Ending.published
    do {
        try await TranscriptPublisher.$beforeStep.withValue({ if $0 == step { throw InjectedFault() } }) {
            try await TranscriptPointerSave.$afterSave.withValue({ if fault == .afterSave { throw InjectedFault() } }) {
                try await SpeakerTranscriptRetarget.$afterHeadWritten.withValue({
                    if fault == .afterHeadWritten { throw InjectedFault() }
                }) {
                    try await TranscriptPublisher.publish(session: session, lease: lease) { decision }
                }
            }
        }
    } catch let error as CommittedFailure {
        #expect(error.underlying is InjectedFault)
        ending = .committed
    } catch let error as HeadFailure {
        #expect(error.underlying is InjectedFault)
        ending = .headFailed
    } catch is InjectedFault {
        ending = .thrown
    }

    let events = try SessionArchive.readEvents(at: session).events.dropFirst(eventsBefore)
    let state = PublisherState(
        staged: (try? SessionSpeakerStore.readRun(id: carried.id, session: session)) != nil,
        revisionSaved: (try? SessionFiles.transcript(id: revision.id, session: session)) != nil,
        events: events.map { "\($0.kind) \($0.details["transcriptID"] ?? "")" },
        pointerIsNew: try SessionArchive.currentTranscriptID(at: session) == new.id,
        headIsNew: try SessionSpeakerStore.readHead(session: session)?.runID == carried.id,
        ending: ending)
    #expect(state == expected(kind, fault, revision: revision.id, published: new.id))
    // Released however it ended: both locks are free again.
    #expect(try !SessionArchive.isActive(at: session))
    try SessionArchive.withSpeakerLock(at: session, timeout: .zero) {}
}
