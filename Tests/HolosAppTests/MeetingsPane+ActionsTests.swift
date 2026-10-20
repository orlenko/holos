import AppKit
import HolosCore
import HolosMeeting
import HolosStorage
import HolosTestSupport
import Testing
@testable import HolosApp

@MainActor
struct MeetingsPaneActionsTests {
    @Test func startRecordingUsesTheInjectedMenuActionAndFollowsRecorderAvailability() throws {
        let temp = try TemporaryDirectory("meeting-start-action")
        defer { temp.remove() }
        let (window, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 601, height: 560), root: temp.url)
        var starts = 0
        pane.onStartRecording = { starts += 1 }
        let button = try #require(MainWindowNarrowTests.allViews(pane.view).compactMap { $0 as? NSButton }
            .first { $0.title == "Start Recording…" })
        #expect(button.isEnabled)
        button.performClick(nil)
        #expect(starts == 1)
        pane.update(meetingState: MeetingRecordingControlsTests.active(.recording))
        #expect(!button.isEnabled)
        pane.startRecording()
        #expect(starts == 1, "An action arriving after recording starts is refused.")
        pane.update(meetingState: .idle)
        #expect(button.isEnabled)
        button.performClick(nil)
        #expect(starts == 2)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(MainWindowNarrowTests.brokenConstraints(in: pane.view).isEmpty)
    }

    @Test func anOpenMeetingKeepsItsAdvancedActionsWhenItsTitleLeavesTheSearch() throws {
        let temp = try TemporaryDirectory("meeting-menu-search")
        defer { temp.remove() }
        let (_, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 1000, height: 700), root: temp.url)
        var summary = SessionSummary(id: "generated-id", directory: temp.url, name: "First title", createdAt: .now,
                                     source: .system, state: .complete, manifestStatus: "complete", liveness: .exited)
        pane.show([summary], people: [:], freeBytes: nil)
        let search = try #require(pane.searchField)
        search.stringValue = "First"
        _ = NSApplication.shared.sendAction(try #require(search.action), to: search.target, from: search)
        pane.showLive(sessionID: summary.id, directory: temp.url)
        summary.name = "Second title"
        pane.show([summary], people: [:], freeBytes: nil)
        let menu = try #require(pane.advancedMenu(sessionID: summary.id))
        #expect(menu.items.contains { $0.title == "Clean Up" })
        #expect(menu.items.contains { $0.title == "Rename…" })
        #expect(pane.selectedSessionIDs == [summary.id])
        pane.showList()
    }

    @Test(.timeLimit(.minutes(1)))
    func aForegroundJobShowsProgressEvenWhenTheSavedManifestIsComplete() async throws {
        let temp = try TemporaryDirectory("meeting-foreground-progress")
        defer { temp.remove() }
        let archive = try SessionArchive.create(root: temp.url, name: "Generated meeting", source: .system,
                                                locale: "en-CA", backend: .speech)
        try await archive.finish(status: ArchiveStatus.complete)
        let progress = PostProcessingProgress(stage: .diarize, fraction: 0.4, message: "Processing")
        let record = PostProcessingRecord(sessionID: archive.id, state: .running, progress: progress,
                                          pid: 1, startedAt: .now, updatedAt: .now)
        try AtomicFile.writeJSON(record, to: SessionPaths.postprocess(archive.directory))
        let (_, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 1000, height: 700), root: temp.url)
        defer { pane.sectionDidHide() }
        pane.update(running: [archive.id: "Labelling speakers"])
        pane.refresh()
        #expect(await eventually { pane.listState.progress[archive.id] == progress })
    }

    @Test func theMeetingScreenAdoptsReviewWhenAnExternalJobReleasesIt() throws {
        let temp = try TemporaryDirectory("meeting-external-job")
        defer { temp.remove() }
        NSApplication.shared.setActivationPolicy(.prohibited)
        var opens = 0
        let pane = MeetingsPane(root: temp.url, perform: { _, _ in }, openReview: { _ in opens += 1 },
                                beginUsing: { _, _ in true }, endUsing: { _ in },
                                liveHeader: { _, _ in .init(name: "Generated meeting", phase: .saved, detail: "") })
        pane.sectionDidShow()
        defer { pane.sectionDidHide(); pane.showList() }
        var summary = SessionSummary(id: "generated-id", directory: temp.url, name: "Generated meeting",
                                     createdAt: .now, source: .system, state: .complete, manifestStatus: "complete",
                                     speakerState: .labelled, runID: "generated-run", liveness: .exited,
                                     jobInProgress: "Generated processing job")
        pane.show([summary], people: [:], freeBytes: nil)
        pane.showLive(sessionID: summary.id, directory: temp.url)
        pane.refreshLiveHeader()
        #expect(opens == 0)
        #expect(pane.live?.contentState.requestedReview == false)
        summary.jobInProgress = nil
        pane.show([summary], people: [:], freeBytes: nil)
        pane.refreshLiveHeader()
        #expect(opens == 1)
    }

}
