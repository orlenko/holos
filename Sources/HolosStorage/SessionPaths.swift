import Foundation

/// Every path inside a `<SESSION-UUID>.holos` folder (docs/meeting-design.md §2.1), so no code spells one by hand.
/// Functions that take an ID do not validate it; callers validate IDs with `SessionArchive.validToken` first.
public enum SessionPaths {
    public static func manifest(_ session: URL) -> URL { file("manifest.json", in: session) }
    public static func events(_ session: URL) -> URL { file("events.jsonl", in: session) }
    public static func meetingInfo(_ session: URL) -> URL { file("meeting.json", in: session) }
    public static func vocabulary(_ session: URL) -> URL { file("vocabulary.json", in: session) }
    public static func status(_ session: URL) -> URL { file("status.json", in: session) }
    public static func controlDirectory(_ session: URL) -> URL { folder("control", in: session) }
    public static func postprocess(_ session: URL) -> URL { file("postprocess.json", in: session) }
    public static func audioDeleted(_ session: URL) -> URL { file("audio-deleted.json", in: session) }

    public static func transcripts(_ session: URL) -> URL { folder("transcripts", in: session) }
    public static func transcript(_ id: String, in session: URL) -> URL {
        file("\(id).json", in: transcripts(session))
    }
    public static func transcriptPointer(_ session: URL) -> URL { file("current.json", in: transcripts(session)) }
    /// transcripts/current.pending: the revision a save is publishing; only that revision may be saved again.
    public static func pendingTranscript(_ session: URL) -> URL { file("current.pending", in: transcripts(session)) }

    public static func runs(_ session: URL) -> URL { folder("runs", in: speakers(session)) }
    public static func run(_ id: String, in session: URL) -> URL { file("\(id).json", in: runs(session)) }
    public static func head(_ session: URL) -> URL { file("head.json", in: speakers(session)) }
    public static func edits(_ session: URL) -> URL { file("edits.jsonl", in: speakers(session)) }
    public static func voiceDirectory(_ session: URL) -> URL { folder("voice", in: speakers(session)) }
    public static func voiceData(_ runID: String, in session: URL) -> URL {
        file("\(runID).json", in: voiceDirectory(session))
    }
    public static func recognition(_ runID: String, in session: URL) -> URL {
        file("\(runID).json", in: recognitionDirectory(session))
    }

    public static func exports(_ session: URL) -> URL { folder("exports", in: session) }
    public static func export(_ fileExtension: String, in session: URL) -> URL {
        file("transcript.\(fileExtension)", in: exports(session))
    }
    public static func generatedExports(_ session: URL) -> URL { file(".generated.json", in: exports(session)) }

    public static func derived(_ session: URL) -> URL { folder("derived", in: session) }
    public static func render(track: String, in session: URL) -> URL { file("\(track)-16k.caf", in: derived(session)) }

    // MARK: - Internal

    /// speakers/
    static func speakers(_ session: URL) -> URL { folder("speakers", in: session) }
    /// speakers/recognition/
    static func recognitionDirectory(_ session: URL) -> URL { folder("recognition", in: speakers(session)) }
    /// speakers/edits.torn-<UUID>.jsonl: backup of a torn journal tail before it is repaired.
    static func tornEditsBackup(_ session: URL) -> URL {
        file("edits.torn-\(UUID().uuidString).jsonl", in: speakers(session))
    }

    private static func file(_ name: String, in folder: URL) -> URL {
        folder.appendingPathComponent(name, isDirectory: false)
    }

    private static func folder(_ name: String, in parent: URL) -> URL {
        parent.appendingPathComponent(name, isDirectory: true)
    }
}
