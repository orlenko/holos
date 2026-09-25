// When a quit that waits for a meeting may go ahead (docs/meeting-design.md §5.8).

public enum QuitReadiness {
    /// Whether the app may quit now. `inProcess`: the meeting was recording in this process when the quit began
    /// (`InProcessLauncher.isRecording`); `recordingHere`: it still is.
    ///
    /// Child mode: once the recorder stopped capturing; it saves, labels speakers, and writes its exited status on its
    /// own. In-process: only once the recording here has ended, which is after its exited status is written (a retried
    /// one included, `InProcessLauncher.isWritingExit`). The app is the recorder's process, so a quit while it waits for
    /// its labelling child (phase `postprocessing`) would leave status.json unfinished. The app tells it to leave the
    /// labelling to its child instead (`InProcessLauncher.leaveLabellingToItsChild`), and the recording then ends.
    public static func ready(_ state: MeetingState, inProcess: Bool, recordingHere: Bool) -> Bool {
        if inProcess { return !recordingHere }
        switch state {
        case .starting, .active: return false
        case .idle, .failed, .finishing: return true
        }
    }
}
