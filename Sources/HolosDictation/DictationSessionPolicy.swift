/// Session suspension is independent of meetings and persists until an explicit enable succeeds.
/// In particular, a deferred Setup Assistant model-download completion cannot undo it.
public struct DictationSessionPolicy: Sendable, Equatable {
    public private(set) var suspended = false
    public init() {}
    public mutating func suspend() { suspended = true }
    public mutating func didEnable() { suspended = false }
    /// Finishing setup with an explicit enable choice is allowed; a background completion is not.
    public func allowsSetupEnable(deferred: Bool) -> Bool { !deferred || !suspended }
}
