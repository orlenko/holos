import Foundation

/// What the menu's Copy Result and Copy Original offer after a dictation.
public struct DictationResult: Equatable, Sendable {
    /// Copy Result: the transcript, or the part of it that was not written.
    public var text: String
    /// Copy Original: the text as heard, when Apple Intelligence's fix changed what was written.
    public var original: String

    public init(text: String = "", original: String = "") {
        self.text = text
        self.original = original
    }

    /// True when there is nothing worth copying (whitespace only counts as nothing).
    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Keeps the last dictation's result until a later dictation produces one of its own. Dictated text is never put
/// on the clipboard automatically, so a press that is cancelled, released before listening, or recognizes nothing
/// must not throw away the previous result's unwritten text.
public struct ResultRetention: Equatable, Sendable {
    public enum Conclusion: Equatable, Sendable {
        /// The dictation produced a result, which replaced the kept one; its ten-minute expiry starts now.
        case replaced
        /// The dictation produced nothing; the previous result (and its expiry) stays as it was.
        case keptPrevious
        /// The dictation produced nothing and there is no earlier result, or no dictation was waiting to conclude.
        case nothing
    }

    /// The result the menu offers.
    public private(set) var kept = DictationResult()
    /// True between a dictation's key-down and its conclusion.
    public private(set) var awaiting = false

    public init() {}

    /// A dictation started; it concludes once, however it ends.
    public mutating func begin() { awaiting = true }

    /// The dictation that began ended with `result` (empty when it produced nothing). Later calls, until the next
    /// `begin`, change nothing, so a stray end (a reset after the result) never replaces or clears the kept result.
    public mutating func conclude(_ result: DictationResult) -> Conclusion {
        guard awaiting else { return .nothing }
        awaiting = false
        if !result.isEmpty {
            kept = result
            return .replaced
        }
        return kept.isEmpty ? .nothing : .keptPrevious
    }

    /// Discard Result or the ten-minute expiry. A dictation in progress still concludes normally.
    public mutating func discard() { kept = DictationResult() }
}
