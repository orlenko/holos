import Foundation
import HolosCore
import HolosStorage

/// The files that hold a session's speaker labels, read and validated one way for both the catalog
/// (`SessionCatalog.speakerLabels`) and recovery (`SessionRecoveryCommand.currentLabels`), so the two never disagree
/// about whether the saved labels can be used (docs/meeting-design.md §5.6).
///
/// Reads postprocess.json, speakers/head.json, and the run the head names, each with its schema-version check. A file
/// that exists but cannot be read (damaged, written by a newer Holos, an I/O error) is a problem, and so is one that
/// another file names but that is missing: the head's run, or the head when postprocess.json names a run (labels load
/// through the head, so a record whose head is gone has no usable labels).
struct SavedSpeakerState {
    var record: PostProcessingRecord?
    var head: SpeakerHead?
    /// The run the head names, once it was read.
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
        if let head {
            do { state.headRun = try SessionSpeakerStore.readRun(id: head.runID, session: session) } catch {
                state.problems.append(prefixed(error, "The labels' speaker run cannot be read: "))
            }
        } else if let runID = state.record?.runID {
            state.problems.append(HolosError.incomplete(
                "postprocess.json names speaker run \(runID), but speakers/head.json is missing."))
        }
        return state
    }

    /// The problem that forbids replacing the files: one written by a newer Holos (`unavailable`, schema rule 3,
    /// §1.6) first, else one that cannot be read now (not `SessionFiles.isDamage`). Nil when every problem is damage
    /// or a missing file, which post-processing may replace.
    var refusal: (any Error)? {
        problems.first { if case .unavailable? = $0 as? HolosError { true } else { false } }
            ?? problems.first { !SessionFiles.isDamage($0) }
    }

    /// `error` with `prefix` before its message, keeping its `HolosError` kind.
    private static func prefixed(_ error: any Error, _ prefix: String) -> any Error {
        let message = prefix + error.localizedDescription
        switch error as? HolosError {
        case .invalidInput?: return HolosError.invalidInput(message)
        case .unavailable?: return HolosError.unavailable(message)
        case .permissionDenied?: return HolosError.permissionDenied(message)
        case .incomplete?: return HolosError.incomplete(message)
        case .io?: return HolosError.io(message)
        case nil: return error
        }
    }
}
