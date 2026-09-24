import Foundation
import HolosCore

/// Timeline order shared by the projection and the exports: turns by start, a start that is not a number last.
enum TurnOrder {
    /// The start a turn sorts by: NaN sorts after every time, so sorting stays a strict weak order.
    static func sortKey(_ start: Double) -> Double {
        start.isNaN ? .infinity : start
    }

    /// Whether a turn at (`leftStart`, `leftTrack`) comes before one at (`rightStart`, `rightTrack`); nil when both
    /// keys are equal and the caller breaks the tie.
    static func precedes(_ leftStart: Double, _ leftTrack: String, _ rightStart: Double, _ rightTrack: String) -> Bool? {
        let left = sortKey(leftStart)
        let right = sortKey(rightStart)
        if left != right { return left < right }
        if leftTrack != rightTrack { return leftTrack < rightTrack }
        return nil
    }
}

extension WordTimingQuality {
    /// `measured` when no word is estimated, `estimated` when every word is, `mixed` otherwise.
    init(estimated: Int, of count: Int) {
        self = estimated == 0 ? .measured : estimated == count ? .estimated : .mixed
    }
}
