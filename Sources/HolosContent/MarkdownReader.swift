import Foundation

/// Markdown through Foundation's parser: headings become sections, emphasis and link markup
/// are dropped (link text is kept), list items and quotes become paragraphs (ordered items keep
/// their numbers: "1. Preheat"), table rows are read cell by cell, and code blocks, images, and
/// thematic breaks are skipped. YAML front matter supplies the title and author.
public enum MarkdownReader {
    public static func document(from markdown: String) -> ReadableDocument {
        let (frontMatter, body) = splitFrontMatter(DocumentText.normalized(markdown))
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: body, options: options) else {
            let plain = PlainTextReader.document(from: body)
            return ReadableDocument(title: frontMatter["title"] ?? plain.title,
                                    author: frontMatter["author"], sections: plain.sections)
        }

        enum Kind { case heading(Int), paragraph, row }
        struct Block { var identity: Int; var kind: Kind; var text: String; var cell: Int? }
        var blocks: [Block] = []
        // List items whose number has been read: only an item's first block starts with it.
        var numberedItems = Set<Int>()
        for run in parsed.runs {
            guard run.imageURL == nil, let intent = run.presentationIntent else { continue }
            // Innermost first: [paragraph, listItem 2, orderedList, listItem 4, orderedList, ...].
            let components = intent.components
            // Code is not read aloud; a thematic break ("---", parsed as "⸻") only separates blocks.
            if components.contains(where: {
                switch $0.kind { case .codeBlock, .thematicBreak: true; default: false }
            }) { continue }
            let text = String(parsed[run.range].characters)
            var kind = Kind.paragraph
            var identity = components.first?.identity ?? -1
            var cell: Int?
            var marker: String?
            var innermostItem = true
            for (index, component) in components.enumerated() {
                switch component.kind {
                case .header(let level): kind = .heading(level)
                case .tableCell: cell = component.identity
                case .tableRow, .tableHeaderRow:
                    kind = .row
                    identity = component.identity
                case .listItem(let ordinal):
                    // Foundation drops the "3." from the text and keeps the number here (it
                    // honors a list's start number). Bullets are not read; nested items read
                    // their own number.
                    guard innermostItem else { break }
                    innermostItem = false
                    let parent = components.indices.contains(index + 1) ? components[index + 1].kind : nil
                    if case .orderedList = parent, !numberedItems.contains(component.identity) {
                        numberedItems.insert(component.identity)
                        marker = "\(ordinal). "
                    }
                // Block quotes read as their paragraphs; lists, tables, and the document itself
                // carry nothing to read.
                default: break
                }
            }
            if let last = blocks.last, last.identity == identity {
                var merged = last
                if case .row = kind, let cell, last.cell != cell { merged.text += "; " }
                merged.text += text
                merged.cell = cell
                blocks[blocks.count - 1] = merged
            } else {
                blocks.append(Block(identity: identity, kind: kind, text: (marker ?? "") + text, cell: cell))
            }
        }

        var builder = ReadableDocument.Builder()
        for block in blocks {
            switch block.kind {
            case .heading(let level): builder.heading(block.text, level: level)
            case .paragraph, .row: builder.paragraph(block.text)
            }
        }
        return ReadableDocument(title: frontMatter["title"] ?? builder.leadingTitle,
                                author: frontMatter["author"], language: frontMatter["lang"] ?? frontMatter["language"],
                                sections: builder.sections)
    }

    /// `---` YAML front matter: simple `key: value` lines only.
    static func splitFrontMatter(_ text: String) -> ([String: String], String) {
        guard text.hasPrefix("---\n") else { return ([:], text) }
        let lines = text.components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else { return ([:], text) }
        var values: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty { values[key] = value }
        }
        return (values, lines[(end + 1)...].joined(separator: "\n"))
    }
}
