import Foundation
import HolosCore
import HolosStorage
import os

/// A snapshot of the current words beside an independent recognition of each saved track.
public enum SessionCompareRecognitionCommand {
    public struct Outcome: Codable, Sendable {
        public var current: String?
        public var candidate: String
        public var engine: String
    }

    public static func finished(_ status: String) -> Bool {
        [ArchiveStatus.complete, ArchiveStatus.recovered, ArchiveStatus.audioOnly,
         ArchiveStatus.transcriptionIncomplete].contains(status)
    }

    public static func run(session: URL, makeTranscriber: @Sendable () throws -> any DeepTranscriber) async throws -> Outcome {
        let manifest = try SessionArchive.readManifest(at: session)
        guard finished(manifest.status), try !SessionArchive.isActive(at: session) else {
            throw HolosError.unavailable("Choose a finished meeting to compare recognition.")
        }
        guard !manifest.chunks.isEmpty, try !SessionFiles.audioDeleted(session: session, sessionID: manifest.id) else {
            throw HolosError.unavailable("This meeting has no saved audio for comparison.")
        }
        let current = try SessionFiles.currentTranscript(session: session)
        let meeting = try SessionFiles.meetingInfo(session: session, manifest: manifest)
        guard DictationLanguage.meetingLanguages(meeting.languages ?? []).count <= 1,
              DictationLanguage.meetingLanguages(current?.languages ?? []).count <= 1 else {
            throw HolosError.invalidInput("Recognition comparison supports meetings in one language.")
        }
        let locale = meeting.languages?.first ?? current?.languages?.first ?? current?.locale ?? manifest.locale
        let language = Locale(identifier: locale).language.languageCode?.identifier.lowercased()
        let transcriber = try makeTranscriber()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: scratch) }
            catch { Logger(subsystem: "ca.orlenko.holos.app", category: "meeting").error("Could not remove a comparison audio folder") }
        }
        var tracks: [String] = []
        for track in Set(manifest.chunks.map(\.track)).sorted() {
            try Task.checkCancellation()
            let segments: [DeepHeardSegment]
            do {
                segments = try await DeepTranscriptionStage.transcribeTrack(
                    track, session: session, manifest: manifest, renderTo: scratch.appendingPathComponent("track.caf"),
                    transcriber: transcriber, language: language, prompt: "", reference: nil, progress: { _ in })
            } catch let error as DeepTranscriptionStage.RenderFailure {
                throw error.underlying
            }
            let words = segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
            tracks.append("\(track)\n\(words.isEmpty ? "No speech recognized." : words)")
        }
        try Task.checkCancellation()
        return Outcome(current: current?.text, candidate: tracks.joined(separator: "\n\n"), engine: transcriber.engine)
    }
}
