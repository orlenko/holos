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

    @Test func orderedListsKeepTheirNumbersAndBreaksAreSilent() {
        let document = MarkdownReader.document(from: """
        3. Preheat the *oven*
        4. Bake
           1. nested one
           2. nested two

           Second paragraph of four.
        5. Serve

        - bullet
          1. inner ordered

        > 1. quoted step

        ---

        After the break.
        """)
        #expect(document.sections.flatMap(\.paragraphs) == [
            "3. Preheat the oven", "4. Bake", "1. nested one", "2. nested two", "Second paragraph of four.",
            "5. Serve", "bullet", "1. inner ordered", "1. quoted step", "After the break.",
        ])
    }

    @Test func frontMatterTitleIsReadOnceWhenTheTextOpensWithIt() {
        for body in ["# Guide to Bread\n\nText.", "## Guide to Bread\n\nText.", "Guide to Bread\n\nText."] {
            let document = MarkdownReader.document(from: "---\ntitle: Guide to Bread | My Blog\n---\n" + body)
            #expect(document.title == "Guide to Bread | My Blog")
            #expect(ReadingScript(document: document).text == "Guide to Bread\n\nText.", "\(body)")
        }
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

    @Test func orderedListsKeepTheirNumbers() {
        let html = """
        <html><body>
        <ol start="3"><li>Preheat</li><li><p>Bake</p><ol type="a"><li>Inner</li></ol></li></ol>
        <ol reversed><li>Three</li><li>Two</li><li>One</li></ol>
        <ol type="I"><li value="4">Four</li><li>Five</li></ol>
        <ul><li>Dot</li></ul>
        <ol><li><table><tr><td>Cell</td><td>Row</td></tr></table></li></ol>
        </body></html>
        """
        #expect(HTMLReader.document(from: Data(html.utf8)).sections.flatMap(\.paragraphs) == [
            "3. Preheat", "4. Bake", "a. Inner", "3. Three", "2. Two", "1. One", "IV. Four", "V. Five", "Dot",
            "1. Cell; Row",
        ])
        #expect(HTMLReader.Walker.marker(28, type: "a") == "ab.")
        #expect(HTMLReader.Walker.marker(1_994, type: "i") == "mcmxciv.")
        #expect(HTMLReader.Walker.marker(0, type: "A") == "0.")
    }

    @Test func anItemsNumberWaitsForItsOwnTextPastANestedList() {
        let html = """
        <html><body>
        <ol><li><ul><li>substep</li></ul>main step</li><li>second</li></ol>
        <ol start="5"><li><ol type="a"><li>inner</li></ol><p>outer</p></li></ol>
        <ol><li>Before<ul><li>nested</li></ul>after</li></ol>
        <menu><li>Copy</li><li>Paste</li></menu>
        </body></html>
        """
        #expect(HTMLReader.document(from: Data(html.utf8)).sections.flatMap(\.paragraphs) == [
            "substep", "1. main step", "2. second", "a. inner", "5. outer", "1. Before", "nested", "after",
            "Copy", "Paste",
        ])
    }

    @Test func extremeListNumbersNeverTrap() {
        let html = """
        <html><body>
        <ol start="9223372036854775807"><li>Max</li><li>After max</li></ol>
        <ol reversed start="-9223372036854775808"><li>Min</li><li>After min</li></ol>
        <ol start="99999999999999999999999"><li>Unparseable</li></ol>
        <ol start="1000000000"><li>Limit</li><li>Past limit</li></ol>
        <ol reversed start="-1000000000"><li>Low limit</li><li>Below</li></ol>
        <ol><li value="9223372036854775807">Value max</li><li>Next</li></ol>
        <ol reversed><li value="-9223372036854775808">Value min</li><li>Next</li></ol>
        <ol type="a" start="1000000000"><li>Letters</li></ol>
        <ol start="-5" type="i"><li>Negative roman</li></ol>
        </body></html>
        """
        #expect(HTMLReader.document(from: Data(html.utf8)).sections.flatMap(\.paragraphs) == [
            "1. Max", "2. After max", "2. Min", "1. After min", "1. Unparseable",
            "1000000000. Limit", "1000000001. Past limit", "-1000000000. Low limit", "-1000000001. Below",
            "1. Value max", "2. Next", "2. Value min", "1. Next", "cfdgsxl. Letters", "-5. Negative roman",
        ])
        #expect(HTMLReader.Walker.counter("1000000001") == nil)
        #expect(HTMLReader.Walker.counter("-1000000001") == nil)
        #expect(HTMLReader.Walker.counter(" 7") == nil)
        #expect(HTMLReader.Walker.counter("+7") == 7)
        #expect(HTMLReader.Walker.counter(nil) == nil)
        // The markers themselves take any Int.
        #expect(HTMLReader.Walker.marker(.max, type: "a").hasSuffix("."))
        #expect(HTMLReader.Walker.marker(.min, type: "I") == "\(Int.min).")
    }

    @Test func textListsWithExtremeStartNumbersDoNotTrap() {
        for start in [Int.max, Int.min, Int(Int32.max), 0] {
            let list = NSTextList(markerFormat: .decimal, options: 0)
            list.startingItemNumber = start
            let style = NSMutableParagraphStyle()
            style.textLists = [list]
            let text = NSMutableAttributedString(string: "Intro paragraph here.\n")
            text.append(NSAttributedString(string: "First\nSecond\n", attributes: [.paragraphStyle: style]))
            let paragraphs = RichTextReader.document(from: text, title: nil, author: nil).sections.flatMap(\.paragraphs)
            #expect(paragraphs.count == 3, "\(start)")
            #expect(paragraphs.last?.hasSuffix("Second") == true, "\(start)")
        }
    }

    @Test func nonASCIITextSurvivesWithOrWithoutADeclaredCharset() {
        for head in ["", #"<meta charset="utf-8">"#, #"<meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1">"#] {
            let document = HTMLReader.document(from: Data("\u{FEFF}<html lang=\"fr\"><head>\(head)<title>Café — Blog</title></head><body><p>Crème brûlée, 漢字, 👩🏽‍💻 &amp; “quotes”.</p></body></html>".utf8))
            #expect(document.title == "Café — Blog", "\(head)")
            #expect(document.sections.flatMap(\.paragraphs) == ["Crème brûlée, 漢字, 👩🏽‍💻 & “quotes”."], "\(head)")
        }
    }

    @Test func titleIsReadOnceWhenThePageRepeatsIt() {
        // <title> with the site name, no h1, and a first paragraph that says the title.
        let plain = HTMLReader.document(from: Data("""
        <html><head><title>Why Bread Rises — The Kitchen Blog</title></head>
        <body><p>Why Bread Rises</p><p>Yeast makes gas.</p></body></html>
        """.utf8))
        #expect(ReadingScript(document: plain).text == "Why Bread Rises\n\nYeast makes gas.")
        // A byline before the h1: the h1 is the title and is read where it stands.
        let byline = HTMLReader.document(from: Data("""
        <html><head><title>Why Bread Rises | Blog</title></head>
        <body><p>By Sam</p><h1>Why Bread Rises</h1><p>Yeast makes gas.</p></body></html>
        """.utf8))
        #expect(ReadingScript(document: byline).text == "By Sam\n\nWhy Bread Rises\n\nYeast makes gas.")
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

    @MainActor @Test func metadataTitleRepeatedByTheFirstLineIsReadOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("holos-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (declared, visible) in [("Quarterly Report", "Quarterly Report"),
                                    ("Microsoft Word - Quarterly Report.docx", "QUARTERLY REPORT"),
                                    ("Quarterly Report | ACME Corp", "Quarterly Report")] {
            let url = directory.appendingPathComponent("\(UUID().uuidString).pdf")
            try makePDF(url, pages: [[visible, "", "The body of the report is a sentence that ends here."]], title: declared)
            let script = ReadingScript(document: try DocumentLoader.load(url))
            #expect(script.text == "\(visible)\n\nThe body of the report is a sentence that ends here.", "\(declared)")
            #expect(script.text.lowercased().components(separatedBy: "quarterly").count == 2, "\(declared)")
        }
        // A metadata title the page does not show is still read first.
        let other = directory.appendingPathComponent("other.pdf")
        try makePDF(other, pages: [["Visible Heading", "", "The body is a sentence that ends here."]], title: "Hidden Name")
        #expect(ReadingScript(document: try DocumentLoader.load(other)).text
            == "Hidden Name\n\nVisible Heading\n\nThe body is a sentence that ends here.")
    }

    /// One PDF page per element; each string is drawn as a line, top to bottom.
    private func makePDF(_ url: URL, pages: [[String]], title: String? = nil) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info = title.map { [kCGPDFContextTitle as String: $0] as CFDictionary }
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, info))
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

    @Test func headingsReflowSetsApartBecomeChapters() {
        let paragraphs = ["Quarterly Report", "Introduction", "The year went well.", "2. Methods",
                          "We counted everything twice.", "Chapter 3", "Results", "Sales rose.",
                          "Shopping list:", "- milk", "- bread", "Then we went home.",
                          "Steps:", "1) Mix", "2) Bake", "Done.", "2024", "A closing line after a number.",
                          "An unpunctuated line after one", "Final words"]
        for declared in ["Quarterly Report", nil] {
            let document = PDFReader.document(paragraphs: paragraphs, declaredTitle: declared, author: nil)
            #expect(document.title == "Quarterly Report")
            #expect(document.sections.map(\.heading)
                == ["Quarterly Report", "Introduction", "2. Methods", "Chapter 3", "Results"], "\(declared ?? "-")")
            #expect(document.sections.map(\.level) == [1, 2, 2, 2, 2])
            #expect(document.sections.last?.paragraphs == ["Sales rose.", "Shopping list:", "- milk", "- bread",
                                                           "Then we went home.", "Steps:", "1) Mix", "2) Bake",
                                                           "Done.", "2024", "A closing line after a number.",
                                                           "An unpunctuated line after one", "Final words"])
            let script = ReadingScript(document: document)
            #expect(script.segments.compactMap(\.chapter) == ["Quarterly Report", "Introduction", "2. Methods",
                                                               "Chapter 3", "Results"])
            #expect(script.text.components(separatedBy: "Quarterly Report").count == 2)
        }
        // Under a metadata title the page does not show, the first heading is a chapter, too.
        let other = PDFReader.document(paragraphs: ["Visible Heading", "Body."], declaredTitle: "Hidden", author: nil)
        #expect(other.sections == [.init(heading: "Visible Heading", level: 2, paragraphs: ["Body."])])
        // Three short lines in a row are not headings.
        let lines = PDFReader.document(paragraphs: ["A sentence.", "Alpha", "Beta", "Gamma", "More text."],
                                       declaredTitle: "T", author: nil)
        #expect(lines.sections == [.init(paragraphs: ["A sentence.", "Alpha", "Beta", "Gamma", "More text."])])
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

    @Test func numberedListsKeepTheirNumbersInEveryFormat() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("holos-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let decimal = NSTextList(markerFormat: .decimal, options: 0)
        let alpha = NSTextList(markerFormat: .lowercaseAlpha, options: 0)
        let bullets = NSTextList(markerFormat: .disc, options: 0)
        func style(_ lists: [NSTextList]) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.textLists = lists
            return style
        }
        let body = NSFont.systemFont(ofSize: 12)
        let text = NSMutableAttributedString(string: "Steps to follow in order.\n", attributes: [.font: body])
        for (marker, item, lists, font) in [
            ("1.", "Preheat", [decimal], body), ("2.", "Bold Step", [decimal], NSFont.boldSystemFont(ofSize: 12)),
            ("a.", "Inner", [decimal, alpha], body), ("3.", "Serve", [decimal], body), ("•", "Dot", [bullets], body),
        ] {
            text.append(NSAttributedString(string: "\t\(marker)\t\(item)\n",
                                           attributes: [.font: font, .paragraphStyle: style(lists)]))
        }
        for (name, type) in [("a.rtf", NSAttributedString.DocumentType.rtf), ("a.odt", .openDocument),
                             ("a.docx", .officeOpenXML)] {
            let url = directory.appendingPathComponent(name)
            try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
                .write(to: url)
            let document = try DocumentLoader.load(url)
            // The bold item is a list item, not a heading.
            #expect(document.sections.compactMap(\.heading).isEmpty, "\(name)")
            let paragraphs = document.sections.flatMap(\.paragraphs)
            #expect(Array(paragraphs.prefix(5)) == ["Steps to follow in order.", "1. Preheat", "2. Bold Step", "a. Inner", "3. Serve"],
                    "\(name)")
            #expect(paragraphs.last?.hasSuffix("Dot") == true, "\(name)")
        }
        #expect(RichTextReader.numbered("Serve", marker: "3") == "3. Serve")
        #expect(RichTextReader.numbered("\t3.\tServe", marker: "3") == "\t3.\tServe")
        #expect(RichTextReader.numbered("Dot", marker: "•") == "Dot")
        #expect(RichTextReader.numbered("Step", marker: "(iv)") == "(iv) Step")
    }

    @Test func declaredTitleRepeatedByTheFirstParagraphIsReadOnce() {
        let text = NSAttributedString(string: "Plain Title\nBody text of the document.\n",
                                      attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let document = RichTextReader.document(from: text, title: "Plain Title", author: nil)
        #expect(ReadingScript(document: document).text == "Plain Title\n\nBody text of the document.")
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

@Suite struct TitleMatchTests {
    @Test func sameTitleIgnoresCasePunctuationAndSiteNames() {
        #expect(ReadableDocument.sameTitle("Page Title | Site", "Page Title"))
        #expect(ReadableDocument.sameTitle("Site — Page Title", "page title."))
        #expect(ReadableDocument.sameTitle("Café Notes", "CAFE NOTES"))
        #expect(ReadableDocument.sameTitle("Article | Section | Site", "Article"))
        #expect(ReadableDocument.sameTitle("Title", "Title - Blog"))
        #expect(!ReadableDocument.sameTitle("Article | Section | Site", "Section"))
        #expect(!ReadableDocument.sameTitle("Dune: Part Two", "Dune"))
        #expect(!ReadableDocument.sameTitle("???", "!!!"))
    }

    @Test func aDifferentOpeningStillHearsTheTitle() {
        let script = ReadingScript(document: ReadableDocument(title: "Dune: Part Two", sections: [
            .init(heading: "Dune", level: 1, paragraphs: ["Text."]),
        ]))
        #expect(script.text == "Dune: Part Two\n\nDune\n\nText.")
    }
}

@Suite struct ReadingOutputTests {
    @Test func destinationIsCheckedBeforeRendering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-out-\(UUID().uuidString)")
        let readings = root.appendingPathComponent("Readings")
        let shared = root.appendingPathComponent("Shared")
        let locked = root.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: readings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("file.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        func locate(_ output: String?, readings: URL = readings, resume: Bool = false) throws -> ReadingLocation {
            try ReadingOutput.locate(output: output, name: "T.m4a", identity: "a", readingsRoot: readings, resume: resume)
        }
        // The folder is missing, is a file, or cannot take new files.
        for bad in ["Missing/x.m4a", "file.txt/x.m4a", "Locked/x.m4a", "Locked"] {
            #expect(throws: HolosError.self, "\(bad)") { try locate(root.appendingPathComponent(bad).path) }
        }
        // Nothing is replaced: an existing file is an error unless resuming.
        let taken = shared.appendingPathComponent("Taken.m4a")
        try Data("old".utf8).write(to: taken)
        try Data("old".utf8).write(to: shared.appendingPathComponent("T.m4a"))
        #expect(throws: HolosError.self) { try locate(taken.path) }
        #expect(throws: HolosError.self) { try locate(shared.path) }
        #expect(try locate(taken.path, resume: true).output.lastPathComponent == "Taken.m4a")
        #expect(try locate(shared.path, resume: true).output.lastPathComponent == "T.m4a")
        // A broken link is something already there, too.
        try FileManager.default.createSymbolicLink(atPath: shared.appendingPathComponent("Link.m4a").path,
                                                   withDestinationPath: root.appendingPathComponent("nowhere").path)
        #expect(throws: HolosError.self) { try locate(shared.appendingPathComponent("Link.m4a").path) }
        // The Readings folder holds the cache in every case.
        for output in [nil, shared.appendingPathComponent("New.m4a").path] {
            #expect(throws: HolosError.self) { try locate(output, readings: root.appendingPathComponent("NoReadings")) }
            #expect(throws: HolosError.self) { try locate(output, readings: locked) }
        }
        // Paths past PATH_MAX are rejected, counting the temporary file written beside the output.
        let deep = URL(fileURLWithPath: "/" + String(repeating: "folder/", count: 150) + "x.m4a")
        #expect(throws: HolosError.self) { try ReadingOutput.checkPathLength(deep) }
        #expect(throws: Never.self) { try ReadingOutput.checkPathLength(shared.appendingPathComponent("x.m4a")) }
        // No probe files are left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).filter { $0.hasPrefix(".holos-probe") }.isEmpty)
    }

    @Test func fileNamesAreSafeAndReadable() {
        #expect(ReadingOutput.fileName(title: "Why Local Speech Matters") == "Why Local Speech Matters.m4a")
        #expect(ReadingOutput.fileName(title: "A/B: C? <D>|\"E\"*") == "A-B- C D-E.m4a")
        #expect(ReadingOutput.fileName(title: "..hidden\nname\t") == "hidden name.m4a")
        #expect(ReadingOutput.fileName(title: "  ", fallback: "article") == "article.m4a")
        #expect(ReadingOutput.fileName(title: nil, fallback: "???") == "Reading.m4a")
        let long = ReadingOutput.fileName(title: String(repeating: "é", count: 300))
        #expect(long == String(repeating: "é", count: 100) + ".m4a")
    }

    @Test func generatedFileNamesArePortableToWindows() {
        // Device names, in any case, with an extension or spaces before it, and with superscripts.
        for (title, expected) in [
            ("CON", "_CON"), ("con", "_con"), ("Aux", "_Aux"), ("NUL", "_NUL"), ("prn", "_prn"),
            ("COM1", "_COM1"), ("com0", "_com0"), ("LPT9", "_LPT9"), ("COM\u{00B9}", "_COM\u{00B9}"),
            ("lpt\u{00B3}", "_lpt\u{00B3}"), ("CON.txt", "_CON.txt"), ("nul.tar.gz", "_nul.tar.gz"),
            ("CON .txt", "_CON .txt"), ("CONIN$", "_CONIN$"), ("conout$", "_conout$"),
            ("CON.", "_CON"), ("..CON..", "_CON"), ("\u{0007}AUX\u{0000}", "_AUX"),
        ] {
            #expect(ReadingOutput.fileName(title: title) == expected + ".m4a", "\(title)")
        }
        // Names that only start like device names are fine.
        for title in ["CONSOLE", "Conference", "COM10", "LPT", "COM", "NULL", "AUXILIARY", "CON-TXT", "Com 1"] {
            #expect(ReadingOutput.fileName(title: title) == title + ".m4a", "\(title)")
        }
        // A fallback that is a device name, and a title that becomes one once shortened.
        #expect(ReadingOutput.fileName(title: "?*", fallback: "prn") == "_prn.m4a")
        #expect(ReadingOutput.fileName(title: "CON. The rest of the title", limit: 8) == "_CON.m4a")
        // The "_" is kept when the name must be shortened again to fit.
        #expect(ReadingOutput.fileName(title: "CON", limit: 7) == "_CO.m4a")
        // Characters Windows and exFAT reject, controls, and leading and trailing dots and spaces.
        #expect(ReadingOutput.fileName(title: " .a<b>c:d\"e/f\\g|h?i*j\u{0001}k\u{007F}l. ") == "abc-de-f-g-hij k l.m4a")
        #expect(ReadingOutput.fileName(title: "...", fallback: " . ") == "Reading.m4a")
        // A name placed in an existing output directory is checked as well.
        #expect(ReadingOutput.fitting("aux.m4a", limit: 255) == "_aux.m4a")
        #expect(ReadingOutput.fitting("Auxiliary.m4a", limit: 255) == "Auxiliary.m4a")
        #expect(ReadingOutput.isReserved("LPT1.m4a"))
        #expect(!ReadingOutput.isReserved("LPT10.m4a"))
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
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Readings"), withIntermediateDirectories: true)
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
        try FileManager.default.createDirectory(at: readings, withIntermediateDirectories: true)
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
