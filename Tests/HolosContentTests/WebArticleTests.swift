import CryptoKit
import Foundation
import HolosCore
import Testing
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

    static let article = """
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
        <p>\(paragraphs[1])</p>
        <pre><code>let steps = 117 // counted by hand</code></pre>
        <ul><li>She checks the lens.</li><li>She wipes the windows with <code>fresh water</code>.</li></ul>
        <blockquote><p>\(paragraphs[2])</p></blockquote>
        <h2>References</h2>
        <ol><li>Harbour, A. Keeper's log, volume three. Private collection, 1998.</li></ol>
        </article></main>
        <footer><p>Copyright Coastal News. All rights reserved. Privacy policy. Cookie settings.</p></footer>
        </body></html>
        """

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

    private static func jsString(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
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
                  (2, "Section"), (0, "[1]"), (0, "Second [note] paragraph.")])
        #expect(article.title == "A Title")
        #expect(article.byline == "Jane Doe")
        #expect(article.siteName == nil)
        #expect(article.blocks == [.paragraph("First paragraph."), .heading(level: 2, text: "Section"),
                                   .paragraph("Second [note] paragraph.")])
        #expect(article.wordCount == 6)
        #expect(article.spokenText == "A Title\n\nBy Jane Doe\n\nFirst paragraph.\n\nSection\n\nSecond [note] paragraph.")
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
                      "References", "[1]"] {
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

    @Test func readabilityIsTheVendoredRelease() {
        // THIRD_PARTY_NOTICES.md records this SHA-256 for Readability.js at tag 0.6.0.
        let digest = SHA256.hash(data: Data(WebArticleExtractor.readabilitySource.utf8))
        #expect(digest.map { String(format: "%02x", $0) }.joined()
            == "34dcab3d0832d0019f02990eed6b6124e029e8c32b9f0c6f2550544ff8dff174")
    }
}
