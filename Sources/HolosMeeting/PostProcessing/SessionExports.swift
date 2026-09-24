import CryptoKit
import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

public struct ExportWriteResult: Sendable, Equatable {
    public var written: [URL]
    /// Hand-edited exports moved to `exports/edited-<YYYYMMDD-HHMMSS>.<ext>` before regeneration.
    public var movedAside: [URL]

    public init(written: [URL] = [], movedAside: [URL] = []) {
        self.written = written; self.movedAside = movedAside
    }
}

/// Writes a session's exports (`exports/transcript.{md,json,txt}`) from its speaker snapshot (docs/meeting-design.md
/// §4.11). `exports/` is a generated cache: each file is written 0400 and its SHA-256 recorded in
/// `exports/.generated.json`; a file that no longer matches (someone edited it) is moved aside, never overwritten.
public enum SessionExports {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "postprocess")
    /// Mode of generated export files.
    static let generatedPermissions: mode_t = 0o400
    /// Mode of a hand-edited export moved aside.
    static let editedPermissions: mode_t = 0o600
    static let maxExportBytes = 256 << 20
    /// The formats in the order they are written.
    static let formats: [ExportFormat] = [.md, .json, .txt]

    /// Takes the speaker lock, loads the snapshot, writes exports/transcript.{md,json,txt}, releases the lock.
    @discardableResult
    public static func regenerate(session: URL, profileNames: [String: String] = [:]) throws -> ExportWriteResult {
        try SessionArchive.withSpeakerLock(at: session) {
            try regenerateLocked(session: session, profileNames: profileNames)
        }
    }

    /// Caller holds the speaker lock.
    ///
    /// Every format is rendered before anything is written, so a render failure changes nothing. Then, per file:
    /// an existing file that differs from what will be written, and matches neither the digest recorded for it in
    /// `.generated.json` nor the digest a regeneration recorded just before writing it (a crash in between; files
    /// accepted that way are folded into the recorded digests, so repeated interruptions keep them), is
    /// copied to `exports/edited-<YYYYMMDD-HHMMSS>.<ext>` (0600, local time; `-2`, `-3`, … when taken) and listed
    /// in `movedAside`. Before any export was generated here (no `.generated.json`), the speaker-less exports
    /// `SessionArchive.saveTranscript` writes for the current transcript count as generated; any other existing file
    /// is moved aside. A `.generated.json` from a newer Holos is refused (`unavailable`); a damaged one records
    /// nothing, so every existing file that differs is moved aside.
    @discardableResult
    public static func regenerateLocked(session: URL, profileNames: [String: String] = [:]) throws -> ExportWriteResult {
        let snapshot = try SpeakerSessionSnapshot.load(session: session, profileNames: profileNames)
        let rendered = try renderAll(exportDocument(snapshot))
        let result = try write(rendered, session: session, snapshot: snapshot)
        log.info("Session \(snapshot.manifest.id, privacy: .public): wrote \(result.written.count, privacy: .public) exports; moved \(result.movedAside.count, privacy: .public) edited exports aside")
        return result
    }

    /// One format, not written anywhere.
    public static func render(_ format: ExportFormat, session: URL,
                              profileNames: [String: String] = [:]) throws -> Data {
        let snapshot = try SpeakerSessionSnapshot.load(session: session, profileNames: profileNames)
        return try TranscriptExporter.render(exportDocument(snapshot), format: format)
    }

    /// The document the exports are written from: the snapshot's, except when the transcript changed after speakers
    /// were labelled (`transcriptChanged`). The head run's labels then name words of the earlier transcript, so the
    /// exports show the current transcript without speakers until speakers are labelled again; a newer transcript
    /// never disappears from them.
    static func exportDocument(_ snapshot: SpeakerSessionSnapshot) throws -> ExportDocument {
        var document = snapshot.exportDocument()
        guard snapshot.transcriptChanged,
              let current = try SessionFiles.currentTranscript(session: snapshot.session) else { return document }
        document.transcript = current
        document.run = nil
        document.projection = nil
        return document
    }

    /// Every format, in the order they are written.
    static func renderAll(_ document: ExportDocument) throws -> [(format: ExportFormat, data: Data)] {
        try formats.map { ($0, try TranscriptExporter.render(document, format: $0)) }
    }

    // MARK: - Private

    /// Contents of `exports/.generated.json`.
    struct GeneratedRecord: Codable, Equatable {
        var schemaVersion: Int
        /// File name → SHA-256 (lowercase hex) of the bytes last written.
        var files: [String: String]
        /// Set while a regeneration writes: file name → SHA-256 of the bytes it is writing, so a file it wrote before
        /// a crash still counts as generated.
        var pending: [String: String]?

        init(schemaVersion: Int = 1, files: [String: String], pending: [String: String]? = nil) {
            self.schemaVersion = schemaVersion; self.files = files; self.pending = pending
        }

        func isGenerated(_ name: String, digest: String) -> Bool {
            files[name] == digest || pending?[name] == digest
        }
    }

    private static func write(_ rendered: [(format: ExportFormat, data: Data)], session: URL,
                              snapshot: SpeakerSessionSnapshot) throws -> ExportWriteResult {
        var result = ExportWriteResult(movedAside: try beginWrite(rendered, session: session, snapshot: snapshot))
        for entry in rendered {
            let url = SessionPaths.export(entry.format.rawValue, in: session)
            try AtomicFile.write(entry.data, to: url, permissions: generatedPermissions)
            result.written.append(url)
        }
        try AtomicFile.writeJSON(GeneratedRecord(files: digestsByName(rendered)), to: SessionPaths.generatedExports(session))
        return result
    }

    private static func digestsByName(_ rendered: [(format: ExportFormat, data: Data)]) -> [String: String] {
        var digests: [String: String] = [:]
        for entry in rendered { digests[fileName(entry.format)] = sha256(entry.data) }
        return digests
    }

    /// The part of a write before the export files are replaced: moves hand-edited files aside and records the
    /// digests about to be written as `pending`. Returns the files moved aside. (Tests call it alone to stand for
    /// a regeneration interrupted before it replaced any file.)
    static func beginWrite(_ rendered: [(format: ExportFormat, data: Data)], session: URL,
                           snapshot: SpeakerSessionSnapshot) throws -> [URL] {
        try AtomicFile.ensurePrivateDirectory(SessionPaths.exports(session))
        let record = try readRecord(session: session)
        let digests = digestsByName(rendered)

        var movedAside: [URL] = []
        var legacy: [String: Data]?
        var legacyLoaded = false
        // Every file on disk accepted as generated is recorded under `files` before the new `pending` replaces the
        // old one, so a file an earlier interrupted regeneration wrote still counts after another interruption.
        var files = record?.files ?? [:]
        for entry in rendered {
            let name = fileName(entry.format)
            let url = SessionPaths.export(entry.format.rawValue, in: session)
            guard let existing = try AtomicFile.readIfPresent(url, maxBytes: maxExportBytes) else { continue }
            let digest = sha256(existing)
            if digest == digests[name] {
                files[name] = digest
                continue
            }
            if let record {
                if record.isGenerated(name, digest: digest) {
                    files[name] = digest
                    continue
                }
            } else {
                if !legacyLoaded {
                    legacy = legacyExports(session: session, snapshot: snapshot)
                    legacyLoaded = true
                }
                if let legacyData = legacy?[entry.format.rawValue], legacyData == existing {
                    files[name] = digest
                    continue
                }
            }
            movedAside.append(try moveAside(existing, format: entry.format, session: session))
        }
        try AtomicFile.writeJSON(GeneratedRecord(files: files, pending: digests), to: SessionPaths.generatedExports(session))
        return movedAside
    }

    private static func fileName(_ format: ExportFormat) -> String { "transcript.\(format.rawValue)" }

    /// nil when no export was ever generated here; an empty record when the file is damaged.
    private static func readRecord(session: URL) throws -> GeneratedRecord? {
        let name = "exports/.generated.json"
        guard let data = try AtomicFile.readIfPresent(SessionPaths.generatedExports(session), maxBytes: 1 << 20) else {
            return nil
        }
        try SessionFiles.checkVersion(data, current: 1, name: name)
        do {
            return try HolosJSON.decoder().decode(GeneratedRecord.self, from: data)
        } catch {
            log.error("\(name, privacy: .public) is damaged; every edited export will be moved aside")
            return GeneratedRecord(files: [:])
        }
    }

    /// The speaker-less exports `saveTranscript` wrote for the current transcript, or nil when it cannot be read.
    private static func legacyExports(session: URL, snapshot: SpeakerSessionSnapshot) -> [String: Data]? {
        do {
            let currentID = try SessionArchive.currentTranscriptID(at: session)
            let transcript = currentID == snapshot.transcript.id
                ? snapshot.transcript : try SessionFiles.currentTranscript(session: session)
            return transcript.map { SessionArchive.legacyExports(for: $0, name: snapshot.manifest.name) }
        } catch {
            log.error("Cannot read the current transcript to recognize older exports: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// Copies `contents` to a new `exports/edited-<YYYYMMDD-HHMMSS>.<ext>` and returns its URL. The caller then
    /// replaces the original, so the edit is kept whether or not a crash comes in between.
    private static func moveAside(_ contents: Data, format: ExportFormat, session: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        for attempt in 1...1_000 {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let url = SessionPaths.exports(session)
                .appendingPathComponent("edited-\(stamp)\(suffix).\(format.rawValue)", isDirectory: false)
            guard try AtomicFile.openForReading(url) == nil else { continue }
            try AtomicFile.create(contents, at: url, permissions: editedPermissions)
            return url
        }
        throw HolosError.io("Cannot find a free name to keep the edited transcript.\(format.rawValue).")
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
