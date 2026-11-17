import AppKit
import Foundation
import HolosCore
import HolosMeeting
import Testing
@testable import HolosApp

/// Stop and Save…, Pause, and Resume of the meeting being recorded: the menu bar's rules (`MeetingRecordingControls`),
/// the one path every control takes (`MeetingRecordingCommands.perform`) on a fake meeting, and the live transcript's
/// header buttons, shown per phase and sending their command through the Meetings section.
@MainActor
struct MeetingRecordingControlsTests {
    // MARK: - Rules

    @Test func nothingToStopOrPauseWithoutARecording() {
        let states: [MeetingState] = [
            .idle, .finishing(sessionID: Self.id, status: nil), .failed(sessionID: Self.id, message: "No microphone"),
        ]
        for state in states {
            #expect(MeetingRecordingControls(state: state, stopRequested: false, stoppedWhileStarting: false) == .none)
        }
    }

    @Test func aStartingMeetingCanBeStoppedOnceWithoutAQuestion() {
        let state = MeetingState.starting(sessionID: Self.id, since: Date(), pid: nil)
        let controls = MeetingRecordingControls(state: state, stopRequested: false, stoppedWhileStarting: false)
        #expect(controls.sessionID == Self.id)
        #expect(controls.stop == .cancelStart)
        #expect(controls.stop?.title == "Stop Recording")
        #expect(controls.stopEnabled)
        #expect(controls.pause == nil)
        let stopped = MeetingRecordingControls(state: state, stopRequested: false, stoppedWhileStarting: true)
        #expect(stopped.stop == .cancelStart)
        #expect(!stopped.stopEnabled)
    }

    /// Each recorder phase while the meeting is active, as the menu bar always offered them.
    @Test(arguments: [
        // phase, pause, pause enabled, marker enabled, stop enabled
        (RecorderPhase.recording, MeetingRecordingControls.Pause.pause, true, true, true),
        (.waiting, .pause, true, true, true),
        (.paused, .resume, true, true, true),
        (.sleeping, .pause, false, true, true),
        (.unknown, .pause, false, true, true),
        (.starting, .pause, false, false, true),
        (.stopping, .pause, false, false, false),
    ])
    func anActiveMeetingFollowsTheMenuBarRules(phase: RecorderPhase, pause: MeetingRecordingControls.Pause,
                                               pauseEnabled: Bool, markerEnabled: Bool, stopEnabled: Bool) {
        let controls = MeetingRecordingControls(state: Self.active(phase), stopRequested: false,
                                                stoppedWhileStarting: false)
        #expect(controls.sessionID == Self.id)
        #expect(controls.pause == pause)
        #expect(controls.pauseEnabled == pauseEnabled)
        #expect(controls.markerEnabled == markerEnabled)
        #expect(controls.stop == .stopAndSave)
        #expect(controls.stop?.title == "Stop and Save…")
        #expect(controls.stopEnabled == stopEnabled)
    }

    @Test func aStopAlreadyAskedForTurnsStopOff() {
        let controls = MeetingRecordingControls(state: Self.active(.recording), stopRequested: true,
                                                stoppedWhileStarting: false)
        #expect(controls.stop == .stopAndSave)
        #expect(!controls.stopEnabled)
        #expect(controls.pauseEnabled, "Pause stays as the menu bar has it.")
    }

    // MARK: - The one path

    @Test func pauseAndResumeOnlyWhenTheirControlIsOn() {
        let meeting = FakeRecording(Self.active(.recording))
        #expect(perform(.pause, meeting))
        #expect(!perform(.resume, meeting))
        meeting.state = Self.active(.paused)
        #expect(perform(.resume, meeting))
        #expect(!perform(.pause, meeting))
        meeting.state = Self.active(.sleeping)
        #expect(!perform(.pause, meeting))
        #expect(meeting.calls == ["pause", "resume"])
    }

    @Test func stopAndSaveAsksFirstAndStopsOnYes() {
        let meeting = FakeRecording(Self.active(.recording))
        var questions: [MeetingRecordingCommands.StopQuestion] = []
        MeetingRecordingCommands.perform(.stop, on: meeting, sessionID: Self.id) { question, answer in
            questions.append(question)
            answer(false)
        }
        #expect(meeting.calls.isEmpty, "Keep Recording stops nothing.")
        MeetingRecordingCommands.perform(.stop, on: meeting, sessionID: nil) { question, answer in
            questions.append(question)
            answer(true)
        }
        #expect(meeting.calls == ["confirmStop"])
        #expect(questions.count == 2)
        #expect(questions.first?.message == "Stop and save “Weekly planning”?")
    }

    @Test func aStopTurnedOffAsksNothing() {
        let meeting = FakeRecording(Self.active(.recording))
        meeting.stopRequested = true
        var asked = false
        let performed = MeetingRecordingCommands.perform(.stop, on: meeting, sessionID: Self.id) { _, answer in
            asked = true
            answer(true)
        }
        #expect(!performed)
        #expect(!asked)
        meeting.stopRequested = false
        meeting.state = Self.active(.stopping)
        #expect(!perform(.stop, meeting))
        #expect(meeting.calls.isEmpty)
    }

    /// A sheet answers later: by then the meeting may have been stopped from the menu bar, or have ended.
    @Test func aLateYesStopsOnlyTheSameMeetingStillRecording() {
        let meeting = FakeRecording(Self.active(.recording))
        var answers: [@MainActor (Bool) -> Void] = []
        for _ in 0..<3 {
            MeetingRecordingCommands.perform(.stop, on: meeting, sessionID: Self.id) { _, answer in answers.append(answer) }
        }
        meeting.stopRequested = true
        answers[0](true)
        meeting.stopRequested = false
        meeting.state = .active(sessionID: "another", status: Self.status(.recording, id: "another"))
        answers[1](true)
        #expect(meeting.calls.isEmpty)
        meeting.state = Self.active(.recording)
        answers[2](true)
        #expect(meeting.calls == ["confirmStop"])
    }

    @Test func aStartingMeetingStopsWithoutAQuestion() {
        let meeting = FakeRecording(.starting(sessionID: Self.id, since: Date(), pid: nil))
        var asked = false
        MeetingRecordingCommands.perform(.stop, on: meeting, sessionID: Self.id) { _, _ in asked = true }
        #expect(!asked)
        #expect(meeting.calls == ["confirmStop"])
        meeting.stoppedWhileStarting = true
        #expect(!perform(.stop, meeting))
        #expect(meeting.calls == ["confirmStop"])
    }

    @Test func anotherMeetingsControlDoesNothing() {
        let meeting = FakeRecording(Self.active(.recording))
        var asked = false
        let performed = MeetingRecordingCommands.perform(.stop, on: meeting, sessionID: "older") { _, answer in
            asked = true
            answer(true)
        }
        #expect(!performed)
        #expect(!asked)
        #expect(!MeetingRecordingCommands.perform(.pause, on: meeting, sessionID: "older") { _, _ in })
        #expect(meeting.calls.isEmpty)
    }

    // MARK: - The live transcript's header

    /// Pause / Resume and Stop show while the meeting is captured and the app follows it, and hide once it saves (the
    /// finished meeting's button follows) or when the app does not follow it.
    @Test(arguments: [
        (LiveMeetingPhase.starting, true), (.recording, true), (.paused, true), (.saving, false), (.saved, false),
        (.interrupted, false), (.failed, false),
    ])
    func theHeaderShowsTheControlsWhileCapturing(phase: LiveMeetingPhase, shown: Bool) throws {
        let (pane, live, session) = try Self.live()
        defer { try? FileManager.default.removeItem(at: session.deletingLastPathComponent()) }
        _ = pane
        let state: MeetingState = switch phase {
        case .starting: .starting(sessionID: Self.id, since: Date(), pid: nil)
        case .recording: Self.active(.recording)
        case .paused: Self.active(.paused)
        case .saving: Self.active(.stopping)
        default: .idle
        }
        let controls = MeetingRecordingControls(state: state, stopRequested: false, stoppedWhileStarting: false)
        live.update(header: LiveMeetingHeader(name: "Weekly planning", phase: phase, detail: "0:12:34",
                                              controls: controls),
                    finishedAction: phase == .saved ? "Open Review" : nil)
        let stop = Self.stopButton(live)
        #expect((stop?.isHiddenOrHasHiddenAncestor == false) == shown)
        let pause = Self.pauseButton(live)
        #expect((pause?.isHiddenOrHasHiddenAncestor == false) == (shown && phase != .starting))
        // A meeting the app does not follow (the voiceislocal tool records it) has no controls.
        live.update(header: LiveMeetingHeader(name: "Weekly planning", phase: phase, detail: "0:12:34"),
                    finishedAction: nil)
        #expect(Self.stopButton(live)?.isHiddenOrHasHiddenAncestor != false)
    }

    @Test func theHeaderButtonsFollowTheRulesAndSendTheirCommand() throws {
        let (pane, live, session) = try Self.live()
        defer { try? FileManager.default.removeItem(at: session.deletingLastPathComponent()) }
        var sent: [(MeetingRecordingCommand, String)] = []
        pane.onRecordingCommand = { sent.append(($0, $1)) }
        func show(_ state: MeetingState, stopRequested: Bool = false) {
            let controls = MeetingRecordingControls(state: state, stopRequested: stopRequested,
                                                    stoppedWhileStarting: false)
            live.update(header: LiveMeetingHeader(name: "Weekly planning", phase: .recording, detail: "0:12:34",
                                                  controls: controls), finishedAction: nil)
        }
        show(Self.active(.recording))
        let stop = try #require(Self.stopButton(live))
        let pause = try #require(Self.pauseButton(live))
        #expect(stop.isEnabled && pause.isEnabled)
        #expect(stop.toolTip == "Stop and Save…")
        #expect(stop.accessibilityLabel() == "Stop and Save…")
        #expect(pause.toolTip == "Pause Recording")
        #expect(pause.accessibilityLabel() == "Pause Recording")
        #expect(stop.keyEquivalent.isEmpty && pause.keyEquivalent.isEmpty, "Escape is Back and Return is Open.")
        pause.performClick(nil)
        stop.performClick(nil)
        #expect(sent.map(\.0) == [.pause, .stop])
        #expect(sent.allSatisfy { $0.1 == Self.id })

        show(Self.active(.paused))
        #expect(pause.toolTip == "Resume Recording")
        #expect(pause.accessibilityLabel() == "Resume Recording")
        pause.performClick(nil)
        #expect(sent.last?.0 == .resume)

        // Asked to stop: Stop turns off until the recorder stops (the menu bar's rule).
        show(Self.active(.recording), stopRequested: true)
        #expect(!stop.isEnabled)
        show(Self.active(.sleeping))
        #expect(!pause.isEnabled)
        #expect(stop.isEnabled)
    }

    // MARK: - The meeting's menu in Meetings

    /// The row of the meeting being recorded: Pause / Resume Recording and Stop and Save…, enabled by the same rules,
    /// each sending its command for that meeting; none for a meeting that is not recorded by the app.
    @Test func theMeetingsMenuOffersTheSameControls() throws {
        var controls = MeetingRecordingControls(state: Self.active(.recording), stopRequested: false,
                                                stoppedWhileStarting: false)
        let pane = MeetingsPane(root: FileManager.default.temporaryDirectory, perform: { _, _ in },
                                openReview: { _ in }, beginUsing: { _, _ in true }, endUsing: { _ in },
                                liveHeader: { _, _ in
                                    LiveMeetingHeader(name: "Weekly planning", phase: .recording, detail: "0:12:34",
                                                      controls: controls)
                                })
        var sent: [(MeetingRecordingCommand, String)] = []
        pane.onRecordingCommand = { sent.append(($0, $1)) }
        let summary = SessionSummary(id: Self.id, directory: URL(fileURLWithPath: "/\(Self.id).holos"),
                                     name: "Weekly planning", createdAt: Date(), source: .microphone,
                                     state: .recording, manifestStatus: "recording", transcriptID: nil,
                                     speakerState: .none, liveness: .capturing)
        func items() -> [NSMenuItem] {
            let menu = NSMenu()
            pane.addRecordingItems(for: summary, isLive: true, to: menu)
            return menu.items.filter { !$0.isSeparatorItem }
        }
        var shown = items()
        #expect(shown.map(\.title) == ["Pause Recording", "Stop and Save…"])
        #expect(shown.allSatisfy { $0.isEnabled })
        for item in shown { _ = (item.target as? NSObject)?.perform(item.action, with: item) }
        #expect(sent.map(\.0) == [.pause, .stop])
        #expect(sent.allSatisfy { $0.1 == Self.id })

        controls = MeetingRecordingControls(state: Self.active(.paused), stopRequested: true,
                                            stoppedWhileStarting: false)
        shown = items()
        #expect(shown.map(\.title) == ["Resume Recording", "Stop and Save…"])
        #expect(shown.map(\.isEnabled) == [true, false])

        let menu = NSMenu()
        pane.addRecordingItems(for: summary, isLive: false, to: menu)
        #expect(menu.items.isEmpty)
        controls = .none
        #expect(items().isEmpty)
    }

    // MARK: - Fixture

    nonisolated static let id = "6F0D7B4A-2C1E-4B8A-9F3D-1A2B3C4D5E6F"  // `LiveMeetingViewTests.sessionID`

    @MainActor
    final class FakeRecording: MeetingRecording {
        var state: MeetingState
        var stopRequested = false
        var stoppedWhileStarting = false
        var calls: [String] = []

        init(_ state: MeetingState) { self.state = state }

        func confirmStop() { calls.append("confirmStop") }
        func pause() { calls.append("pause") }
        func resume() { calls.append("resume") }
    }

    private func perform(_ command: MeetingRecordingCommand, _ meeting: FakeRecording) -> Bool {
        MeetingRecordingCommands.perform(command, on: meeting, sessionID: Self.id) { _, answer in answer(true) }
    }

    static func status(_ phase: RecorderPhase, id: String = id) -> RecorderStatus {
        RecorderStatus(sessionID: id, name: "Weekly planning", pid: 1, phase: phase, sequence: 1,
                       startedAt: Date(), updatedAt: Date(), source: .microphone, elapsedSeconds: 754)
    }

    static func active(_ phase: RecorderPhase) -> MeetingState {
        .active(sessionID: id, status: status(phase))
    }

    /// The live transcript of a made-up recording in the Meetings section of a main window (laid out, never shown).
    static func live() throws -> (MeetingsPane, LiveMeetingViewController, URL) {
        let session = try LiveMeetingViewTests.recordingSession()
        let (_, pane) = try LiveMeetingViewTests.meetings(size: NSSize(width: 900, height: 700))
        pane.showLive(sessionID: id, directory: session)
        let live = try #require(pane.children.compactMap { $0 as? LiveMeetingViewController }.first)
        return (pane, live, session)
    }

    static func buttons(_ live: LiveMeetingViewController) -> [NSButton] {
        MainWindowNarrowTests.allViews(live.view).compactMap { $0 as? NSButton }
    }

    static func stopButton(_ live: LiveMeetingViewController) -> NSButton? {
        buttons(live).first { $0.action.map(NSStringFromSelector) == "stopRecording" }
    }

    static func pauseButton(_ live: LiveMeetingViewController) -> NSButton? {
        buttons(live).first { $0.action.map(NSStringFromSelector) == "pauseOrResume" }
    }
}
