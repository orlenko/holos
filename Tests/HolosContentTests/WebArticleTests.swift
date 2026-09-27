import CryptoKit
import Foundation
import HolosCore
import HolosSynthesis
import Testing
import WebKit
@testable import HolosContent

/// Handcrafted pages; nothing here touches the network (pages load with `loadHTMLString` and a base URL).
private enum Fixture {
    static let base = URL(string: "https://news.example.test/2026/09/lighthouse")!

    static let paragraphs = [
        "The lighthouse on the northern cape has guided ships through the narrow channel for more than a century, "
            + "and its keepers have recorded every storm in a leather logbook that still sits on the desk upstairs.",
        "When the automated lamp was installed, the last keeper stayed on as a caretaker. She still climbs the "
            + "spiral stairs each morning to wipe the salt from the windows and check that the lens turns smoothly.",
        "Visitors often ask whether the building is haunted. The caretaker laughs and says the only ghosts are "
            + "the gulls that nest on the gallery rail and complain loudly whenever anyone opens the door.",
    ]

    static let log = "Harbour, A. Keeper's log, volume three. Private collection, 1998."

    /// Article text that back-matter fixtures place near, or around, a back-matter heading.
    static let closing = "The caretaker plans to write her own chapter in the logbook before the season ends, "
        + "describing the winter storms and the ships that sheltered in the bay below the cape."

    static let references = "<h2>References</h2>\n<ol><li>\(log)</li></ol>"

    static let article = article(backMatter: references)

    /// The article page with `backMatter` after the last paragraph, inside the article.
    static func article(backMatter: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <title>The Last Keeper of the Northern Cape | Coastal News</title>
        <meta property="og:site_name" content="Coastal News"></head>
        <body>
        <header><nav><a href="/">Home</a> <a href="/world">World</a> <a href="/sport">Sport</a>
        <a href="/subscribe">Subscribe now for unlimited access</a></nav></header>
        <aside class="sidebar"><h3>Most read</h3><ul><li><a href="/a">Ten gadgets you need</a></li>
        <li><a href="/b">Weather this weekend</a></li></ul></aside>
        <main><article>
        <h1>The Last Keeper of the Northern Cape</h1>
        <p class="byline">By Ada Harbour</p>
        <p>\(paragraphs[0])<sup class="reference"><a href="#r1">[1]</a></sup></p>
        <figure><img src="lamp.jpg" alt="The lamp"><figcaption>The lamp room at dusk.</figcaption></figure>
        <h2>A daily climb</h2>
        <p>\(paragraphs[1])<sup class="reference"><a href="#r2">[2]</a><a href="#r3">[3]</a></sup></p>
        <pre><code>let steps = 117 // counted by hand</code></pre>
        <ul><li>She checks the lens.</li><li>She wipes the windows with <code>fresh water</code>.</li></ul>
        <blockquote><p>\(paragraphs[2])<sup>[4], [5]</sup></p></blockquote>
        \(backMatter)
        </article></main>
        <footer><p>Copyright Coastal News. All rights reserved. Privacy policy. Cookie settings.</p></footer>
        </body></html>
        """
    }

    /// A page with no article whose script or meta refresh sends the main frame to `http`. The address is the
    /// loopback discard port, and the navigation is refused before any request.
    static func leavingHTTPS(_ head: String, _ body: String = "") -> String {
        """
        <!doctype html><html><head><title>Moving</title>\(head)</head><body><p>One moment.</p>\(body)</body></html>
        """
    }

    /// The same article, but the page builds it with a script a moment after loading.
    static var scripted: String {
        let body = paragraphs.map { "<p>\($0)</p>" }.joined()
        return """
            <!doctype html><html><head><title>Scripted Keeper</title></head><body><div id="app">Loading…</div>
            <script>
            setTimeout(function () {
              document.getElementById("app").innerHTML =
                '<article><h1>Scripted Keeper</h1>' + \(jsString(body)) + '</article>';
            }, 150);
            </script></body></html>
            """
    }

    static let notAnArticle = """
        <!doctype html><html><head><title>Sign in</title></head><body>
        <form><label>Email <input name="email"></label><button>Continue</button></form>
        <p>Subscribe to keep reading.</p></body></html>
        """

    /// An image from the `stall` scheme, which never answers: a page that shows it never finishes loading. (An
    /// https page may not run scripts from that scheme, but it may show its images.)
    static let stalledImage = #"<img src="stall://slow.png" alt="">"#

    static let neverFinishesLoading = """
        <!doctype html><html><head><title>Stalled</title></head><body><p>Short page.</p>\(stalledImage)</body></html>
        """

    /// A page without an article that finishes loading and then asks the `stall` scheme for an image, which says
    /// the extractor is past the load and into its pauses between reads.
    static let stallsAfterLoading = """
        <!doctype html><html><head><title>Loaded</title></head><body><p>Short page.</p>
        <script>window.addEventListener("load", function () {
          setTimeout(function () { new Image().src = "stall://after-load.png"; }, 0);
        });</script></body></html>
        """

    /// An article about something else, long enough to be accepted, that `redirect` sends away after loading.
    static func stale(_ redirect: String) -> String {
        let text = "The ferry timetable changes every spring, and the harbour office prints a new card for each "
            + "passenger who asks. This year the first sailing leaves at six, the last at nine, and the cafe on "
            + "the pier opens only when the weather allows the tables to stand outside without blowing away."
        return """
            <!doctype html><html><head><title>Ferry Timetable</title>\(redirect)</head><body><article>
            <h1>Ferry Timetable</h1><p>\(text)</p><p>\(text)</p></article></body></html>
            """
    }

    /// Ways a loaded page sends the main frame on to `site://news.test/<path>`. (A `Refresh` response header
    /// cannot be served here: WebKit hands custom-scheme responses to the navigation delegate without headers.)
    static func redirects(to path: String) -> [String] {
        let target = "site://news.test/\(path)"
        return [
            // Script redirects after the page has loaded.
            #"<script>addEventListener("load", () => setTimeout(() => { location.href = "\#(target)"; }, 0));</script>"#,
            #"<script>addEventListener("load", () => setTimeout(() => location.replace("\#(target)"), 0));</script>"#,
            // A meta refresh, due at once and after a second.
            #"<meta http-equiv="refresh" content="0; url=\#(target)">"#,
            #"<meta http-equiv="Refresh" content="1;URL='\#(target)'">"#,
        ]
    }

    /// A page with a hostile title, byline, and paragraph: escape sequences (C0 and C1), DEL, bidirectional
    /// overrides and isolates, NEL, a line separator, and a soft hyphen, all set by a script.
    static var hostile: String {
        article(backMatter: #"""
            <script>
            document.title = "\u001b]0;owned\u0007The Keeper ‮txt.exe‬\u009b2J\u007f";
            document.querySelector(".byline").textContent = "By ⁦Ada⁩ Harbour\u001b[0m‏";
            document.querySelectorAll("article > p")[2].append(" \u0085Ends here­\u{E0041}.");
            </script>
            """#)
    }

    private static func jsString(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

/// Serves the `stall` URL scheme by never answering, and reports each request it receives.
@MainActor private final class StallingSchemeHandler: NSObject, WKURLSchemeHandler {
    let requests: AsyncStream<URL>
    private let received: AsyncStream<URL>.Continuation
    private var held: [ObjectIdentifier: any WKURLSchemeTask] = [:]

    override init() {
        (requests, received) = AsyncStream.makeStream(of: URL.self)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        held[ObjectIdentifier(urlSchemeTask)] = urlSchemeTask
        received.yield(urlSchemeTask.request.url!)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        held[ObjectIdentifier(urlSchemeTask)] = nil
    }

    /// Waits for the first request.
    func firstRequest() async -> URL? {
        for await url in requests { return url }
        return nil
    }
}

/// Serves the `site` URL scheme from fixed answers by path: a page (after a pause), no answer ever, or a failure.
/// Stands in for https in navigation tests (WebKit keeps https for itself).
@MainActor private final class SiteSchemeHandler: NSObject, WKURLSchemeHandler {
    enum Answer {
        case page(String, after: Duration = .zero)
        case never
        case failure
    }

    private let answers: [String: Answer]
    private var held: [ObjectIdentifier: any WKURLSchemeTask] = [:]

    init(_ answers: [String: Answer]) {
        self.answers = answers
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!
        let id = ObjectIdentifier(urlSchemeTask)
        held[id] = urlSchemeTask
        switch answers[url.path] ?? .failure {
        case .never:
            return
        case .failure:
            held[id] = nil
            urlSchemeTask.didFailWithError(URLError(.cannotConnectToHost))
        case .page(let html, let pause):
            Task { @MainActor in
                if pause > .zero { try? await Task.sleep(for: pause) }
                // A task WebKit stopped meanwhile must not be answered.
                guard let task = self.held.removeValue(forKey: id) else { return }
                task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                headerFields: ["Content-Type": "text/html; charset=utf-8"])!)
                task.didReceive(Data(html.utf8))
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        held[ObjectIdentifier(urlSchemeTask)] = nil
    }
}

/// Stands in for WebKit's script evaluation, and records each script and the time limit it was given.
@MainActor private final class ScriptLog {
    var calls: [(script: String, timeout: Duration)] = []

    /// Records the script, then never answers: the wait ends only when its time limit does.
    func neverAnswering(_ body: String, _ webView: WKWebView, _ timeout: Duration) async throws -> String {
        calls.append((body, timeout))
        return try await OneShot<String>().wait(timeout: timeout, orElse: .failure(WebArticleExtractor.ScriptTimeout()))
    }

    /// Records the script and answers at once that the page shows no article.
    func noArticle(_ body: String, _ webView: WKWebView, _ timeout: Duration) async throws -> String {
        calls.append((body, timeout))
        return #"{"found":false}"#
    }
}

/// No control or format characters, other than the line feeds that separate paragraphs.
private func isPrintable(_ text: String) -> Bool {
    !text.unicodeScalars.contains {
        $0 != "\n" && ($0.properties.generalCategory == .control || $0.properties.generalCategory == .format)
    }
}

@MainActor @Suite(.serialized) struct WebArticleTests {
    private static let start = URL(string: "site://news.test/start")!

    /// Extracts the page the `site` handler serves at `/start`.
    private func extractSite(_ handler: SiteSchemeHandler, options: WebArticleExtractor.Options) async throws
        -> WebArticle {
        let extractor = WebArticleExtractor(options: options, documentSchemes: ["site"]) {
            $0.setURLSchemeHandler(handler, forURLScheme: "site")
        }
        return try await extractor.extract(requested: Self.start) { $0.load(URLRequest(url: Self.start)) }
    }

    private let fast = WebArticleExtractor.Options(
        loadTimeout: .seconds(20), settle: .milliseconds(100), retryWindow: .seconds(10), minimumWords: 50)

    @Test func assemblyNormalizesWhitespaceAndDropsNoise() {
        let url = URL(string: "https://blog.example.test/post")!
        let article = WebArticle.assemble(
            url: url, title: "  A  Title\n", byline: " Jane\u{00A0}Doe ", siteName: "", language: "en",
            raw: [(1, "a title"), (0, "  First\u{200B} \t\n paragraph. "), (0, "   "), (0, "[edit]"),
                  (2, "Section"), (0, "[1]"), (0, "[1][2]"), (0, " [1], [2]; [3]–[4] "), (0, "[edit] [a][note 3]"),
                  (0, "Second [note] paragraph."), (0, "[1] and [2]")])
        #expect(article.title == "A Title")
        #expect(article.byline == "Jane Doe")
        #expect(article.siteName == nil)
        #expect(article.blocks == [.paragraph("First paragraph."), .heading(level: 2, text: "Section"),
                                   .paragraph("Second [note] paragraph."), .paragraph("[1] and [2]")])
        #expect(article.wordCount == 9)
        #expect(article.spokenText
            == "A Title\n\nFirst paragraph.\n\nSection\n\nSecond [note] paragraph.\n\n[1] and [2]")
        #expect(article.document.author == "Jane Doe")
    }

    @Test func aBylineBecomesTheAuthorWithoutBy() {
        let url = URL(string: "https://blog.example.test/post")!
        let article = WebArticle.assemble(url: url, title: nil, byline: "by Jane Doe", siteName: nil,
                                          language: nil, raw: [(0, "Body.")])
        #expect(article.title == "blog.example.test")
        #expect(article.document.author == "Jane Doe")
        #expect(article.spokenText == "blog.example.test\n\nBody.")
        #expect(WebArticle.author(fromByline: "By Jane Doe") == "Jane Doe")
        #expect(WebArticle.author(fromByline: "Jane Doe, Science Editor") == "Jane Doe, Science Editor")
        #expect(WebArticle.author(fromByline: "Bybee Smith") == "Bybee Smith")
        #expect(WebArticle.author(fromByline: "By ") == nil)
    }

    @Test func sanitizingRemovesEveryControlAndFormatCharacter() {
        let hostile = "\u{1B}]0;owned\u{07}Title\u{9B}2J \u{202E}rev\u{202C} \u{2066}iso\u{2069}\u{7F}\u{200E}\n\u{85}"
            + "\u{2028}end\u{E0041}\u{00AD}\u{FEFF}\u{FFFF}\t\r\u{0}"
        #expect(WebArticle.sanitized(hostile) == "]0;ownedTitle2J rev iso end")
        #expect(WebArticle.sanitized("  Plain  text, café — 東京 👍  ") == "Plain text, café — 東京 👍")
    }

    @Test func anArticleIsSanitizedHoweverItIsMade() {
        let url = URL(string: "https://blog.example.test/post")!
        let made = WebArticle(url: url, title: "\u{1B}[31mRed\u{202E}", byline: "By\u{9B} Jane\u{2067}",
                              siteName: "Site\u{7}", language: "en\u{200F}",
                              blocks: [.heading(level: 2, text: "Part\u{1B}[2J"), .paragraph("Body\u{85}text\u{2069}")])
        #expect(made.title == "[31mRed")
        #expect(made.byline == "By Jane")
        #expect(made.siteName == "Site")
        #expect(made.language == "en")
        #expect(made.blocks == [.heading(level: 2, text: "Part[2J"), .paragraph("Body text")])
        #expect(isPrintable(made.spokenText))
        #expect(made.address == url.absoluteString)

        let assembled = WebArticle.assemble(url: url, title: "\u{9D}8;;https://evil.test\u{9C}Title",
                                            byline: nil, siteName: nil, language: nil,
                                            raw: [(0, "\u{1B}[1mBold\u{1B}[0m words")])
        #expect(assembled.title == "8;;https://evil.testTitle")
        #expect(assembled.blocks == [.paragraph("[1mBold[0m words")])
    }

    @Test func aHostilePageYieldsPrintableText() async throws {
        let article = try await WebArticleExtractor(options: fast).extract(html: Fixture.hostile, baseURL: Fixture.base)
        #expect(article.title.contains("The Keeper"), "\(article.title)")
        for text in [article.title, article.byline ?? "", article.siteName ?? "", article.address,
                     article.spokenText] + article.blocks.map(\.text) {
            #expect(isPrintable(text), "\(text.unicodeScalars.map { String($0.value, radix: 16) })")
        }
        #expect(article.blocks.map(\.text).contains(Fixture.paragraphs[1] + " Ends here."))
    }

    @Test func anArticleBecomesADocumentWithAChapterAtEachHeading() {
        let url = URL(string: "https://news.example.test/keeper")!
        let article = WebArticle(
            url: url, title: "The Keeper", byline: "By Ada Harbour", siteName: "Coastal News", language: "en-GB",
            blocks: [.paragraph("Intro one."), .paragraph("Intro two."), .heading(level: 2, text: "A daily climb"),
                     .paragraph("Stairs."), .heading(level: 3, text: "The lens"), .heading(level: 2, text: "Ghosts"),
                     .paragraph("Gulls."), .paragraph("More gulls.")])
        let document = article.document
        #expect(document.title == "The Keeper")
        #expect(document.author == "Ada Harbour")
        #expect(document.language == "en-GB")
        #expect(document.sections == [
            .init(paragraphs: ["Intro one.", "Intro two."]),
            .init(heading: "A daily climb", level: 2, paragraphs: ["Stairs."]),
            .init(heading: "The lens", level: 3),
            .init(heading: "Ghosts", level: 2, paragraphs: ["Gulls.", "More gulls."]),
        ])
        let script = ReadingScript(document: document)
        #expect(script.segments.compactMap(\.chapter) == ["A daily climb", "The lens", "Ghosts"])
        // The site name and the byline are not spoken; the title is, once, first.
        #expect(script.text == "The Keeper\n\nIntro one.\n\nIntro two.\n\nA daily climb\n\nStairs.\n\nThe lens"
            + "\n\nGhosts\n\nGulls.\n\nMore gulls.")
        #expect(article.spokenText == script.text)
        #expect(WebArticle(url: url, title: "Empty", byline: nil, siteName: nil, language: nil, blocks: []).document
            == ReadableDocument(title: "Empty", sections: []))
    }

    @Test func theTitleIsNotSpokenTwice() {
        let url = URL(string: "https://news.example.test/keeper")!
        // The extractor drops a leading heading that repeats the title.
        let assembled = WebArticle.assemble(url: url, title: "The Keeper", byline: nil, siteName: nil, language: nil,
                                            raw: [(1, "The Keeper"), (0, "Body."), (2, "Part"), (0, "More.")])
        #expect(assembled.spokenText == "The Keeper\n\nBody.\n\nPart\n\nMore.")
        // A first heading that says the title with the site name around it, or the other way round, is the title.
        for (title, heading) in [("The Keeper", "The Keeper"), ("The Keeper | Coastal News", "The Keeper"),
                                 ("The Keeper", "The Keeper – Coastal News")] {
            let article = WebArticle(url: url, title: title, byline: "By Ada", siteName: nil, language: nil,
                                     blocks: [.heading(level: 1, text: heading), .paragraph("Body.")])
            #expect(article.spokenText == "\(heading)\n\nBody.", "\(title) / \(heading)")
            #expect(ReadingScript(document: article.document).segments.first?.chapter == heading)
        }
    }

    @Test func aHostileArticleMakesASanitizedDocumentAndPreview() {
        let url = URL(string: "https://news.example.test/keeper")!
        let article = WebArticle(url: url, title: "\u{1B}]0;owned\u{07}Title\u{202E}", byline: "By \u{9B}2JJane",
                                 siteName: "Site\u{7}", language: "en\u{200F}",
                                 blocks: [.heading(level: 2, text: "Part\u{1B}[2J"),
                                          .paragraph("Body\u{85}text\u{2069} \u{2066}here")])
        let document = article.document
        #expect(document.title == "]0;ownedTitle")
        #expect(document.author == "2JJane")
        #expect(document.language == "en")
        #expect(document.sections == [.init(heading: "Part[2J", level: 2, paragraphs: ["Body text here"])])
        let script = ReadingScript(document: document)
        let preview = ReadingPreview.text(script: script,
                                          metadata: AudioBookMetadata(title: document.title, author: document.author,
                                                                      language: document.language),
                                          voice: "Ava\u{1B}[0m (Premium)", fileName: "Name\u{202E}.m4a")
        #expect(isPrintable(preview), "\(preview.unicodeScalars.map { String($0.value, radix: 16) })")
        #expect(preview.contains("Voice: Ava[0m (Premium)\nFile: Name.m4a\n"))
    }

    @Test func aLocalFilesPreviewHasItsControlCharactersRemovedButKeepsItsLines() {
        let document = ReadableDocument(title: "Notes\u{1B}[2J", author: "Me\u{202E}", sections: [
            .init(heading: "One\u{7}", level: 1, paragraphs: ["First line\nsecond\u{1B}]8;; line"]),
        ])
        let preview = ReadingPreview.text(script: ReadingScript(document: document),
                                          metadata: AudioBookMetadata(title: document.title, author: document.author),
                                          voice: "Ava", fileName: "Notes.m4a")
        #expect(preview == """
            Title: Notes[2J
            Author: Me
            Language: unknown
            Voice: Ava
            File: Notes.m4a
            Chapters: Notes[2J | One

            Notes[2J

            One

            First line
            second]8;; line
            """)
    }

    /// `voiceislocal read <https address> --print-text` without the network: a fixture page goes through the extractor,
    /// the document mapping, and the preview the command prints.
    @Test func printTextForAWebPageShowsTheDocumentAsItIsRead() async throws {
        let article = try await WebArticleExtractor(options: fast).extract(html: Fixture.article, baseURL: Fixture.base)
        let document = article.document
        let script = ReadingScript(document: document)
        let metadata = AudioBookMetadata(title: document.title, author: document.author,
                                         language: AudioBookMetadata.languageTag(document.language))
        let preview = ReadingPreview.text(
            script: script, metadata: metadata, voice: "Ava (Premium) (com.apple.voice.premium.en-US.Ava)",
            fileName: ReadingOutput.fileName(title: metadata.title, fallback: article.url.host()))
        let lines = preview.components(separatedBy: "\n")
        #expect(Array(lines.prefix(7)) == [
            "Title: The Last Keeper of the Northern Cape",
            "Author: Ada Harbour",
            "Language: en",
            "Voice: Ava (Premium) (com.apple.voice.premium.en-US.Ava)",
            "File: The Last Keeper of the Northern Cape.m4a",
            "Chapters: The Last Keeper of the Northern Cape | A daily climb",
            "",
        ])
        let text = lines.dropFirst(7).joined(separator: "\n")
        #expect(text == script.text)
        #expect(text.hasPrefix("The Last Keeper of the Northern Cape\n\n\(Fixture.paragraphs[0])\n\nA daily climb\n\n"))
        #expect(text.components(separatedBy: "The Last Keeper of the Northern Cape").count == 2)
        for noise in ["Ada Harbour", "Coastal News", "Subscribe now", "References", "[1]"] {
            #expect(!text.contains(noise), "Leaked: \(noise)")
        }
        #expect(isPrintable(preview))
    }

    @Test func contentHTMLBecomesOrderedHeadingsAndParagraphs() async throws {
        let html = """
            <div><h2>Intro</h2><p>One <em>two</em>&nbsp;three<sup>[4]</sup>.</p>
            Loose text in a div.<br>After a break.
            <ul><li>Item one<ul><li>Nested item</li></ul></li><li>Item <code>two</code></li></ul>
            <pre><code>print("skipped")</code></pre>
            <table><tr><td>skipped cell</td></tr></table>
            <figure><img src="x.png"><figcaption>Skipped caption</figcaption></figure>
            <blockquote>Quoted words.</blockquote><h3>Deeper</h3><p>x<sup>2</sup> grows.</p></div>
            """
        let blocks = try await WebArticleExtractor(options: fast).blocks(fromContentHTML: html)
        #expect(blocks == [
            .heading(level: 2, text: "Intro"), .paragraph("One two three."), .paragraph("Loose text in a div."),
            .paragraph("After a break."), .paragraph("Item one"), .paragraph("Nested item"),
            .paragraph("Item two"), .paragraph("Quoted words."), .heading(level: 3, text: "Deeper"),
            .paragraph("x2 grows."),
        ])
    }

    @Test func superscriptsOfCitationMarksAreDroppedWhateverTheirGrouping() async throws {
        let html = """
            <p>Grouped<sup class="reference"><a href="#1">[1]</a><a href="#2">[2]</a></sup> marks<sup>[1], [2]</sup>,
            lettered<sup><a>[a]</a><a>[note 3]</a></sup> notes<sup>[1]–[3]; [7]</sup>,
            tagged<sup class="noprint"><span>[</span><i><a>citation needed</a></i><span>]</span></sup> claims<sup><sup>[9]</sup></sup>,
            and x<sup>2<sup>[4]</sup></sup> stays<sup>[1] see below</sup>.</p>
            """
        let blocks = try await WebArticleExtractor(options: fast).blocks(fromContentHTML: html)
        #expect(blocks == [.paragraph("Grouped marks, lettered notes, tagged claims, and x2 stays[1] see below.")])
    }

    @Test func extractsTheArticleAndLeavesBoilerplateOut() async throws {
        let article = try await WebArticleExtractor(options: fast).extract(html: Fixture.article, baseURL: Fixture.base)
        #expect(article.title == "The Last Keeper of the Northern Cape")
        #expect(article.byline == "By Ada Harbour")
        #expect(article.siteName == "Coastal News")
        #expect(article.language == "en")
        #expect(article.url == Fixture.base)
        let texts = article.blocks.map(\.text)
        #expect(texts.first == Fixture.paragraphs[0])
        #expect(article.blocks.contains(.heading(level: 2, text: "A daily climb")))
        #expect(texts.contains(Fixture.paragraphs[1]))
        #expect(texts.contains(Fixture.paragraphs[2]))
        #expect(texts.contains("She checks the lens."))
        #expect(texts.contains("She wipes the windows with fresh water."))
        let spoken = article.spokenText
        for noise in ["Subscribe now", "Most read", "Copyright", "lamp room", "let steps", "Keeper's log",
                      "References", "[1]", "[2]", "[3]", "[4]", "[5]"] {
            #expect(!spoken.contains(noise), "Leaked: \(noise)")
        }
    }

    @Test func readsAnArticleThatAScriptBuildsAfterLoading() async throws {
        let article = try await WebArticleExtractor(options: fast).extract(html: Fixture.scripted,
                                                                           baseURL: Fixture.base)
        #expect(article.title == "Scripted Keeper")
        #expect(article.blocks.map(\.text) == Fixture.paragraphs)
    }

    @Test func aPageWithoutAnArticleFailsWithAHint() async throws {
        let options = WebArticleExtractor.Options(loadTimeout: .seconds(20), settle: .milliseconds(50),
                                                  retryWindow: .milliseconds(200), minimumWords: 50)
        do {
            _ = try await WebArticleExtractor(options: options).extract(html: Fixture.notAnArticle,
                                                                        baseURL: Fixture.base)
            Issue.record("Expected no article to be found.")
        } catch let HolosError.unavailable(message) {
            #expect(message.contains("Could not find article text"))
            #expect(message.contains(".txt file"))
        }
    }

    @Test func tooFewWordsIsNoArticle() async throws {
        let options = WebArticleExtractor.Options(loadTimeout: .seconds(20), settle: .milliseconds(50),
                                                  retryWindow: .milliseconds(200), minimumWords: 5_000)
        await #expect(throws: HolosError.self) {
            _ = try await WebArticleExtractor(options: options).extract(html: Fixture.article, baseURL: Fixture.base)
        }
    }

    @Test func onlyHTTPSAddressesAreLoaded() async {
        for address in ["http://example.test/a", "file:///etc/hosts", "ftp://example.test/a"] {
            await #expect(throws: HolosError.self) {
                _ = try await WebArticleExtractor(options: fast).extract(from: URL(string: address)!)
            }
        }
    }

    @Test(arguments: [
        // Script redirect while the page parses.
        Fixture.leavingHTTPS("", #"<script>location.replace("http://127.0.0.1:9/next");</script>"#),
        // Meta refresh.
        Fixture.leavingHTTPS(#"<meta http-equiv="refresh" content="0; url=http://127.0.0.1:9/next">"#),
        // Script redirect after the page has loaded and been read once.
        Fixture.leavingHTTPS("", #"<script>setTimeout(function () { location.href = "http://127.0.0.1:9/next"; }, 250);</script>"#),
    ])
    func aMainFrameNavigationOffHTTPSIsRefused(page: String) async throws {
        let options = WebArticleExtractor.Options(loadTimeout: .seconds(20), settle: .milliseconds(100),
                                                  retryWindow: .seconds(5), minimumWords: 50)
        do {
            _ = try await WebArticleExtractor(options: options).extract(html: page, baseURL: Fixture.base)
            Issue.record("Expected the http navigation to be refused.")
        } catch let HolosError.unavailable(message) {
            #expect(message.contains("http://127.0.0.1:9/next"), "\(message)")
            #expect(message.contains("not https://"), "\(message)")
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: Fixture.redirects(to: "slow").indices)
    func aPageThatMovesOnAfterLoadingIsReadWhereItLands(variant: Int) async throws {
        // The first page is a whole article of its own, and the destination answers only after a pause: a
        // read while the destination is on its way must not return the first page.
        let redirect = Fixture.redirects(to: "slow")[variant]
        let handler = SiteSchemeHandler([
            "/start": .page(Fixture.stale(redirect)),
            "/slow": .page(Fixture.article, after: .milliseconds(400)),
        ])
        let options = WebArticleExtractor.Options(loadTimeout: .seconds(20), settle: .milliseconds(50),
                                                  retryWindow: .seconds(3), minimumWords: 50)
        let article = try await extractSite(handler, options: options)
        #expect(article.title == "The Last Keeper of the Northern Cape")
        #expect(article.url == URL(string: "site://news.test/slow"))
        #expect(!article.spokenText.contains("ferry"))
    }

    @Test(.timeLimit(.minutes(1)), arguments: Fixture.redirects(to: "never").indices)
    func aPageThatMovesOnToADestinationThatNeverAnswersTimesOut(variant: Int) async throws {
        let redirect = Fixture.redirects(to: "never")[variant]
        let handler = SiteSchemeHandler([
            "/start": .page(Fixture.stale(redirect)),
            "/never": .never,
        ])
        let options = WebArticleExtractor.Options(loadTimeout: .seconds(2), settle: .milliseconds(50),
                                                  retryWindow: .seconds(3), minimumWords: 50)
        do {
            let article = try await extractSite(handler, options: options)
            Issue.record("Expected a timeout, read \(article.title) at \(article.address).")
        } catch let HolosError.unavailable(message) {
            #expect(message.contains("Timed out loading site://news.test/never"), "\(message)")
        }
    }

    @Test(.timeLimit(.minutes(1))) func aPageThatMovesOnToADestinationThatFailsIsAnError() async throws {
        let handler = SiteSchemeHandler([
            "/start": .page(Fixture.stale(Fixture.redirects(to: "gone")[0])),
            "/gone": .failure,
        ])
        let options = WebArticleExtractor.Options(loadTimeout: .seconds(20), settle: .milliseconds(50),
                                                  retryWindow: .seconds(3), minimumWords: 50)
        do {
            let article = try await extractSite(handler, options: options)
            Issue.record("Expected the failed navigation to be reported, read \(article.title).")
        } catch let HolosError.unavailable(message) {
            #expect(message.contains("Could not load the page"), "\(message)")
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        // A slow self-refresh (a live page) is not a redirect.
        #"<meta http-equiv="refresh" content="300">"#,
        // Moving within the document loads nothing new.
        ##"<script>addEventListener("load", () => { location.hash = "timetable"; history.pushState({}, "", "#later"); });</script>"##,
    ])
    func aPageThatStaysIsRead(head: String) async throws {
        // A long load timeout: waiting for a navigation that never comes would outlast the time limit.
        let handler = SiteSchemeHandler(["/start": .page(Fixture.stale(head))])
        let options = WebArticleExtractor.Options(loadTimeout: .seconds(600), settle: .milliseconds(50),
                                                  retryWindow: .seconds(3), minimumWords: 50)
        let article = try await extractSite(handler, options: options)
        #expect(article.title == "Ferry Timetable")
        #expect(article.address.hasPrefix("site://news.test/start"))
    }

    @Test(.timeLimit(.minutes(1))) func aPageThatKeepsReloadingIsAnError() async throws {
        let reload = #"<script>addEventListener("load", () => setTimeout(() => location.reload(), 0));</script>"#
        let handler = SiteSchemeHandler(["/start": .page(Fixture.stale(reload))])
        let options = WebArticleExtractor.Options(loadTimeout: .seconds(20), settle: .milliseconds(50),
                                                  retryWindow: .seconds(3), minimumWords: 50)
        do {
            let article = try await extractSite(handler, options: options)
            Issue.record("Expected an error, read \(article.title).")
        } catch let HolosError.unavailable(message) {
            #expect(message.contains("kept moving"), "\(message)")
        }
    }

    @Test func aLoadThatNeverCommitsReportsTheTimeout() async throws {
        // No navigation ever commits (as when DNS, TLS, or the server stalls): the web view still shows its empty
        // initial document, which must not be read as a page without an article.
        let options = WebArticleExtractor.Options(loadTimeout: .milliseconds(200), settle: .milliseconds(50),
                                                  retryWindow: .milliseconds(200), minimumWords: 50)
        do {
            _ = try await WebArticleExtractor(options: options).extract(requested: Fixture.base) { _ in nil }
            Issue.record("Expected the load to time out.")
        } catch let HolosError.unavailable(message) {
            #expect(message.contains("Timed out loading \(Fixture.base.absoluteString)"), "\(message)")
        }
    }

    @Test func aCommittedParsedPageIsReadWhenItsLoadTimesOut() async throws {
        // The page commits and parses, but an image never arrives, so loading never finishes.
        let handler = StallingSchemeHandler()
        // The load wait gets 1 s of the 2 s deadline; the ready-state probe gets what is left.
        let options = WebArticleExtractor.Options(loadTimeout: .seconds(2), settle: .milliseconds(50),
                                                  retryWindow: .seconds(10), minimumWords: 50)
        let extractor = WebArticleExtractor(options: options) { $0.setURLSchemeHandler(handler, forURLScheme: "stall") }
        let article = try await extractor.extract(
            html: Fixture.article(backMatter: Fixture.stalledImage), baseURL: Fixture.base)
        #expect(article.blocks.map(\.text).contains(Fixture.paragraphs[1]))
        #expect(await handler.firstRequest() == URL(string: "stall://slow.png"))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [Fixture.neverFinishesLoading, Fixture.stallsAfterLoading])
    func cancellingTheCallerEndsTheExtraction(page: String) async throws {
        // Every wait is far longer than the time limit, so only cancellation can end the extraction in time.
        let handler = StallingSchemeHandler()
        let options = WebArticleExtractor.Options(loadTimeout: .seconds(600), settle: .seconds(600),
                                                  retryWindow: .seconds(600), minimumWords: 50)
        let extractor = WebArticleExtractor(options: options) { $0.setURLSchemeHandler(handler, forURLScheme: "stall") }
        let extraction = Task { try await extractor.extract(html: page, baseURL: Fixture.base) }
        _ = await handler.firstRequest()
        extraction.cancel()
        await #expect(throws: CancellationError.self) { _ = try await extraction.value }
    }

    @Test(.timeLimit(.minutes(1))) func cancellingTheCallerEndsAScriptThatNeverReturns() async throws {
        let handler = StallingSchemeHandler()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: "stall")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let script = #"new Image().src = "stall://in-script.png"; await new Promise(() => {}); return "never";"#
        let evaluation = Task { try await WebArticleExtractor.run(script, in: webView, timeout: .seconds(600)) }
        _ = await handler.firstRequest()
        evaluation.cancel()
        await #expect(throws: CancellationError.self) { _ = try await evaluation.value }
    }

    @Test func aScriptThatNeverReturnsTimesOut() async throws {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        await #expect(throws: WebArticleExtractor.ScriptTimeout.self) {
            _ = try await WebArticleExtractor.run("await new Promise(() => {}); return 'never';", in: webView,
                                                  timeout: .milliseconds(100))
        }
        // No time left: the script is not even started.
        await #expect(throws: WebArticleExtractor.ScriptTimeout.self) {
            _ = try await WebArticleExtractor.run("return 'late';", in: webView, timeout: .zero)
        }
    }

    @Test func aDeadlineGivesEachWaitOnlyTheTimeLeft() {
        let start = ContinuousClock.now
        let deadline = WebArticleExtractor.Deadline(.seconds(10), from: start)
        #expect(deadline.remaining(at: start) == .seconds(10))
        #expect(deadline.remaining(at: start + .seconds(4)) == .seconds(6))
        #expect(deadline.remaining(at: start + .seconds(4), reserving: .seconds(2)) == .seconds(4))
        #expect(deadline.remaining(at: start + .seconds(9), reserving: .seconds(2)) == .zero)
        #expect(deadline.remaining(at: start + .seconds(11)) == .zero)
        #expect(WebArticleExtractor.Deadline(.seconds(-1), from: start).remaining(at: start) == .zero)
        #expect(WebArticleExtractor.scriptReserve(for: .seconds(30)) == .seconds(2))
        #expect(WebArticleExtractor.scriptReserve(for: .seconds(1)) == .milliseconds(500))
        #expect(WebArticleExtractor.scriptReserve(for: .zero) == .zero)
    }

    @Test func theLoadWaitAndTheReadyStateProbeShareOneDeadline() async throws {
        let start = ContinuousClock.now
        let timeout = Duration.seconds(30)
        // A load that never finishes and a probe that never answers: each uses all it is given, and the clock
        // moves on by that much. Together they get the one timeout, no more.
        var clock = start
        var waits: [Duration] = []
        var outcome = try await WebArticleExtractor.waitForLoad(
            timeout: timeout, start: start, now: { clock },
            settle: { waits.append($0); clock = clock + $0; return .timedOut },
            probe: { waits.append($0); clock = clock + $0 })
        #expect(outcome == .timedOut)
        #expect(waits == [.seconds(28), .seconds(2)])
        #expect(waits.reduce(.zero, +) == timeout)

        // A load wait that overran its share (a late timer) leaves the probe only what is left, down to nothing.
        for (overrun, left) in [(Duration.seconds(1), Duration.seconds(1)), (.seconds(5), .zero)] {
            clock = start
            waits = []
            _ = try await WebArticleExtractor.waitForLoad(
                timeout: timeout, start: start, now: { clock },
                settle: { clock = clock + $0 + overrun; return .timedOut },
                probe: { waits.append($0) })
            #expect(waits == [left])
        }

        // Time spent in the phase before the load wait (the phase started earlier) counts too.
        clock = start + .seconds(10)
        waits = []
        _ = try await WebArticleExtractor.waitForLoad(
            timeout: timeout, start: start, now: { clock },
            settle: { waits.append($0); clock = clock + $0; return .timedOut },
            probe: { waits.append($0) })
        #expect(waits == [.seconds(18), .seconds(2)])

        // A load that finished needs no probe.
        waits = []
        outcome = try await WebArticleExtractor.waitForLoad(
            timeout: timeout, start: start, now: { start },
            settle: { _ in .finished }, probe: { waits.append($0) })
        #expect(outcome == .finished)
        #expect(waits.isEmpty)
    }

    @Test func aProbeThatNeverAnswersGetsOnlyWhatIsLeftOfTheLoadDeadline() async throws {
        // The page commits but never finishes loading, and never answers a script: the ready-state probe must
        // not start a fresh `loadTimeout` after the load wait used its share.
        let handler = StallingSchemeHandler()
        let log = ScriptLog()
        let loadTimeout = Duration.seconds(4)
        let options = WebArticleExtractor.Options(loadTimeout: loadTimeout, settle: .milliseconds(50),
                                                  retryWindow: .milliseconds(100), minimumWords: 50)
        let extractor = WebArticleExtractor(
            options: options, configure: { $0.setURLSchemeHandler(handler, forURLScheme: "stall") },
            evaluate: log.neverAnswering)
        do {
            _ = try await extractor.extract(html: Fixture.article(backMatter: Fixture.stalledImage),
                                            baseURL: Fixture.base)
            Issue.record("Expected the load to time out.")
        } catch let HolosError.unavailable(message) {
            #expect(message.contains("Timed out loading"), "\(message)")
        }
        #expect(log.calls.map(\.script) == [WebArticleExtractor.readyStateScript])
        let reserve = WebArticleExtractor.scriptReserve(for: loadTimeout)
        #expect(log.calls.allSatisfy { $0.timeout <= reserve }, "\(log.calls.map(\.timeout))")
    }

    @Test func everyReadGetsOnlyWhatIsLeftOfTheReadingDeadline() async throws {
        let log = ScriptLog()
        let options = WebArticleExtractor.Options(loadTimeout: .seconds(5), settle: .milliseconds(50),
                                                  retryWindow: .milliseconds(200), minimumWords: 50)
        let extractor = WebArticleExtractor(options: options, configure: { _ in }, evaluate: log.noArticle)
        await #expect(throws: HolosError.self) {
            _ = try await extractor.extract(html: Fixture.article, baseURL: Fixture.base)
        }
        let schedule = WebArticleExtractor.attemptSchedule(settle: options.settle, retryWindow: options.retryWindow)
        let timeouts = log.calls.map(\.timeout)
        #expect(timeouts.count == schedule.count)
        // One deadline, `loadTimeout` after the last scheduled read: each read gets less than the one before, the
        // first at most the rest of the window plus `loadTimeout`, the last at most `loadTimeout`.
        #expect(zip(timeouts, timeouts.dropFirst()).allSatisfy { $0 > $1 }, "\(timeouts)")
        if let first = timeouts.first, let last = timeouts.last, let window = schedule.last {
            #expect(first <= window - schedule[0] + options.loadTimeout)
            #expect(last <= options.loadTimeout)
        }
    }

    @Test func aOneShotResultIsDeliveredOnceWhenEverItArrives() async throws {
        let early = OneShot<Int>()
        early.resume(with: .success(1))
        early.resume(with: .success(2))
        #expect(try await early.wait() == 1)

        let late = OneShot<Int>()
        async let value = late.wait()
        await Task.yield()
        late.resume(with: .success(3))
        late.resume(with: .failure(CancellationError()))
        #expect(try await value == 3)

        let cancelledFirst = OneShot<Int>()
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cancelledFirst.wait()
        }
        await #expect(throws: CancellationError.self) { _ = try await waiter.value }
    }

    @Test func onlyHTTPSMainFrameAddressesPass() {
        #expect(PageLoader.refusal(of: URL(string: "https://example.test/a")!) == nil)
        #expect(PageLoader.refusal(of: URL(string: "HTTPS://example.test/a")!) == nil)
        for address in ["http://example.test/a", "about:blank", "file:///etc/hosts", "data:text/html,x",
                        "blob:https://example.test/1"] {
            #expect(PageLoader.refusal(of: URL(string: address)!) != nil, "\(address)")
        }
        #expect(PageLoader.refusal(of: nil) != nil)
    }

    @Test func onlyFragmentMovesStayInTheDocument() {
        let shown = URL(string: "https://example.test/a?x=1#top")!
        let same = PageLoader.isSameDocument
        #expect(same(URLRequest(url: URL(string: "https://example.test/a?x=1#part")!), .other, shown))
        #expect(same(URLRequest(url: URL(string: "https://example.test/a?x=1#")!), .linkActivated, shown))
        #expect(!same(URLRequest(url: URL(string: "https://example.test/a?x=1")!), .other, shown))
        #expect(!same(URLRequest(url: URL(string: "https://example.test/b#part")!), .other, shown))
        #expect(!same(URLRequest(url: URL(string: "https://example.test/a?x=1#part")!), .reload, shown))
        var post = URLRequest(url: URL(string: "https://example.test/a?x=1#part")!)
        post.httpMethod = "POST"
        #expect(!same(post, .formSubmitted, shown))
        #expect(!same(URLRequest(url: URL(string: "https://example.test/a#part")!), .other, nil))
    }

    @Test func refreshHeadersGiveTheirDelay() {
        #expect(PageLoader.refreshDelay("5") == 5)
        #expect(PageLoader.refreshDelay(" 0; url=https://example.test/") == 0)
        #expect(PageLoader.refreshDelay("1.5;URL=x") == 1.5)
        #expect(PageLoader.refreshDelay(".5") == 0.5)
        #expect(PageLoader.refreshDelay("url=x") == nil)
        #expect(PageLoader.refreshDelay(nil) == nil)
    }

    @Test func readsAreScheduledThroughTheEndOfTheRetryWindow() {
        let schedule = WebArticleExtractor.attemptSchedule
        // Defaults: first read 1 s after loading, then every second until 6 s after the first read.
        #expect(schedule(.seconds(1), .seconds(6)) == (1...7).map { Duration.seconds($0) })
        // A window that is not a whole number of intervals still ends with a read at its deadline.
        #expect(schedule(.seconds(1), .milliseconds(2_500))
            == [.seconds(1), .seconds(2), .seconds(3), .milliseconds(3_500)])
        #expect(schedule(.milliseconds(400), .seconds(1))
            == [.milliseconds(400), .milliseconds(800), .milliseconds(1_200), .milliseconds(1_400)])
        #expect(schedule(.seconds(1), .zero) == [.seconds(1)])
        #expect(schedule(.zero, .seconds(2)) == [.zero, .seconds(2)])
        #expect(schedule(.zero, .zero) == [.zero])
        #expect(schedule(.seconds(-1), .seconds(-1)) == [.zero])
    }

    @Test(arguments: [
        #"<div class="section-heading"><h2>References</h2></div><ol><li>\#(Fixture.log)</li></ol>"#,
        ##"<div class="mw-heading mw-heading2"><h2 id="References">References</h2><span class="mw-editsection"><span>[</span><a href="#e">edit</a><span>]</span></span></div><div class="reflist"><ol><li>\##(Fixture.log)</li></ol></div>"##,
        ##"<div class="hd"><span class="title"><h2>Further reading</h2></span><a class="anchor" href="#f">#</a></div><ul><li>\##(Fixture.log)</li></ul>"##,
        #"<h2>References:</h2><ol><li>\#(Fixture.log)</li></ol>"#,
        #"<h2>Notes.</h2><ol><li>\#(Fixture.log)</li></ol>"#,
        #"<h2>See also —</h2><ul><li>\#(Fixture.log)</li></ul>"#,
        #"<h2>7. External Links</h2><ul><li>\#(Fixture.log)</li></ul>"#,
        #"<h2>Notes &amp; References ¶</h2><ol><li>\#(Fixture.log)</li></ol>"#,
        #"<section><header><h3>SOURCES</h3></header></section><p>\#(Fixture.log)</p>"#,
        // Loose text right after the heading, not wrapped in any element, with comments between.
        #"<h2>References</h2>\#(Fixture.log) Loose second reference, 2001.<br>Third loose line."#,
        #"<h2>References</h2><!-- list -->\#(Fixture.log)<!-- end --><div><h3>Primary</h3>Loose second reference, 2001.</div>Third loose line."#,
        #"<div class="section-heading"><h2>Notes</h2></div>\#(Fixture.log)<p>Loose second reference, 2001.</p>Third loose line."#,
    ])
    func backMatterIsDroppedWhateverItsHeadingLooksLike(backMatter: String) async throws {
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        let spoken = article.spokenText
        #expect(spoken.contains(Fixture.paragraphs[2]))
        for noise in ["Keeper's log", "References", "Notes", "Further reading", "See also", "External",
                      "SOURCES", "Loose second", "Third loose", "Primary"] {
            #expect(!spoken.contains(noise), "Leaked: \(noise)")
        }
    }

    @Test(arguments: [
        // The next heading of the section's level, later in a wrapper that follows the heading.
        #"""
        <h2>References</h2>\#(Fixture.log)<!-- more --><div class="more"><p>Loose second reference, 2001.</p>
        <h3>Archives</h3>Third loose line.<h2>Afterword</h2><p>\#(Fixture.closing)</p></div>
        """#,
        // The next heading of the section's level sits in a different ancestor: the heading's wrappers end, the
        // section crosses into the next ones, and stops at that heading. A lower-level heading on the way does not
        // stop it.
        #"""
        <div class="refs"><h2>References</h2><ol><li>\#(Fixture.log)</li></ol></div>
        <section><div><h3>Archives</h3><p>Loose second reference, 2001.</p></div>Third loose line.</section>
        <section><div class="part"><h2>Afterword</h2><p>\#(Fixture.closing)</p></div></section>
        """#,
        // A higher-level heading, deeper than the back-matter heading, stops it too.
        #"""
        <section><header><h3>Sources</h3></header><p>\#(Fixture.log)</p></section>
        <div><div><p>Loose second reference, 2001.</p><h2>Afterword</h2></div><p>\#(Fixture.closing)</p></div>
        """#,
    ])
    func backMatterEndsAtTheNextHeadingOfItsLevelWhereverItSits(backMatter: String) async throws {
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        let texts = article.blocks.map(\.text)
        #expect(texts.contains(Fixture.paragraphs[2]))
        #expect(texts.contains(Fixture.closing))
        #expect(texts.contains("Afterword"))
        for noise in ["Keeper's log", "References", "Sources", "Loose second", "Archives", "Third loose"] {
            #expect(!article.spokenText.contains(noise), "Leaked: \(noise)")
        }
    }

    @Test(arguments: [
        // The heading ends an inner division that holds article text; the list follows in the article.
        #"""
        <div class="closing"><p>\#(Fixture.closing)</p><h2>References</h2></div><ol><li>\#(Fixture.log)</li></ol>
        """#,
        // Deep in section > div > header, after article text in the section; the section goes on after the
        // header's division, and loose text follows the section.
        #"""
        <section><p>\#(Fixture.closing)</p><div><header><h2>References</h2><a href="#r">¶</a></header>
        <ol><li>\#(Fixture.log)</li></ol></div>
        <ul><li>Loose second reference, 2001.</li></ul></section>Third loose line.
        """#,
        // Every wrapper of the heading ends right after it; the list is outside all of them.
        #"""
        <section><div class="closing"><p>\#(Fixture.closing)</p><div><header><h2>Notes</h2></header></div></div>
        </section><div><ol><li>\#(Fixture.log)</li></ol></div><p>Loose second reference, 2001.</p>Third loose line.
        """#,
    ])
    func backMatterGoesOnPastTheEndOfTheHeadingsWrappers(backMatter: String) async throws {
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        let texts = article.blocks.map(\.text)
        // The article text before the heading stays, in the elements that also held the heading.
        #expect(texts.contains(Fixture.paragraphs[2]))
        #expect(texts.contains(Fixture.closing))
        for noise in ["Keeper's log", "References", "Notes", "¶", "Loose second", "Third loose"] {
            #expect(!article.spokenText.contains(noise), "Leaked: \(noise)")
        }
    }

    @Test func otherHeadingsAndTheirWrappersStay() async throws {
        // Not a back-matter name, so the list is read; and a wrapper holding article text is never removed.
        let backMatter = #"""
            <h2>Notes on the lamp:</h2><ol><li>\#(Fixture.log)</li></ol>
            <div class="closing"><p>\#(Fixture.closing)</p><h2>References</h2></div>
            """#
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        let texts = article.blocks.map(\.text)
        #expect(texts.contains("Notes on the lamp:"))
        #expect(texts.contains(Fixture.log))
        #expect(texts.contains(Fixture.closing))
        #expect(!texts.contains("References"))
    }

    @Test func backMatterStopsAtTheEndOfTheAsideThatHoldsIt() async throws {
        // A "See also" box inside the article: only the box's list goes; the article text after the box stays.
        let backMatter = #"""
            <aside class="box"><h3>See also</h3><ul><li>\#(Fixture.log)</li></ul></aside><p>\#(Fixture.closing)</p>
            """#
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        let texts = article.blocks.map(\.text)
        #expect(texts.contains(Fixture.closing))
        #expect(!article.spokenText.contains("Keeper's log"))
        #expect(!article.spokenText.contains("See also"))
    }

    @Test func readabilityIsTheVendoredRelease() {
        // THIRD_PARTY_NOTICES.md records this SHA-256 for Readability.js at tag 0.6.0.
        let digest = SHA256.hash(data: Data(WebArticleExtractor.readabilitySource.utf8))
        #expect(digest.map { String(format: "%02x", $0) }.joined()
            == "34dcab3d0832d0019f02990eed6b6124e029e8c32b9f0c6f2550544ff8dff174")
    }
}
