import Foundation
import HolosCore
import HolosMeeting

/// What the followed meeting's recording offers now: Stop, Pause or Resume, and Add Marker…, each enabled or not. The
/// menu bar's meeting block, the live transcript's header, and the meeting's menu in Meetings all show these
/// (docs/design.md "Live transcript"), and `MeetingRecordingCommands.perform` checks them again before it acts.
struct MeetingRecordingControls: Equatable {
    enum Stop: Equatable {
        /// The recorder is still starting: "Stop Recording", at once (nothing is saved yet).
        case cancelStart
        /// "Stop and Save…", after a confirmation.
        case stopAndSave

        var title: String {
            switch self {
            case .cancelStart: "Stop Recording"
            case .stopAndSave: "Stop and Save…"
            }
        }
    }

    enum Pause: Equatable {
        case pause, resume

        var title: String {
            switch self {
            case .pause: "Pause Recording"
            case .resume: "Resume Recording"
            }
        }
    }

    /// The meeting the controls are for; nil when no meeting is starting or recording.
    var sessionID: String?
    var stop: Stop?
    var stopEnabled = false
    var pause: Pause?
    var pauseEnabled = false
    var markerEnabled = false

    static let none = MeetingRecordingControls()

    /// The controls of `state`. Starting: Stop Recording until it was asked for. Recording: Pause (while recording or
    /// waiting for audio) or Resume (paused), Add Marker… once the recorder started, and Stop and Save… until the
    /// recorder stops or a stop was asked for (`MeetingReducer.stopRequested`). Saving, failed, idle: none.
    init(state: MeetingState, stopRequested: Bool, stoppedWhileStarting: Bool) {
        switch state {
        case .starting(let id, _, _):
            sessionID = id
            stop = .cancelStart
            stopEnabled = !stoppedWhileStarting
        case .active(let id, let status):
            sessionID = id
            let stopping = status.phase == .stopping
            if status.phase == .paused {
                pause = .resume
                pauseEnabled = true
            } else {
                pause = .pause
                pauseEnabled = status.phase == .recording || status.phase == .waiting
            }
            markerEnabled = !stopping && status.phase != .starting
            stop = .stopAndSave
            stopEnabled = !stopping && !stopRequested
        case .idle, .finishing, .failed:
            break
        }
    }

    init() {}

    @MainActor
    init(_ recording: (any MeetingRecording)?) {
        guard let recording else {
            self.init()
            return
        }
        self.init(state: recording.state, stopRequested: recording.stopRequested,
                  stoppedWhileStarting: recording.stoppedWhileStarting)
    }
}

/// What a recording control asks for.
enum MeetingRecordingCommand: Equatable {
    case stop, pause, resume
}

/// The meeting being recorded, as the recording controls see it: `MeetingController` in the app, a fake in tests.
@MainActor
protocol MeetingRecording: AnyObject {
    var state: MeetingState { get }
    var stopRequested: Bool { get }
    var stoppedWhileStarting: Bool { get }
    func confirmStop()
    func pause()
    func resume()
}

extension MeetingController: MeetingRecording {
    var stopRequested: Bool { reducer.stopRequested }
    var stoppedWhileStarting: Bool { reducer.stoppedWhileStarting }
}

/// The one path of Stop, Pause, and Resume, wherever they are chosen (the menu bar, the live transcript's header, the
/// meeting's menu in Meetings).
@MainActor
enum MeetingRecordingCommands {
    /// The question Stop and Save… asks first.
    struct StopQuestion: Equatable {
        var message: String
        var information: String
        static let stopButton = "Stop and Save"
        static let keepButton = "Keep Recording"

        @MainActor
        init(name: String) {
            message = "Stop and save “\(HolosAppDelegate.short(name))”?"
            information = "Voice is Local then labels speakers, which takes about 2 minutes for a 3-hour meeting, or about 5 when it also detects languages. Keep the lid open until it finishes; the next meeting can start once it has."
        }
    }

    /// Carries out `command` on `recording` when its control is enabled now (`MeetingRecordingControls`); otherwise
    /// nothing happens. `sessionID`: the meeting the control was shown for (nil: whichever is followed); another
    /// meeting's control does nothing. Stop and Save… asks `confirm` first, and stops only if the answer is yes and
    /// the same meeting can still be stopped then (the answer may come later, from a sheet). Returns whether the
    /// command was carried out or the question asked.
    @discardableResult
    static func perform(_ command: MeetingRecordingCommand, on recording: any MeetingRecording, sessionID: String?,
                        confirm: (StopQuestion, @escaping @MainActor (Bool) -> Void) -> Void) -> Bool {
        let controls = MeetingRecordingControls(recording)
        guard let id = controls.sessionID, sessionID == nil || sessionID == id else { return false }
        switch command {
        case .pause:
            guard controls.pause == .pause, controls.pauseEnabled else { return false }
            recording.pause()
        case .resume:
            guard controls.pause == .resume, controls.pauseEnabled else { return false }
            recording.resume()
        case .stop:
            guard let stop = controls.stop, controls.stopEnabled else { return false }
            switch stop {
            case .cancelStart:
                recording.confirmStop()
            case .stopAndSave:
                guard case .active(_, let status) = recording.state else { return false }
                confirm(StopQuestion(name: status.name)) { [weak recording] confirmed in
                    guard confirmed, let recording else { return }
                    let now = MeetingRecordingControls(recording)
                    guard now.sessionID == id, now.stop == .stopAndSave, now.stopEnabled else { return }
                    recording.confirmStop()
                }
            }
        }
        return true
    }
}
