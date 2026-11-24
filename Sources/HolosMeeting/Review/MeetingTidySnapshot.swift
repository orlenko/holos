import Foundation
import HolosCore
import HolosSpeakers

/// A captured transcript for a separate, plain-text cleanup export (docs/meeting/exports.md §4.11).
/// Each request contains only a speaker block's text. Its label, time and overlap stay outside the model.
public struct MeetingTidySnapshot: Sendable, Codable {
    public struct Block: Sendable, Codable {
        public let heading: String
        public let text: String
    }

    public let title: String
    public let blocks: [Block]

    public init(document: ExportDocument) {
        title = Self.singleLine(document.metadata.name)
        blocks = TranscriptExporter.blocks(document).map { block in
            var heading = "\(TimeFormat.clock(block.start))  \(Self.singleLine(block.speakerLabel))"
            if !block.overlapWith.isEmpty {
                heading += " (overlapping with \(block.overlapWith.map(Self.singleLine).joined(separator: ", ")))"
            }
            return Block(heading: heading, text: block.text)
        }
    }

    public var original: String { result(blocks.map { part($0, edited: $0.text) }).text }

    /// Sends only blocks without numbers or comparison notation. Keeps edits that preserve the spoken word sequence.
    /// A cancellation discards the whole export.
    public func tidy(using tidier: TextTidier,
                     progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> TextTidier.Result {
        var parts: [TextTidier.Part] = []
        for (index, block) in blocks.enumerated() {
            try Task.checkCancellation()
            progress(index, blocks.count)
            if block.text.contains(where: Self.isNumericNotation) {
                parts.append(part(block, edited: block.text, kept: "it contains numbers or comparison notation"))
                continue
            }
            let edit = try await tidier.tidy(block.text)
            let reason = edit.parts.compactMap(\.kept).first ?? Self.refusal(original: block.text, edited: edit.text)
            parts.append(part(block, edited: reason == nil ? edit.text : block.text, kept: reason))
        }
        try Task.checkCancellation()
        progress(blocks.count, blocks.count)
        return result(parts)
    }

    private func part(_ block: Block, edited: String, kept: String? = nil) -> TextTidier.Part {
        let prefix = block.heading + "\n"
        return TextTidier.Part(original: prefix + block.text, text: prefix + edited, separator: "\n\n", kept: kept)
    }

    private func result(_ parts: [TextTidier.Part]) -> TextTidier.Result {
        TextTidier.Result(parts: parts, leading: title + "\n\n", trailing: "\n")
    }

    private static func refusal(original: String, edited: String) -> String? {
        guard WordChanges.words(in: original).map(\.word) == WordChanges.words(in: edited).map(\.word) else {
            return "the model changed the spoken words"
        }
        guard !edited.contains(where: isNumericNotation) else {
            return "the model added numbers or comparison notation"
        }
        return nil
    }

    private static func isNumericNotation(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .decimalNumber, .letterNumber, .otherNumber, .currencySymbol: true
            default: "<>=≤≥≠≈≲≳~±+−%‰‱°".unicodeScalars.contains(scalar)
            }
        }
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
