import Foundation

/// Remembers the last value a view showed, to tell whether a new one needs a redraw (the review window's playback
/// state, docs/meeting-design.md §5.10). Compares whole values, so a change between two states that are alike in one
/// respect (loading → off, both not ready) still counts.
public struct StateChangeTracker<Value: Equatable> {
    public private(set) var shown: Value?

    public init() {}

    /// Records `value` and returns whether it differs from the last one recorded (always true the first time).
    public mutating func update(_ value: Value) -> Bool {
        guard shown != value else { return false }
        shown = value
        return true
    }
}

extension StateChangeTracker: Sendable where Value: Sendable {}
