import Foundation
import HolosCore
import Synchronization
import WebKit

/// Turns a web page into a `WebArticle`: loads it in an offscreen `WKWebView` (so pages built by JavaScript have a
/// real DOM), runs Mozilla Readability 0.6.0 on a copy of the document, and reduces the article HTML to headings and
/// paragraphs. Nothing persists: the web view uses a non-persistent website data store.
///
/// The caller's process must run the main run loop while awaiting (an app, or a command-line tool with an async
/// `main`, which Swift drives with `CFRunLoopRun`).
@MainActor public final class WebArticleExtractor {
    public struct Options: Sendable {
        /// How long the load phase of each document lasts in all: the wait for the page to finish loading and,
        /// when that runs out, the check whether its document has been parsed share this one deadline (see
        /// `waitForLoad`). A parsed page is then read anyway; one still loading is an error. Also how long the
        /// reads may run past the last scheduled one: every read's script shares the deadline `loadTimeout` after
        /// the end of the retry window.
        public var loadTimeout: Duration
        /// The pause after loading before the first read, so scripts can build the page; also the interval
        /// between later reads.
        public var settle: Duration
        /// How long after the first read to keep re-reading a page that shows no article yet (pages that render
        /// late). The last read happens at the end of the window. See `attemptSchedule`.
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

    /// Runs a script in a web view with a time limit and returns its string result (see `run`).
    typealias Evaluator = @MainActor (_ body: String, _ webView: WKWebView, _ timeout: Duration) async throws -> String

    private let options: Options
    private let configureWebView: @MainActor (WKWebViewConfiguration) -> Void
    /// The schemes a main-frame document may have: https, plus schemes tests serve themselves.
    private let documentSchemes: Set<String>
    private let evaluate: Evaluator

    public convenience init(options: Options = Options()) {
        self.init(options: options, configure: { _ in })
    }

    /// `configure` adjusts each web view's configuration before the view is made (tests register URL schemes);
    /// `documentSchemes` lists the schemes a main-frame document may have (tests add the ones they serve);
    /// `evaluate` runs every script (tests stand in for WebKit's answers).
    init(options: Options, documentSchemes: Set<String> = ["https"],
         configure: @escaping @MainActor (WKWebViewConfiguration) -> Void,
         evaluate: @escaping Evaluator = { try await WebArticleExtractor.run($0, in: $1, timeout: $2) }) {
        self.options = options
        self.documentSchemes = documentSchemes
        self.configureWebView = configure
        self.evaluate = evaluate
    }

    /// Loads an `https` page and extracts its article.
    ///
    /// Cancelling the calling task ends every wait (the page load, the pauses between reads, a script still
    /// running in the page) with `CancellationError` and stops the web view.
    public func extract(from url: URL) async throws -> WebArticle {
        guard url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else {
            throw HolosError.invalidInput("Only https:// web addresses can be read: \(WebArticle.address(url))")
        }
        return try await extract(requested: url) { $0.load(URLRequest(url: url)) }
    }

    /// Extracts the article from HTML already in hand, resolving relative links against `baseURL`.
    func extract(html: String, baseURL: URL) async throws -> WebArticle {
        try await extract(requested: baseURL) { $0.loadHTMLString(html, baseURL: baseURL) }
    }

    /// Reduces article HTML (Readability's output) to headings and paragraphs, without running Readability.
    func blocks(fromContentHTML html: String) async throws -> [WebArticle.Block] {
        let webView = makeWebView()
        let loader = PageLoader(documentSchemes: documentSchemes)
        webView.navigationDelegate = loader
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
        let baseURL = URL(string: "https://example.invalid/")!
        // The load and the script share one deadline.
        let deadline = Deadline(options.loadTimeout)
        let loadWait = deadline.remaining(reserving: Self.scriptReserve(for: options.loadTimeout))
        guard try await loader.load(timeout: loadWait, start: { webView.loadHTMLString(html, baseURL: baseURL) })
            == .finished
        else { throw HolosError.unavailable("Timed out loading the article HTML.") }
        let json = try await evaluate(Self.conversionScript, webView, deadline.remaining())
        let raw = try JSONDecoder().decode([Payload.RawBlock].self, from: Data(json.utf8))
        return WebArticle.assemble(url: baseURL, title: nil, byline: nil, siteName: nil, language: nil,
                                   raw: raw.map { ($0.level, $0.text) }).blocks
    }

    /// Most documents one extraction follows through script, meta-refresh, and `Refresh`-header navigations; a
    /// page that keeps moving (a redirect loop, a page that reloads itself) ends with an error.
    static let maximumDocuments = 10
    /// A page that asks to refresh within this many seconds (a `<meta http-equiv="refresh">` or a `Refresh`
    /// response header) is an interstitial on its way elsewhere: it is never taken as the article, and the
    /// extractor waits for it to move.
    static let redirectRefreshLimit = 10.0

    /// Starts the main-frame navigation with `start` (which returns it, or nil when WebKit gave none) and reads
    /// the article of the document the main frame settles on.
    ///
    /// Every main-frame navigation counts, not only the first: while one is being decided, is provisional (the
    /// previous document and address still shown), or has committed but not finished loading, the page is not
    /// read; the extractor waits for it as for the first one (see `awaitDocument`). A read that overlaps the
    /// start of a navigation is discarded. The article's address is the one of the document read, taken in the
    /// same script that reads it.
    func extract(requested: URL, start: (WKWebView) -> WKNavigation?) async throws -> WebArticle {
        let webView = makeWebView()
        let loader = PageLoader(documentSchemes: documentSchemes)
        webView.navigationDelegate = loader
        // Runs on every exit, including cancellation: nothing keeps loading once the caller has stopped waiting.
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
        loader.begin { start(webView) }
        let shownAddress = WebArticle.address(requested)
        var bestWords = 0
        var lastFailure: String?
        var documents = 0
        documentLoop: while true {
            documents += 1
            guard documents <= Self.maximumDocuments else {
                throw HolosError.unavailable("\(shownAddress) kept moving to other pages; no article was read.")
            }
            try await awaitDocument(in: webView, loader: loader, requested: requested)
            let ready = ContinuousClock.now
            let mark = loader.mark
            var refresh: Double?
            let schedule = Self.attemptSchedule(settle: options.settle, retryWindow: options.retryWindow)
            // Every read's script shares one deadline: `loadTimeout` after the last scheduled read.
            let reading = Deadline((schedule.last ?? .zero) + options.loadTimeout, from: ready)
            for offset in schedule {
                try await Task.sleep(until: ready + offset, clock: .continuous)
                try loader.check()
                if loader.moved(since: mark) { continue documentLoop }
                let payload: Payload
                do {
                    let json = try await evaluate(Self.extractionScript, webView, reading.remaining())
                    payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
                } catch is CancellationError {
                    throw CancellationError()
                } catch is ScriptTimeout {
                    throw HolosError.unavailable("\(shownAddress) stopped responding while it was read.")
                } catch {
                    // A navigation that commits while the script runs ends it; the next document is read instead.
                    payload = Payload(found: false, error: error.localizedDescription)
                }
                // The document read may already be on its way out: a navigation decided or started while the
                // script ran (the script yields once before answering, so one the page had scheduled is decided
                // before the answer arrives). Read the next document instead.
                try loader.check()
                if loader.moved(since: mark) { continue documentLoop }
                let pageURL = payload.url.flatMap { URL(string: $0) } ?? webView.url ?? requested
                if let refusal = loader.refusal(of: pageURL) { throw refusal }
                lastFailure = payload.error.map(WebArticle.sanitized) ?? lastFailure
                refresh = [payload.refresh, loader.refreshHeader].compactMap { $0 }
                    .filter { $0 <= Self.redirectRefreshLimit }.min()
                if refresh != nil { continue }
                if payload.found {
                    let article = WebArticle.assemble(
                        url: pageURL, title: payload.title, byline: payload.byline, siteName: payload.siteName,
                        language: payload.lang, raw: (payload.blocks ?? []).map { ($0.level, $0.text) })
                    if article.wordCount >= options.minimumWords { return article }
                    bestWords = max(bestWords, article.wordCount)
                }
            }
            guard let refresh else { break }
            // The page said it would move (its refresh timer starts when it finishes loading): wait for that.
            let deadline = ready + .milliseconds(Int(refresh * 1_000)) + options.loadTimeout
            while !loader.moved(since: mark) {
                guard ContinuousClock.now < deadline else {
                    throw HolosError.unavailable("\(WebArticle.address(webView.url ?? requested)) asked to move "
                        + "to another page but did not.")
                }
                try await Task.sleep(for: .milliseconds(50))
                try loader.check()
            }
        }
        if bestWords == 0, let lastFailure {
            throw HolosError.unavailable("Article extraction failed on \(shownAddress): \(lastFailure)")
        }
        let found = bestWords > 0 ? " (only \(bestWords) words)" : ""
        throw HolosError.unavailable(
            "Could not find article text on \(shownAddress)\(found). The page may need a sign-in, "
                + "show a paywall, or not be an article. Open it in a browser, save the article's text to a .txt "
                + "file, and pass that file to voiceislocal read.")
    }

    /// Waits for the main frame's latest navigation to finish loading, within one `loadTimeout` deadline (see
    /// `waitForLoad`). When the load wait runs out: a navigation that was allowed but never started (it stayed
    /// within the document) is dropped; a committed document that has been parsed is read anyway, and its loading
    /// is stopped; anything else (a navigation that never committed: DNS, TLS, a server that never answers; a
    /// page that does not say in the time left whether it was parsed) is a timeout. Until the first navigation
    /// commits, the web view shows its empty initial document, which is never read.
    private func awaitDocument(in webView: WKWebView, loader: PageLoader, requested: URL) async throws {
        let outcome = try await Self.waitForLoad(
            timeout: options.loadTimeout, start: .now, now: { .now },
            settle: { try await loader.waitUntilSettled(timeout: $0) },
            probe: { timeLeft in
                loader.dropUnstartedNavigation()
                if loader.phase == .loading,
                   try await self.documentState(of: webView, timeout: timeLeft) != "loading",
                   loader.phase == .loading {
                    webView.stopLoading()
                    loader.stoppedLoading()
                }
            })
        guard outcome == .timedOut else { return }
        try loader.check()
        guard loader.phase == .finished else {
            throw HolosError.unavailable("Timed out loading \(WebArticle.address(loader.destination ?? requested)).")
        }
    }

    /// One deadline shared by every wait of a phase: each wait gets the time left, never a fresh full timeout.
    struct Deadline: Sendable, Equatable {
        let end: ContinuousClock.Instant

        init(_ duration: Duration, from start: ContinuousClock.Instant = .now) {
            end = start + max(duration, .zero)
        }

        /// The time left at `now`, less `reserve` (kept for a later wait of the same phase); never negative.
        func remaining(at now: ContinuousClock.Instant = .now, reserving reserve: Duration = .zero) -> Duration {
            max((end - now) - max(reserve, .zero), .zero)
        }
    }

    /// The part of a phase's `timeout` kept, after the wait for a load, for one script in the page (the
    /// ready-state probe, or the conversion script): half, at most 2 s.
    nonisolated static func scriptReserve(for timeout: Duration) -> Duration {
        min(max(timeout, .zero) / 2, .seconds(2))
    }

    /// The load phase's waits under one deadline, `timeout` after `start`: `settle` waits for the load with the
    /// time left less `scriptReserve(for: timeout)`; when it times out, `probe` (the ready-state check) gets
    /// whatever is left of the same deadline, nothing more. Together they never get more than `timeout`, whatever
    /// either does with its share. `now` reads the clock (tests pass their own). Returns `settle`'s outcome.
    static func waitForLoad(timeout: Duration, start: ContinuousClock.Instant,
                            now: () -> ContinuousClock.Instant,
                            settle: (Duration) async throws -> PageLoader.Outcome,
                            probe: (Duration) async throws -> Void) async throws -> PageLoader.Outcome {
        let deadline = Deadline(timeout, from: start)
        let outcome = try await settle(deadline.remaining(at: now(), reserving: scriptReserve(for: timeout)))
        if outcome == .timedOut { try await probe(deadline.remaining(at: now())) }
        return outcome
    }

    /// When to read the page, as offsets from the moment loading ended: the first read after `settle`, then one
    /// every `settle` until `retryWindow` after the first read, with a last read exactly at that deadline. With
    /// the defaults (1 s, 6 s) that is 1, 2, … 7 s after loading.
    nonisolated static func attemptSchedule(settle: Duration, retryWindow: Duration) -> [Duration] {
        let first = max(settle, .zero)
        let deadline = first + max(retryWindow, .zero)
        var offsets = [first]
        if first > .zero {
            var next = first + first
            while next < deadline {
                offsets.append(next)
                next += first
            }
        }
        if let last = offsets.last, last < deadline { offsets.append(deadline) }
        return offsets
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        // WebKit's own user agent plus Safari's suffix, so sites serve the page they give desktop Safari.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configureWebView(configuration)
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 1600), configuration: configuration)
    }

    /// A script that did not finish within its time limit (the page's own scripts may be keeping it busy).
    struct ScriptTimeout: Error {}

    /// The document's `readyState`; "loading" when the page cannot say (a script error, or no answer in time).
    /// Cancellation is passed on.
    private func documentState(of webView: WKWebView, timeout: Duration) async throws -> String {
        do {
            return try await evaluate(Self.readyStateScript, webView, timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return "loading"
        }
    }

    /// Runs a function body in WebKit's client content world (the page's DOM, but not its scripts' globals) and
    /// returns the string it resolves to. Ends with `ScriptTimeout` after `timeout` (at once when no time is left),
    /// and with `CancellationError` as soon as the calling task is cancelled; WebKit's own completion is then
    /// ignored.
    static func run(_ body: String, in webView: WKWebView, timeout: Duration) async throws -> String {
        try Task.checkCancellation()
        guard timeout > .zero else { throw ScriptTimeout() }
        let result = OneShot<String>()
        webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .defaultClient) { outcome in
            result.resume(with: outcome.flatMap { value in
                guard let text = value as? String else {
                    return .failure(HolosError.unavailable("Article extraction returned no result."))
                }
                return .success(text)
            })
        }
        return try await result.wait(timeout: timeout, orElse: .failure(ScriptTimeout()))
    }

    private struct Payload: Decodable {
        struct RawBlock: Decodable {
            let level: Int
            let text: String
        }

        let found: Bool
        /// The address of the document read (`location.href`, read in the same script).
        var url: String? = nil
        /// The shortest `<meta http-equiv="refresh">` delay the document declares, in seconds.
        var refresh: Double? = nil
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
    /// captions, media, and forms are skipped; so are superscripts that hold only bracketed reference marks, one or
    /// several with optional separators: `<sup>[1]</sup>`, `<sup><a>[1]</a><a>[2]</a></sup>`, `<sup>[1], [2]</sup>`,
    /// `<sup>[a][note 3]</sup>`, `<sup>[citation needed]</sup>`.
    private static let blockWalker = #"""
    function holosArticleBlocks(root) {
      const citationMarks = /^\s*\[[^\[\]]*\](?:\s*[,;–—-]?\s*\[[^\[\]]*\])*\s*$/;
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
          if (child.nodeType === Node.TEXT_NODE || child.nodeType === Node.CDATA_SECTION_NODE) {
            buffer += child.data;
            continue;
          }
          if (child.nodeType !== Node.ELEMENT_NODE) continue;
          const tag = child.tagName.toUpperCase();
          if (skipInline.has(tag)) continue;
          if (skipBlock.has(tag)) { flush(); continue; }
          if (tag === "SUP" && citationMarks.test(child.textContent)) continue;
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
    /// of the page before Readability runs. The section is everything after such a heading in document order
    /// (elements, loose text, comments, across the ends of the elements that hold the heading) up to the next
    /// heading of the same or a higher level, wherever that heading sits, or else to the end of the nearest
    /// `article`, `main`, `aside`, or `nav` element holding the heading (the body when there is none). Elements
    /// the section only partly covers stay, with the part before the section (the article text before the
    /// heading, the part holding the next heading). The heading goes too, and so does each element that held it
    /// and is left with nothing meaningful (Wikipedia's `<div class="mw-heading">` once its edit link is gone, a
    /// `<div class="section-heading">`). Heading text is compared without bracketed marks (`[edit]`), leading
    /// section numbers, surrounding punctuation or symbols ("References:", "Notes.", "See also —",
    /// "References ¶"), and case.
    private static let backMatterRemover = #"""
    function holosDropBackMatter(doc) {
      const names = /^(references|notes|footnotes|citations|sources|bibliography|further reading|external links|see also|notes and references|references and notes|works cited)$/;
      const headings = "h1, h2, h3, h4, h5, h6";
      const labelOf = (text) => text
        .replace(/\[[^\]]*\]/g, " ")
        .replace(/&/g, " and ")
        .replace(/\s+/g, " ")
        .replace(/^[\s\p{P}\p{S}]+|[\s\p{P}\p{S}]+$/gu, "")
        .replace(/^\d+(?:\.\d+)*[.)]?\s+/u, "")
        .toLowerCase();
      // Letters and digits only, without bracketed marks: what a listener would hear.
      const meaningful = (text) => text.replace(/\[[^\]]*\]/g, "").replace(/[^\p{L}\p{N}]+/gu, "").toLowerCase();
      const levelOf = (heading) => Number(heading.localName[1]);
      const after = (node, other) =>
        (node.compareDocumentPosition(other) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0 && !node.contains(other);
      for (const heading of Array.from(doc.querySelectorAll(headings))) {
        if (!heading.isConnected) continue;
        if (!names.test(labelOf(heading.textContent))) continue;
        const level = levelOf(heading);
        const root = heading.closest("article, main, aside, nav") || doc.body || doc.documentElement;
        const end = Array.from(root.querySelectorAll(headings))
          .find((other) => levelOf(other) <= level && after(heading, other));
        // Everything between the heading and `end` in document order; a range leaves the elements it only
        // partly covers in place, emptied of the part it covers.
        const section = doc.createRange();
        section.setStartAfter(heading);
        if (end) section.setEndBefore(end); else section.setEnd(root, root.childNodes.length);
        section.deleteContents();
        let wrapper = heading.parentElement;
        heading.remove();
        while (wrapper && wrapper !== root && !meaningful(wrapper.textContent) && !wrapper.querySelector(headings)) {
          const outer = wrapper.parentElement;
          wrapper.remove();
          wrapper = outer;
        }
      }
    }
    """#

    static let readyStateScript = "return document.readyState;"

    private static let conversionScript = blockWalker + "\nreturn JSON.stringify(holosArticleBlocks(document.body));"

    /// The shortest refresh delay, in seconds, that the document's `<meta http-equiv="refresh">` elements declare;
    /// null when there is none.
    private static let refreshReader = #"""
    function holosRefreshDelay(doc) {
      let delay = null;
      for (const meta of doc.querySelectorAll("meta[http-equiv]")) {
        if ((meta.getAttribute("http-equiv") || "").trim().toLowerCase() !== "refresh") continue;
        const match = /^\s*(\d+(?:\.\d*)?|\.\d+)/.exec(meta.getAttribute("content") || "");
        if (!match) continue;
        const seconds = Number(match[1]);
        if (delay === null || seconds < delay) delay = seconds;
      }
      return delay;
    }
    """#

    /// Reads the document's address, refresh delay, and article in one synchronous pass (so they all describe
    /// the same document), then yields to the page's event loop once before answering: a navigation the page had
    /// already scheduled (a script redirect, a meta refresh whose timer is due) is then decided before the answer
    /// arrives, and the extractor sees it.
    private static let extractionScript = readabilitySource + "\n" + backMatterRemover + "\n" + blockWalker + "\n"
        + refreshReader + #"""

    const holosDocument = { url: location.href, refresh: holosRefreshDelay(document) };
    let holosResult;
    try {
      const page = document.cloneNode(true);
      holosDropBackMatter(page);
      const article = new Readability(page).parse();
      if (!article) {
        holosResult = { found: false, title: document.title };
      } else {
        const content = new DOMParser().parseFromString(article.content || "", "text/html");
        holosResult = {
          found: true, title: article.title, byline: article.byline, siteName: article.siteName,
          lang: article.lang, blocks: holosArticleBlocks(content.body)
        };
      }
    } catch (error) {
      holosResult = { found: false, error: String(error) };
    }
    await new Promise((resolve) => setTimeout(resolve, 0));
    return JSON.stringify(Object.assign(holosResult, holosDocument));
    """#
}

/// Follows every main-frame navigation of one web view (the first and any later one: script and meta-refresh
/// redirects, reloads) from its policy decision through start, commit, finish, or failure, and refuses error pages,
/// non-HTML documents, new windows, and any main-frame address whose scheme is not allowed (https): the first
/// request, server redirects, script and meta-refresh navigations, the response, and the committed and finished
/// page.
@MainActor final class PageLoader: NSObject, WKNavigationDelegate {
    enum Outcome: Sendable { case finished, timedOut }

    /// Where the main frame stands. Only `finished` shows a document that may be read.
    enum Phase: Sendable, Equatable {
        /// Nothing is shown and nothing is on its way (a request that never started).
        case idle
        /// A navigation was requested or allowed and has not started; the current document is on its way out.
        case deciding
        /// A navigation started and has not committed: the web view still shows the previous document and address.
        case provisional
        /// A document committed and is still loading.
        case loading
        /// The document shown finished loading, or its loading was stopped after it was parsed.
        case finished
    }

    /// A point in the main frame's history, to tell whether the page has moved since.
    struct Mark: Equatable {
        fileprivate let navigations: Int
        fileprivate let commits: Int
    }

    /// The schemes a main-frame document may have.
    let documentSchemes: Set<String>
    /// Whether a navigation was allowed (or requested) that has not started yet.
    private var deciding = false
    /// The navigation that started and has not committed or failed yet.
    private var provisional: WKNavigation?
    /// The navigation whose document is shown, and whether that document finished loading.
    private var shown: WKNavigation?
    private var hasShownDocument = false
    private var shownFinished = false
    /// Main-frame navigations allowed or started so far (one navigation may count more than once).
    private var navigations = 0
    /// Main-frame documents committed so far.
    private var commits = 0
    /// The `Refresh` header delay of the response on its way, and of the document shown.
    private var incomingRefreshHeader: Double?
    private(set) var refreshHeader: Double?
    /// Where the latest navigation is going, when known.
    private(set) var destination: URL?
    /// Why the page was refused, once it was.
    private(set) var rejection: HolosError?
    /// Why a navigation failed, once one did.
    private(set) var failure: HolosError?
    /// The wait in progress, if any.
    private var pending: OneShot<Outcome>?

    init(documentSchemes: Set<String> = ["https"]) {
        self.documentSchemes = documentSchemes
    }

    var phase: Phase {
        if provisional != nil { return .provisional }
        if deciding { return .deciding }
        guard hasShownDocument else { return .idle }
        return shownFinished ? .finished : .loading
    }

    var mark: Mark { Mark(navigations: navigations, commits: commits) }

    /// Whether the document shown when `mark` was taken may no longer be the one to read: a navigation was
    /// allowed, started, or committed since, or one is in progress.
    func moved(since mark: Mark) -> Bool { phase != .finished || self.mark != mark }

    /// Throws the refusal or failure, if there was one.
    func check() throws {
        if let rejection { throw rejection }
        if let failure { throw failure }
    }

    /// Starts the first navigation.
    func begin(_ start: () -> WKNavigation?) {
        deciding = true
        navigations += 1
        _ = start()
    }

    /// Starts the navigation and waits until it finishes, fails, or `timeout` passes.
    func load(timeout: Duration, start: () -> WKNavigation?) async throws -> Outcome {
        try Task.checkCancellation()
        begin(start)
        return try await waitUntilSettled(timeout: timeout)
    }

    /// Waits until the main frame shows a finished document with no navigation on its way (`finished`), a
    /// navigation fails or is refused (thrown), or `timeout` passes (`timedOut`). Cancelling the calling task ends
    /// the wait at once with `CancellationError` (the caller then stops the web view).
    func waitUntilSettled(timeout: Duration) async throws -> Outcome {
        try Task.checkCancellation()
        try check()
        if phase == .finished { return .finished }
        let wait = OneShot<Outcome>()
        pending = wait
        defer { pending = nil }
        return try await wait.wait(timeout: timeout, orElse: .success(.timedOut))
    }

    /// Forgets a navigation that was allowed but never started (it stayed within the document).
    func dropUnstartedNavigation() {
        if provisional == nil { deciding = false }
    }

    /// Records that the caller stopped the shown document's loading after it was parsed.
    func stoppedLoading() {
        shownFinished = true
    }

    /// Why a main-frame address may not be read, or nil when its scheme is allowed.
    func refusal(of url: URL?) -> HolosError? {
        Self.refusal(of: url, allowing: documentSchemes)
    }

    /// Why a main-frame address may not be read, or nil when it is an https address (or has a scheme in `schemes`).
    nonisolated static func refusal(of url: URL?, allowing schemes: Set<String> = ["https"]) -> HolosError? {
        if let scheme = url?.scheme?.lowercased(), schemes.contains(scheme) { return nil }
        let address = url.map(WebArticle.address) ?? "an unknown address"
        return .unavailable("The page moved to \(address), which is not https://. Only https pages are read.")
    }

    /// Whether a navigation only moves within the document shown (a fragment link), so no new document loads.
    nonisolated static func isSameDocument(_ request: URLRequest, type: WKNavigationType, shown: URL?) -> Bool {
        guard type != .reload, (request.httpMethod ?? "GET").uppercased() == "GET", let target = request.url,
              target.fragment != nil, let shown else { return false }
        func withoutFragment(_ url: URL) -> URL? {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return components?.url
        }
        return withoutFragment(target) == withoutFragment(shown)
    }

    /// The delay of a `Refresh` header value ("5" or "0; url=…"), in seconds.
    nonisolated static func refreshDelay(_ header: String?) -> Double? {
        guard let header, let match = header.prefixMatch(of: /\s*(\d+(?:\.\d*)?|\.\d+)/) else { return nil }
        return Double(match.1)
    }

    /// Ends a wait in progress when the frame settled.
    private func settleIfFinished() {
        if phase == .finished { pending?.resume(with: .success(.finished)) }
    }

    /// Records the first refusal, and ends a wait in progress with it.
    private func refuse(_ error: HolosError) {
        if rejection == nil { rejection = error }
        pending?.resume(with: .failure(rejection ?? error))
    }

    /// Records the first failure, and ends a wait in progress with it (or with the refusal that caused it).
    private func fail(_ error: HolosError) {
        if failure == nil { failure = error }
        pending?.resume(with: .failure(rejection ?? failure ?? error))
    }

    /// Refuses the page when the main frame's current address is not allowed; true when it was refused.
    @discardableResult private func refuseUnlessAllowed(_ webView: WKWebView) -> Bool {
        guard let refusal = refusal(of: webView.url) else { return false }
        refuse(refusal)
        webView.stopLoading()
        return true
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
    }

    // Answered synchronously (not with the async variant), so the navigation is recorded before WebKit hears the
    // answer: a script result that arrives after this decision sees the page moving.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // No new windows; subframes may load anything, since only the main frame's document is read.
        guard let frame = navigationAction.targetFrame else { return decisionHandler(.cancel) }
        guard frame.isMainFrame else { return decisionHandler(.allow) }
        if let refusal = refusal(of: navigationAction.request.url) {
            refuse(refusal)
            return decisionHandler(.cancel)
        }
        if !Self.isSameDocument(navigationAction.request, type: navigationAction.navigationType, shown: webView.url) {
            deciding = true
            navigations += 1
            destination = navigationAction.request.url
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        provisional = navigation
        deciding = false
        navigations += 1
        if destination == nil { destination = webView.url }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        destination = webView.url ?? destination
        refuseUnlessAllowed(webView)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse)
        async -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame else { return .allow }
        if let refusal = refusal(of: navigationResponse.response.url) {
            refuse(refusal)
            return .cancel
        }
        let address = navigationResponse.response.url.map(WebArticle.address) ?? "the page"
        let http = navigationResponse.response as? HTTPURLResponse
        if let http, http.statusCode >= 400 {
            refuse(.unavailable("\(address) answered HTTP \(http.statusCode) "
                + "(\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode)))."))
            return .cancel
        }
        let type = navigationResponse.response.mimeType?.lowercased() ?? "text/html"
        guard type == "text/html" || type == "application/xhtml+xml" else {
            refuse(.unavailable("\(address) is not a web page (\(WebArticle.sanitized(type))). "
                + "Download it and pass the file instead."))
            return .cancel
        }
        incomingRefreshHeader = Self.refreshDelay(http?.value(forHTTPHeaderField: "Refresh"))
        return .allow
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Any decision made before this commit belonged to this navigation (a server redirect) or is superseded:
        // a navigation decided later starts after it.
        provisional = nil
        deciding = false
        shown = navigation
        hasShownDocument = true
        shownFinished = false
        commits += 1
        refreshHeader = incomingRefreshHeader
        incomingRefreshHeader = nil
        refuseUnlessAllowed(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A document replaced since (a later navigation committed) no longer counts.
        guard navigation === shown else { return }
        if refuseUnlessAllowed(webView) { return }
        shownFinished = true
        settleIfFinished()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        // The shown document's loading ended early.
        guard navigation === shown else { return }
        if Self.isCancellation(error), rejection == nil {
            // Stopped (by the page, or by a navigation that replaces it): the document is what it is.
            shownFinished = true
            settleIfFinished()
            return
        }
        fail(.unavailable("Could not load the page: \(WebArticle.sanitized(error.localizedDescription))"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        // A navigation replaced by a later one before it committed no longer counts.
        guard navigation === provisional else { return }
        provisional = nil
        if Self.isCancellation(error), rejection == nil {
            // Cancelled without a refusal: a later navigation replaces it (then `deciding` is set), or the frame
            // stays on the document it shows.
            if phase == .idle { fail(.unavailable("Could not load the page: the load was cancelled.")) }
            settleIfFinished()
            return
        }
        fail(.unavailable("Could not load the page: \(WebArticle.sanitized(error.localizedDescription))"))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail(.unavailable("The web page's content process stopped while loading."))
    }
}

/// A result awaited once. The first `resume` wins, from any thread, before or after the wait begins; later ones
/// are ignored. Cancelling the waiting task ends the wait with `CancellationError`, even when the task was
/// cancelled before the wait began.
final class OneShot<Value: Sendable>: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<Value, any Error>)
        case delivered(Result<Value, any Error>)
        case done
    }

    private let state = Mutex(State.idle)

    /// Waits for the result. Call once.
    func wait() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let early: Result<Value, any Error>? = state.withLock { state in
                    guard case .delivered(let result) = state else {
                        state = .waiting(continuation)
                        return nil
                    }
                    state = .done
                    return result
                }
                if let early { continuation.resume(with: early) }
            }
        } onCancel: {
            resume(with: .failure(CancellationError()))
        }
    }

    /// Waits for the result, which becomes `timedOut` when nothing else arrives within `timeout`.
    func wait(timeout: Duration, orElse timedOut: Result<Value, any Error>) async throws -> Value {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.resume(with: timedOut)
        }
        defer { timer.cancel() }
        return try await wait()
    }

    func resume(with result: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Value, any Error>? = state.withLock { state in
            switch state {
            case .idle:
                state = .delivered(result)
                return nil
            case .waiting(let continuation):
                state = .done
                return continuation
            case .delivered, .done:
                return nil
            }
        }
        continuation?.resume(with: result)
    }
}
