import AppKit
import Foundation
import HolosCore
import HolosMeeting
import Testing
@testable import HolosApp

/// The live transcript in the real main window (`MainWindowController`, the Meetings section, `MeetingsPane.showLive`),
/// laid out offscreen at several window sizes and fed a session journal shaped like a real call recording: the window
/// is never shown. Guards the blank live transcript of 2026-10-06: the hairline under the header had no height of its
/// own, so the height between the header and the edit bar was split between it and the transcript at random, and in
/// some windows the hairline took all of it and the transcript got none, although its words were read.
@MainActor
struct LiveMeetingViewTests {
    nonisolated static let sizes = SettingsEmbeddingTests.sizes

    @Test(.timeLimit(.minutes(1)), arguments: sizes)
    func theTranscriptFillsTheSectionAndShowsTheJournaledWords(size: NSSize) async throws {
        let session = try Self.recordingSession()
        defer { try? FileManager.default.removeItem(at: session.deletingLastPathComponent()) }
        let (window, pane) = try Self.meetings(size: size)
        pane.showLive(sessionID: Self.sessionID, directory: session)
        let live = try #require(pane.children.compactMap { $0 as? LiveMeetingViewController }.first)
        live.start()
        defer { live.stop() }
        // Polls with a budget, never a wall-clock bound: the reads run off the main actor.
        for _ in 0..<2_000 where !(live.shownText.contains("budget") && live.shownText.contains("agenda")) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(live.shownText.contains("budget"), "The microphone's finalized words are shown.")
        #expect(live.shownText.contains("agenda"), "The system track's finalized words are shown.")
        window.contentView?.layoutSubtreeIfNeeded()

        // The transcript takes the height between the header and the edit bar; the hairline stays a line.
        let text = try #require(live.preferredFirstResponder as? NSTextView)
        let scroll = try #require(text.enclosingScrollView)
        #expect(scroll.frame.height > live.view.bounds.height - 120)
        #expect(scroll.frame.width == live.view.bounds.width)
        let separator = try #require(live.view.subviews.first { $0 is NSBox })
        let line = separator.alignmentRect(forFrame: separator.frame)
        #expect(line.height <= 1.5)
        #expect(line.width == live.view.bounds.width)
        // The words are in view.
        #expect(scroll.contentView.documentVisibleRect.height > 0)
        #expect(text.frame.width > 0)
    }

    // MARK: - Helpers

    static let sessionID = "6F0D7B4A-2C1E-4B8A-9F3D-1A2B3C4D5E6F"

    /// The main window on Meetings, laid out but never shown.
    static func meetings(size: NSSize) throws -> (NSWindow, MeetingsPane) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-view-\(UUID().uuidString)")
        let pane = MeetingsPane(root: root, perform: { _, _ in }, openReview: { _ in },
                                beginUsing: { _, _ in true }, endUsing: { _ in },
                                liveHeader: { _, _ in
                                    LiveMeetingHeader(name: "Meeting", phase: .recording, detail: "0:01:00")
                                })
        let controller = MainWindowController { section in section == .meetings ? pane : NSViewController() }
        controller.window.setContentSize(size)
        controller.select(.meetings)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        SettingsEmbeddingTests.retained.append(controller)
        return (controller.window, pane)
    }

    /// A call being recorded: system audio starts late (a discontinuity), then each track finalizes a phrase.
    static func recordingSession() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("live-session-\(UUID().uuidString)")
        let session = parent.appendingPathComponent("\(sessionID).holos", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try HolosJSON.encoder().encode(MeetingInfo(sessionID: sessionID, mode: .call, othersInRoom: true))
            .write(to: session.appendingPathComponent("meeting.json"))
        var lines: [String] = []
        func event(_ kind: String, _ details: [String: String]) throws {
            let object: [String: Any] = ["sequence": lines.count + 1, "at": "2026-10-06T03:59:02Z", "kind": kind,
                                         "details": details]
            lines.append(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                                as: UTF8.self))
        }
        try event(MeetingEventKind.captureStarted, ["epoch": "0", "timelineOffset": "0"])
        try event(MeetingEventKind.chunkOpened, ["track": "mic", "start": "0.04", "relativePath": "audio/mic/000001.caf"])
        try event(MeetingEventKind.audioDiscontinuity, ["track": "system", "previousEnd": "0.0", "nextStart": "0.41",
                                         "reason": "audioUnavailable"])
        try event(MeetingEventKind.chunkOpened, ["track": "system", "start": "0.41", "relativePath": "audio/system/000001.caf"])
        try event(MeetingEventKind.transcriptFinalized, ["track": "mic", "start": "3.04", "end": "5.44",
                                                         "segmentID": "M1", "text": "the budget looks fine"])
        try event(MeetingEventKind.transcriptFinalized, ["track": "system", "start": "23.75", "end": "26.87",
                                                         "segmentID": "S1", "text": "next item on the agenda"])
        try (lines.joined(separator: "\n") + "\n").write(to: session.appendingPathComponent("events.jsonl"),
                                                         atomically: false, encoding: .utf8)
        return session
    }
}
