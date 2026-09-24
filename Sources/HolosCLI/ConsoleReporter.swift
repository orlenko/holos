import HolosCore
import HolosMeeting

/// Prints finalized phrases to stdout and progress or warnings to stderr.
struct ConsoleReporter: RecordingReporter {
    func phrase(_ segment: TranscriptSegment, track: String) { Console.segment(segment, track: track) }
    func message(_ text: String) { Console.error(text) }
}
