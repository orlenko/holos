import Foundation
import HolosCore
import HolosStorage

/// The files that hold a session's speaker labels, read and validated one way for both the catalog
/// (`SessionCatalog.speakerLabels`) and recovery (`SessionRecoveryCommand.currentLabels`), so the two never disagree
/// about whether the saved labels can be used (docs/meeting-design.md §5.6).
///
/// Reads postprocess.json (versioned, and of this session) and speakers/head.json. When a head exists, the labels are
/// usable exactly when `SpeakerSessionSnapshot.load`, the loader the exports and speaker commands use, loads the
/// head's run: its run file and the transcript revision the run was built from exist and decode, and every span fits
/// that transcript. So the catalog and recovery never call labels usable that the exports would leave out.
///
/// A file that exists but cannot be read (damaged, of another session, written by a newer Holos, an I/O error) is a
/// problem, and so is one that another file names but that is missing: the head's run or its transcript, or the head
/// when postprocess.json names a run (labels load through the head, so a record whose head is gone has no usable
/// labels).
struct SavedSpeakerState {
    var record: PostProcessingRecord?
    var head: SpeakerHead?
    /// The run the head names, once `SpeakerSessionSnapshot.load` loaded it as the session's labels.
    var headRun: DiarizationRun?
    /// Why the saved labels cannot be used, in reading order; empty when every file that exists or is named can be
    /// read. Each keeps its `HolosError` kind: `unavailable` for a file from a newer Holos, `invalidInput` or
    /// `incomplete` for a damaged or missing one (`SessionFiles.isDamage`).
    var problems: [any Error] = []

    static func read(session: URL) -> SavedSpeakerState {
        var state = SavedSpeakerState()
        do { state.record = try SessionFiles.postProcessingRecord(session: session) } catch {
            state.problems.append(error)
        }
        let head: SpeakerHead?
        do { head = try SessionSpeakerStore.readHead(session: session) } catch {
            state.problems.append(error)
            return state
        }
        state.head = head
        guard let head else {
            if let runID = state.record?.runID {
                state.problems.append(HolosError.incomplete(
                    "postprocess.json names speaker run \(runID), but speakers/head.json is missing."))
            }
            return state
        }
        do {
            let snapshot = try SpeakerSessionSnapshot.load(session: session)
            if let run = snapshot.run, run.id == head.runID {
                state.headRun = run
            } else {
                state.problems.append(HolosError.invalidInput(
                    snapshot.runProblem ?? "speakers/head.json changed while it was read."))
            }
        } catch {
            state.problems.append(SessionFiles.prefixed(error, "The speaker labels cannot be loaded: "))
        }
        return state
    }

    /// The session has speaker labels the exports and the review window can use: the head's run loads as the labels
    /// and every file that exists or is named can be read. The one test for "labels are ready" (the naming offer, a
    /// finished meeting's `speakersReady`, the app's Label Speakers result).
    var labelsReady: Bool { problems.isEmpty && headRun != nil }

    /// The problem that forbids replacing the files: one written by a newer Holos (`unavailable`, schema rule 3,
    /// §1.6) first, else one that cannot be read now (not `SessionFiles.isDamage`). Nil when every problem is damage
    /// or a missing file, which post-processing may replace.
    var refusal: (any Error)? {
        problems.first { if case .unavailable? = $0 as? HolosError { true } else { false } }
            ?? problems.first { !SessionFiles.isDamage($0) }
    }
}
