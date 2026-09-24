import Foundation

/// Swaps that learning declined (see `CorrectionList.learnReportingDeclined`), kept until the user adds
/// or skips each one, so every declined pair can still be added by hand.
public struct DeclinedCorrectionQueue: Equatable, Sendable {
    /// An edited transcript whose only changes were declined swaps. It becomes the last transcript once
    /// the user adds one of its swaps, provided the last recognized text is still the one it was edited from.
    public struct PendingEdit: Equatable, Sendable {
        public var recognized: String
        public var edited: String

        public init(recognized: String, edited: String) {
            self.recognized = recognized
            self.edited = edited
        }

        /// The transcript to keep when one of this edit's swaps is added: the edited text while
        /// `lastRecognized` is still the text it was edited from, otherwise nil.
        public func transcript(whenLastRecognized lastRecognized: String) -> String? {
            recognized == lastRecognized ? edited : nil
        }
    }

    /// A waiting swap and the edit it came from (nil when that edit was already kept).
    public struct Item: Equatable, Sendable {
        public var correction: Correction
        public var edit: PendingEdit?

        public init(correction: Correction, edit: PendingEdit? = nil) {
            self.correction = correction
            self.edit = edit
        }
    }

    public private(set) var items: [Item] = []

    public init(pending: [Correction] = []) {
        receive(pending)
    }

    public var pending: [Correction] { items.map(\.correction) }

    public var isEmpty: Bool { items.isEmpty }

    /// Adds newly declined swaps from `edit` behind the ones already waiting; a swap for a phrase already
    /// waiting replaces it in place.
    public mutating func receive(_ declined: [Correction], edit: PendingEdit? = nil) {
        for correction in declined {
            let item = Item(correction: correction, edit: edit)
            let key = CorrectionList.normalized(correction.heard)
            if let index = items.firstIndex(where: { CorrectionList.normalized($0.correction.heard) == key }) {
                items[index] = item
            } else {
                items.append(item)
            }
        }
    }

    /// The pair to put in the Add fields: the next waiting one, but only when both fields are blank, so
    /// input the user already typed is never replaced.
    public func prefill(heard: String, meant: String) -> Correction? {
        guard heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              meant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return items.first?.correction
    }

    /// Records a successful Add. Adding a rule for a waiting phrase resolves it (the rule list keys on
    /// the heard phrase), even if the user changed the meant text. Returns the resolved item, if any.
    @discardableResult
    public mutating func resolve(added correction: Correction) -> Item? {
        let key = CorrectionList.normalized(correction.heard)
        guard let index = items.firstIndex(where: { CorrectionList.normalized($0.correction.heard) == key }) else {
            return nil
        }
        return items.remove(at: index)
    }

    /// Drops the next waiting pair without adding it.
    @discardableResult
    public mutating func skip() -> Correction? {
        items.isEmpty ? nil : items.removeFirst().correction
    }

    public mutating func removeAll() {
        items.removeAll()
    }
}
