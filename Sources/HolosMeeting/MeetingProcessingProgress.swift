import Foundation
import HolosCore

/// The current processing progress of a meeting, read off the main actor.
public enum MeetingProcessingProgress {
    public static func read(session: URL) -> PostProcessingProgress? {
        guard let record = try? SessionFiles.postProcessingRecord(session: session),
              record.state == .running else { return nil }
        return record.progress
    }
}
