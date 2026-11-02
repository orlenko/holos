import AppKit
import Foundation
import HolosCore
import PDFKit

/// PDF text through PDFKit, with line breaks reflowed into paragraphs.
public enum PDFReader {
    static func document(_ url: URL) throws -> ReadableDocument {
        guard let pdf = PDFDocument(url: url) else {
            throw HolosError.invalidInput("\(url.lastPathComponent) is not a readable PDF.")
        }
        guard !pdf.isLocked else {
            throw HolosError.invalidInput("\(url.lastPathComponent) is password-protected.")
        }
        let attributes = pdf.documentAttributes ?? [:]
        let declared = (attributes[PDFDocumentAttribute.titleAttribute] as? String).map(cleanTitle)
        let author = attributes[PDFDocumentAttribute.authorAttribute] as? String
        var styled: [NSAttributedString?] = []
        for index in 0..<pdf.pageCount {
            // A long PDF read for a reading that was stopped ends here (outside a task, never).
            try Task.checkCancellation()
            let page = pdf.page(at: index)
            styled.append(page?.attributedString ?? page?.string.map { NSAttributedString(string: $0) })
        }
        let (pages, bodySize) = try bookPages(styled)
        let book = try PDFBookStructure.book(pages: pages, outline: outline(of: pdf), bodySize: bodySize,
                                             hasTitle: declared?.isEmpty == false)
        guard !book.paragraphs.isEmpty else {
            throw HolosError.invalidInput("\(url.lastPathComponent) has no text to read. Scanned PDFs need OCR, which is not supported.")
        }
        var result = document(book, declaredTitle: declared, author: author)
        result.insertByline(PDFBookStructure.byline(author: author, pages: styled.map { $0?.string ?? "" }))
        return result
    }

    /// A book's sections are the chapters its outline names, when it names them: a heading-like line in the text is not
    /// a chapter then, nor a file of its own. The outline's name stands for the lines that say it ("Chapter 1", then the
    /// chapter's title), so it is said once. Without chapters, headings are told by their look (`document(paragraphs:)`).
    static func document(_ book: PDFBookStructure.Book, declaredTitle: String?, author: String?) -> ReadableDocument {
        guard let first = book.chapters.first else {
            return document(paragraphs: book.paragraphs, declaredTitle: declaredTitle, author: author)
        }
        let opening = document(paragraphs: Array(book.paragraphs[..<first.paragraph]), declaredTitle: declaredTitle, author: author)
        var sections = first.paragraph > 0 ? opening.sections : []
        for (index, chapter) in book.chapters.enumerated() {
            let end = index + 1 < book.chapters.count ? book.chapters[index + 1].paragraph : book.paragraphs.count
            var body = Array(book.paragraphs[chapter.paragraph..<end])
            let name = ReadableDocument.titleKey(chapter.label)
            var said = ""
            while let line = body.first {
                let key = ReadableDocument.titleKey(line)
                let next = said.isEmpty ? key : said + " " + key
                guard !key.isEmpty, name == next || name.hasPrefix(next + " ") else { break }
                said = next
                body.removeFirst()
            }
            sections.append(.init(heading: chapter.label, level: 2, paragraphs: body))
        }
        return ReadableDocument(title: opening.title ?? declaredTitle, author: author, sections: sections)
    }

    /// Each page's text, as it stands, with each line's main size and the small runs of digits or symbols in it, which
    /// `PDFBookStructure` judges once it knows what the page is. The book's body size is the one most of its characters
    /// are set in.
    static func bookPages(_ styled: [NSAttributedString?]) throws -> (pages: [PDFBookStructure.Page], bodySize: Double) {
        var counts: [Double: Int] = [:]
        for page in styled.compactMap({ $0 }) {
            page.enumerateAttribute(.font, in: NSRange(location: 0, length: page.length)) { value, range, _ in
                counts[fontSize(value), default: 0] += range.length
            }
        }
        // Ties go to the larger size: the same file must always give the same text, or a reading could not resume.
        let bodySize = counts.filter { $0.key > 0 }.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? 0
        var pages: [PDFBookStructure.Page] = []
        for page in styled {
            try Task.checkCancellation()
            guard let page else {
                pages.append(.init(text: ""))
                continue
            }
            var result = PDFBookStructure.Page(text: "")
            var lines: [String] = []
            let source = page.string as NSString
            source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) { _, range, _, _ in
                let styled = styledLine(page, range: range, bodySize: bodySize)
                lines.append(styled.text)
                guard !styled.text.isEmpty else { return }
                result.lineSizes[styled.text] = styled.size
                result.smallRuns[styled.text, default: []].append(styled.small)
            }
            result.text = lines.joined(separator: "\n")
            pages.append(result)
        }
        return (pages, bodySize)
    }

    private static func fontSize(_ value: Any?) -> Double { (value as? NSFont).map { Double($0.pointSize) } ?? 0 }

    /// One line's text, the size most of it is set in, and where small marker-like runs stand in it.
    private static func styledLine(_ page: NSAttributedString, range: NSRange, bodySize: Double)
        -> (text: String, size: Double, small: [PDFBookStructure.SmallRun]) {
        let source = page.string as NSString
        var line = ""
        var small: [PDFBookStructure.SmallRun] = []
        var lengths: [Double: Int] = [:]
        page.enumerateAttribute(.font, in: range) { value, run, _ in
            let text = source.substring(with: run).replacingOccurrences(of: "\u{FFFC}", with: "")
            let size = fontSize(value)
            lengths[size, default: 0] += run.length
            let bare = text.trimmingCharacters(in: .whitespaces)
            if bodySize > 0, size > 0, size <= bodySize * 0.8, PDFBookStructure.isMarkerText(bare) {
                let lead = text.prefix { $0.isWhitespace }.utf16.count
                small.append(.init(offset: line.utf16.count + lead, length: bare.utf16.count, label: bare))
            }
            line += text
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let lead = line.prefix { $0.isWhitespace }.utf16.count
        let size = lengths.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? 0
        return (trimmed, size, small.map { .init(offset: $0.offset - lead, length: $0.length, label: $0.label) })
    }

    /// The outline's entries at every level, with the page each opens.
    private static func outline(of pdf: PDFDocument) -> [PDFBookStructure.OutlineEntry] {
        var entries: [PDFBookStructure.OutlineEntry] = []
        func walk(_ node: PDFOutline, level: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                if let label = child.label, let page = child.destination?.page {
                    entries.append(.init(label: label, page: pdf.index(for: page), level: level))
                }
                walk(child, level: level + 1)
            }
        }
        if let root = pdf.outlineRoot { walk(root, level: 0) }
        return entries
    }

    /// The title is the metadata title, else a title-like first paragraph; a first paragraph that
    /// says the title is its level-1 heading, read once. Headings `reflow` set apart become
    /// level-2 sections, so chapters (see `isHeading`).
    static func document(paragraphs: [String], declaredTitle: String?, author: String?) -> ReadableDocument {
        var title = declaredTitle.flatMap { $0.isEmpty ? nil : $0 }
        var builder = ReadableDocument.Builder()
        var start = 0
        if paragraphs.count > 1, PlainTextReader.looksLikeTitle(paragraphs[0]),
           title.map({ ReadableDocument.sameTitle($0, paragraphs[0]) }) ?? true {
            title = title ?? paragraphs[0]
            builder.heading(paragraphs[0], level: 1)
            start = 1
        }
        let candidates = paragraphs.map(isHeadingCandidate)
        var index = start
        while index < paragraphs.count {
            // A run of one or two heading-like paragraphs ("Chapter 2", "Methods") after the start,
            // the title, or a finished sentence, with body text after it, is headings.
            var end = index
            while end < paragraphs.count, candidates[end] { end += 1 }
            let run = index..<end
            let afterBreak = index == start || endsSentence(paragraphs[index - 1])
            if !run.isEmpty, run.count <= 2, afterBreak, end < paragraphs.count {
                for heading in run { builder.heading(paragraphs[heading], level: 2) }
            } else {
                for paragraph in run { builder.paragraph(paragraphs[paragraph]) }
            }
            if end < paragraphs.count { builder.paragraph(paragraphs[end]) }
            index = end + 1
        }
        return ReadableDocument(title: title, author: author, sections: builder.sections)
    }

    /// Short (80 characters at most), one line, with a letter, not ending like a sentence or a
    /// clause, and not a bulleted or lettered list item: what `reflow` sets apart as a heading.
    /// A numbered heading ("2. Methods", "3.1 Results") qualifies; a long numbered list does not,
    /// because a heading run is at most two paragraphs.
    static func isHeadingCandidate(_ paragraph: String) -> Bool {
        paragraph.count <= 80 && PlainTextReader.looksLikeTitle(paragraph) && paragraph.contains(where: \.isLetter)
            && paragraph.range(of: #"^\s*([-–—•*·▪◦]|\(?[0-9]{1,3}\)|\(?[a-zA-Z][.)])\s"#,
                               options: .regularExpression) == nil
    }

    /// "Microsoft Word - Report.docx" -> "Report".
    static func cleanTitle(_ title: String) -> String {
        var result = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Microsoft Word - ", "Microsoft PowerPoint - "] where result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
            for suffix in [".docx", ".doc", ".pptx", ".ppt"] where result.lowercased().hasSuffix(suffix) {
                result = String(result.dropLast(suffix.count))
            }
        }
        return result
    }

    /// Joins wrapped lines into paragraphs, one page's text per element of `pages`. A paragraph
    /// ends at a blank line inside a page, after a line that ends a sentence short of the margin,
    /// or after any clearly short line; at a page break it continues unless its sentence ended.
    /// Hyphenated line ends are rejoined. Page furniture (page numbers and running headers and
    /// footers) is dropped only from the top and bottom of a page; see `pageContent`.
    public static func reflow(pages: [String]) -> [String] {
        reflow(content: pageContent(pages.map(lines(of:))))
    }

    /// The same, for pages `pageContent` has already taken the furniture off.
    static func reflow(content: [[String]]) -> [String] {
        let lengths = content.joined().map(\.count).filter { $0 > 0 }.sorted()
        let fullLine = lengths.isEmpty ? 0 : lengths[min(lengths.count - 1, lengths.count * 9 / 10)]
        var paragraphs: [String] = []
        var current = ""
        func end() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { paragraphs.append(trimmed) }
            current = ""
        }
        for (pageIndex, page) in content.enumerated() {
            // A page break inside a sentence continues the paragraph.
            if pageIndex > 0, endsSentence(current) { end() }
            for line in page {
                // Leading and trailing blank lines are trimmed per page, so this blank line is
                // inside the page: a real paragraph break.
                if line.isEmpty { end(); continue }
                let length = Double(line.count), full = Double(fullLine)
                let hyphenated = line.hasSuffix("-") && line.dropLast().last?.isLetter == true
                // A short line without closing punctuation after a finished sentence is a heading.
                if endsSentence(current), length < full * 0.6, !endsSentence(line) { end() }
                if current.isEmpty {
                    current = line
                } else if current.hasSuffix("-"), current.dropLast().last?.isLetter == true,
                          line.first?.isLowercase == true {
                    current = String(current.dropLast()) + line
                } else {
                    current += " " + line
                }
                // Inside a paragraph every line but the last runs to the margin, so a short line
                // ends one (a heading, too, when it has no punctuation).
                if (endsSentence(line) && length < full * 0.75) || (length < full * 0.6 && !hyphenated) { end() }
            }
        }
        end()
        return paragraphs
    }

    /// A page's lines, trimmed, without the blank lines before its first or after its last text.
    static func lines(of page: String) -> [String] {
        let lines = DocumentText.withLFLineEndings(page).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.firstIndex(where: { !$0.isEmpty }),
              let last = lines.lastIndex(where: { !$0.isEmpty }) else { return [] }
        return Array(lines[first...last])
    }

    /// Removes page furniture, looking only at the first and last lines of each page (two deep,
    /// for a header above a page number):
    /// - a running header or footer: the same line, digits aside, at the same end of at least
    ///   half the pages (three or more);
    /// - "Page 3", "3 of 10", "3 / 10", "- 3 -": always;
    /// - a bare number: when it runs with the pages, that is, another page's edge number has the
    ///   same offset from its page index, or it is at the bottom and equals the page's position;
    ///   at most one per page, the bottom one first;
    /// - a line with a page number at its start or end ("8 Chapter Name", "Chapter Name 9"), when at
    ///   least three other pages' edge lines run with the pages in the same way: a chapter's own
    ///   running head is on too few of a book's pages to count as repeated.
    /// Numbers, years, and repeated lines anywhere else on a page are text and are kept.
    static func pageContent(_ pages: [[String]]) -> [[String]] {
        var pages = pages
        let threshold = pages.count >= 3 ? max(3, (pages.count + 1) / 2) : Int.max
        var numbered = Set<Int>()
        for _ in 0..<2 {
            var headers: [String: Int] = [:]
            var footers: [String: Int] = [:]
            var numberOffsets: [Int: Int] = [:]
            var headOffsets: [Int: Int] = [:]
            var headTexts: [String: Int] = [:]
            for (index, page) in pages.enumerated() {
                guard let first = page.first, let last = page.last else { continue }
                for text in Set([first, last].filter { runningHeadKey($0, page: index) != nil }.map(runningHeadText)) {
                    headTexts[text, default: 0] += 1
                }
                // Counted once a page: a page's two edges numbered alike are not two pages agreeing.
                for key in Set([first, last].compactMap({ runningHeadKey($0, page: index) })) {
                    headOffsets[key, default: 0] += 1
                }
                headers[furnitureKey(first), default: 0] += 1
                footers[furnitureKey(last), default: 0] += 1
                for line in Set([first, last]) {
                    if let number = bareNumber(line) { numberOffsets[number - index, default: 0] += 1 }
                }
            }
            for index in pages.indices {
                var page = pages[index]
                guard let first = page.first, let last = page.last else { continue }
                func isFurniture(_ line: String, bottom: Bool) -> Bool {
                    let isNumber = bareNumber(line) != nil || isPageLabel(line)
                    var furniture = (bottom ? footers : headers)[furnitureKey(line), default: 0] >= threshold
                        || isPageLabel(line)
                    if !furniture, !numbered.contains(index), let number = bareNumber(line) {
                        furniture = numberOffsets[number - index, default: 0] >= 2 || (bottom && number == index + 1)
                    }
                    // Its words repeat on another page too: "1 Introduction", "2 Methods" number along with their pages
                    // and are headings.
                    if !furniture, let key = runningHeadKey(line, page: index), headOffsets[key, default: 0] >= 4,
                       headTexts[runningHeadText(line), default: 0] >= 2 {
                        furniture = true
                    }
                    if furniture && isNumber { numbered.insert(index) }
                    return furniture
                }
                let bottom = isFurniture(last, bottom: true)
                let top = isFurniture(first, bottom: false)
                if page.count == 1 {
                    if bottom || top { page = [] }
                } else {
                    if bottom { page.removeLast() }
                    if top { page.removeFirst() }
                }
                pages[index] = lines(of: page.joined(separator: "\n"))
            }
        }
        return pages
    }

    static func furnitureKey(_ line: String) -> String {
        line.lowercased().replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func bareNumber(_ line: String) -> Int? {
        guard (1...4).contains(line.count), line.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(line)
    }

    /// A running head's words, without its page number, whichever side that is on.
    static func runningHeadText(_ line: String) -> String {
        ReadableDocument.titleKey(line).split(separator: " ")
            .filter { word in !word.allSatisfy(\.isNumber) && romanNumeral(String(word)) == nil }.joined(separator: " ")
    }

    /// How a running head's page number ("8 Chapter Name", "Chapter Name 9", "Foreword xi") stands to its page's index,
    /// the same for every page numbered in the same series; nil for a line without one.
    static func runningHeadKey(_ line: String, page: Int) -> Int? {
        guard line.count <= 90, bareNumber(line) == nil, line.contains(where: \.isLetter), !isNumberedHeading(line) else {
            return nil
        }
        let words = line.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, let first = words.first, let last = words.last else { return nil }
        for word in [last, first] {
            if word.count <= 4, word.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(word) { return number - page }
            if let number = romanNumeral(String(word)) { return 100_000 + number - page }
        }
        return nil
    }

    /// "Chapter 1", "Part II": a chapter opening on the page it numbers looks like a running head and is not one.
    private static func isNumberedHeading(_ line: String) -> Bool {
        line.range(of: #"^(chapter|part|book|section|lecture|volume)\s+(\d{1,4}|[ivxlc]{1,7})$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A lowercase roman numeral's value, as front matter is numbered.
    private static func romanNumeral(_ word: String) -> Int? {
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100]
        guard (1...7).contains(word.count), word.allSatisfy({ values[$0] != nil }) else { return nil }
        let digits = word.compactMap { values[$0] }
        return digits.indices.reduce(0) { sum, index in
            sum + (index + 1 < digits.count && digits[index] < digits[index + 1] ? -digits[index] : digits[index])
        }
    }

    /// "Page 3", "page 3 of 10", "3 of 10", "3 / 10", "- 3 -".
    static func isPageLabel(_ line: String) -> Bool {
        line.range(of: #"^(page\s+\d{1,4}(\s+(of|/)\s+\d{1,4})?|\d{1,4}\s+(of|/)\s+\d{1,4}|[-–—]\s*\d{1,4}\s*[-–—])$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = PDFBookStructure.withoutTrailingMarkers(text.trimmingCharacters(in: .whitespaces)).last else {
            return false
        }
        return ".!?:\"”’)".contains(last)
    }
}
