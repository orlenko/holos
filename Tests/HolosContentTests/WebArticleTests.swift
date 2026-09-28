import CryptoKit
import Foundation
import HolosCore
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
            == "A Title\n\nBy Jane Doe\n\nFirst paragraph.\n\nSection\n\nSecond [note] paragraph.\n\n[1] and [2]")
    }

    @Test func assemblyDropsPermalinkAndBreakMarksButKeepsOtherSymbols() {
        let url = URL(string: "https://blog.example.test/post")!
        let noise = ["#", " ¶ ", "§", "🔗", "🔗\u{FE0F}", "Permalink", "permalink", "* * *", " *  *  * ", "***", "⁂",
                     "~", "—", "---", "· · ·", "❧"]
        let kept = ["🔥", "∞ ≠ ∅", "— … —", "##", "§ 3", "~/bin", "* * * *", "π", "→"]
        let article = WebArticle.assemble(
            url: url, title: "Title", byline: nil, siteName: nil, language: nil,
            raw: noise.map { (0, $0) } + [(2, "🔥"), (2, "#")] + kept.map { (0, $0) })
        #expect(article.blocks == [.heading(level: 2, text: "🔥")] + kept.map { .paragraph($0) })
    }

    @Test func assemblyKeepsABylineThatAlreadySaysBy() {
        let url = URL(string: "https://blog.example.test/post")!
        let article = WebArticle.assemble(url: url, title: nil, byline: "by Jane Doe", siteName: nil,
                                          language: nil, raw: [(0, "Body.")])
        #expect(article.title == "blog.example.test")
        #expect(article.spokenText == "blog.example.test\n\nby Jane Doe\n\nBody.")
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

    @Test(arguments: [
        // Wikipedia's markup (2026): nested sections, each heading in a `div.mw-heading` beside its edit link.
        ##"<div class="mw-heading mw-heading{LEVEL}"><h{LEVEL} id="{ID}">{TEXT}</h{LEVEL}><span class="mw-editsection"><span class="mw-editsection-bracket">[</span><a href="/w/index.php?title=Lighthouse&amp;action=edit&amp;section=1" title="Edit section: {TEXT}"><span>edit</span></a><span class="mw-editsection-bracket">]</span></span></div>"##,
        // A docs site's heading beside its permalink anchor.
        ##"<div class="heading-wrapper"><h{LEVEL} id="{ID}">{TEXT}</h{LEVEL}><a class="anchor" href="#{ID}" aria-label="Permalink">#</a></div>"##,
        // The same in a wrapper named "section-header".
        ##"<div class="section-header" id="header-{ID}"><h{LEVEL}>{TEXT}</h{LEVEL}><a href="#header-{ID}">¶</a></div>"##,
        // Substack's markup (2026): the heading's own class says "header"; its link button sits inside it.
        ##"<h{LEVEL} class="header-anchor-post">{TEXT}<div class="pencraft pc-display-flex pc-position-absolute pc-reset header-anchor-parent"><div class="pencraft pc-display-contents pc-reset"><div id="§{ID}" class="pencraft pc-reset header-anchor offset-top"></div><button tabindex="0" type="button" aria-label="Link" data-href="https://news.example.test/i/1/{ID}" class="pencraft pc-reset iconButton"><svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24"><path d="M10 13a5 5 0 0 0 7.54.54"></path></svg></button></div></div></h{LEVEL}>"##,
    ])
    func sectionHeadingsStayWhateverTheirMarkup(wrapper: String) async throws {
        func heading(_ level: Int, _ text: String) -> String {
            wrapper.replacingOccurrences(of: "{LEVEL}", with: "\(level)")
                .replacingOccurrences(of: "{ID}", with: text.replacingOccurrences(of: " ", with: "_"))
                .replacingOccurrences(of: "{TEXT}", with: text)
        }
        let p = Fixture.paragraphs
        // Short headings (which Readability's div cleanup took for short, linky blocks), a heading that opens its
        // parent's section, headings followed by a figure, an empty span, a hatnote, a navigation box, or a nested
        // section, and a heading with only a hatnote before its first subsection.
        let page = """
            <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Lighthouse - Wikipedia</title></head>
            <body><div id="content"><h1 id="firstHeading">Lighthouse</h1>
            <div id="mw-content-text" class="mw-body-content"><div class="mw-content-ltr mw-parser-output">
            <section data-mw-section-id="0"><p>\(p[0])</p><p>\(p[1])</p></section>
            <section data-mw-section-id="1">\(heading(2, "History"))<p>\(p[2])</p>
            <section data-mw-section-id="2">\(heading(3, "Mechanical devices"))<span class="mw-empty-elt"></span>
            <p>\(p[0])</p></section>
            <section data-mw-section-id="3">\(heading(3, "Electronic devices"))
            <figure class="mw-default-size"><a href="/wiki/File:Lamp.jpg"><img src="lamp.jpg" alt=""></a>
            <figcaption>The lamp room at dusk.</figcaption></figure><p>\(p[1])</p></section></section>
            <section data-mw-section-id="4">\(heading(2, "Keepers"))
            <div role="note" class="hatnote navigation-not-searchable">Main article: <a href="/wiki/Keeper">Keeper</a></div>
            <section data-mw-section-id="5">\(heading(3, "Mattel"))
            <div role="note" class="hatnote navigation-not-searchable">Main article: <a href="/wiki/Mattel">Mattel</a></div>
            <p>\(p[2])</p></section>
            <section data-mw-section-id="6">\(heading(4, "Diphone synthesis"))<p>\(p[0])</p></section>
            <section data-mw-section-id="7">\(heading(3, "Artificial intelligence in lighthouses"))
            <div class="sidebar-list" role="navigation"><ul><li><a href="/wiki/AGI">Artificial general
            intelligence and superintelligence</a></li></ul></div><p>\(p[1])</p>
            </section></section>
            <section data-mw-section-id="8">\(heading(2, "References"))<div class="reflist"><ol>
            <li>\(Fixture.log)</li></ol></div></section>
            </div></div></div></body></html>
            """
        let article = try await WebArticleExtractor(options: fast).extract(html: page, baseURL: Fixture.base)
        let headings = article.blocks.compactMap { block -> String? in
            guard case .heading(let level, let text) = block else { return nil }
            return "h\(level) \(text)"
        }
        #expect(headings == ["h2 History", "h3 Mechanical devices", "h3 Electronic devices", "h2 Keepers",
                             "h3 Mattel", "h4 Diphone synthesis", "h3 Artificial intelligence in lighthouses"])
        // Each heading comes right before its section's first paragraph; the links beside it are not read. (Whether
        // Readability keeps the hatnotes is its own call, not checked here.)
        let texts = article.blocks.map(\.text).filter { !$0.hasPrefix("Main article:") }
        #expect(texts == [p[0], p[1], "History", p[2], "Mechanical devices", p[0], "Electronic devices", p[1],
                          "Keepers", "Mattel", p[2], "Diphone synthesis", p[0],
                          "Artificial intelligence in lighthouses", p[1]])
    }

    @Test(arguments: [
        // Widgets whose heading sits with their own links or buttons.
        #"<div class="sidebar-widget"><h3>Related stories</h3><a href="/rss">RSS</a></div>"#,
        #"<div role="navigation"><h3>Related stories</h3><button>Previous</button><button>Next</button></div>"#,
        #"<div class="related-content" id="sidebar"><h3>Related stories</h3><a href="/more">More</a></div>"#,
        #"<div class="widget"><h2 class="widget-header">Related stories</h2><ul><li><a href="/a">Ten gadgets you need</a></li><li><a href="/b">Weather this weekend</a></li></ul></div>"#,
        #"<aside><h3>Related stories</h3><a href="/share/x">Share on X</a> <a href="/share/mail">Email</a></aside>"#,
        #"<div role="navigation"><h3>Related stories</h3><ul><li><a href="/c">A much longer headline about the harbour and the storms of the winter</a></li></ul></div>"#,
        // Hidden headings, alone or with their sections.
        #"<div hidden><h3>Related stories</h3><p>\#(Fixture.paragraphs[2])</p></div>"#,
        #"<div aria-hidden="true"><h3>Related stories</h3><p>\#(Fixture.paragraphs[2])</p></div>"#,
        #"<div style="display:none"><h3>Related stories</h3><p>\#(Fixture.paragraphs[2])</p></div>"#,
        #"<h3 hidden>Related stories</h3>"#,
        #"<div style="visibility: hidden"><h3>Related stories</h3></div>"#,
    ])
    func furnitureHeadingsStayOut(furniture: String) async throws {
        // The furniture sits in the article, before a section whose heading Readability drops with its wrapper.
        let backMatter = furniture + #"""
            <div class="mw-heading mw-heading2"><h2>After the storm</h2><span>[<a href="/edit">edit</a>]</span></div>
            <p>\#(Fixture.closing)</p>
            """#
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        #expect(!article.spokenText.contains("Related stories"))
        let texts = article.blocks.map(\.text)
        #expect(Array(texts.suffix(2)) == ["After the storm", Fixture.closing])
        #expect(article.blocks.filter { if case .heading = $0 { true } else { false } }.map(\.text)
            == ["A daily climb", "After the storm"])
    }

    @Test func aHeadingBesideAScriptComesBackBeforeItsSection() async throws {
        // Readability removes the script, then the short, linky wrapper with the heading in it.
        let config = String(repeating: "window.holosWidgetConfiguration.push({ theme: 'dark', size: 12 }); ", count: 20)
        let backMatter = #"""
            <div class="anchored"><h2>Setup</h2><script>\#(config)</script><a href="#setup">#</a></div>
            <p>\#(Fixture.closing)</p>
            """#
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        #expect(Array(article.blocks.suffix(2)) == [.heading(level: 2, text: "Setup"), .paragraph(Fixture.closing)])
        #expect(!article.spokenText.contains("holosWidgetConfiguration"))
    }

    @Test func titleAndKeptHeadingsAreNotAddedTwice() async throws {
        let p = Fixture.paragraphs
        // A title heading in a wrapper (Readability drops it as the title), a section heading in the same wrapper,
        // one Readability keeps, and two with the same name.
        func wrapped(_ text: String) -> String {
            #"<div class="mw-heading mw-heading2"><h2>\#(text)</h2><span>[<a href="/edit">edit</a>]</span></div>"#
        }
        let page = """
            <!doctype html><html lang="en"><head><meta charset="utf-8">
            <title>The Last Keeper of the Northern Cape | Coastal News</title></head>
            <body><main><article>
            \(wrapped("The last keeper of the northern cape."))<p>\(p[0])</p>
            \(wrapped("A daily climb"))<p>\(p[1])</p>
            <h2>Visitors</h2><p>\(p[2])</p>
            \(wrapped("Visitors"))<p>\(Fixture.closing)</p>
            </article></main></body></html>
            """
        let article = try await WebArticleExtractor(options: fast).extract(html: page, baseURL: Fixture.base)
        #expect(article.title == "The Last Keeper of the Northern Cape")
        #expect(article.blocks == [.paragraph(p[0]), .heading(level: 2, text: "A daily climb"), .paragraph(p[1]),
                                   .heading(level: 2, text: "Visitors"), .paragraph(p[2]),
                                   .heading(level: 2, text: "Visitors"), .paragraph(Fixture.closing)])
    }

    /// A heading in Wikipedia's wrapper beside its edit link, which Readability drops as a short, linky block.
    private func wrappedHeading(_ text: String, level: Int = 2) -> String {
        #"<div class="mw-heading mw-heading\#(level)"><h\#(level)>\#(text)</h\#(level)>"#
            + #"<span>[<a href="/edit">edit</a>]</span></div>"#
    }

    private func headings(_ article: WebArticle) -> [String] {
        article.blocks.compactMap { block in
            guard case .heading(let level, let text) = block else { return nil }
            return "h\(level) \(text)"
        }
    }

    @Test(arguments: [
        // Widgets whose controls have accessible names and no text.
        #"<nav role="navigation"><h3>Share this story</h3><button aria-label="Share on X"><svg viewBox="0 0 24 24"><path d="M1 1h22v22H1z"></path></svg></button><button aria-label="Email"><svg viewBox="0 0 24 24"><path d="M2 4h20v16H2z"></path></svg></button></nav>"#,
        #"<div role="complementary"><h3>Share this story</h3><a href="/share/x" aria-label="Share on X"><svg viewBox="0 0 24 24"></svg></a></div>"#,
        #"<aside><h3>Share this story</h3><button aria-label="Copy link"><svg viewBox="0 0 24 24"></svg></button></aside>"#,
        #"<div role="navigation"><div class="share"><h3>Share this story</h3><button aria-label="Share on X"></button></div></div>"#,
    ])
    func aWidgetHeadingNeverTakesTheArticleAfterItAsItsSection(widget: String) async throws {
        // The widget sits before the article's last paragraph, with no heading between them.
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: widget + "<p>\(Fixture.closing)</p>"), baseURL: Fixture.base)
        #expect(!article.spokenText.contains("Share this story"))
        #expect(article.blocks.last == .paragraph(Fixture.closing))
        #expect(headings(article) == ["h2 A daily climb"])
    }

    @Test func duplicatedTextDoesNotTieAHeadingToTheWrongCopy() async throws {
        let p = Fixture.paragraphs
        // An aside repeats the article's first paragraph under its own heading; a real section later repeats it too.
        let backMatter = """
            <aside role="complementary"><h2>Related</h2><p>\(p[0])</p></aside>
            <aside><h2>Also related</h2><p>\(p[0])</p></aside>
            \(wrappedHeading("Recap"))<p>\(p[0])</p>
            <p>\(Fixture.closing)</p>
            """
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        #expect(!article.spokenText.contains("Related"))
        #expect(!article.spokenText.contains("Also related"))
        #expect(headings(article) == ["h2 A daily climb", "h2 Recap"])
        #expect(Array(article.blocks.suffix(3))
            == [.heading(level: 2, text: "Recap"), .paragraph(p[0]), .paragraph(Fixture.closing)])
        #expect(article.blocks.first == .paragraph(p[0]))
    }

    @Test func aSectionWithOnlyAFigureGetsNoHeading() async throws {
        let caption = "A long caption that describes the lamp room at dusk, the brass fittings, and the view of "
            + "the channel from the gallery rail on a clear evening."
        let backMatter = """
            \(wrappedHeading("Gallery"))
            <figure><img src="lamp.jpg" alt=""><figcaption>\(caption)</figcaption></figure>
            <figure><img src="stairs.jpg" alt=""><p>\(caption)</p></figure>
            \(wrappedHeading("After the storm"))<p>\(Fixture.closing)</p>
            """
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        #expect(!article.spokenText.contains("Gallery"))
        #expect(!article.spokenText.contains("brass fittings"))
        #expect(headings(article) == ["h2 A daily climb", "h2 After the storm"])
        #expect(Array(article.blocks.suffix(2)) == [.heading(level: 2, text: "After the storm"),
                                                    .paragraph(Fixture.closing)])
    }

    @Test func sectionsOfShortBlocksKeepTheirHeadings() async throws {
        // A FAQ of short answers, release notes of short bullets, and a section in a `div` holding only text
        // (which Readability turns into a new paragraph).
        let backMatter = """
            \(wrappedHeading("Questions"))
            \(wrappedHeading("Is it haunted?", level: 3))<p>No.</p>
            \(wrappedHeading("Can I visit?", level: 3))<p>Yes, on Sundays.</p>
            \(wrappedHeading("Release notes"))
            <ul><li>New lens.</li><li>Fixed the stairs.</li><li>Brighter lamp.</li><li>Quieter foghorn.</li></ul>
            \(wrappedHeading("Keeper's diary"))<div>\(Fixture.closing)</div>
            """
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        let texts = article.blocks.map(\.text)
        let start = try #require(texts.firstIndex(of: "Questions"))
        #expect(Array(texts[start...]) == ["Questions", "Is it haunted?", "No.", "Can I visit?", "Yes, on Sundays.",
                                           "Release notes", "New lens.", "Fixed the stairs.", "Brighter lamp.",
                                           "Quieter foghorn.", "Keeper's diary", Fixture.closing])
        #expect(headings(article) == ["h2 A daily climb", "h2 Questions", "h3 Is it haunted?", "h3 Can I visit?",
                                      "h2 Release notes", "h2 Keeper's diary"])
    }

    @Test func aPagesOwnMarksDoNotBringBackAHeading() async throws {
        // The page carries the attributes the extractor uses; they are ignored.
        let backMatter = """
            <aside data-holos-h="0"><h2 data-holos-h="1">Related</h2><p data-holos-b="0">Short.</p></aside>
            <p data-holos-b="1">\(Fixture.closing)</p>
            """
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        #expect(!article.spokenText.contains("Related"))
        #expect(article.blocks.last == .paragraph(Fixture.closing))
    }

    @Test(arguments: [
        // Wikipedia-style: the section's text is loose in the `section` beside the heading's wrapper.
        "<section>{HEADING}{TEXT}</section>",
        // The same after a paragraph of the same `section`, which comes before the heading.
        "<section><p>{BEFORE}</p>{HEADING}{TEXT}</section>",
        // Loose text in a `div` around the wrapper.
        "<div class=\"body\">{HEADING}{TEXT}</div>",
    ])
    func looseTextAfterAHeadingWrapperIsItsSection(layout: String) async throws {
        let p = Fixture.paragraphs
        let backMatter = layout.replacingOccurrences(of: "{HEADING}", with: wrappedHeading("After the storm"))
            .replacingOccurrences(of: "{BEFORE}", with: p[1])
            .replacingOccurrences(of: "{TEXT}", with: Fixture.closing)
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        #expect(headings(article) == ["h2 A daily climb", "h2 After the storm"])
        #expect(Array(article.blocks.suffix(2)) == [.heading(level: 2, text: "After the storm"),
                                                    .paragraph(Fixture.closing)])
        #expect(!article.spokenText.contains("edit"))
    }

    @Test func onlyTheFirstTitleLikeHeadingIsTheTitle() async throws {
        let p = Fixture.paragraphs
        // The title heading, then a later `h1` like it that Readability drops for its class name, with its own
        // section.
        let page = """
            <!doctype html><html lang="en"><head><meta charset="utf-8">
            <title>The Last Keeper of the Northern Cape | Coastal News</title></head>
            <body><main><article>
            <h1>The Last Keeper of the Northern Cape</h1><p>\(p[0])</p><p>\(p[2])</p>
            <h1 class="header-anchor-post">The last keeper of the northern cape, again</h1><p>\(p[1])</p>
            <p>\(Fixture.closing)</p>
            </article></main></body></html>
            """
        let article = try await WebArticleExtractor(options: fast).extract(html: page, baseURL: Fixture.base)
        #expect(article.blocks == [.paragraph(p[0]), .paragraph(p[2]),
                                   .heading(level: 2, text: "The last keeper of the northern cape, again"),
                                   .paragraph(p[1]), .paragraph(Fixture.closing)])
    }

    @Test func aTitleLikeHeadingAfterTheArticleBeginsIsASectionHeading() async throws {
        let p = Fixture.paragraphs
        // The first title-like heading comes after the article's first paragraph.
        let page = """
            <!doctype html><html lang="en"><head><meta charset="utf-8">
            <title>The Last Keeper of the Northern Cape | Coastal News</title></head>
            <body><main><article>
            <p>\(p[0])</p>
            \(wrappedHeading("The last keeper of the northern cape"))<p>\(p[1])</p>
            </article></main></body></html>
            """
        let article = try await WebArticleExtractor(options: fast).extract(html: page, baseURL: Fixture.base)
        #expect(article.blocks == [.paragraph(p[0]),
                                   .heading(level: 2, text: "The last keeper of the northern cape"),
                                   .paragraph(p[1])])
    }

    @Test(arguments: [
        ##"<nav role="navigation"><h2>On this page</h2><ul><li><a href="#top">Top</a></li></ul></nav>"##,
        ##"<aside><h2>On this page</h2><a href="#top">Top</a></aside>"##,
        #"<div role="complementary"><h3>On this page</h3></div>"#,
        ##"<div role="menu"><h1>On this page</h1><a href="#top">Top</a></div>"##,
    ])
    func aFurnitureHeadingNeitherEndsNorStartsASection(furniture: String) async throws {
        // The widget sits between a dropped article heading and its section's text.
        let backMatter = wrappedHeading("After the storm") + furniture + "<p>\(Fixture.closing)</p>"
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        #expect(!article.spokenText.contains("On this page"))
        #expect(headings(article) == ["h2 A daily climb", "h2 After the storm"])
        #expect(Array(article.blocks.suffix(2)) == [.heading(level: 2, text: "After the storm"),
                                                    .paragraph(Fixture.closing)])
    }

    @Test func thePageAndTheAssemblyAgreeOnWhatIsSpoken() async throws {
        let long = String(repeating: "x", count: 22)
        let samples = [
            "", " ", "\t\n", "\u{200B}", "\u{FEFF}", "\u{00A0}\u{2028}", "Hello", "  Hello  world ",
            "#", " # ", "\u{200B}#", "#\u{00A0}", "\u{0085}#", "\u{202E}#\u{2066}", "##", "# 1",
            "¶", "§", "§ 3", "🔗", "🔗\u{FE0F}", "Permalink", "PERMALINK", " permalink\u{200D} ",
            "* * *", "*  *  *", "\t* * *\n", "* * * *", "***", "⁂", "~", "~/bin", "—", "— … —", "---", "· · ·", "❧",
            "[1]", "[edit]", "[ Edit ]", "[1][2]", "[1], [2]", " [1], [2]; [3]–[4] ", "[edit] [a][note 3]",
            "[1] and [2]", "[\(long)]", "[\(long)x]", "[" + String(repeating: "👍🏽", count: 11) + "]",
            "[" + String(repeating: "👍🏽", count: 12) + "]", "[e\u{301}]", "[\u{200B}1]",
            "🔥", "∞ ≠ ∅", "π", "→", "…", "İ", "\u{FFFE}", "a\u{FFFF}b",
        ]
        let json = String(decoding: try JSONEncoder().encode(samples), as: UTF8.self)
        let webView = WKWebView(frame: .zero)
        let answer = try await WebArticleExtractor.run(
            WebArticleExtractor.spokenPredicate + "\nreturn JSON.stringify(\(json).map(holosSpoken));",
            in: webView, timeout: .seconds(20))
        let page = try JSONDecoder().decode([Bool].self, from: Data(answer.utf8))
        let swift = samples.map(WebArticle.isSpoken)
        for (index, sample) in samples.enumerated() {
            #expect(page[index] == swift[index], "\(sample.unicodeScalars.map { String($0.value, radix: 16) })")
        }
        // The table covers both answers.
        #expect(swift.contains(true) && swift.contains(false))
        #expect(WebArticle.isSpoken("🔥") && WebArticle.isSpoken("∞ ≠ ∅") && !WebArticle.isSpoken("[edit]"))
    }

    @Test func aSectionOfOnlySymbolsKeepsItsHeading() async throws {
        let backMatter = """
            <section><div class="mw-heading mw-heading2"><h2>Reaction</h2><a href="#Reaction">#</a></div>
            <p>🔥</p></section>
            """
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        #expect(headings(article) == ["h2 A daily climb", "h2 Reaction"])
        #expect(Array(article.blocks.suffix(2)) == [.heading(level: 2, text: "Reaction"), .paragraph("🔥")])
    }

    @Test(arguments: ["#", "[1]", "¶", "[edit]", "* * *"])
    func aSectionOfOnlyNoiseGetsNoHeading(noise: String) async throws {
        let backMatter = wrappedHeading("Links") + "<p>\(noise)</p>" + wrappedHeading("After the storm")
            + "<p>\(Fixture.closing)</p>"
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        #expect(!article.spokenText.contains("Links"))
        #expect(headings(article) == ["h2 A daily climb", "h2 After the storm"])
        #expect(Array(article.blocks.suffix(2)) == [.heading(level: 2, text: "After the storm"),
                                                    .paragraph(Fixture.closing)])
    }

    @Test(arguments: ["🔥", "∞ ≠ ∅"])
    func aHeadingStaysAfterASymbolBlockBeforeIt(symbols: String) async throws {
        // The symbol paragraph shares the heading's container; nothing else of it comes before the heading.
        let backMatter = #"<div class="post-body"><p>\#(symbols)</p>"# + wrappedHeading("After the storm")
            + "<p>\(Fixture.closing)</p><p>\(Fixture.paragraphs[0])</p></div>"
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        let texts = article.blocks.map(\.text)
        let start = try #require(texts.firstIndex(of: symbols))
        #expect(Array(texts[start...]) == [symbols, "After the storm", Fixture.closing, Fixture.paragraphs[0]])
    }

    @Test(arguments: ["section", "div"])
    func looseTextBeforeARestoredHeadingStaysBeforeIt(container: String) async throws {
        let p = Fixture.paragraphs
        let backMatter = "<\(container) class=\"body\">\(p[0])\(wrappedHeading("Details"))\(Fixture.closing)"
            + "</\(container)>"
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        #expect(headings(article) == ["h2 A daily climb", "h2 Details"])
        #expect(Array(article.blocks.suffix(3)) == [.paragraph(p[0]), .heading(level: 2, text: "Details"),
                                                    .paragraph(Fixture.closing)])
    }

    @Test(arguments: ["section", "div"])
    func looseTextBeforeAHeadingDoesNotKeepItsSectionAlive(container: String) async throws {
        // The element's text after the heading is a share widget, which Readability removes; its text before the
        // heading stays. That text is not the heading's section.
        let p = Fixture.paragraphs
        let backMatter = "<\(container) class=\"body\">\(p[0])\(wrappedHeading("Details"))"
            + "<span class=\"share\">Share this story with a friend</span></\(container)>"
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        #expect(!article.spokenText.contains("Details"))
        #expect(!article.spokenText.contains("Share this story"))
        #expect(headings(article) == ["h2 A daily climb"])
        #expect(article.blocks.last == .paragraph(p[0]))
    }

    @Test(arguments: ["section", "div"])
    func looseTextAfterAHeadingThatSurvivesBringsItBack(container: String) async throws {
        // As above, but the element's text after the heading goes on past the share widget; that part stays.
        let p = Fixture.paragraphs
        let backMatter = "<\(container) class=\"body\">\(p[0])\(wrappedHeading("Details"))"
            + "<span class=\"share\">Share this story with a friend</span>\(Fixture.closing)</\(container)>"
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        #expect(!article.spokenText.contains("Share this story"))
        #expect(headings(article) == ["h2 A daily climb", "h2 Details"])
        #expect(Array(article.blocks.suffix(3)) == [.paragraph(p[0]), .heading(level: 2, text: "Details"),
                                                    .paragraph(Fixture.closing)])
    }

    @Test(arguments: [
        // Readability takes the heading itself for the byline.
        #"<h3 class="byline">Ada Harbour</h3>"#,
        // A heading inside a short wrapper named for the author.
        #"<div class="author"><h4>Ada Harbour</h4></div>"#,
        #"<div class="post-byline"><h3>Ada Harbour</h3><span>Staff writer</span></div>"#,
    ])
    func aHeadingTakenAsTheBylineIsNotRestored(byline: String) async throws {
        let page = Fixture.article(backMatter: "<p>\(Fixture.closing)</p>")
            .replacingOccurrences(of: #"<p class="byline">By Ada Harbour</p>"#, with: byline)
        let article = try await WebArticleExtractor(options: fast).extract(html: page, baseURL: Fixture.base)
        #expect(article.byline?.hasPrefix("Ada Harbour") == true)
        #expect(article.spokenText.components(separatedBy: "Ada Harbour").count == 2)
        #expect(headings(article) == ["h2 A daily climb"])
        #expect(article.blocks.first == .paragraph(Fixture.paragraphs[0]))
    }

    @Test func aDroppedHeadingThatRepeatsTheBylineIsNotRestored() async throws {
        // The byline comes from the page's metadata; a heading with the same name sits where the byline would.
        let page = Fixture.article(backMatter: "<p>\(Fixture.closing)</p>")
            .replacingOccurrences(of: #"<p class="byline">By Ada Harbour</p>"#,
                                  with: wrappedHeading("By Ada Harbour", level: 3))
            .replacingOccurrences(of: "<meta charset=\"utf-8\">",
                                  with: "<meta charset=\"utf-8\"><meta name=\"author\" content=\"Ada Harbour\">")
        let article = try await WebArticleExtractor(options: fast).extract(html: page, baseURL: Fixture.base)
        #expect(article.byline == "Ada Harbour")
        #expect(article.spokenText.components(separatedBy: "Ada Harbour").count == 2)
        #expect(headings(article) == ["h2 A daily climb"])
    }

    @Test func readabilityIsTheVendoredRelease() {
        // THIRD_PARTY_NOTICES.md records this SHA-256 for Readability.js at tag 0.6.0.
        let digest = SHA256.hash(data: Data(WebArticleExtractor.readabilitySource.utf8))
        #expect(digest.map { String(format: "%02x", $0) }.joined()
            == "34dcab3d0832d0019f02990eed6b6124e029e8c32b9f0c6f2550544ff8dff174")
    }
}
