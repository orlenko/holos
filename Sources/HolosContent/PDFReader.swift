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
        var pages: [String] = []
        for index in 0..<pdf.pageCount {
            // A long PDF read for a reading that was stopped ends here (outside a task, never).
            try Task.checkCancellation()
            pages.append(pdf.page(at: index)?.string ?? "")
        }
        let paragraphs = reflow(pages: pages)
        guard !paragraphs.isEmpty else {
            throw HolosError.invalidInput("\(url.lastPathComponent) has no text to read. Scanned PDFs need OCR, which is not supported.")
        }
        let attributes = pdf.documentAttributes ?? [:]
        let declared = (attributes[PDFDocumentAttribute.titleAttribute] as? String).map(cleanTitle)
        let author = attributes[PDFDocumentAttribute.authorAttribute] as? String
        return document(paragraphs: paragraphs, declaredTitle: declared, author: author)
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
        let content = pageContent(pages.map(lines(of:)))
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
    ///   at most one per page, the bottom one first.
    /// Numbers, years, and repeated lines anywhere else on a page are text and are kept.
    static func pageContent(_ pages: [[String]]) -> [[String]] {
        var pages = pages
        let threshold = pages.count >= 3 ? max(3, (pages.count + 1) / 2) : Int.max
        var numbered = Set<Int>()
        for _ in 0..<2 {
            var headers: [String: Int] = [:]
            var footers: [String: Int] = [:]
            var numberOffsets: [Int: Int] = [:]
            for (index, page) in pages.enumerated() {
                guard let first = page.first, let last = page.last else { continue }
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

    /// "Page 3", "page 3 of 10", "3 of 10", "3 / 10", "- 3 -".
    static func isPageLabel(_ line: String) -> Bool {
        line.range(of: #"^(page\s+\d{1,4}(\s+(of|/)\s+\d{1,4})?|\d{1,4}\s+(of|/)\s+\d{1,4}|[-–—]\s*\d{1,4}\s*[-–—])$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?:\"”’)".contains(last)
    }
}
