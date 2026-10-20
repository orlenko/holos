/// Dictation pauses for sleep or an inactive login session (docs/design.md "Dictation").
///
/// Invariants:
/// 1. Enabling is blocked until every outstanding interruption ends.
/// 2. Returning restores dictation only when it was enabled or enabling before suspension.
/// 3. Explicitly disabling clears the restore request; duplicate notifications never create one.
public struct DictationSessionPolicy: Sendable, Equatable {
    public enum Interruption: Sendable, Hashable { case sleep, inactiveSession }
    private var interruptions: Set<Interruption> = []
    private var resumeRequested = false
    public var suspended: Bool { !interruptions.isEmpty }
    public init() {}

    public mutating func suspend(for reason: Interruption, wasEnabled: Bool) {
        resumeRequested = resumeRequested || wasEnabled
        interruptions.insert(reason)
    }

    /// Consumes a restore request once, after both sleep and session changes have ended.
    public mutating func resume(from reason: Interruption) -> Bool {
        guard interruptions.remove(reason) != nil, interruptions.isEmpty else { return false }
        let restore = resumeRequested
        resumeRequested = false
        return restore
    }

    public mutating func didDisable() { resumeRequested = false }
    public mutating func didEnable() { resumeRequested = false }
    /// Neither explicit setup nor a background download can enable during an interruption.
    public func allowsSetupEnable(deferred: Bool) -> Bool { !suspended }
}
