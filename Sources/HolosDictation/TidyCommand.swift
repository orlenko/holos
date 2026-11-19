import Foundation
import HolosCore

/// `voiceislocal tidy` (docs/design.md "Tidy Up"): one text tidied by one model, with the words it changed.
public enum TidyCommand {
    /// Which model tidies.
    public enum Engine: String, Sendable, Codable, CaseIterable {
        /// Apple's on-device model (`OnDeviceTidy`).
        case apple
    }

    public struct Outcome: Sendable, Codable, Equatable {
        public var engine: Engine
        /// The tidied text.
        public var text: String
        /// Each part as sent and as used; a part that kept its own text says why.
        public var parts: [TextTidier.Part]
        /// The words `text` changed from the text given, for marking (`WordChanges.between`).
        public var changes: [WordChanges.Change]

        public init(engine: Engine, text: String, parts: [TextTidier.Part], changes: [WordChanges.Change]) {
            self.engine = engine
            self.text = text
            self.parts = parts
            self.changes = changes
        }

        /// The parts that kept their own text.
        public var keptParts: [TextTidier.Part] { parts.filter { $0.kept != nil } }
        /// Every part kept its own text: nothing was tidied.
        public var nothingTidied: Bool { parts.allSatisfy { $0.kept != nil } }
    }

    /// Tidies `text` with `tidier` (the model of `engine`), reporting `progress(done, total)` in parts. Throws
    /// `CancellationError` when cancelled.
    public static func run(_ text: String, engine: Engine, tidier: TextTidier,
                           progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Outcome {
        let result = try await tidier.tidy(text, progress: progress)
        return Outcome(engine: engine, text: result.text, parts: result.parts,
                       changes: WordChanges.between(text, result.text))
    }
}
