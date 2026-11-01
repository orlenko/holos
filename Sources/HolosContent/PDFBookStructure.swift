import Foundation

/// What a person reading a book aloud would leave out, and where they would read its notes.
///
/// A PDF says little about itself, so this reads its structure: the outline's names for its parts, the font sizes that
/// set a footnote and a note's little number apart from the text, and the numbering that ties the two together.
///
/// Invariants:
/// 1. Nothing is left out unless a part names itself (the outline) or looks unmistakably like front or back matter.
/// 2. A marker is a small run of digits or a symbol straight after text. It is never spoken: its note is, after the
///    sentence holding it, or it goes silently when no note is found, unless nothing says it is a citation at all. Small runs are judged only once the page's
///    furniture is gone and the page is known to be text, so a page number or a note's own number is never taken for one.
/// 3. No note is lost: when the markers do not pair with the notes, the notes section is read as ordinary text, and
///    when they do, a note no marker cited is said at the end of the book.
/// 4. A note is said once per marker, in its own paragraph, as "Footnote: …".
enum PDFBookStructure {
    /// A run of digits or a symbol set small in a line: a marker, if the page and its place in the line say so.
    struct SmallRun: Equatable {
        /// UTF-16 place in the line.
        let offset: Int
        let length: Int
        let label: String
    }

    /// One page's text, with the size of each line's main font and the small runs in each line.
    struct Page: Equatable {
        var text: String
        var lineSizes: [String: Double] = [:]
        /// For each line's text, the runs of each time the page says it: a line can repeat in other type.
        var smallRuns: [String: [[SmallRun]]] = [:]
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

    /// The book's paragraphs: `pages` without their furniture, without the parts nobody reads aloud, and with each note
    /// after the sentence that cites it. `markers`: the text of any marker scalar already in `pages`.
    static func paragraphs(pages: [Page], markers given: [String] = [], outline: [OutlineEntry], bodySize: Double,
                           hasTitle: Bool) throws -> [String] {
        // The furniture goes first, so a small running footer is not taken for the end of a footnote, and a page number
        // for a marker; then the parts, read from the text as it stands.
        var framed = PDFReader.pageContent(pages.map { PDFReader.lines(of: $0.text) })
        // An outline that would silence the book is ignored (`roles`), so it takes nothing off a page either.
        let notesBelow = namedRoles(content: framed, outline: outline, hasTitle: hasTitle) == nil ? [:]
            : takeBackMatterBelow(&framed, outline: outline)
        var roles = self.roles(content: framed, outline: outline, hasTitle: hasTitle)
        var markers = given
        // The page each marker was found on, where its footnote is, wherever its sentence is.
        var markerPages: [Int: Int] = [:]
        var footnotes: [[Note]] = []
        var content: [[String]] = []
        // The note a page's unmarked small print can run on from: the last one begun, while each page since ran it on.
        var owner: (page: Int, note: Int)?
        for (index, page) in pages.enumerated() {
            try Task.checkCancellation()
            guard roles[index] == .body else {
                footnotes.append([])
                content.append(framed[index])
                owner = nil
                continue
            }
            let (notesStart, notes) = pageFootnotes(page, lines: framed[index], markers: markers, bodySize: bodySize,
                                                    previous: owner.map { footnotes[$0.page][$0.note] })
            if let carried = notes.carried, let owner {
                footnotes[owner.page][owner.note].text = joined(footnotes[owner.page][owner.note].text, carried)
            }
            footnotes.append(notes.notes)
            if !notes.notes.isEmpty {
                owner = (footnotes.count - 1, notes.notes.count - 1)
            } else if notes.carried == nil {
                owner = nil
            }
            let lines = framed[index]
            let kept = Array(lines[..<notesStart.lowerBound]) + Array(lines[notesStart.upperBound...])
            let found = markers.count
            let text = marked(kept, page: page, bodySize: bodySize, markers: &markers, into: &content)
            content.append(text)
            for marker in found..<markers.count { markerPages[marker] = index }
        }
        try Task.checkCancellation()
        let (endnotes, names, symbolic) = try endnoteBlocks(content: content, roles: roles, pages: pages, outline: outline,
                                                         notesBelow: notesBelow)
        let resolved = try resolve(content: content, roles: roles, markers: markers, markerPages: markerPages, footnotes: footnotes,
                               endnotes: endnotes, names: names, chapters: chapters(outline, hasTitle: hasTitle))
        // Invariant 3.
        if !resolved.endnotesPaired {
            roles = roles.map { $0 == .notes ? .body : $0 }
            for (page, sections) in notesBelow {
                // Last first: each place was counted with those before it already gone.
                for notes in sections.reversed() {
                    content[page].insert(contentsOf: notes.lines, at: min(notes.at, content[page].count))
                }
            }
        }
        let bodyPages = content.indices.filter { roles[$0] == .body }.map { content[$0] }
        // No notes, and numbers that do not count upward as citations do: they are text (H₂O, x²).
        let literal = resolved.notes.isEmpty && !countUpward(markers)
        try Task.checkCancellation()
        let body = try PDFReader.reflow(content: bodyPages).flatMap { paragraph in
            try Task.checkCancellation()
            return expand(paragraph, notes: resolved.endnotesPaired ? resolved.notes : resolved.footnotesOnly, markers: markers,
                          literal: literal)
        }
        let unsaid = (resolved.endnotesPaired ? symbolic + resolved.uncited : []) + resolved.uncitedFootnotes
        return body + unsaid.map(Self.spoken)
    }

    /// Splits each page where the outline's parts change partway down, in reading order and before anything is removed,
    /// so no boundary is missed for an earlier removal. What belongs to a notes section is returned, by page, with its
    /// place among the lines left and its heading or a blank in the heading's place; other back matter goes as the part
    /// does; text stays. A page in one part throughout is left for `roles`.
    private static func takeBackMatterBelow(_ framed: inout [[String]], outline: [OutlineEntry])
        -> [Int: [(at: Int, lines: [String])]] {
        var notes: [Int: [(at: Int, lines: [String])]] = [:]
        // The back matter being read: nested entries are of it, until one at its depth or above.
        var active: (role: Role, level: Int)?
        for page in framed.indices {
            let lines = framed[page]
            var cuts: [(line: Int, active: (role: Role, level: Int)?)] = []
            var state = active
            var from = 0
            for entry in outline where entry.page == page {
                let named = role(named: entry.label, hasTitle: true)
                let backMatter = named != nil && opensMidPage(entry.label)
                if named == nil, let current = state, entry.level > current.level { continue }
                // Front matter has its pages to itself, for `roles`.
                if named != nil, !backMatter { continue }
                let heading = headingLine(of: entry.label, in: lines, from: from)
                // Back matter with no heading here begins on the next page, and text at the top of this one.
                let line = heading ?? (backMatter ? lines.count : 0)
                state = named.map { ($0, entry.level) }
                cuts.append((line, state))
                from = max(from, line)
            }
            defer { active = state }
            let first = active
            let partway = cuts.contains { $0.line > 0 && $0.line < lines.count } || (cuts.first?.line == 0 && cuts.count > 1)
            let endsWithin = first != nil && cuts.contains { $0.line > 0 && $0.line < lines.count }
            guard partway || endsWithin else { continue }
            var kept: [String] = []
            var start = 0
            var current = first
            for cut in cuts + [(line: lines.count, active: nil)] {
                let piece = Array(lines[min(start, lines.count)..<max(start, min(cut.line, lines.count))])
                switch current?.role {
                case .notes?:
                    if !piece.isEmpty {
                        // A section begun here opens on its heading; one going on from the page before has none.
                        let opens = start > 0 || first == nil || cuts.first?.line == 0
                        notes[page, default: []].append((kept.count, (opens ? [] : [""]) + piece))
                    }
                case .skipped?: break
                case .body?, nil: kept += piece
                }
                start = cut.line
                current = cut.active
            }
            framed[page] = kept
        }
        return notes
    }

    /// The line on a page that heads the outline's `label`: its words, or the start of them ("Chapter 1" for "Chapter 1
    /// Its Long Name").
    private static func headingLine(of label: String, in lines: [String], from start: Int) -> Int? {
        let name = ReadableDocument.titleKey(label)
        return lines[min(start, lines.count)...].firstIndex { line in
            let key = ReadableDocument.titleKey(line)
            return !key.isEmpty && (key == name || name.hasPrefix(key + " "))
        }
    }

    /// Whether small numbers rise as citations do, most of the way through.
    private static func countUpward(_ markers: [String]) -> Bool {
        let numbers = markers.compactMap { Int($0) }
        guard numbers.count >= 3 else { return false }
        let rises = zip(numbers, numbers.dropFirst()).filter { $0 < $1 }.count
        return rises * 10 >= (numbers.count - 1) * 6
    }

    // MARK: - Finding the markers

    /// A text page's lines with its markers replaced. A small run counts straight after text, opening a line of body
    /// text, or as a line of its own inside the page; at the page's ends alone it is the page's. A marker opening a line
    /// or alone belongs to the sentence before, on the page before if need be (`earlier`), so it is moved there.
    private static func marked(_ lines: [String], page: Page, bodySize: Double, markers: inout [String],
                               into earlier: inout [[String]]) -> [String] {
        var result: [String] = []
        let filled = lines.indices.filter { !lines[$0].isEmpty }
        var seen: [String: Int] = [:]
        for (position, line) in lines.enumerated() {
            let occurrence = seen[line, default: 0]
            seen[line] = occurrence + 1
            let said = page.smallRuns[line] ?? []
            // The same words in other type, with some taken off the page: which is which cannot be told, so no marker.
            let kept = lines.filter { $0 == line }.count
            let runs = said.count == kept || Set(said.map(\.count)).count == 1
                ? (said.indices.contains(occurrence) ? said[occurrence] : []) : []
            guard !runs.isEmpty else {
                result.append(line)
                continue
            }
            let source = line as NSString
            let atEnd = position == filled.first || position == filled.last
            var text = ""
            var cursor = 0
            for run in runs where run.offset >= cursor && run.offset + run.length <= source.length {
                let before = source.substring(to: run.offset)
                let after = source.substring(from: run.offset + run.length).trimmingCharacters(in: .whitespaces)
                let opens = before.trimmingCharacters(in: .whitespaces).isEmpty
                let counts = opens
                    ? (after.isEmpty ? !atEnd : (page.lineSizes[line] ?? 0) >= bodySize * 0.95)
                    : before.last?.isWhitespace == false
                guard counts, let scalar = markerScalar(markers.count) else { continue }
                text += source.substring(with: NSRange(location: cursor, length: run.offset - cursor))
                text.append(scalar)
                markers.append(run.label)
                cursor = run.offset + run.length
                // The space after a run opening the line goes with it.
                if opens, cursor < source.length, source.character(at: cursor) == 32 { cursor += 1 }
            }
            text += source.substring(from: cursor)
            // Moved back onto the sentence it cites.
            var leading = ""
            while let first = text.first, withoutTrailingMarkers(String(first)).isEmpty {
                leading.append(first)
                text.removeFirst()
            }
            if !leading.isEmpty {
                if let previous = result.lastIndex(where: { !$0.isEmpty }) {
                    result[previous] += leading
                } else if let page = earlier.indices.last(where: { earlier[$0].contains { !$0.isEmpty } }),
                          let previous = earlier[page].lastIndex(where: { !$0.isEmpty }) {
                    earlier[page][previous] += leading
                } else {
                    text = leading + text
                }
            }
            if !text.isEmpty { result.append(text) }
        }
        return result
    }

    // MARK: - Footnotes at the foot of a page

    /// Finds the block of smaller lines at the foot of `page`, when it opens with a marker this page uses (or runs on
    /// from the note before). A page number under the block stays. A numbered line going on from the note before it is a
    /// note of its own even if its marker was not found: `resolve` then says it with those no marker cited.
    private static func pageFootnotes(_ page: Page, lines: [String], markers: [String], bodySize: Double, previous: Note?)
        -> (range: Range<Int>, notes: (notes: [Note], carried: String?)) {
        let none = (lines.count..<lines.count, (notes: [Note](), carried: String?.none))
        guard bodySize > 0, !lines.isEmpty else { return none }
        var end = lines.count
        // Furniture has gone. A number in small print still here is the end of a note, and one in other type is under it.
        func small(_ line: String) -> Bool { page.lineSizes[line].map { $0 > 0 && $0 <= bodySize * 0.95 } ?? false }
        while end > 0, lines[end - 1].isEmpty || !small(lines[end - 1])
            && (PDFReader.bareNumber(lines[end - 1]) != nil || PDFReader.isPageLabel(lines[end - 1])) { end -= 1 }
        var start = end
        // Blank lines can separate the notes. A page all small print is only a note running on, from one not finished.
        while start > 0 {
            let line = lines[start - 1]
            guard line.isEmpty || (page.lineSizes[line].map { $0 > 0 && $0 <= bodySize * 0.95 } ?? false) else { break }
            start -= 1
        }
        while start < end, lines[start].isEmpty { start += 1 }
        let runsOn = previous.map { !PDFReader.endsSentence($0.text) } ?? false
        guard start < end, start > 0 || runsOn else { return none }
        let already = lines[..<start].joined().unicodeScalars.compactMap(markerIndex)
            .compactMap { markers.indices.contains($0) ? markers[$0] : nil }
        let used = Set(already + lines[..<start].flatMap { (page.smallRuns[$0] ?? []).flatMap { $0 }.map(\.label) })
        var notes: [Note] = []
        var carried: String?
        for line in lines[start..<end] where !line.isEmpty {
            let start = noteStart(line)
            let follows = start.flatMap { Int($0.label) } != nil
                && notes.last.flatMap { Int($0.label) }.map { $0 + 1 } == start.flatMap { Int($0.label) }
            // "2 million entries." wrapped inside a note that has not ended is that note's.
            let wrapped = start?.text.first?.isLowercase == true && notes.last.map { !PDFReader.endsSentence($0.text) } ?? false
            if let start, !wrapped, used.contains(start.label) || follows {
                notes.append(Note(label: start.label, text: start.text))
            } else if !notes.isEmpty {
                notes[notes.count - 1].text = joined(notes[notes.count - 1].text, line)
            } else if let previous, !PDFReader.endsSentence(previous.text) {
                // Runs on only from a note that did not end: anything else in small print is the page's own.
                carried = carried.map { joined($0, line) } ?? line
            } else {
                return none
            }
        }
        guard !notes.isEmpty || carried != nil else { return none }
        return (start..<end, (notes, carried))
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
        var roles = namedRoles(content: content, outline: outline, hasTitle: hasTitle)
            ?? [Role](repeating: .body, count: content.count)
        recognize(content, into: &roles)
        return roles
    }

    /// What the outline names each page; nil when that would silence nearly the whole book, which then ignores it.
    private static func namedRoles(content: [[String]], outline: [OutlineEntry], hasTitle: Bool) -> [Role]? {
        var roles = [Role](repeating: .body, count: content.count)
        // In outline order: a part's chapters inherit its role, and one naming its own overrides it.
        let entries = outline.filter { content.indices.contains($0.page) }
        for (index, entry) in entries.enumerated() {
            guard let role = role(named: entry.label, hasTitle: hasTitle) else { continue }
            // An outline gives only the page: back matter starting partway down one leaves that page to the text before.
            let start = opensMidPage(entry.label) && !opensPart(content[entry.page], named: entry.label)
                ? entry.page + 1 : entry.page
            // A part beginning on this same page leaves it, and everything after, to that part.
            let end = entries[(index + 1)...].first { $0.level <= entry.level && $0.page >= entry.page }?.page ?? content.count
            for page in min(start, end)..<end { roles[page] = role }
        }
        // A wrong outline, or one with nothing else in it, must not silence the book (invariant 1).
        return roles.filter { $0 != .body }.count * 10 > content.count * 8 ? nil : roles
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

    /// Pages no outline named: the contents and the copyright page near the start, the index and notes near the end.
    private static func recognize(_ content: [[String]], into roles: inout [Role]) {
        let early = min(content.count, max(8, min(30, content.count / 4)))
        var index = 0
        while index < early {
            defer { index += 1 }
            guard roles[index] == .body else { continue }
            if content.count >= 8, isCopyrightPage(content[index]) { roles[index] = .skipped }
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
                // While the pages look like an index: readable matter can follow it.
                for rest in page..<content.count {
                    guard roles[rest] == .body, rest == page || share(content[rest], endingInANumber) >= 0.5 else { break }
                    roles[rest] = .skipped
                }
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
        // A notice, not a page that merely talks about copyright.
        let claims = text.contains("all rights reserved") || text.contains("©")
            || text.range(of: #"copyright\s+\d{4}"#, options: .regularExpression) != nil
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
    private static func endnoteBlocks(content: [[String]], roles: [Role], pages: [Page], outline: [OutlineEntry],
                                      notesBelow: [Int: [(at: Int, lines: [String])]])
        throws -> (blocks: [[Int: String]], names: [String?], symbolic: [String]) {
        let parts = outline.map { outlineName($0.label) }
        let lines = noteLines(content: content, roles: roles, pages: pages, notesBelow: notesBelow)
        let widest = lines.map(\.text.count).max() ?? 0
        var blocks: [[Int: String]] = []
        // What the line before each block names it, when one does: "Chapter 2".
        var names: [String?] = []
        // "* A note": no number to pair by, so said with those no marker cited rather than lost.
        var symbolic: [String] = []
        var inSymbolic = false
        var last: Int?
        var pending: String?
        var lastLine = ""
        func flush() {
            guard let line = pending else { return }
            guard let last, !blocks.isEmpty, let note = blocks[blocks.count - 1][last] else {
                // Before any note: nothing to add it to, and, unless it is a heading, still not to be lost.
                if !namesAPart(line, parts: parts, afterFinished: true) { symbolic.append(line) }
                pending = nil
                return
            }
            blocks[blocks.count - 1][last] = joined(note, line)
            pending = nil
        }
        var heading: String?
        let texts = lines.map(\.text)
        for (position, line) in lines.enumerated() {
            try Task.checkCancellation()
            if line.heading {
                flush()
                heading = ReadableDocument.titleKey(line.text)
                continue
            }
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
            let closed = heading != nil
                || (pending.map { $0.count <= 90 || PDFReader.endsSentence($0) } ?? PDFReader.endsSentence(note ?? "."))
            let start = noteStart(line.text).flatMap { start -> (number: Int, text: String)? in
                Int(start.label).map { ($0, start.text) }
            }.flatMap { start -> (number: Int, text: String)? in
                // A wrapped line can open with the next number: "(CW 12, n.\n26) that must be…". In lowercase after an
                // open bracket or an unfinished note, it is that; "4 ibid., p. 12." after a finished note is a note.
                if start.number == next, note == nil || start.text.first?.isLowercase != true
                    || (finished && bracketsClosed(pending.map { joined(note ?? "", $0) } ?? note ?? "")) { return start }
                // A larger chapter name has already said a block begins.
                if start.number == 1, closed, heading != nil || startsABlock(texts, after: position, next: next) {
                    return start
                }
                // A gap in the numbering: a sentence opening just past the next number, after a note that ended.
                if start.number > next, start.number <= next + 3, finished, start.text.first?.isUppercase == true {
                    return start
                }
                return nil
            } ?? (heading != nil && line.stray.contains(1) ? (1, line.text) : nil)
                ?? (line.stray.contains(next) && (finished || (note == nil && !namesAPart(line.text, parts: parts, afterFinished: false)))
                ? (next, line.text) : nil)
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
                var name = heading
                heading = nil
                if let line = pending {
                    // Only positive evidence makes it a heading: a note's last line can read just like one, and a heading
                    // kept in a note loses nothing.
                    if namesAPart(line, parts: parts, afterFinished: note == nil) {
                        name = name ?? ReadableDocument.titleKey(line)
                    } else {
                        flush()
                    }
                }
                pending = nil
                blocks.append([:])
                names.append(name)
            } else {
                flush()
            }
            blocks[blocks.count - 1][start.number] = start.text
            last = start.number
        }
        flush()
        return (blocks, names, symbolic)
    }

    /// The notes pages' lines, with the numbers stray on each line's page. A larger line is no part of a note: it is
    /// a heading, which can name the block after it.
    private static func noteLines(content: [[String]], roles: [Role], pages: [Page],
                                  notesBelow: [Int: [(at: Int, lines: [String])]])
        -> [(text: String, stray: Set<Int>, heading: Bool)] {
        var lines: [(text: String, stray: Set<Int>, heading: Bool)] = []
        for index in content.indices where roles[index] == .notes || notesBelow[index] != nil {
            // Without the heading of notes taken from a shared page.
            let page = (roles[index] == .notes ? content[index] : []) + (notesBelow[index] ?? []).flatMap { $0.lines.dropFirst() }
            // Numbers given apart stand before all the page's text but perhaps its heading, after the furniture has gone.
            // One further down is a note's own: its label, on a line of its own, or a page reference that wrapped.
            let headed = page.first.map { PDFReader.bareNumber($0) == nil } == true
                && page.dropFirst().first.flatMap(PDFReader.bareNumber) != nil ? 1 : 0
            let leading = page.dropFirst(headed).prefix { $0.isEmpty || PDFReader.bareNumber($0) != nil }
            let stray = Set(leading.compactMap(PDFReader.bareNumber))
            let sizes = pages[index].lineSizes.values.filter { $0 > 0 }.sorted()
            let usual = sizes.isEmpty ? 0 : sizes[sizes.count / 2]
            for line in page.prefix(headed) + page.dropFirst(headed + leading.count) where !line.isEmpty {
                let heading = pages[index].lineSizes[line].map { usual > 0 && $0 > usual * 1.08 } ?? false
                lines.append((line, stray, heading))
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

    /// The outline's chapters: at the depth of the entries it calls chapters, else its shallowest level with several text
    /// parts, so a section inside a chapter is no new chapter. One naming only front and back matter says nothing.
    private static func chapters(_ outline: [OutlineEntry], hasTitle: Bool) -> [OutlineEntry] {
        // Not those inside a part nobody reads as text: Notes can hold its own "Chapter 1".
        var parts: [OutlineEntry] = []
        var inside: Int?
        for entry in outline {
            if let level = inside, entry.level > level { continue }
            inside = role(named: entry.label, hasTitle: hasTitle) == nil ? nil : entry.level
            if inside == nil { parts.append(entry) }
        }
        let named = parts.filter { $0.label.lowercased().hasPrefix("chapter") }
        let levels = Set(parts.map(\.level)).sorted()
        let shallowest = levels.first { level in parts.filter { $0.level == level }.count >= 2 }
        // Text before the chapters (a foreword, an introduction) has notes of its own, at the chapters' depth.
        let level = named.first?.level ?? shallowest
        let chapters = parts.filter { $0.level == level }
        return Set(chapters.map(\.page)).count >= 2 ? chapters : []
    }

    /// Each marker's note, going through the text in reading order. Past the start of a part where the outline names
    /// chapters, a number the next block has moves on to it; without chapters, only one falling back to where that block
    /// begins does. A chapter citing an earlier note again does not. `endnotesPaired`: most of the markers not at a page's foot found theirs. `uncited`: the notes none of
    /// them cited, in order.
    private static func resolve(content: [[String]], roles: [Role], markers: [String], markerPages: [Int: Int],
                                footnotes: [[Note]],
                                endnotes: [[Int: String]], names: [String?], chapters: [OutlineEntry])
        throws -> (notes: [Int: String], footnotesOnly: [Int: String], endnotesPaired: Bool, uncited: [String],
                   uncitedFootnotes: [String]) {
        var notes: [Int: String] = [:]
        var footnotesOnly: [Int: String] = [:]
        var block = 0, last = 0, lastPage = -1, wanted = 0, found = 0
        var cited = endnotes.map { _ in Set<Int>() }
        var citedFootnotes = Set<String>()
        // Where each chapter starts, by its heading on the page where that can be found, else at the page's top.
        let starts = chapters.map { chapter -> (page: Int, line: Int, name: String) in
            let name = ReadableDocument.titleKey(chapter.label)
            let lines = content.indices.contains(chapter.page) ? content[chapter.page] : []
            let line = lines.firstIndex { line in
                let key = ReadableDocument.titleKey(withoutTrailingMarkers(line))
                return !key.isEmpty && (key == name || name.hasPrefix(key + " "))
            }
            return (chapter.page, line ?? 0, name)
        }
        var lastLine = -1
        let markersInOrder = content.indices.filter { roles[$0] == .body }.flatMap { page in
            content[page].enumerated().flatMap { line, text in
                text.unicodeScalars.compactMap(markerIndex).map { (page: page, line: line, index: $0) }
            }
        }
        for (page, line, index) in markersInOrder where markers.indices.contains(index) {
            try Task.checkCancellation()
            let label = markers[index]
            let source = markerPages[index] ?? page
            // A page can use one label twice, its numbering starting over: each marker takes the next not yet said.
            let same = footnotes[source].indices.filter { footnotes[source][$0].label == label }
            if let found = same.first(where: { !citedFootnotes.contains("\(source):\($0)") }) ?? same.first {
                let note = footnotes[source][found]
                notes[index] = note.text
                footnotesOnly[index] = note.text
                citedFootnotes.insert("\(source):\(found)")
                continue
            }
            guard let number = Int(label), !endnotes.isEmpty else { continue }
            wanted += 1
            let partBegan = starts.contains { start in
                (start.page, start.line) > (lastPage, lastLine) && (start.page, start.line) <= (page, line)
            }
            let nextBlock = block + 1 < endnotes.count ? endnotes[block + 1] : nil
            // Blocks mean numbering per chapter, so a chapter's first citation moves on, risen or not, past the first.
            // With no chapters to go by, numbers start over only once this block's notes have all been cited: a
            // chapter can cite an earlier note again.
            let moves = starts.isEmpty
                ? number <= last && number == nextBlock?.keys.min() && cited[block].count >= endnotes[block].count
                : last > 0 && partBegan && nextBlock?[number] != nil
            // A block named for the part this citation opens settles it, whichever chapters had no citations found.
            let named = partBegan ? namedBlock(names, part: starts.last { ($0.page, $0.line) <= (page, line) }?.name) : nil
            if let named, endnotes[named][number] != nil {
                block = named
                last = number
            } else if moves {
                block += 1
                last = number
            } else {
                last = max(last, number)
            }
            lastPage = page
            lastLine = line
            if let note = endnotes[block][number] {
                notes[index] = note
                cited[block].insert(number)
                found += 1
            }
        }
        let uncited = endnotes.indices.flatMap { block in
            endnotes[block].keys.filter { !cited[block].contains($0) }.sorted().compactMap { endnotes[block][$0] }
        }
        let uncitedFootnotes = footnotes.indices.flatMap { page in
            footnotes[page].indices.filter { !citedFootnotes.contains("\(page):\($0)") }.map { footnotes[page][$0].text }
        }
        return (notes, footnotesOnly, !endnotes.isEmpty && wanted > 0 && found * 10 >= wanted * 6, uncited, uncitedFootnotes)
    }

    /// The block named for `part`: "Chapter 2" for "Chapter 2 Its Long Name".
    private static func namedBlock(_ names: [String?], part: String?) -> Int? {
        guard let part else { return nil }
        return names.firstIndex { name in name.map { !$0.isEmpty && (part == $0 || part.hasPrefix($0 + " ")) } ?? false }
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
