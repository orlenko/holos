import Foundation

/// What a person reading a book aloud would leave out, and where they would read its notes.
///
/// A PDF says little about itself, so this reads its structure: the outline's names for its parts, the font sizes that
/// set a footnote and a note's little number apart from the text, and the numbering that ties the two together.
///
/// Invariants:
/// 1. Nothing is left out unless a part names itself (the outline) or looks unmistakably like front or back matter.
/// 2. A marker is a small run of digits or a symbol straight after text. It is never spoken: its note is, after the
///    sentence holding it, or it goes silently when no note is found.
/// 3. Notes that do not pair with the text's markers are not lost: their section is read as ordinary text.
/// 4. A note is said once per marker, in its own paragraph, as "Footnote: …".
enum PDFBookStructure {
    /// One page's text, each marker replaced by a `markerScalar`, with the size of each line's main font.
    struct Page: Equatable {
        var text: String
        var lineSizes: [String: Double] = [:]
        /// How high on the page each line stands, where the file can tell.
        var lineLevels: [String: Double] = [:]
    }

    struct OutlineEntry: Equatable {
        let label: String
        let page: Int
    }

    enum Role: Equatable { case body, skipped, notes }

    private struct Note {
        let label: String
        var text: String
    }

    // MARK: - Markers

    /// A marker stands in the text as one scalar of a private-use plane, so reflowing lines cannot split or lose it.
    private static let markerBase: UInt32 = 0xF0000
    private static let markerLimit = 0xFFFD

    static func markerScalar(_ index: Int) -> Character? {
        guard index >= 0, index < markerLimit, let scalar = Unicode.Scalar(markerBase + UInt32(index)) else { return nil }
        return Character(scalar)
    }

    private static func markerIndex(_ scalar: Unicode.Scalar) -> Int? {
        let value = scalar.value
        guard value >= markerBase, value < markerBase + UInt32(markerLimit) else { return nil }
        return Int(value - markerBase)
    }

    /// `text` without trailing markers: what a line ends with when its sentence ended before the little number.
    static func withoutTrailingMarkers(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let last = scalars.last, markerIndex(last) != nil { scalars.removeLast() }
        return String(scalars)
    }

    /// Digits or a footnote symbol, as a marker's text.
    static func isMarkerText(_ text: String) -> Bool {
        (1...3).contains(text.count) && (text.allSatisfy { $0.isASCII && $0.isNumber }
            || text.allSatisfy { "*†‡§".contains($0) })
    }

    // MARK: - The whole book

    /// The book's paragraphs: `pages` (with `markers`, the text of each marker scalar in them) without its furniture,
    /// without the parts nobody reads aloud, and with each note after the sentence that cites it.
    static func paragraphs(pages: [Page], markers: [String], outline: [OutlineEntry], bodySize: Double,
                           hasTitle: Bool) -> [String] {
        var footnotes: [[Note]] = []
        var stripped: [[String]] = []
        for page in pages {
            let (lines, notes) = pageFootnotes(page, markers: markers, bodySize: bodySize,
                                               previous: footnotes.last?.last)
            // A note running over from the page before belongs to that page's last note.
            if let carried = notes.carried, !footnotes.isEmpty, !footnotes[footnotes.count - 1].isEmpty {
                let last = footnotes[footnotes.count - 1].count - 1
                footnotes[footnotes.count - 1][last].text = joined(footnotes[footnotes.count - 1][last].text, carried)
            }
            footnotes.append(notes.notes)
            stripped.append(lines)
        }
        let content = PDFReader.pageContent(stripped)
        var roles = self.roles(content: content, outline: outline, hasTitle: hasTitle)
        let endnotes = endnoteBlocks(content: content, roles: roles, pages: pages)
        let resolved = resolve(content: content, roles: roles, markers: markers, footnotes: footnotes,
                               endnotes: endnotes)
        // Invariant 3.
        if !resolved.endnotesPaired { roles = roles.map { $0 == .notes ? .body : $0 } }
        let spoken = content.indices.filter { roles[$0] == .body }.map { content[$0] }
        let literal = markers.count < 3
        return PDFReader.reflow(content: spoken).flatMap { paragraph in
            expand(paragraph, notes: resolved.endnotesPaired ? resolved.notes : resolved.footnotesOnly, markers: markers,
                   literal: literal)
        }
    }

    // MARK: - Footnotes at the foot of a page

    /// Takes the block of smaller lines at the foot of `page` off it, when it opens with a marker this page uses (or
    /// runs on from the note before). A page number under the block stays, for `pageContent` to drop.
    private static func pageFootnotes(_ page: Page, markers: [String], bodySize: Double, previous: Note?)
        -> (lines: [String], notes: (notes: [Note], carried: String?)) {
        let lines = PDFReader.lines(of: page.text)
        guard bodySize > 0, !lines.isEmpty else { return (lines, ([], nil)) }
        var end = lines.count
        while end > 0, lines[end - 1].isEmpty || PDFReader.bareNumber(lines[end - 1]) != nil
            || PDFReader.isPageLabel(lines[end - 1]) { end -= 1 }
        var start = end
        while start > 0, !lines[start - 1].isEmpty, let size = page.lineSizes[lines[start - 1]], size > 0,
              size <= bodySize * 0.95 { start -= 1 }
        guard start < end, start > 0 else { return (lines, ([], nil)) }
        let used = Set(lines[..<start].joined().unicodeScalars.compactMap(markerIndex)
            .compactMap { markers.indices.contains($0) ? markers[$0] : nil })
        var notes: [Note] = []
        var carried: String?
        for line in lines[start..<end] {
            if let (label, rest) = noteStart(line), used.contains(label) {
                notes.append(Note(label: label, text: rest))
            } else if !notes.isEmpty {
                notes[notes.count - 1].text = joined(notes[notes.count - 1].text, line)
            } else if previous != nil {
                carried = carried.map { joined($0, line) } ?? line
            } else {
                return (lines, ([], nil))
            }
        }
        guard !notes.isEmpty || carried != nil else { return (lines, ([], nil)) }
        return (Array(lines[..<start]) + Array(lines[end...]), (notes, carried))
    }

    /// "14 Text", "14. Text", "* Text": the note's label and its text.
    private static func noteStart(_ line: String) -> (label: String, text: String)? {
        let clean = String(String.UnicodeScalarView(line.unicodeScalars.filter { markerIndex($0) == nil }))
        let label = String(clean.prefix { $0.isASCII && $0.isNumber || "*†‡§".contains($0) })
        guard isMarkerText(label) else { return nil }
        var rest = clean.dropFirst(label.count)
        if let first = rest.first, ".):".contains(first) { rest = rest.dropFirst() }
        guard rest.isEmpty || rest.first?.isWhitespace == true || rest.first?.isLetter == true else { return nil }
        return (label, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func joined(_ first: String, _ second: String) -> String {
        if first.hasSuffix("-"), first.dropLast().last?.isLetter == true, second.first?.isLowercase == true {
            return String(first.dropLast()) + second
        }
        return first.isEmpty ? second : first + " " + second
    }

    // MARK: - Parts of the book

    /// What each page is: named by the outline, else recognized by its look.
    static func roles(content: [[String]], outline: [OutlineEntry], hasTitle: Bool) -> [Role] {
        var roles = [Role](repeating: .body, count: content.count)
        let sorted = outline.filter { content.indices.contains($0.page) }.sorted { $0.page < $1.page }
        for (index, entry) in sorted.enumerated() {
            guard let role = role(named: entry.label, hasTitle: hasTitle) else { continue }
            let end = sorted[(index + 1)...].first { $0.page > entry.page }?.page ?? content.count
            for page in entry.page..<end { roles[page] = role }
        }
        // A wrong outline, or one with nothing else in it, must not silence the book (invariant 1).
        let silent = roles.filter { $0 != .body }.count
        if silent * 10 > content.count * 8 { roles = [Role](repeating: .body, count: content.count) }
        recognize(content, into: &roles)
        return roles
    }

    private static func role(named label: String, hasTitle: Bool) -> Role? {
        let name = label.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
        switch name {
        case "notes", "endnotes", "end notes", "footnotes": return .notes
        case "cover", "front cover", "back cover", "half title", "halftitle", "half title page", "series page",
             "endorsement", "endorsements", "endorsement page", "praise", "copyright", "copyright page", "imprint",
             "contents", "table of contents", "toc", "brief contents", "list of figures", "list of tables",
             "list of illustrations", "index", "subject index", "name index", "author index", "bibliography",
             "references", "works cited", "other books by", "also by":
            return .skipped
        case "title", "title page": return hasTitle ? .skipped : nil
        default: return nil
        }
    }

    /// Pages no outline named: the contents and the copyright page near the start, the index and notes near the end.
    private static func recognize(_ content: [[String]], into roles: inout [Role]) {
        let early = min(content.count, max(8, min(30, content.count / 4)))
        var index = 0
        while index < early {
            defer { index += 1 }
            guard roles[index] == .body else { continue }
            if isCopyrightPage(content[index]) { roles[index] = .skipped }
            guard opens(content[index], with: ["contents", "table of contents"]), share(content[index], endingInANumber) >= 0.5
            else { continue }
            var page = index
            while page < content.count, page == index || share(content[page], endingInANumber) >= 0.6 {
                if roles[page] == .body { roles[page] = .skipped }
                page += 1
            }
        }
        guard content.count >= 8 else { return }
        for page in (content.count * 3 / 5)..<content.count where roles[page] == .body {
            if opens(content[page], with: ["index"]), share(content[page], endingInANumber) >= 0.5 {
                for rest in page..<content.count where roles[rest] == .body { roles[rest] = .skipped }
                break
            }
            if opens(content[page], with: ["notes", "endnotes"]), share(content[page], startingWithANumber) >= 0.3 {
                var rest = page
                while rest < content.count, rest == page || share(content[rest], startingWithANumber) >= 0.1,
                      roles[rest] == .body {
                    roles[rest] = .notes
                    rest += 1
                }
            }
        }
    }

    private static func opens(_ lines: [String], with names: Set<String>) -> Bool {
        lines.prefix(2).contains { names.contains($0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func share(_ lines: [String], _ test: (String) -> Bool) -> Double {
        let filled = lines.filter { !$0.isEmpty }
        return filled.isEmpty ? 0 : Double(filled.filter(test).count) / Double(filled.count)
    }

    private static func endingInANumber(_ line: String) -> Bool {
        line.range(of: #"(\s|\.)(\d{1,4}|[ivxlc]{1,7})$"#, options: .regularExpression) != nil
    }

    private static func startingWithANumber(_ line: String) -> Bool {
        line.range(of: #"^\d{1,3}[.)]?\s"#, options: .regularExpression) != nil
    }

    private static func isCopyrightPage(_ lines: [String]) -> Bool {
        let text = lines.joined(separator: " ").lowercased()
        guard text.count < 2_500 else { return false }
        let claims = text.contains("all rights reserved") || text.contains("©") || text.contains("copyright")
        return claims && (text.contains("isbn") || text.contains("first published") || text.contains("library of congress"))
    }

    // MARK: - Notes sections

    /// The notes of the notes pages, a block for each run of numbers: a book numbering its notes per chapter starts
    /// over at 1 for each. A larger line (a chapter's name) is no part of a note, nor is a short line that closes a
    /// block (the name of the chapter whose notes come next, set like the notes).
    private static func endnoteBlocks(content: [[String]], roles: [Role], pages: [Page]) -> [[Int: String]] {
        var blocks: [[Int: String]] = []
        var last: Int?
        var pending: String?
        func flush() {
            guard let line = pending, let last, !blocks.isEmpty, let note = blocks[blocks.count - 1][last] else {
                pending = nil
                return
            }
            blocks[blocks.count - 1][last] = joined(note, line)
            pending = nil
        }
        for index in content.indices where roles[index] == .notes {
            let sizes = pages[index].lineSizes.values.filter { $0 > 0 }.sorted()
            let usual = sizes.isEmpty ? 0 : sizes[sizes.count / 2]
            let lines = numberedAsPrinted(content[index], page: pages[index])
            for (position, line) in lines.enumerated() where !line.isEmpty {
                if let size = pages[index].lineSizes[line], usual > 0, size > usual * 1.08 { continue }
                let unfinished = pending == nil && last.flatMap { blocks.last?[$0] }.map { !PDFReader.endsSentence($0) } ?? false
                if let (label, text) = noteStart(line), let number = Int(label), number == (last ?? 0) + 1
                    || (number == 1 && !unfinished && startsABlock(lines, after: position)) {
                    if number == 1 || blocks.isEmpty {
                        // A short line with no end of its own, right before a new block, names that block's chapter.
                        if let line = pending, line.count > 90 || PDFReader.endsSentence(line) { flush() }
                        pending = nil
                        blocks.append([:])
                    } else {
                        flush()
                    }
                    blocks[blocks.count - 1][number] = text
                    last = number
                } else {
                    flush()
                    pending = line
                }
            }
        }
        flush()
        return blocks
    }

    /// A note 1 opens a block when a note 2 soon follows: "1 Corinthians" inside a note has none.
    private static func startsABlock(_ lines: [String], after position: Int) -> Bool {
        let rest = lines[(position + 1)...].prefix(40)
        return rest.isEmpty || rest.count < 40 || rest.contains { noteStart($0)?.label == "2" }
    }

    /// Some typesetting tools keep a few note numbers in a text layer of their own, which the file gives apart from
    /// their lines, at the top of the page. Each is put back on the line at its height.
    private static func numberedAsPrinted(_ lines: [String], page: Page) -> [String] {
        let orphans = PDFReader.lines(of: page.text).filter { PDFReader.bareNumber($0) != nil }
            .compactMap { line in page.lineLevels[line].map { (number: line, level: $0) } }
        guard !orphans.isEmpty else { return lines }
        return lines.compactMap { line in
            if PDFReader.bareNumber(line) != nil { return nil }
            guard let level = page.lineLevels[line],
                  let orphan = orphans.first(where: { abs($0.level - level) < 3 }) else { return line }
            return orphan.number + " " + line
        }
    }

    /// Each marker's note, going through the text in reading order. A number that does not rise starts the next block
    /// of notes. `endnotesPaired`: most of the markers not at a page's foot found theirs.
    private static func resolve(content: [[String]], roles: [Role], markers: [String], footnotes: [[Note]],
                                endnotes: [[Int: String]])
        -> (notes: [Int: String], footnotesOnly: [Int: String], endnotesPaired: Bool) {
        var notes: [Int: String] = [:]
        var footnotesOnly: [Int: String] = [:]
        var block = 0, last = 0, wanted = 0, found = 0
        for page in content.indices where roles[page] == .body {
            for scalar in content[page].joined().unicodeScalars {
                guard let index = markerIndex(scalar), markers.indices.contains(index) else { continue }
                let label = markers[index]
                if let note = footnotes[page].first(where: { $0.label == label }) ?? (page > 0 ? footnotes[page - 1].first { $0.label == label } : nil) {
                    notes[index] = note.text
                    footnotesOnly[index] = note.text
                    continue
                }
                guard let number = Int(label), !endnotes.isEmpty else { continue }
                wanted += 1
                if number <= last, block + 1 < endnotes.count { block += 1 }
                last = number
                if let note = endnotes[block][number] {
                    notes[index] = note
                    found += 1
                }
            }
        }
        return (notes, footnotesOnly, !endnotes.isEmpty && wanted > 0 && found * 10 >= wanted * 6)
    }

    // MARK: - Saying the notes

    /// The paragraph without its markers, each note in a paragraph of its own after the sentence that cites it. With
    /// `literal`, too few small numbers to be a book's notes (an exponent, say) stay as the text they were.
    private static func expand(_ paragraph: String, notes: [Int: String], markers: [String], literal: Bool) -> [String] {
        var text = String.UnicodeScalarView()
        var cited: [(offset: Int, note: String)] = []
        for scalar in paragraph.unicodeScalars {
            guard let index = markerIndex(scalar) else {
                text.append(scalar)
                continue
            }
            if let note = notes[index] {
                cited.append((String(text).utf16.count, note))
            } else if literal, markers.indices.contains(index) {
                text.append(contentsOf: markers[index].unicodeScalars)
            }
        }
        let plain = String(text)
        guard !cited.isEmpty else { return plain.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [plain] }
        let source = plain as NSString
        var sentenceEnds: [Int] = []
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length),
                                   options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            sentenceEnds.append(NSMaxRange(range))
        }
        var result: [String] = []
        var start = 0
        var pending = cited[...]
        for end in sentenceEnds {
            let due = pending.prefix { $0.offset <= end }
            guard !due.isEmpty else { continue }
            pending = pending.dropFirst(due.count)
            result.append(source.substring(with: NSRange(location: start, length: end - start)))
            start = end
            result.append(contentsOf: due.map { spoken($0.note) })
        }
        if start < source.length { result.append(source.substring(from: start)) }
        result.append(contentsOf: pending.map { spoken($0.note) })
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func spoken(_ note: String) -> String {
        let text = note.trimmingCharacters(in: .whitespaces)
        let ended = text.last.map { ".!?\"”’)".contains($0) } ?? true
        return "Footnote: " + text + (ended ? "" : ".")
    }

    // MARK: - The author

    /// "By <author>", when the file names one that its first pages also print: a file's author field often holds the
    /// account or tool that made the file.
    static func byline(author: String?, pages: [String]) -> String? {
        guard let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty, author.count <= 120,
              author.contains(where: \.isLetter), !author.contains("@"), !author.lowercased().contains(".com"),
              !author.lowercased().contains("www.") else { return nil }
        let key = ReadableDocument.titleKey(author)
        guard !key.isEmpty else { return nil }
        let opening = ReadableDocument.titleKey(pages.prefix(8).joined(separator: " "))
        return (" " + opening + " ").contains(" " + key + " ") ? "By \(author)" : nil
    }
}
