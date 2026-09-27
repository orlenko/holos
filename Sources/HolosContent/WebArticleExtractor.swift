import Foundation
import HolosCore
import WebKit

/// Turns a web page into a `WebArticle`: loads it in an offscreen `WKWebView` (so pages built by JavaScript have a
/// real DOM), runs Mozilla Readability 0.6.0 on a copy of the document, and reduces the article HTML to headings and
/// paragraphs. Nothing persists: the web view uses a non-persistent website data store.
///
/// The caller's process must run the main run loop while awaiting (an app, or a command-line tool with an async
/// `main`, which Swift drives with `CFRunLoopRun`).
@MainActor public final class WebArticleExtractor {
    public struct Options: Sendable {
        /// How long to wait for the page to finish loading. When it runs out, a page whose document has been
        /// parsed is read anyway; one still loading is an error.
        public var loadTimeout: Duration
        /// The pause after loading before the first read, so scripts can build the page.
        public var settle: Duration
        /// How long to keep re-reading a page that shows no article yet (pages that render late).
        public var retryWindow: Duration
        /// Fewer words than this is "no article found".
        public var minimumWords: Int

        public init(loadTimeout: Duration = .seconds(30), settle: Duration = .seconds(1),
                    retryWindow: Duration = .seconds(6), minimumWords: Int = 50) {
            self.loadTimeout = loadTimeout
            self.settle = settle
            self.retryWindow = retryWindow
            self.minimumWords = minimumWords
        }
    }

    private let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Loads an `https` page and extracts its article.
    public func extract(from url: URL) async throws -> WebArticle {
        guard url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else {
            throw HolosError.invalidInput("Only https:// web addresses can be read: \(url.absoluteString)")
        }
        return try await extract(requested: url) { $0.load(URLRequest(url: url)) }
    }

    /// Extracts the article from HTML already in hand, resolving relative links against `baseURL`.
    func extract(html: String, baseURL: URL) async throws -> WebArticle {
        try await extract(requested: baseURL) { $0.loadHTMLString(html, baseURL: baseURL) }
    }

    /// Reduces article HTML (Readability's output) to headings and paragraphs, without running Readability.
    func blocks(fromContentHTML html: String) async throws -> [WebArticle.Block] {
        let webView = Self.makeWebView()
        let loader = PageLoader()
        webView.navigationDelegate = loader
        defer { webView.navigationDelegate = nil }
        let baseURL = URL(string: "https://example.invalid/")!
        guard try await loader.load(timeout: options.loadTimeout, start: {
            webView.loadHTMLString(html, baseURL: baseURL)
        }) == .finished else { throw HolosError.unavailable("Timed out loading the article HTML.") }
        let json = try await Self.run(Self.conversionScript, in: webView)
        let raw = try JSONDecoder().decode([Payload.RawBlock].self, from: Data(json.utf8))
        return WebArticle.assemble(url: baseURL, title: nil, byline: nil, siteName: nil, language: nil,
                                   raw: raw.map { ($0.level, $0.text) }).blocks
    }

    private func extract(requested: URL, start: (WKWebView) -> Void) async throws -> WebArticle {
        let webView = Self.makeWebView()
        let loader = PageLoader()
        webView.navigationDelegate = loader
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
        let outcome = try await loader.load(timeout: options.loadTimeout) { start(webView) }
        if outcome == .timedOut {
            let state = try? await Self.run("return document.readyState;", in: webView)
            guard let state, state != "loading" else {
                throw HolosError.unavailable("Timed out loading \(requested.absoluteString).")
            }
            webView.stopLoading()
        }
        let deadline = ContinuousClock.now + options.retryWindow
        var bestWords = 0
        var lastFailure: String?
        while true {
            try await Task.sleep(for: options.settle)
            if let rejection = loader.rejection { throw rejection }
            // A page that navigates again (a script redirect) can make one read fail; the next read sees the new page.
            let payload: Payload
            do {
                let json = try await Self.run(Self.extractionScript, in: webView)
                payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
            } catch {
                payload = Payload(found: false, error: error.localizedDescription)
            }
            lastFailure = payload.error ?? lastFailure
            if payload.found {
                let pageURL = webView.url.flatMap { $0.scheme == "about" ? nil : $0 } ?? requested
                let article = WebArticle.assemble(
                    url: pageURL, title: payload.title, byline: payload.byline, siteName: payload.siteName,
                    language: payload.lang, raw: (payload.blocks ?? []).map { ($0.level, $0.text) })
                if article.wordCount >= options.minimumWords { return article }
                bestWords = max(bestWords, article.wordCount)
            }
            if ContinuousClock.now + options.settle > deadline { break }
        }
        if bestWords == 0, let lastFailure {
            throw HolosError.unavailable("Article extraction failed on \(requested.absoluteString): \(lastFailure)")
        }
        let found = bestWords > 0 ? " (only \(bestWords) words)" : ""
        throw HolosError.unavailable(
            "Could not find article text on \(requested.absoluteString)\(found). The page may need a sign-in, "
                + "show a paywall, or not be an article. Open it in a browser, save the article's text to a .txt "
                + "file, and pass that file to voiceislocal read.")
    }

    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        // WebKit's own user agent plus Safari's suffix, so sites serve the page they give desktop Safari.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 1600), configuration: configuration)
    }

    /// Runs a function body in WebKit's client content world (the page's DOM, but not its scripts' globals) and
    /// returns the string it resolves to.
    private static func run(_ body: String, in webView: WKWebView) async throws -> String {
        let value = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .defaultClient)
        guard let text = value as? String else {
            throw HolosError.unavailable("Article extraction returned no result.")
        }
        return text
    }

    private struct Payload: Decodable {
        struct RawBlock: Decodable {
            let level: Int
            let text: String
        }

        let found: Bool
        var error: String? = nil
        var title: String? = nil
        var byline: String? = nil
        var siteName: String? = nil
        var lang: String? = nil
        var blocks: [RawBlock]? = nil
    }

    /// Mozilla Readability 0.6.0, verbatim (see THIRD_PARTY_NOTICES.md).
    static let readabilitySource = String(decoding: PackageResources.Readability_js, as: UTF8.self)

    /// Walks article HTML and returns `[{level, text}]`: level 1–6 for headings, 0 for paragraphs. Block elements
    /// (paragraphs, list items, quotations, divisions) and `<br>` end a paragraph; code blocks, tables, figures,
    /// captions, media, and forms are skipped; so are bracketed reference marks such as `<sup>[1]</sup>`.
    private static let blockWalker = #"""
    function holosArticleBlocks(root) {
      const skipBlock = new Set(["FIGURE", "FIGCAPTION", "PRE", "TABLE", "FORM", "FIELDSET", "IFRAME", "VIDEO",
        "AUDIO", "CANVAS", "OBJECT", "EMBED", "SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "DIALOG"]);
      const skipInline = new Set(["IMG", "PICTURE", "SVG", "MATH", "BUTTON", "INPUT", "SELECT", "TEXTAREA",
        "LABEL", "MAP", "SOURCE", "TRACK", "WBR"]);
      const block = new Set(["ADDRESS", "ARTICLE", "ASIDE", "BLOCKQUOTE", "DD", "DETAILS", "DIV", "DL", "DT",
        "FOOTER", "HEADER", "HGROUP", "LI", "MAIN", "NAV", "OL", "P", "SECTION", "SUMMARY", "UL"]);
      const blocks = [];
      let buffer = "";
      let headingLevel = 0;
      const flush = () => {
        const text = buffer.replace(/\s+/g, " ").trim();
        if (text) blocks.push({ level: headingLevel, text: text });
        buffer = "";
      };
      const walk = (node) => {
        for (const child of node.childNodes) {
          if (child.nodeType === Node.TEXT_NODE) { buffer += child.data; continue; }
          if (child.nodeType !== Node.ELEMENT_NODE) continue;
          const tag = child.tagName.toUpperCase();
          if (skipInline.has(tag)) continue;
          if (skipBlock.has(tag)) { flush(); continue; }
          if (tag === "SUP" && /^\s*\[[^\]]*\]\s*$/.test(child.textContent)) continue;
          if (tag === "BR" || tag === "HR") { flush(); continue; }
          if (/^H[1-6]$/.test(tag)) {
            flush();
            const outer = headingLevel;
            headingLevel = Number(tag[1]);
            walk(child);
            flush();
            headingLevel = outer;
            continue;
          }
          if (block.has(tag)) { flush(); walk(child); flush(); continue; }
          walk(child);
        }
      };
      walk(root);
      flush();
      return blocks;
    }
    """#

    /// Removes back-matter sections (references, notes, "see also", external links, further reading) from a copy
    /// of the page before Readability runs: each such heading and the elements after it up to the next heading of
    /// the same or a higher level.
    private static let backMatterRemover = #"""
    function holosDropBackMatter(doc) {
      const names = /^(references|notes|footnotes|citations|sources|bibliography|further reading|external links|see also|notes and references|references and notes|works cited)$/i;
      const levelOf = (element) => {
        const heading = /^H[1-6]$/.test(element.tagName) ? element : element.querySelector("h1, h2, h3, h4, h5, h6");
        return heading ? Number(heading.tagName[1]) : 7;
      };
      for (const heading of Array.from(doc.querySelectorAll("h1, h2, h3, h4, h5, h6"))) {
        if (!heading.isConnected) continue;
        const label = heading.textContent.replace(/\[[^\]]*\]/g, "").replace(/\s+/g, " ").trim();
        if (!names.test(label)) continue;
        const level = Number(heading.tagName[1]);
        // Wikipedia wraps a heading and its edit link in <div class="mw-heading">.
        const parent = heading.parentElement;
        const start = parent && parent.classList.contains("mw-heading") ? parent : heading;
        let next = start.nextElementSibling;
        while (next && levelOf(next) > level) {
          const after = next.nextElementSibling;
          next.remove();
          next = after;
        }
        start.remove();
      }
    }
    """#

    private static let conversionScript = blockWalker + "\nreturn JSON.stringify(holosArticleBlocks(document.body));"

    private static let extractionScript = readabilitySource + "\n" + backMatterRemover + "\n" + blockWalker + #"""

    try {
      const page = document.cloneNode(true);
      holosDropBackMatter(page);
      const article = new Readability(page).parse();
      if (!article) return JSON.stringify({ found: false, title: document.title });
      const content = new DOMParser().parseFromString(article.content || "", "text/html");
      return JSON.stringify({
        found: true, title: article.title, byline: article.byline, siteName: article.siteName,
        lang: article.lang, blocks: holosArticleBlocks(content.body)
      });
    } catch (error) {
      return JSON.stringify({ found: false, error: String(error) });
    }
    """#
}

/// Waits for the main-frame navigation of one web view to finish, fail, or time out, and refuses error pages and
/// non-HTML documents.
@MainActor private final class PageLoader: NSObject, WKNavigationDelegate {
    enum Outcome { case finished, timedOut }

    private var continuation: CheckedContinuation<Outcome, any Error>?
    private var timer: Task<Void, Never>?
    /// Why the page was refused, once it was.
    private(set) var rejection: HolosError?

    func load(timeout: Duration, start: () -> Void) async throws -> Outcome {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(.success(.timedOut))
            }
            start()
        }
    }

    private func finish(_ result: Result<Outcome, any Error>) {
        timer?.cancel()
        timer = nil
        continuation?.resume(with: result)
        continuation = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse)
        async -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame else { return .allow }
        let address = navigationResponse.response.url?.absoluteString ?? "the page"
        if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
            rejection = .unavailable("\(address) answered HTTP \(http.statusCode) "
                + "(\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))).")
            return .cancel
        }
        let type = navigationResponse.response.mimeType?.lowercased() ?? "text/html"
        guard type == "text/html" || type == "application/xhtml+xml" else {
            rejection = .unavailable("\(address) is not a web page (\(type)). Download it and pass the file instead.")
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(.finished))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        failed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(HolosError.unavailable("The web page's content process stopped while loading.")))
    }

    private func failed(_ error: any Error) {
        // A script or redirect that starts another navigation cancels the first one; wait for the new one.
        if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled,
           rejection == nil { return }
        finish(.failure(rejection ?? HolosError.unavailable("Could not load the page: \(error.localizedDescription)")))
    }
}
