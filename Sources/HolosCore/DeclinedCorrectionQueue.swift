import Foundation

/// Swaps that learning declined (see `CorrectionList.learnReportingDeclined`), kept until the user adds
/// or skips each one, so every declined pair can still be added by hand.
public struct DeclinedCorrectionQueue: Equatable, Sendable {
    public private(set) var pending: [Correction] = []

    public init(pending: [Correction] = []) {
        receive(pending)
    }

    public var isEmpty: Bool { pending.isEmpty }

    /// Adds newly declined swaps behind the ones already waiting; a swap for a phrase already waiting
    /// replaces it in place.
    public mutating func receive(_ declined: [Correction]) {
        for correction in declined {
            let key = CorrectionList.normalized(correction.heard)
            if let index = pending.firstIndex(where: { CorrectionList.normalized($0.heard) == key }) {
                pending[index] = correction
            } else {
                pending.append(correction)
            }
        }
    }

    /// The pair to put in the Add fields: the next waiting one, but only when both fields are blank, so
    /// input the user already typed is never replaced.
    public func prefill(heard: String, meant: String) -> Correction? {
        guard heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              meant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return pending.first
    }

    /// Records a successful Add. Adding a rule for a waiting phrase resolves it (the rule list keys on
    /// the heard phrase), even if the user changed the meant text. Returns whether one was resolved.
    @discardableResult
    public mutating func resolve(added correction: Correction) -> Bool {
        let key = CorrectionList.normalized(correction.heard)
        guard let index = pending.firstIndex(where: { CorrectionList.normalized($0.heard) == key }) else {
            return false
        }
        pending.remove(at: index)
        return true
    }

    /// Drops the next waiting pair without adding it.
    @discardableResult
    public mutating func skip() -> Correction? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    public mutating func removeAll() {
        pending.removeAll()
    }
}
