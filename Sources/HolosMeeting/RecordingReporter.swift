import HolosCore

/// Where a recording reports what it is doing. The CLI prints; the app keeps its own presentation.
public protocol RecordingReporter: Sendable {
    /// A finalized phrase. The CLI prints it (PR2a: unless --no-live-text).
    func phrase(_ segment: TranscriptSegment, track: String)
    /// A progress or warning line (stderr in the CLI).
    func message(_ text: String)
}
