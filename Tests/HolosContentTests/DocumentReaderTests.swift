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

    /// A byte order mark never hides front matter or ends up in a title, from a file in UTF-8,
    /// UTF-16, or UTF-32, or from a string (stdin) that still has one.
    @MainActor @Test func aLeadingByteOrderMarkIsDropped() throws {
        let markdown = "---\ntitle: Front Title\nauthor: Jane\nlang: fr\n---\n\n# Heading\n\nBody text."
        let plain = "My Article\n\nFirst paragraph."
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-bom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        func encodings(_ text: String) -> [Data] {
            [Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8),
             Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!,
             Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!,
             Data([0xFF, 0xFE, 0x00, 0x00]) + text.data(using: .utf32LittleEndian)!]
        }
        for (index, data) in encodings(markdown).enumerated() {
            #expect(DocumentText.decode(data) == markdown, "\(index)")
            let url = folder.appendingPathComponent("front\(index).md")
            try data.write(to: url)
            let document = try DocumentLoader.load(url)
            #expect(document.title == "Front Title", "\(index)")
            #expect(document.author == "Jane", "\(index)")
            #expect(document.language == "fr", "\(index)")
            #expect(!ReadingScript(document: document).text.contains("title:"), "\(index)")
        }
        for (index, data) in encodings(plain).enumerated() {
            let url = folder.appendingPathComponent("plain\(index).txt")
            try data.write(to: url)
            #expect(try DocumentLoader.load(url).title == "My Article", "\(index)")
        }
        // Strings (stdin is decoded with `DocumentText` too) lose one mark; a second one is text.
        #expect(MarkdownReader.document(from: "\u{FEFF}" + markdown).title == "Front Title")
        #expect(PlainTextReader.document(from: "\u{FEFF}" + plain).title == "My Article")
        #expect(DocumentText.decode(Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0x41])) == "\u{FEFF}A")
        // Without a mark, only UTF-8 is text.
        #expect(DocumentText.decode(Data([0xFF, 0x41])) == nil)
    }

    /// Classic Mac (CR) and Windows (CRLF) line endings are made LF when the text is decoded, so
    /// front matter, headings, and paragraphs are found in every file.
    @MainActor @Test func everyLineEndingIsReadAsOne() throws {
        let markdown = "---\ntitle: Front Title\nauthor: Jane\nlang: fr\n---\n\n# Heading\n\nBody text.\n\nMore text."
        let plain = "My Article\n\nFirst paragraph.\nStill first.\n\nSecond."
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-eol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let expected = MarkdownReader.document(from: markdown)
        #expect(expected.title == "Front Title")
        for (index, ending) in ["\r", "\r\n"].enumerated() {
            let data = Data(markdown.replacingOccurrences(of: "\n", with: ending).utf8)
            #expect(DocumentText.decode(data) == markdown, "\(index)")
            let url = folder.appendingPathComponent("mac\(index).md")
            try data.write(to: url)
            let document = try DocumentLoader.load(url)
            #expect(document == expected, "\(index)")
            #expect(document.author == "Jane", "\(index)")
            #expect(document.language == "fr", "\(index)")
            #expect(!ReadingScript(document: document).text.contains("title:"), "\(index)")
            // A string (not decoded from bytes) is read the same way.
            #expect(MarkdownReader.document(from: markdown.replacingOccurrences(of: "\n", with: ending)) == expected)

            let text = folder.appendingPathComponent("mac\(index).txt")
            try Data(plain.replacingOccurrences(of: "\n", with: ending).utf8).write(to: text)
            #expect(try DocumentLoader.load(text) == PlainTextReader.document(from: plain), "\(index)")
        }
        // HTML text is decoded the same way.
        #expect(HTMLReader.decode(Data("<p>a\r\nb\rc</p>".utf8)) == "<p>a\nb\nc</p>")
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

    /// A table cell is read like the rest of the page: its lists keep their numbers, its blocks
    /// stay apart, and a nested table's rows are read, all on the cell's line.
    @Test func tableCellsAreReadLikeThePage() {
        #expect(paragraphs("""
        <html><body>
        <table>
        <caption>Steps</caption>
        <tr><td><ol><li>First</li><li>Second</li></ol></td></tr>
        <tr><th>Rank</th><td><ol start="3" type="i"><li>Third</li></ol><ul><li>Dot</li></ul></td></tr>
        <tr><td><dl><dt>Term</dt><dd>Meaning</dd></dl></td><td><blockquote><p>Quoted</p><p>twice</p></blockquote></td></tr>
        <tr><td><h3>Cell heading</h3>Cell body</td><td><table><tr><td>Inner</td><td>cell</td></tr><tr><td>Row two</td></tr></table></td></tr>
        <tr><td>Hidden <span hidden>menu</span> text<br>after break</td></tr>
        </table>
        <ol><li><table><tr><td><ol><li>Nested</li></ol></td><td>Other</td></tr></table></li><li>Next</li></ol>
        </body></html>
        """) == [
            "Steps",
            "1. First 2. Second",
            "Rank; iii. Third Dot",
            "Term Meaning; Quoted twice",
            "Cell heading Cell body; Inner; cell Row two",
            "Hidden text after break",
            "1. 1. Nested; Other",
            "2. Next",
        ])
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

    /// Every block in an ordered item takes the item's number when it comes first: a heading (so
    /// the section and its chapter are "1. Install"), a definition term, a figure caption, and a
    /// table caption alike.
    @Test func headingsAndCaptionsInListItemsKeepTheItemsNumber() {
        let html = """
        <html><body>
        <ol><li><h2>Install</h2><p>Download it.</p></li><li><h2>Run</h2><p>Open it.</p></li></ol>
        <ol start="3"><li><dl><dt>Term</dt><dd>Meaning</dd></dl></li>
        <li><figure><figcaption>Figure caption</figcaption></figure></li>
        <li><table><caption>Table caption</caption><tr><td>Cell</td></tr></table></li>
        <li><h3>   </h3>Text after an empty heading</li></ol>
        </body></html>
        """
        let document = HTMLReader.document(from: Data(html.utf8))
        #expect(document.sections.map(\.heading) == ["1. Install", "2. Run"])
        #expect(document.sections.map(\.paragraphs) == [
            ["Download it."],
            ["Open it.", "3. Term", "Meaning", "4. Figure caption", "5. Table caption", "Cell",
             "6. Text after an empty heading"],
        ])
        let chapters = ReadingScript(document: document).segments.compactMap(\.chapter)
        #expect(chapters == ["1. Install", "2. Run"])
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

    /// Element, attribute, and metadata names in any ASCII case, in or out of the XHTML namespace.
    @Test func metadataNamesMatchInAnyCase() {
        for (html, author, language) in [
            (#"<HTML LANG="fr-CA"><HEAD><TITLE>Upper</TITLE><META NAME="AUTHOR" CONTENT="Jane Doe"></HEAD>"#, "Jane Doe", "fr-CA"),
            (#"<html lang="en"><head><title>Upper</title><meta name="Author" content="Jane Doe"></head>"#, "Jane Doe", "en"),
            (#"<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="de"><head><title>Upper</title><meta Name="DC.Creator" Content="Dublin Writer"></head>"#, "Dublin Writer", "de"),
            (#"<html><head><title>Upper</title><meta name="dcterms.creator" content="Terms Writer"><meta name="author" content=" "><meta name="AUTHOR" content="Second Author"></head>"#, "Second Author", nil),
            (#"<html><head><title>Upper</title><meta property="article:author" content="https://example.test/jane"></head>"#, nil, nil),
        ] as [(String, String?, String?)] {
            let document = HTMLReader.document(from: Data((html + "<body><p>Text.</p></body></html>").utf8))
            #expect(document.title == "Upper", "\(html)")
            #expect(document.author == author, "\(html)")
            #expect(document.language == language, "\(html)")
        }
        // "author" wins over Dublin Core, wherever it is.
        let both = HTMLReader.document(from: Data(#"<html><head><meta name="DC.creator" content="Dublin"><meta name="Author" content="Named"></head><body><p>Text.</p></body></html>"#.utf8))
        #expect(both.author == "Named")
    }

    /// UTF-16 (Notepad's "Unicode") and UTF-8 pages with a byte order mark read the same.
    @Test func htmlWithAByteOrderMarkInAnyUnicodeEncoding() {
        let html = "<html lang=\"fr\"><head><title>Café</title><meta name=\"Author\" content=\"Zoé\"></head><body><p>Crème brûlée.</p></body></html>"
        for data in [Data([0xEF, 0xBB, 0xBF]) + Data(html.utf8), Data([0xFF, 0xFE]) + html.data(using: .utf16LittleEndian)!,
                     Data([0xFE, 0xFF]) + html.data(using: .utf16BigEndian)!] {
            let document = HTMLReader.document(from: data)
            #expect(document.title == "Café")
            #expect(document.author == "Zoé")
            #expect(document.sections.flatMap(\.paragraphs) == ["Crème brûlée."])
        }
    }

    private func paragraphs(_ html: String) -> [String] {
        HTMLReader.document(from: Data(html.utf8)).sections.flatMap(\.paragraphs)
    }

    /// Skipped elements go with everything inside them, however they nest: the parser keeps
    /// HTML5 elements as elements, and the tree is walked.
    @Test func nestedSkippedElementsAreSkippedWhole() {
        #expect(paragraphs("""
        <!DOCTYPE html><html><head><title>T</title></head><body>
        <header><p>Header text</p></header>
        <nav>Menu <nav>Inner menu</nav> menu tail <ul><li>Link</li></ul></nav>
        <main><article><section><p>First.</p>
        <template>Outer <template>inner</template> outer tail <p>template paragraph</p></template>
        <aside>Aside <aside>inner aside</aside> aside tail</aside>
        <p>Second <my-widget>custom inline</my-widget> and <mark>marked</mark> text.</p>
        <figure><svg viewBox="0 0 1 1"><title>Icon title</title><path d="M0 0"/><text>svg text</text></svg><figcaption>Caption.</figcaption></figure>
        <table><tr><template><td>template cell</td></template><td>Real cell</td></tr></table>
        <p>Price <svg><g><svg><text>nested</text></svg></g><desc>desc</desc></svg> now.</p>
        </section></article></main>
        <NAV CLASS="upper">Upper nav</NAV>
        <footer><p>Footer <footer>inner footer</footer> tail</p></footer>
        <p>Last.</p></body></html>
        """) == ["Header text", "First.", "Second custom inline and marked text.", "Caption.", "Real cell",
                 "Price now.", "Last."])
    }

    /// `/>` ends only a void element or foreign content (SVG, MathML); on any other element HTML
    /// ignores the slash, and the element stays open up to its end tag.
    @Test func selfClosingSyntaxFollowsHTML() {
        #expect(paragraphs("""
        <html><body>
        <p>One.</p>
        <template/>hidden template</template>
        <nav/>menu</nav>
        <NAV CLASS="x" />upper menu</NAV>
        <p>Line<br/>break <img src="a.png"/>image<wbr/>end.</p>
        <p>Icon <svg><path d="M0 0"/><circle r="1"/><title/>svg text</svg> after.</p>
        <p>Empty <svg/> and <math/> foreign.</p>
        <video><source src="a.mp4">video text</video>
        <p>Media <audio><source src="a.mp3"><track src="t.vtt"></audio>done.</p>
        <template><svg><path/></svg>still hidden<div/>hidden div</template>
        <aside/>aside text</aside>
        <script/>document.write("x")</script>
        <p><a href=/next/>Next</a> page.</p>
        <p>Last.</p>
        </body></html>
        """) == ["One.", "Line", "break imageend.", "Icon after.", "Empty and foreign.", "Media done.",
                 "Next page.", "Last."])
        let marker = "data-holos-x-tag"
        #expect(HTMLReader.prepared("<template/>a</template>", nameAttribute: marker)
            == #"<div data-holos-x-tag="template">a</div>"#)
        #expect(HTMLReader.prepared("<div/>a</div><br/><source src=x>", nameAttribute: marker)
            == #"<div>a</div><br/><span data-holos-x-tag="source" src=x></span>"#)
        #expect(HTMLReader.prepared("<svg><path/></svg>", nameAttribute: marker)
            == #"<span data-holos-x-tag="svg"><span></span></span>"#)
        #expect(HTMLReader.prepared("<a href=/next/>x</a>", nameAttribute: marker) == "<a href=/next/>x</a>")
    }

    /// Tags inside comments and raw text elements are not tags.
    @Test func commentsAndScriptsDoNotOpenElements() {
        #expect(paragraphs("""
        <html><head><style>nav > a { color: red } /* </nav> */</style></head><body>
        <!-- <nav> a commented-out tag -->
        <script>if (a <template) { document.write("</template><p>not read</p>") }</script>
        <p>Kept one.</p>
        <template><script>var s = "</template>";</script>hidden</template>
        <p>Kept two.</p>
        <textarea><nav>typed text</nav></textarea>
        <p>Kept three.</p></body></html>
        """) == ["Kept one.", "Kept two.", "Kept three."])
        // A quote opens an attribute value only after `=`.
        #expect(paragraphs(##"<p><a title=It's href="#">Link</a> <b class='x'>bold</b></p><nav>Menu's</nav><p>After.</p>"##)
            == ["Link bold", "After."])
        let title = HTMLReader.document(from: Data("<html><head><title>Less <nav> more</title></head><body><p>x</p></body></html>".utf8))
        #expect(title.title == "Less <nav> more")
    }

    /// `<!-->` and `<!--->` are whole comments, to the page's parser as to the charset prescan:
    /// what follows one, the body included, is read.
    @Test func abruptlyClosedCommentsEndAtOnce() {
        for comment in ["<!-->", "<!--->"] {
            #expect(paragraphs("<!doctype html>\(comment)<html><head><title>T</title></head><body>"
                + "<p>Kept one.</p>\(comment)<p>Kept two.</p><!-- <p>not read</p> --><p>Kept three.</p></body></html>")
                == ["Kept one.", "Kept two.", "Kept three."])
            #expect(paragraphs("\(comment)<p>Loose page.</p>") == ["Loose page."])
            // The declaration after it is real, and the text is read in that encoding.
            var page = Data("\(comment)<meta charset=windows-1252><body><p>Caf".utf8)
            page.append(0xE9)
            page += Data("</p></body>".utf8)
            #expect(HTMLReader.document(from: page).sections.flatMap(\.paragraphs) == ["Café"])
        }
        let marker = "data-holos-x-tag"
        #expect(HTMLReader.prepared("<!--><p>a</p><!---><!----><!-- b --><!-- c", nameAttribute: marker)
            == "<!----><p>a</p><!----><!----><!-- b --><!-- c")
        for (text, end) in [("<!-->", 5), ("<!--->", 6), ("<!---->", 7), ("<!-- a -- b -->", 15), ("<!-- a", nil)] {
            #expect(HTMLReader.commentEnd(in: Array(text.utf8), from: 0) == end, "\(text)")
        }
    }

    /// The legacy forms of `<pre>` are preformatted code too, and are not read.
    @Test func legacyPreformattedElementsAreSkipped() {
        #expect(paragraphs("""
        <html><body><p>Before.</p>
        <xmp><p>Markup shown as text</p> if (a < b) { run() }</xmp>
        <p>Between.</p>
        <listing>for i in 1...3 { print(i) }</listing>
        <p>After.</p>
        <plaintext>Everything after this is source text.
        """) == ["Before.", "Between.", "After."])
    }

    @Test func hiddenElementsAreSkipped() {
        #expect(paragraphs("""
        <html><body>
        <p hidden>Hidden attribute.</p>
        <div HIDDEN="until-found"><p>Until found.</p></div>
        <p aria-hidden="TRUE">Aria hidden.</p>
        <p aria-hidden="false">Aria visible.</p>
        <p style="color: red; DISPLAY : none !important">Display none.</p>
        <p style="display:block">Display block.</p>
        <section style="display:none"><p>Hidden section.</p></section>
        <p>Inline <span style="display: none">hidden span </span>text.</p>
        <dialog><p>Closed dialog.</p></dialog>
        <dialog open><p>Open dialog.</p></dialog>
        </body></html>
        """) == ["Aria visible.", "Display block.", "Inline text.", "Open dialog."])
    }

    /// Legacy-encoded pages are decoded before parsing and read like UTF-8 ones, navigation and
    /// footers skipped.
    @Test func legacyEncodedPagesSkipNavigationToo() throws {
        let body = "<body><nav>Menü</nav><h1>Café</h1><p>Crème “brûlée” – 5 €.</p><footer>© Pied</footer></body></html>"
        let pages: [(String, String.Encoding)] = [
            (#"<html><head><meta charset="ISO-8859-1"><title>T</title></head>"#, .windowsCP1252),
            (#"<html><head><META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=iso-8859-1"></head>"#, .windowsCP1252),
            (#"<html><head><meta http-equiv='content-type' content='text/html;charset=Windows-1252'></head>"#, .windowsCP1252),
            (#"<html><head><meta charset=windows-1252></head>"#, .windowsCP1252),
            // No declaration and not UTF-8: Windows-1252, HTML's default.
            ("<html><head></head>", .windowsCP1252),
            (#"<html><head><meta charset="x-unknown-charset"></head>"#, .windowsCP1252),
        ]
        for (head, encoding) in pages {
            let data = try #require((head + body).data(using: encoding), "\(head)")
            #expect(DocumentText.decode(data) == nil, "\(head)")
            let document = HTMLReader.document(from: data)
            #expect(document.title == "Café", "\(head)")
            #expect(document.sections.flatMap(\.paragraphs) == ["Crème “brûlée” – 5 €."], "\(head)")
        }
        // Any charset Foundation knows by its IANA name.
        let russian = try #require(#"<html><head><meta charset="KOI8-R"></head><body><aside>Реклама</aside><p>Привет, мир.</p></body></html>"#
            .data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.KOI8_R.rawValue)))))
        #expect(HTMLReader.document(from: russian).sections.flatMap(\.paragraphs) == ["Привет, мир."])
    }

    @Test func pagesInUTF16WithAByteOrderMarkSkipNavigation() {
        let html = "<html><head><meta charset=\"iso-8859-1\"></head><body><nav>Menu</nav><p>Zoë’s text.</p><footer>Foot</footer></body></html>"
        for data in [Data([0xFF, 0xFE]) + html.data(using: .utf16LittleEndian)!,
                     Data([0xFE, 0xFF]) + html.data(using: .utf16BigEndian)!] {
            #expect(HTMLReader.document(from: data).sections.flatMap(\.paragraphs) == ["Zoë’s text."])
        }
    }

    @Test func encodingIsPickedAsBrowsersPickIt() {
        let text = "<p>Café</p>"
        // A byte order mark wins over a declaration.
        #expect(HTMLReader.decode(Data([0xEF, 0xBB, 0xBF]) + Data(#"<meta charset="iso-8859-1">\#(text)"#.utf8))
            == #"<meta charset="iso-8859-1">\#(text)"#)
        // A declaration wins over valid UTF-8: these bytes are "CafÃ©" in Windows-1252.
        #expect(HTMLReader.decode(Data(#"<meta charset="latin1">\#(text)"#.utf8)) == #"<meta charset="latin1">\#(text)"#
            .replacingOccurrences(of: "é", with: "Ã©"))
        // UTF-16 declared without a byte order mark is read as UTF-8.
        #expect(HTMLReader.decode(Data(#"<META Charset="UTF-16">\#(text)"#.utf8)) == #"<META Charset="UTF-16">\#(text)"#)
        // Declared UTF-8 with an invalid byte: UTF-8 with a replacement character.
        #expect(HTMLReader.decode(Data(#"<meta charset="utf-8"><p>A"#.utf8) + Data([0xE9]) + Data("</p>".utf8))
            == "<meta charset=\"utf-8\"><p>A\u{FFFD}</p>")
        // A declaration past the first 1024 bytes is not looked for; the bytes are valid UTF-8.
        let late = String(repeating: " ", count: 1_024) + #"<meta charset="iso-8859-1">"# + text
        #expect(HTMLReader.decode(Data(late.utf8)) == late)
        // Undeclared, invalid UTF-8: Windows-1252, where 0x80 is the euro sign and the undefined
        // 0x81 stands for itself.
        #expect(HTMLReader.decode(Data([0x3C, 0x70, 0x3E, 0x80, 0xE9, 0x81])) == "<p>€é\u{81}")
        #expect(HTMLReader.encoding(named: "US-ASCII") == .windowsCP1252)
        #expect(HTMLReader.encoding(named: "utf-32") == .utf8)
        #expect(HTMLReader.encoding(named: "not-a-charset") == nil)
    }

    /// Only a real `<meta>` tag declares a charset: one in a comment or in a raw text element's
    /// contents (a script writing it, a title quoting it) is text, as in browsers.
    @Test func charsetDeclarationsInCommentsAndRawTextAreIgnored() {
        func declared(_ html: String) -> String.Encoding? { HTMLReader.declaredEncoding(Data(html.utf8)) }
        let pages: [(String, String.Encoding?)] = [
            ("<!-- <meta charset=windows-1252> --><meta charset=utf-8>", .utf8),
            ("<!--<meta charset=windows-1252>--><meta charset=utf-8>", .utf8),
            // `<!-->` is a whole comment, so the declaration after it is real.
            ("<!--><meta charset=windows-1252>", .windowsCP1252),
            (#"<script>document.write('<meta charset="windows-1252">')</script><meta charset="utf-8">"#, .utf8),
            ("<SCRIPT type=module>let s = '<meta charset=windows-1252>'</SCRIPT ><meta charset=utf-8>", .utf8),
            ("<style>/* <meta charset=windows-1252> */</style><meta charset=utf-8>", .utf8),
            ("<title>Use <meta charset=windows-1252></title><meta charset=utf-8>", .utf8),
            ("<textarea><meta charset=windows-1252></textarea><meta charset=utf-8>", .utf8),
            ("<noscript><meta charset=windows-1252></noscript><meta charset=utf-8>", .utf8),
            // A `>` in a quoted value does not end a tag, and `<metadata>` is not `<meta>`.
            (#"<div title="<meta charset=windows-1252>"><meta charset=utf-8>"#, .utf8),
            ("<metadata charset=windows-1252><meta charset=utf-8>", .utf8),
            // An end tag is read past the same way.
            ("</div title='<meta charset=windows-1252>'><meta charset=utf-8>", .utf8),
            // Unfinished comments and scripts hide the rest.
            ("<!-- <meta charset=windows-1252>", nil),
            ("<script><meta charset=windows-1252>", nil),
            // A real declaration after text or other tags still counts.
            ("<html lang=fr><head><title>T</title><meta charset=windows-1252>", .windowsCP1252),
            // A tag name ends at "/": `<script/>` is a script (HTML ignores the slash), so what
            // follows up to `</script>` is text.
            ("<script/><meta charset=windows-1252></script><meta charset=utf-8>", .utf8),
            ("<STYLE/><meta charset=windows-1252></style><meta charset=utf-8>", .utf8),
            ("<title/ ><meta charset=windows-1252></title><meta charset=utf-8>", .utf8),
            ("<meta/charset=windows-1252>", .windowsCP1252),
        ]
        for (html, encoding) in pages {
            #expect(declared(html) == encoding, "\(html)")
        }
        // The cases from the reviews: valid UTF-8 is not read as Windows-1252 mojibake, and the
        // step that prepares the page for parsing reads `<script/>` the same way.
        for page in ["<!-- <meta charset=windows-1252> --><meta charset=utf-8><p>Café</p>",
                     "<script/><meta charset=windows-1252></script><meta charset=utf-8><p>Café</p>"] {
            #expect(HTMLReader.document(from: Data(page.utf8)).sections.flatMap(\.paragraphs) == ["Café"], "\(page)")
        }
    }

    /// The prescan and `prepared` share one tokenizer: they agree on where every tag name and tag
    /// ends, quoted `>` and self-closing slashes included.
    @Test func prescanAndPreparationReadTagsAlike() {
        let tags = [
            "<script/>", "<p title='a>b'>", "<a href=a/>", "<br/>", "<div data-x = \"1\" hidden>",
            "</div title='>'>", "<img src=x.png/>",
        ]
        for tag in tags {
            var scanner = HTMLReader.TagScanner(bytes: Array(tag.utf8), position: 0)
            let name = scanner.tagName()?.name
            while scanner.attribute() != nil {}
            #expect(scanner.position == tag.utf8.count - 1, "\(tag)")
            #expect(name.map { !$0.contains("/") } == true, "\(tag)")
        }
        #expect(paragraphs("<p>One</p><script/>var x = '<p>Hidden</p>';</script><p>Two</p>") == ["One", "Two"])
    }

    /// `<meta>` attributes in every form: names and values in any case, values double-quoted,
    /// single-quoted, or unquoted, `charset` or `http-equiv="content-type"` with `content`.
    @Test func charsetDeclarationAttributesInEveryForm() {
        func declared(_ html: String) -> String.Encoding? { HTMLReader.declaredEncoding(Data(html.utf8)) }
        let pages: [(String, String.Encoding?)] = [
            (#"<meta charset="windows-1252">"#, .windowsCP1252),
            ("<meta charset='windows-1252'>", .windowsCP1252),
            ("<meta charset=windows-1252>", .windowsCP1252),
            ("<meta charset=windows-1252 />", .windowsCP1252),
            (#"<META CHARSET = "Windows-1252" >"#, .windowsCP1252),
            ("<meta/charset=windows-1252>", .windowsCP1252),
            ("<meta\ncharset\t=\t'ISO-8859-1'>", .windowsCP1252),
            (#"<meta http-equiv="Content-Type" content="text/html; charset=windows-1252">"#, .windowsCP1252),
            ("<meta HTTP-EQUIV=content-type CONTENT=text/html;charset=windows-1252>", .windowsCP1252),
            (#"<meta content='text/html; charset="windows-1252"' http-equiv='CONTENT-TYPE'>"#, .windowsCP1252),
            (#"<meta http-equiv="content-type" content="text/html; CHARSET = windows-1252; x=y">"#, .windowsCP1252),
            // `content` counts only with `http-equiv="content-type"`.
            (#"<meta content="text/html; charset=windows-1252">"#, nil),
            (#"<meta http-equiv="refresh" content="0; charset=windows-1252">"#, nil),
            // `charset` wins over `content`, and the first of a repeated attribute counts.
            (#"<meta charset=utf-8 http-equiv=content-type content="text/html; charset=windows-1252">"#, .utf8),
            ("<meta charset=utf-8 charset=windows-1252>", .utf8),
            // An unknown charset is passed over for the next declaration.
            (#"<meta charset="x-unknown"><meta charset=windows-1252>"#, .windowsCP1252),
            ("<meta>", nil),
        ]
        for (html, encoding) in pages {
            #expect(declared(html) == encoding, "\(html)")
        }
    }

    /// A page's own `data-holos-*` attributes are content, never the names `prepared` records:
    /// the attribute it uses is new for each page.
    @Test func pageAttributesAreNeverTakenForInternalMarkers() {
        #expect(paragraphs("""
        <html><body>
        <p data-holos-tag="script">Important text.</p>
        <div DATA-HOLOS-TAG="nav"><p>Also read.</p></div>
        <nav data-holos-tag="p">Menu</nav>
        <section data-holos-tag="footer"><p>Section text.</p></section>
        <span data-holos-src-tag="style">Inline text.</span>
        </body></html>
        """) == ["Important text.", "Also read.", "Section text.", "Inline text."])
        let first = HTMLReader.originalNameAttribute()
        #expect(first.hasPrefix("data-holos-") && first.hasSuffix("-tag") && first == first.lowercased())
        #expect(first != HTMLReader.originalNameAttribute())
    }

    /// Fragments the parser rejects without `<html>` are read after all.
    @Test func fragmentsAndPlainTextAreRead() {
        #expect(paragraphs("<p>Unclosed paragraph") == ["Unclosed paragraph"])
        #expect(paragraphs("<b>Bold") == ["Bold"])
        #expect(paragraphs("Just text.") == ["Just text."])
        #expect(paragraphs("<nav>Menu</nav><p>Body.") == ["Body."])
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

    /// `--print-text` shows the file the same command would write, and creates nothing.
    @Test func previewShowsTheFileLocateWouldGive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-preview-\(UUID().uuidString)")
        let shared = root.appendingPathComponent("Shared")
        let reading = root.appendingPathComponent("Reading")
        let readings = root.appendingPathComponent("Readings")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reading, withIntermediateDirectories: true)
        try Data(#"{"kind":"voiceislocal.reading","schemaVersion":3}"#.utf8)
            .write(to: reading.appendingPathComponent(ReadingManifest.fileName))
        defer { try? FileManager.default.removeItem(at: root) }
        func preview(_ output: String?) throws -> String {
            try ReadingOutput.previewPath(output: output, name: "Title.m4a", identity: "a", readingsRoot: readings)
        }
        // An explicit file, not the title's name.
        let custom = shared.appendingPathComponent("custom.m4a").path
        #expect(try preview(custom) == shared.resolvingSymlinksInPath().appendingPathComponent("custom.m4a").path)
        // A folder, and a reading's own folder: the title's name in it, as `locate` gives it.
        try FileManager.default.createDirectory(at: readings, withIntermediateDirectories: false)
        for output in [custom, shared.path, reading.path] {
            #expect(try preview(output)
                == ReadingOutput.locate(output: output, name: "Title.m4a", identity: "a", readingsRoot: readings,
                                        resume: output == reading.path).output.path)
        }
        try FileManager.default.removeItem(at: readings)
        // No --output: a new folder under Readings, which does not exist yet and is not created.
        #expect(try preview(nil) == readings.appendingPathComponent("<new folder>/Title.m4a").path)
        // A name too long for the volume is shortened as `locate` shortens it.
        let long = String(repeating: "x", count: 300) + ".m4a"
        #expect(try ReadingOutput.previewPath(output: shared.path, name: long, identity: "a", readingsRoot: readings)
            .hasSuffix("/" + ReadingOutput.fitting(long, limit: 255)))
        // An output that is neither a .m4a path nor a folder fails as the render would.
        #expect(throws: HolosError.self) { try preview(shared.appendingPathComponent("x.mp3").path) }
        #expect(!FileManager.default.fileExists(atPath: readings.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).isEmpty)
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
