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

@MainActor @Suite(.serialized) struct WebArticleTests {
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

    @Test func assemblyKeepsABylineThatAlreadySaysBy() {
        let url = URL(string: "https://blog.example.test/post")!
        let article = WebArticle.assemble(url: url, title: nil, byline: "by Jane Doe", siteName: nil,
                                          language: nil, raw: [(0, "Body.")])
        #expect(article.title == "blog.example.test")
        #expect(article.spokenText == "blog.example.test\n\nby Jane Doe\n\nBody.")
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
        let options = WebArticleExtractor.Options(loadTimeout: .milliseconds(300), settle: .milliseconds(50),
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
    ])
    func backMatterIsDroppedWhateverItsHeadingLooksLike(backMatter: String) async throws {
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        let spoken = article.spokenText
        #expect(spoken.contains(Fixture.paragraphs[2]))
        for noise in ["Keeper's log", "References", "Notes", "Further reading", "See also", "External",
                      "SOURCES"] {
            #expect(!spoken.contains(noise), "Leaked: \(noise)")
        }
    }

    @Test func otherHeadingsAndTheirWrappersStay() async throws {
        // Not a back-matter name, so the list is read; and a wrapper holding article text is never removed.
        let closing = "The caretaker plans to write her own chapter in the logbook before the season ends, "
            + "describing the winter storms and the ships that sheltered in the bay below the cape."
        let backMatter = #"""
            <h2>Notes on the lamp:</h2><ol><li>\#(Fixture.log)</li></ol>
            <div class="closing"><p>\#(closing)</p><h2>References</h2></div>
            """#
        let article = try await WebArticleExtractor(options: fast).extract(
            html: Fixture.article(backMatter: backMatter), baseURL: Fixture.base)
        let texts = article.blocks.map(\.text)
        #expect(texts.contains("Notes on the lamp:"))
        #expect(texts.contains(Fixture.log))
        #expect(texts.contains(closing))
        #expect(!texts.contains("References"))
    }

    @Test func readabilityIsTheVendoredRelease() {
        // THIRD_PARTY_NOTICES.md records this SHA-256 for Readability.js at tag 0.6.0.
        let digest = SHA256.hash(data: Data(WebArticleExtractor.readabilitySource.utf8))
        #expect(digest.map { String(format: "%02x", $0) }.joined()
            == "34dcab3d0832d0019f02990eed6b6124e029e8c32b9f0c6f2550544ff8dff174")
    }
}
