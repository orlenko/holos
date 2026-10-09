import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// What `voiceislocal session echo-label-stats` (hidden; docs/meeting-design.md §5.11) does, as a library call: for
/// each call given, what the evidence requirement of the acoustic echo word rule changes in its labels
/// (`EchoLabelStats`), and their total. Counts only: no transcript text, names, word times, or folder paths (a session
/// is named by its ID). It only reads, takes no lock (as `SpeakerSessionSnapshot.load`: every file it reads is replaced
/// atomically), and leaves a meeting that is recording alone.
public enum SessionEchoLabelStats {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "speakers")

    public enum Status: String, Sendable, Equatable, Encodable {
        /// Counted.
        case measured
        /// The meeting is recording: not read.
        case recording
        /// No acoustic echo mask the labels use (not a call, no echo found, not analysed, or the analysis out of date):
        /// nothing to compare.
        case noMask
        /// No transcript yet.
        case noTranscript
        /// A file could not be read (the log says which).
        case unreadable
    }

    public struct SessionResult: Sendable, Equatable, Encodable {
        /// The manifest's session ID; nil when it cannot be read.
        public var sessionID: String?
        public var status: Status
        public var stats: EchoLabelStats?
    }

    public struct Report: Sendable, Equatable, Encodable {
        public var sessions: [SessionResult]
        /// The sum over the sessions measured.
        public var total: EchoLabelStats
        public var measured: Int

        /// One line per session, in the order given, then the total.
        public var lines: [String] {
            var lines = sessions.enumerated().map { index, result in
                let name = result.sessionID ?? "#\(index + 1)"
                guard let stats = result.stats else { return "\(name): not measured (\(result.status.rawValue))" }
                return "\(name): \(stats.line)"
            }
            lines.append("total (\(measured) of \(sessions.count) measured): \(total.line)")
            return lines
        }

        /// 0 when a session was measured; 1 when none was.
        public var exitCode: Int32 { measured > 0 ? 0 : 1 }
    }

    /// The report for what was typed for each session (`SessionLocator.resolve`: a path to a .holos folder or a
    /// session ID under `root`), each on its own: one that names no session (missing, a symbolic link, not a folder,
    /// an unknown ID) is listed as unreadable and anonymous ("#3"), its reason only logged privately (it holds the
    /// path), and the others are measured all the same.
    public static func report(arguments: [String], root: URL = HolosPaths.sessions) -> Report {
        report(arguments.map { argument -> URL? in
            do {
                return try SessionLocator.resolve(argument, root: root)
            } catch {
                log.error("Echo label stats: a session argument names no session: \(error.localizedDescription, privacy: .private)")
                return nil
            }
        })
    }

    /// The report for `sessions` in order; nil stands for an argument that named no session (unreadable).
    public static func report(_ sessions: [URL?]) -> Report {
        let results = sessions.map { $0.map(measure) ?? SessionResult(sessionID: nil, status: .unreadable) }
        var total = EchoLabelStats()
        for result in results { if let stats = result.stats { total.add(stats) } }
        return Report(sessions: results, total: total, measured: results.filter { $0.stats != nil }.count)
    }

    /// One session's stats, against the labels as they are on disk: the head run with its edit journal, and the mask
    /// they are shown with (`EchoMaskStore.usable`).
    public static func measure(_ session: URL) -> SessionResult {
        var result = SessionResult(sessionID: nil, status: .unreadable)
        do {
            let manifest = try SessionArchive.readManifest(at: session)
            result.sessionID = manifest.id
            if try SessionArchive.isActive(at: session) {
                result.status = .recording
                return result
            }
            guard let mask = EchoMaskStore.usable(session: session, manifest: manifest) else {
                result.status = .noMask
                return result
            }
            guard try SessionArchive.currentTranscriptID(at: session) != nil else {
                result.status = .noTranscript
                return result
            }
            let snapshot = try SpeakerSessionSnapshot.load(session: session, applyRecognition: false)
            result.stats = EchoLabelStats.compare(transcript: snapshot.transcript, mask: mask, run: snapshot.run,
                                                  edits: snapshot.journal.edits)
            result.status = .measured
        } catch {
            log.error("Echo label stats: a session could not be read: \(error.localizedDescription, privacy: .private)")
            result.status = .unreadable
        }
        return result
    }
}
