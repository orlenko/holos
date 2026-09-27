import AppKit
import Foundation
import HolosCore
import Testing
@testable import HolosContent

@Suite struct MarkdownReaderTests {
    @Test func markupIsStrippedAndHeadingsBecomeSections() {
        let document = MarkdownReader.document(from: """
        # The Title

        Intro with *emphasis*, **bold**, `code`, and a [link text](https://example.com).
        Soft wrapped line.

        ## Second part

        - item one
        - item **two**

        > A quote.

        ```swift
        let hidden = true
        ```

        ![a diagram](diagram.png)

        | Name | Size |
        |------|------|
        | Ava  | 3    |

        Last paragraph.
        """)
        #expect(document.title == "The Title")
        #expect(document.sections.map(\.heading) == ["The Title", "Second part"])
        #expect(document.sections.map(\.level) == [1, 2])
        #expect(document.sections[0].paragraphs == [
            "Intro with emphasis, bold, code, and a link text. Soft wrapped line.",
        ])
        #expect(document.sections[1].paragraphs == [
            "item one", "item two", "A quote.", "Name; Size", "Ava; 3", "Last paragraph.",
        ])
    }

    @Test func frontMatterSuppliesTitleAndAuthor() {
        let document = MarkdownReader.document(from: """
        ---
        title: "Front Title"
        author: Jane Writer
        lang: fr
        ---
        Body text without a heading.
        """)
        #expect(document.title == "Front Title")
        #expect(document.author == "Jane Writer")
        #expect(document.language == "fr")
        #expect(document.sections == [.init(paragraphs: ["Body text without a heading."])])
    }

    @Test func aLaterOrSmallerHeadingIsNotTheTitle() {
        #expect(MarkdownReader.document(from: "Intro.\n\n# Heading\n\nText.").title == nil)
        #expect(MarkdownReader.document(from: "## Heading\n\nText.").title == nil)
    }
}

@Suite struct PlainTextReaderTests {
    @Test func shortFirstLineIsTheTitle() {
        let document = PlainTextReader.document(from: "My Article\r\n\r\nFirst paragraph.\nStill first.\n\n\nSecond.")
        #expect(document.title == "My Article")
        #expect(document.sections == [.init(heading: "My Article", level: 1,
                                            paragraphs: ["First paragraph.\nStill first.", "Second."])])
    }

    @Test func aSentenceOrSingleParagraphIsNotATitle() {
        #expect(PlainTextReader.document(from: "This is a sentence.\n\nMore.").title == nil)
        #expect(PlainTextReader.document(from: "Only one paragraph").title == nil)
        #expect(PlainTextReader.document(from: "---\n\nText").title == nil)
    }
}

@Suite struct HTMLReaderTests {
    @Test func articleTextHeadingsAndMetadata() {
        let html = """
        <!DOCTYPE html>
        <html lang="en-GB"><head><title>Page Title | Site</title>
        <meta name="author" content="Sam Author"><style>p { color: red }</style>
        <script>var hidden = 1;</script></head>
        <body><nav><a href="/">Home</a> <a href="/about">About</a></nav>
        <article><h1>Article Heading</h1>
        <p>First&nbsp;paragraph with <em>emphasis</em> and <a href="#">a link</a>.</p>
        <div>Loose text in a div.</div>
        <h2>Details</h2>
        <ul><li>One</li><li>Two</li></ul>
        <pre>code that is skipped</pre>
        <table><tr><th>Name</th><th>Size</th></tr><tr><td>Ava</td><td>3</td></tr></table>
        </article><footer>Copyright</footer></body></html>
        """
        let document = HTMLReader.document(from: Data(html.utf8))
        #expect(document.title == "Article Heading")
        #expect(document.author == "Sam Author")
        #expect(document.language == "en-GB")
        #expect(document.sections.map(\.heading) == ["Article Heading", "Details"])
        #expect(document.sections[0].paragraphs == ["First paragraph with emphasis and a link.", "Loose text in a div."])
        #expect(document.sections[1].paragraphs == ["One", "Two", "Name; Size", "Ava; 3"])
    }

    @Test func titleElementWhenThereIsNoH1() {
        let document = HTMLReader.document(from: Data("<html><head><title> Plain  Page </title></head><body><p>Text.</p></body></html>".utf8))
        #expect(document.title == "Plain Page")
        #expect(document.sections == [.init(paragraphs: ["Text."])])
    }
}

@Suite struct PDFReaderTests {
    @Test func wrappedLinesBecomeParagraphs() {
        let page1 = """
        A Report Title
        This is a long line of body text that wraps onto the next line because
        the page is narrow, and it keeps going until the very end of the contin-
        ued sentence, which finishes on this line with some more words in it.
        A short last line.
        1
        """
        let page2 = """
        The next paragraph starts on page two and runs to the end of a full line
        and ends here.
        """
        let paragraphs = PDFReader.reflow(pages: [page1, page2])
        #expect(paragraphs == [
            "A Report Title",
            "This is a long line of body text that wraps onto the next line because the page is narrow, and it keeps going until the very end of the continued sentence, which finishes on this line with some more words in it. A short last line.",
            "The next paragraph starts on page two and runs to the end of a full line and ends here.",
        ])
    }

    @Test func shortUnpunctuatedLineAfterASentenceIsAHeading() {
        let paragraphs = PDFReader.reflow(pages: ["""
        ---
        A long line of text that is the whole paragraph and ends here with a period.
        Heading Here
        Another long line of text that is also a paragraph and ends with a period.
        """])
        #expect(paragraphs == [
            "---",
            "A long line of text that is the whole paragraph and ends here with a period.",
            "Heading Here",
            "Another long line of text that is also a paragraph and ends with a period.",
        ])
    }

    @Test func pageBreakInsideASentenceContinuesTheParagraph() {
        let paragraphs = PDFReader.reflow(pages: [
            "The sentence starts on the first page and keeps going across the",
            "page break without stopping.",
        ])
        #expect(paragraphs == ["The sentence starts on the first page and keeps going across the page break without stopping."])
    }

    @Test func blankLineInsideAPageIsAParagraphBreak() {
        // A long title and a long list item without closing punctuation, each followed by a
        // blank line and more text, still end their paragraphs. Blank lines at the edges of a
        // page are not paragraph breaks: the sentence continues onto the next page.
        let paragraphs = PDFReader.reflow(pages: ["""

        A Title That Is Long Enough To Reach Close To The Right Margin Of The Page Here

        This long paragraph of body text runs all the way to the right margin and it keeps
        going onto a second line that ends the paragraph.
        - a list item that is long enough to reach all the way to the right margin as well

        - bread from the corner bakery on the way home and then onward to the next town over
        and back again without stopping for anything at all along the way, not even for lunch or

        """, """

        a drink of water.
        """])
        #expect(paragraphs == [
            "A Title That Is Long Enough To Reach Close To The Right Margin Of The Page Here",
            "This long paragraph of body text runs all the way to the right margin and it keeps going onto a second line that ends the paragraph.",
            "- a list item that is long enough to reach all the way to the right margin as well",
            "- bread from the corner bakery on the way home and then onward to the next town over and back again without stopping for anything at all along the way, not even for lunch or a drink of water.",
        ])
    }

    @Test func pageFurnitureIsRemovedOnlyAtPageEdges() {
        let body = ["alpha", "bravo", "charlie", "delta", "echo"].map {
            "The \($0) paragraph is a long line of body text that fills the page from margin to margin."
        }
        let pages = [
            ["My Annual Report", "1984", body[0], "2", "Page 1 of 5"],
            ["My Annual Report", body[1], "1984", "7", body[1], "2"],
            ["My Annual Report", "3", body[2], "3 of 5"],
            ["My Annual Report", body[3], "4"],
            ["My Annual Report", "5"],
        ].map { $0.joined(separator: "\n") }
        let content = PDFReader.pageContent(pages.map(PDFReader.lines(of:)))
        #expect(content == [
            // The year at the top of page 1 and the numeral at its end, above the page label,
            // are text.
            ["1984", body[0], "2"],
            // Numbers inside a page are text; the printed page number is not.
            [body[1], "1984", "7", body[1]],
            // Page 3's leading "3" is a numeric title: its page number is at the bottom.
            ["3", body[2]],
            [body[3]],
            [],
        ])
    }

    @Test func singleBareNumberIsKeptUnlessItRunsWithThePages() {
        #expect(PDFReader.pageContent([["1984"]]) == [["1984"]])
        #expect(PDFReader.pageContent([["Text.", "1"]]) == [["Text."]])
        #expect(PDFReader.pageContent([["7", "Text."], ["Text.", "12"]]) == [["7", "Text."], ["Text.", "12"]])
        // Two running headers are not enough to call a line furniture.
        #expect(PDFReader.pageContent([["Header", "Text."], ["Header", "More."]]) == [["Header", "Text."], ["Header", "More."]])
    }

    @MainActor @Test func generatedPDFLosesPageNumbersButKeepsNumericText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("holos-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("numbers.pdf")
        try makePDF(url, pages: [
            ["The First Page", "", "It begins with a sentence that ends here.", "", "2024", "", "1"],
            ["Another sentence on the second page.", "", "2"],
        ])
        let document = try DocumentLoader.load(url)
        let paragraphs = document.sections.flatMap { [$0.heading].compactMap { $0 } + $0.paragraphs }
        #expect(paragraphs.contains("2024"))
        #expect(!paragraphs.contains("1"))
        #expect(!paragraphs.contains("2"))
        #expect(paragraphs.contains("Another sentence on the second page."))
    }

    /// One PDF page per element; each string is drawn as a line, top to bottom.
    private func makePDF(_ url: URL, pages: [[String]]) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for page in pages {
            context.beginPDFPage(nil)
            for (index, text) in page.enumerated() where !text.isEmpty {
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: text, attributes: [.font: font]))
                context.textPosition = CGPoint(x: 72, y: 720 - CGFloat(index) * 18)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    @Test func titleFromAttributesOrFirstLine() {
        #expect(PDFReader.cleanTitle("Microsoft Word - Budget.docx") == "Budget")
        let declared = PDFReader.document(paragraphs: ["Heading", "Body."], declaredTitle: "Declared", author: nil)
        #expect(declared.title == "Declared")
        let guessed = PDFReader.document(paragraphs: ["Heading", "Body."], declaredTitle: nil, author: "A")
        #expect(guessed.title == "Heading")
        #expect(guessed.sections == [.init(heading: "Heading", level: 1, paragraphs: ["Body."])])
    }
}

@MainActor @Suite struct RichTextReaderTests {
    private func styled() -> NSAttributedString {
        let text = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 12)
        text.append(NSAttributedString(string: "Big Title\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)]))
        text.append(NSAttributedString(string: "Body paragraph one is plain text.\n", attributes: [.font: body]))
        text.append(NSAttributedString(string: "Bold Subheading\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
        text.append(NSAttributedString(string: "Body paragraph two, also plain.\n", attributes: [.font: body]))
        text.append(NSAttributedString(string: "Bold sentence that ends with a period.\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
        return text
    }

    @Test func largerOrBoldShortLinesAreHeadings() {
        let document = RichTextReader.document(from: styled(), title: nil, author: "Writer")
        #expect(document.title == "Big Title")
        #expect(document.author == "Writer")
        #expect(document.sections.map(\.heading) == ["Big Title", "Bold Subheading"])
        #expect(document.sections.map(\.level) == [1, 2])
        #expect(document.sections[1].paragraphs == ["Body paragraph two, also plain.", "Bold sentence that ends with a period."])
    }

    @Test func rtfAndWordFilesLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("holos-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = styled()
        for (name, type) in [("a.rtf", NSAttributedString.DocumentType.rtf), ("a.docx", .officeOpenXML)] {
            let url = directory.appendingPathComponent(name)
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: type, .title: "Declared Title"])
            try data.write(to: url)
            let document = try DocumentLoader.load(url)
            #expect(document.title == "Declared Title", "\(name)")
            #expect(document.sections.flatMap(\.paragraphs).contains("Body paragraph one is plain text."), "\(name)")
            #expect(document.sections.compactMap(\.heading).contains("Big Title"), "\(name)")
        }
        let empty = directory.appendingPathComponent("empty.txt")
        try Data(" \n\n ".utf8).write(to: empty)
        #expect(throws: HolosError.self) { try DocumentLoader.load(empty) }
    }
}

@Suite struct ReadingOutputTests {
    @Test func fileNamesAreSafeAndReadable() {
        #expect(ReadingOutput.fileName(title: "Why Local Speech Matters") == "Why Local Speech Matters.m4a")
        #expect(ReadingOutput.fileName(title: "A/B: C? <D>|\"E\"*") == "A-B- C D-E.m4a")
        #expect(ReadingOutput.fileName(title: "..hidden\nname\t") == "hidden name.m4a")
        #expect(ReadingOutput.fileName(title: "  ", fallback: "article") == "article.m4a")
        #expect(ReadingOutput.fileName(title: nil, fallback: "???") == "Reading.m4a")
        let long = ReadingOutput.fileName(title: String(repeating: "é", count: 300))
        #expect(long == String(repeating: "é", count: 100) + ".m4a")
    }

    @Test func fileNamesFitTheFilesystemLimitOnCharacterBoundaries() {
        // 100 CJK characters are 300 UTF-8 bytes; 100 of these emoji are 1,500.
        let cjk = ReadingOutput.fileName(title: String(repeating: "漢", count: 100))
        #expect(cjk.utf8.count <= 255)
        #expect(cjk == String(repeating: "漢", count: 83) + ".m4a")
        let emoji = "👩🏽‍💻"
        let people = ReadingOutput.fileName(title: String(repeating: emoji, count: 100))
        #expect(people.utf8.count <= 255)
        #expect(people == String(repeating: emoji, count: 16) + ".m4a")
        // Joiners stay inside emoji; bidi overrides are dropped.
        #expect(ReadingOutput.fileName(title: "Notes\u{202E}4pm.exe") == "Notes4pm.exe.m4a")
        // Decomposed length counts too (HFS+ stores names in NFD): each "ǘ" is three UTF-16 units there.
        let accented = ReadingOutput.fileName(title: String(repeating: "\u{01D8}", count: 100))
        #expect(ReadingOutput.fits(accented))
        #expect(accented.decomposedStringWithCanonicalMapping.utf16.count <= 255)
        #expect(accented == String(repeating: "\u{01D8}", count: 83) + ".m4a")
        // A smaller volume limit, and an existing name re-fitted to it.
        #expect(ReadingOutput.fileName(title: String(repeating: "漢", count: 10), limit: 16) == "漢漢漢漢.m4a")
        #expect(ReadingOutput.fitting("漢漢漢漢漢漢漢漢漢漢.m4a", limit: 16) == "漢漢漢漢.m4a")
        #expect(ReadingOutput.fitting("Short.m4a", limit: 16) == "Short.m4a")
    }

    @Test func tooLongExplicitOutputNameIsRejectedUpFront() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = String(repeating: "漢", count: 90) + ".m4a"
        #expect(throws: HolosError.self) {
            try ReadingOutput.locate(output: root.appendingPathComponent(name).path, name: "T.m4a", identity: "a",
                                     readingsRoot: root.appendingPathComponent("Readings"))
        }
    }

    @Test func outputOptionResolvesToAFileAndACache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-out-\(UUID().uuidString)")
        let readings = root.appendingPathComponent("Readings")
        let shared = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fresh = try ReadingOutput.locate(output: nil, name: "T.m4a", identity: "a", readingsRoot: readings)
        #expect(fresh.workDirectory.deletingLastPathComponent().path == readings.path)
        #expect(fresh.output == fresh.workDirectory.appendingPathComponent("T.m4a"))

        let file = try ReadingOutput.locate(output: shared.appendingPathComponent("x.M4A").path, name: "T.m4a", identity: "a", readingsRoot: readings)
        #expect(file.output.lastPathComponent == "x.M4A")
        #expect(file.workDirectory.lastPathComponent.hasPrefix("Output-"))
        let same = try ReadingOutput.locate(output: shared.appendingPathComponent("x.M4A").path, name: "Other.m4a", identity: "a", readingsRoot: readings)
        #expect(same == file)
        let changed = try ReadingOutput.locate(output: shared.appendingPathComponent("x.M4A").path, name: "T.m4a",
                                               identity: "b", readingsRoot: readings)
        #expect(changed.output == file.output)
        #expect(changed.workDirectory != file.workDirectory)

        let inDirectory = try ReadingOutput.locate(output: shared.path, name: "T.m4a", identity: "a", readingsRoot: readings)
        #expect(inDirectory.output.lastPathComponent == "T.m4a")
        #expect(inDirectory.output.deletingLastPathComponent().resolvingSymlinksInPath() == shared.resolvingSymlinksInPath())
        #expect(inDirectory.workDirectory != file.workDirectory)

        // A reading made without --output is resumed by passing its folder.
        let existing = readings.appendingPathComponent("ABC")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data(#"{"kind": "voiceislocal.reading", "schemaVersion": 3}"#.utf8)
            .write(to: existing.appendingPathComponent("manifest.json"))
        let resumed = try ReadingOutput.locate(output: existing.path, name: "T.m4a", identity: "a", readingsRoot: readings)
        #expect(resumed.workDirectory.standardizedFileURL == existing.standardizedFileURL)
        #expect(resumed.output.lastPathComponent == "T.m4a")

        // Some other program's manifest.json (a web project, say) is an ordinary output folder.
        for unrelated in ["{}", #"{"name": "web-app", "version": 1}"#, #"{"kind": "other", "schemaVersion": 3}"#, "not json"] {
            try Data(unrelated.utf8).write(to: shared.appendingPathComponent("manifest.json"))
            let located = try ReadingOutput.locate(output: shared.path, name: "T.m4a", identity: "a", readingsRoot: readings)
            #expect(located == inDirectory, "\(unrelated)")
        }

        #expect(throws: HolosError.self) {
            try ReadingOutput.locate(output: shared.appendingPathComponent("x.mp3").path, name: "T.m4a", identity: "a", readingsRoot: readings)
        }
    }

    @Test func languageDetection() {
        #expect(ReadingLanguage.detect("The quick brown fox jumps over the lazy dog, and then it runs away into the forest.") == "en")
        #expect(ReadingLanguage.detect("Le renard brun rapide saute par-dessus le chien paresseux, puis il s'enfuit dans la forêt.") == "fr")
    }
}
