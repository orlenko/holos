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
/// 3. No note is lost: when the markers do not pair with the notes, the notes section is read as ordinary text, and
///    when they do, a note no marker cited is said at the end of the book.
/// 4. A note is said once per marker, in its own paragraph, as "Footnote: …".
enum PDFBookStructure {
    /// One page's text, each marker replaced by a `markerScalar`, with the size of each line's main font.
    struct Page: Equatable {
        var text: String
        var lineSizes: [String: Double] = [:]
    }

    struct OutlineEntry: Equatable {
        let label: String
        let page: Int
        /// How deep in the outline: a part runs to the next entry at its own depth or above.
        var level = 0
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
                           hasTitle: Bool) throws -> [String] {
        // The furniture goes first, so a small running footer is not taken for the end of a footnote.
        let framed = PDFReader.pageContent(pages.map { PDFReader.lines(of: $0.text) })
        var footnotes: [[Note]] = []
        var content: [[String]] = []
        // The note a page's unmarked small print can run on from: the last one begun, while each page since ran it on.
        var owner: (page: Int, note: Int)?
        for (page, framedLines) in zip(pages, framed) {
            try Task.checkCancellation()
            let (lines, notes) = pageFootnotes(page, lines: framedLines, markers: markers, bodySize: bodySize,
                                               previous: owner.map { footnotes[$0.page][$0.note] })
            // A note running over from the page before belongs to that page's last note.
            if let carried = notes.carried, let owner {
                footnotes[owner.page][owner.note].text = joined(footnotes[owner.page][owner.note].text, carried)
            }
            footnotes.append(notes.notes)
            if !notes.notes.isEmpty {
                owner = (footnotes.count - 1, notes.notes.count - 1)
            } else if notes.carried == nil {
                owner = nil
            }
            content.append(lines)
        }
        var roles = self.roles(content: content, outline: outline, hasTitle: hasTitle)
        try Task.checkCancellation()
        let (endnotes, symbolic) = endnoteBlocks(content: content, roles: roles, pages: pages, outline: outline)
        let resolved = resolve(content: content, roles: roles, markers: markers, footnotes: footnotes,
                               endnotes: endnotes, partStarts: chapterStarts(outline, hasTitle: hasTitle))
        // Invariant 3.
        if !resolved.endnotesPaired { roles = roles.map { $0 == .notes ? .body : $0 } }
        let bodyPages = content.indices.filter { roles[$0] == .body }.map { content[$0] }
        let literal = markers.count < 3
        try Task.checkCancellation()
        let body = PDFReader.reflow(content: bodyPages).flatMap { paragraph in
            expand(paragraph, notes: resolved.endnotesPaired ? resolved.notes : resolved.footnotesOnly, markers: markers,
                   literal: literal)
        }
        return body + (resolved.endnotesPaired ? (symbolic + resolved.uncited).map(Self.spoken) : [])
    }

    // MARK: - Footnotes at the foot of a page

    /// Takes the block of smaller lines at the foot of `page` off it, when it opens with a marker this page uses (or
    /// runs on from the note before). A page number under the block stays, for `pageContent` to drop.
    private static func pageFootnotes(_ page: Page, lines: [String], markers: [String], bodySize: Double, previous: Note?)
        -> (lines: [String], notes: (notes: [Note], carried: String?)) {
        guard bodySize > 0, !lines.isEmpty else { return (lines, ([], nil)) }
        var end = lines.count
        while end > 0, lines[end - 1].isEmpty || PDFReader.bareNumber(lines[end - 1]) != nil
            || PDFReader.isPageLabel(lines[end - 1]) { end -= 1 }
        var start = end
        // Blank lines can separate the notes. A page all small print is only a note running on, from one not finished.
        while start > 0 {
            let line = lines[start - 1]
            guard line.isEmpty || (page.lineSizes[line].map { $0 > 0 && $0 <= bodySize * 0.95 } ?? false) else { break }
            start -= 1
        }
        while start < end, lines[start].isEmpty { start += 1 }
        let runsOn = previous.map { !PDFReader.endsSentence($0.text) } ?? false
        guard start < end, start > 0 || runsOn else { return (lines, ([], nil)) }
        let used = Set(lines[..<start].joined().unicodeScalars.compactMap(markerIndex)
            .compactMap { markers.indices.contains($0) ? markers[$0] : nil })
        var notes: [Note] = []
        var carried: String?
        for line in lines[start..<end] where !line.isEmpty {
            if let (label, rest) = noteStart(line), used.contains(label) {
                notes.append(Note(label: label, text: rest))
            } else if !notes.isEmpty {
                notes[notes.count - 1].text = joined(notes[notes.count - 1].text, line)
            } else if let previous, !PDFReader.endsSentence(previous.text) {
                // Runs on only from a note that did not end: anything else in small print is the page's own.
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
        // In outline order: a part's chapters inherit its role, and one naming its own overrides it.
        let entries = outline.filter { content.indices.contains($0.page) }
        for (index, entry) in entries.enumerated() {
            guard let role = role(named: entry.label, hasTitle: hasTitle) else { continue }
            // An outline gives only the page: back matter starting partway down one leaves that page to the text before.
            let start = opensMidPage(entry.label) && !opensPart(content[entry.page], named: entry.label)
                ? entry.page + 1 : entry.page
            let end = entries[(index + 1)...].first { $0.level <= entry.level && $0.page > entry.page }?.page ?? content.count
            for page in min(start, end)..<end { roles[page] = role }
        }
        // A wrong outline, or one with nothing else in it, must not silence the book (invariant 1).
        let silent = roles.filter { $0 != .body }.count
        if silent * 10 > content.count * 8 { roles = [Role](repeating: .body, count: content.count) }
        recognize(content, into: &roles)
        return roles
    }

    private static func outlineName(_ label: String) -> String {
        label.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Back matter can begin partway down a page, under the end of the text. Front matter has its own pages.
    private static func opensMidPage(_ label: String) -> Bool {
        ["notes", "endnotes", "end notes", "footnotes", "index", "subject index", "name index", "author index",
         "bibliography", "references", "works cited"].contains(outlineName(label))
    }

    /// The page's first line, past any stray numbers, names the part.
    private static func opensPart(_ lines: [String], named label: String) -> Bool {
        guard let first = lines.first(where: { !$0.isEmpty && PDFReader.bareNumber($0) == nil }) else { return true }
        let name = outlineName(label), line = outlineName(first)
        return line == name || line.hasSuffix(" " + name) || line.hasPrefix(name + " ")
    }

    private static func role(named label: String, hasTitle: Bool) -> Role? {
        switch outlineName(label) {
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

    /// The pages the outline names as notes: their small numbers are the notes' own, not citations.
    static func namedNotesPages(_ outline: [OutlineEntry], pageCount: Int) -> Set<Int> {
        var pages = Set<Int>()
        let entries = outline.filter { (0..<pageCount).contains($0.page) }
        for (index, entry) in entries.enumerated() where role(named: entry.label, hasTitle: true) == .notes {
            let end = entries[(index + 1)...].first { $0.level <= entry.level && $0.page > entry.page }?.page ?? pageCount
            pages.formUnion(entry.page..<end)
        }
        return pages
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
                // A page can be all one long note, so it takes two without a numbered line to end the section.
                var end = page
                var rest = page + 1
                while rest < content.count, rest - end <= 2, roles[rest] == .body {
                    if share(content[rest], startingWithANumber) >= 0.1 { end = rest }
                    rest += 1
                }
                // The last note can run over onto one page more.
                if end + 1 < content.count, roles[end + 1] == .body,
                   let line = content[end].last(where: { !$0.isEmpty }), !PDFReader.endsSentence(line) { end += 1 }
                for notes in page...end { roles[notes] = .notes }
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
    ///
    /// Some typesetting tools keep a few note numbers in a text layer of their own, which the file gives apart from
    /// their lines, at the top of the page, and at no height that can be trusted. So the numbers are not put back by
    /// place but by order: with the next note's number stray on this page, the line after a finished note opens it.
    private static func endnoteBlocks(content: [[String]], roles: [Role], pages: [Page], outline: [OutlineEntry])
        -> (blocks: [[Int: String]], symbolic: [String]) {
        let parts = outline.map { outlineName($0.label) }
        let lines = noteLines(content: content, roles: roles, pages: pages)
        let widest = lines.map(\.text.count).max() ?? 0
        var blocks: [[Int: String]] = []
        // "* A note": no number to pair by, so said with those no marker cited rather than lost.
        var symbolic: [String] = []
        var inSymbolic = false
        var last: Int?
        var pending: String?
        var lastLine = ""
        func flush() {
            guard let line = pending, let last, !blocks.isEmpty, let note = blocks[blocks.count - 1][last] else {
                pending = nil
                return
            }
            blocks[blocks.count - 1][last] = joined(note, line)
            pending = nil
        }
        for (position, line) in lines.enumerated() {
            if let symbol = noteStart(line.text), Int(symbol.label) == nil {
                flush()
                symbolic.append(symbol.text)
                inSymbolic = true
                lastLine = line.text
                continue
            }
            let next = (last ?? 0) + 1
            let note = last.flatMap { blocks.last?[$0] }
            let finished = PDFReader.endsSentence(pending ?? note ?? "") || (note != nil && lastLine.count * 10 < widest * 6)
            // A short line left over before a note 1 may name the chapter whose notes it opens.
            let closed = pending.map { $0.count <= 90 || PDFReader.endsSentence($0) } ?? PDFReader.endsSentence(note ?? ".")
            let start = noteStart(line.text).flatMap { start -> (number: Int, text: String)? in
                Int(start.label).map { ($0, start.text) }
            }.flatMap { start -> (number: Int, text: String)? in
                // A wrapped line can open with the next number: "(CW 12, n.\n26) that must be…". In lowercase after an
                // open bracket or an unfinished note, it is that; "4 ibid., p. 12." after a finished note is a note.
                if start.number == next, note == nil || start.text.first?.isLowercase != true
                    || (finished && bracketsClosed(pending.map { joined(note ?? "", $0) } ?? note ?? "")) { return start }
                if start.number == 1, closed, startsABlock(lines.map(\.text), after: position, next: next) { return start }
                // A gap in the numbering: a sentence opening just past the next number, after a note that ended.
                if start.number > next, start.number <= next + 3, finished, start.text.first?.isUppercase == true {
                    return start
                }
                return nil
            } ?? (line.stray.contains(next) && finished ? (next, line.text) : nil)
            lastLine = line.text
            guard let start else {
                if inSymbolic, !symbolic.isEmpty {
                    symbolic[symbolic.count - 1] = joined(symbolic[symbolic.count - 1], line.text)
                    continue
                }
                flush()
                pending = line.text
                continue
            }
            inSymbolic = false
            if start.number == 1 || blocks.isEmpty {
                // A line right before a new block names that block's chapter only with evidence, since a note's last
                // line can look just the same ("Oxford University Press, 1999"); anything else stays in the note.
                if let line = pending, !namesAPart(line, parts: parts, afterFinished: PDFReader.endsSentence(note ?? ".")) {
                    flush()
                }
                pending = nil
                blocks.append([:])
            } else {
                flush()
            }
            blocks[blocks.count - 1][start.number] = start.text
            last = start.number
        }
        flush()
        return (blocks, symbolic)
    }

    /// The notes pages' lines, with the numbers stray on each line's page. A larger line is no part of a note.
    private static func noteLines(content: [[String]], roles: [Role], pages: [Page]) -> [(text: String, stray: Set<Int>)] {
        var lines: [(text: String, stray: Set<Int>)] = []
        for index in content.indices where roles[index] == .notes {
            // After the furniture has gone, so a printed page number is not taken for a note's.
            let stray = Set(content[index].compactMap(PDFReader.bareNumber))
            let sizes = pages[index].lineSizes.values.filter { $0 > 0 }.sorted()
            let usual = sizes.isEmpty ? 0 : sizes[sizes.count / 2]
            for line in content[index] where !line.isEmpty && PDFReader.bareNumber(line) == nil {
                if let size = pages[index].lineSizes[line], usual > 0, size > usual * 1.08 { continue }
                lines.append((line, stray))
            }
        }
        return lines
    }

    /// Whether a short line before a block of notes names a part of the book: "Chapter 2", or a part the outline names,
    /// or a capitalized line after a note that had ended.
    private static func namesAPart(_ line: String, parts: [String], afterFinished: Bool) -> Bool {
        guard line.count <= 90, !PDFReader.endsSentence(line), line.first?.isUppercase == true else { return false }
        let name = outlineName(line)
        if name.hasPrefix("chapter") || name.hasPrefix("part ") { return true }
        return afterFinished || (!name.isEmpty && parts.contains { $0 == name || $0.hasPrefix(name + " ") })
    }

    private static func bracketsClosed(_ text: String) -> Bool {
        text.filter { $0 == "(" }.count <= text.filter { $0 == ")" }.count
    }

    /// A note 1 opens a block when a note 2 soon follows, or when the section soon ends without the note that would
    /// come next in this block (a last chapter with one note): "1 Corinthians" inside a note has neither.
    private static func startsABlock(_ lines: [String], after position: Int, next: Int) -> Bool {
        let rest = lines[(position + 1)...].prefix(40)
        if rest.contains(where: { noteStart($0)?.label == "2" }) { return true }
        return position + 1 + rest.count == lines.count && !rest.contains { noteStart($0)?.label == String(next) }
    }

    /// Where the outline's chapters start: the entries it calls chapters, else its shallowest level with several text
    /// parts, so a section inside a chapter is no new chapter. One naming only front and back matter says nothing.
    private static func chapterStarts(_ outline: [OutlineEntry], hasTitle: Bool) -> Set<Int> {
        let parts = outline.filter { role(named: $0.label, hasTitle: hasTitle) == nil }
        let named = parts.filter { $0.label.lowercased().hasPrefix("chapter") }
        let levels = Set(parts.map(\.level)).sorted()
        let shallowest = levels.first { level in parts.filter { $0.level == level }.count >= 2 }
        // Text before the chapters (a foreword, an introduction) has notes of its own, at the chapters' depth.
        let level = named.first?.level ?? shallowest
        let starts = Set(parts.filter { $0.level == level }.map(\.page))
        return starts.count >= 2 ? starts : []
    }

    /// Each marker's note, going through the text in reading order. Past the start of a part where the outline names
    /// chapters, a number the next block has moves on to it; without chapters, only one falling back to where that block
    /// begins does. A chapter citing an earlier note again does not. `endnotesPaired`: most of the markers not at a page's foot found theirs. `uncited`: the notes none of
    /// them cited, in order.
    private static func resolve(content: [[String]], roles: [Role], markers: [String], footnotes: [[Note]],
                                endnotes: [[Int: String]], partStarts: Set<Int>)
        -> (notes: [Int: String], footnotesOnly: [Int: String], endnotesPaired: Bool, uncited: [String]) {
        var notes: [Int: String] = [:]
        var footnotesOnly: [Int: String] = [:]
        var block = 0, last = 0, lastPage = -1, wanted = 0, found = 0
        var cited = endnotes.map { _ in Set<Int>() }
        for page in content.indices where roles[page] == .body {
            for scalar in content[page].joined().unicodeScalars {
                guard let index = markerIndex(scalar), markers.indices.contains(index) else { continue }
                let label = markers[index]
                if let note = footnotes[page].first(where: { $0.label == label }) {
                    notes[index] = note.text
                    footnotesOnly[index] = note.text
                    continue
                }
                guard let number = Int(label), !endnotes.isEmpty else { continue }
                wanted += 1
                let partBegan = partStarts.contains { $0 > lastPage && $0 <= page }
                let nextBlock = block + 1 < endnotes.count ? endnotes[block + 1] : nil
                // Blocks mean numbering per chapter, so a chapter's first citation moves on, risen or not, past the first.
                let moves = partStarts.isEmpty ? number <= last && number == nextBlock?.keys.min()
                    : last > 0 && partBegan && nextBlock?[number] != nil
                if moves {
                    block += 1
                    last = number
                } else {
                    last = max(last, number)
                }
                lastPage = page
                if let note = endnotes[block][number] {
                    notes[index] = note
                    cited[block].insert(number)
                    found += 1
                }
            }
        }
        let uncited = endnotes.indices.flatMap { block in
            endnotes[block].keys.filter { !cited[block].contains($0) }.sorted().compactMap { endnotes[block][$0] }
        }
        return (notes, footnotesOnly, !endnotes.isEmpty && wanted > 0 && found * 10 >= wanted * 6, uncited)
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
