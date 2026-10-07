import CoreGraphics
import Foundation
import HolosStorage

/// A connected display as the capture sees it when it starts (docs/meeting-design.md §4.15).
public struct ScreenDisplayCandidate: Sendable, Equatable {
    public var id: CGDirectDisplayID
    /// Where it sits in the arrangement, in global points (the main display's origin is 0, 0).
    public var frame: CGRect
    /// The display with the menu bar.
    public var isMain: Bool

    public init(id: CGDirectDisplayID, frame: CGRect, isMain: Bool) {
        self.id = id; self.frame = frame; self.isMain = isMain
    }
}

/// The numbers of the displays a capture starts with (docs/meeting-design.md §4.15). Pure. A display the meeting's
/// saved keyframes already name keeps its number (a recorder restart in a new epoch); the others are numbered after
/// every number used so far, by arrangement: left to right, then top to bottom. A display past
/// `ScreenContextStore.maximumDisplays` is not captured.
enum ScreenDisplayNumbering {
    static func number(_ candidates: [ScreenDisplayCandidate], known: [ScreenDisplay]) -> [ScreenDisplay] {
        var numbers: [CGDirectDisplayID: Int] = [:]
        for display in known { numbers[display.id] = display.number }
        var next = (numbers.values.max() ?? 0) + 1
        let arranged = candidates.sorted { ($0.frame.minX, $0.frame.minY, $0.id) < ($1.frame.minX, $1.frame.minY, $1.id) }
        for candidate in arranged where numbers[candidate.id] == nil {
            numbers[candidate.id] = next
            next += 1
        }
        return arranged.compactMap { candidate in
            guard let number = numbers[candidate.id], number <= ScreenContextStore.maximumDisplays else { return nil }
            return ScreenDisplay(id: candidate.id, number: number, isMain: candidate.isMain)
        }.sorted { $0.number < $1.number }
    }
}

/// The storage caps every display of a meeting shares (docs/meeting-design.md §4.15): 1000 keyframes and 256 MiB of
/// JPEGs in all. Pure, so the order in which displays stop is tested without a screen.
///
/// Each display beyond the first holds back a tenth of either cap (at most three tenths) for the others. Once the
/// meeting has used the rest, the busiest display (the one that saved the most keyframes, as a call's moving video or
/// a scrolled document does) stops, so a quieter one (slides) keeps coming. The last display runs to the cap itself,
/// which ends the capture and says so, as with one display. With one display nothing changes.
public enum ScreenStoragePolicy {
    public struct Usage: Sendable, Equatable {
        public var display: ScreenDisplay
        /// Keyframes this display saved in the meeting.
        public var keyframes: Int
        /// JPEG bytes this display saved in the meeting (the average for a keyframe saved without its size).
        public var bytes: Int

        public init(display: ScreenDisplay, keyframes: Int, bytes: Int) {
            self.display = display; self.keyframes = keyframes; self.bytes = bytes
        }
    }

    public static let reservePerDisplay = 0.1
    public static let maximumReserve = 0.3

    /// Nothing more may be saved: the meeting has reached the keyframe or the byte cap.
    public static func full(frames: Int, bytes: Int, maximumFrames: Int = ScreenContextStore.maximumFrames,
                            maximumBytes: Int = ScreenContextStore.maximumTotalImageBytes) -> Bool {
        frames >= maximumFrames || bytes >= maximumBytes
    }

    /// The share of either cap at which, with `running` displays still capturing, the busiest one stops.
    static func threshold(running: Int) -> Double {
        1 - min(Double(max(0, running - 1)) * reservePerDisplay, maximumReserve)
    }

    /// The displays to stop now, busiest first, after a keyframe was saved: while more than one display captures and
    /// the meeting's keyframes or bytes have reached `threshold` for that many, the busiest stops.
    public static func displaysToStop(_ running: [Usage], frames: Int, bytes: Int,
                                      maximumFrames: Int = ScreenContextStore.maximumFrames,
                                      maximumBytes: Int = ScreenContextStore.maximumTotalImageBytes) -> [UInt32] {
        let frameShare = Double(frames) / Double(max(1, maximumFrames))
        let byteShare = Double(bytes) / Double(max(1, maximumBytes))
        let used = max(frameShare, byteShare)
        var remaining = busiestFirst(running, byBytes: byteShare > frameShare)
        var stopped: [UInt32] = []
        while remaining.count > 1, used >= threshold(running: remaining.count) {
            stopped.append(remaining.removeFirst().display.id)
        }
        return stopped
    }

    /// Most keyframes first, then most bytes; by bytes first when the byte cap is the nearer one. On a tie a display
    /// other than the main one goes first, then the higher number, so the main display (all that was captured
    /// before) is the one that stays.
    static func busiestFirst(_ usage: [Usage], byBytes: Bool) -> [Usage] {
        usage.sorted { left, right in
            let l = byBytes ? (left.bytes, left.keyframes) : (left.keyframes, left.bytes)
            let r = byBytes ? (right.bytes, right.keyframes) : (right.keyframes, right.bytes)
            if l != r { return l > r }
            if left.display.isMain != right.display.isMain { return !left.display.isMain }
            return left.display.number > right.display.number
        }
    }
}
