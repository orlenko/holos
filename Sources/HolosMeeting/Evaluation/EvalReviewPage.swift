import Foundation
import HolosCore
import HolosStorage

/// `voiceislocal eval review` (docs/reference-evaluation.md, "Cloud reference"): one self-contained HTML page to
/// decide, passage by passage, what was said. It loads nothing from the network (a Content-Security-Policy blocks
/// connections); its audio is `review-audio/<track>.m4a` next to it; decisions stay in the browser's localStorage
/// and are exported as decisions.json for `voiceislocal eval apply`.
public enum EvalReviewPage {
    /// One passage as the page shows it. Times are in the review audio (`renderStart`), which has pauses over 60 s
    /// shortened, and in the session (`start`, shown).
    public struct Item: Codable, Sendable, Equatable {
        public var id: String
        public var track: String
        public var start: Double
        public var renderStart: Double
        public var renderEnd: Double
        public var local: String
        public var cloud: String
        public var group: String
        public var groupTitle: String
        public var before: String
        public var after: String
        public var cloudBefore: String
        public var cloudAfter: String
    }

    public struct PageData: Codable, Sendable, Equatable {
        public var schemaVersion = 1
        public var sessionID: String
        public var sessionName: String
        public var run: String
        public var model: String
        public var transcriptID: String
        /// Track name → audio path relative to the page.
        public var audio: [String: String]
        public var items: [Item]
    }

    /// The page's data: the report's word passages (case/punctuation-only ones are left to report.md), in time order.
    public static func pageData(report: CompareReport, run: CloudRunRecord, sessionName: String) -> PageData {
        let maps = Dictionary(run.tracks.map { ($0.track, $0.timeMap) }, uniquingKeysWith: { first, _ in first })
        let items = report.passages.filter { $0.group != .caseOrPunctuation }
            .sorted { ($0.start, $0.track, $0.id) < ($1.start, $1.track, $1.id) }
            .map { passage in
                let map = maps[passage.track] ?? []
                return Item(id: passage.id, track: passage.track, start: passage.start,
                            renderStart: EvalTimeMap.renderTime(passage.start, map: map),
                            renderEnd: EvalTimeMap.renderTime(passage.end, map: map), local: passage.local,
                            cloud: passage.cloud, group: passage.group.rawValue, groupTitle: passage.group.title,
                            before: passage.before, after: passage.after, cloudBefore: passage.cloudBefore,
                            cloudAfter: passage.cloudAfter)
            }
        return PageData(sessionID: report.sessionID, sessionName: sessionName, run: report.run, model: report.model,
                        transcriptID: report.transcriptID,
                        audio: Dictionary(uniqueKeysWithValues: run.tracks.map { ($0.track, "review-audio/\($0.track).m4a") }),
                        items: items)
    }

    /// The HTML page for `data`. Transcript text is only ever set as text (never parsed as HTML), and the embedded
    /// JSON has "<" escaped, so no transcript can close the script element.
    public static func html(_ data: PageData) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(data), as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return template.replacingOccurrences(of: "__REVIEW_DATA__", with: json)
    }

    static let template = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="icon" href="data:,">
<meta http-equiv="Content-Security-Policy" content="connect-src 'none'; form-action 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'">
<title>Transcript review</title>
<style>
:root { --bg:#fbfbfa; --fg:#1d1d1f; --muted:#6e6e73; --line:#e3e3e0; --card:#fff; --accent:#0a66d8;
  --local:#8a4b00; --cloud:#00655c; --chosen:#e8f1fd; --warn:#8a1c12; --warn-bg:#fde8e6; }
@media (prefers-color-scheme: dark) { :root { --bg:#161617; --fg:#f2f2f2; --muted:#a1a1a6; --line:#343436;
  --card:#1f1f21; --accent:#5aa2ff; --local:#f0b36a; --cloud:#6fd6c8; --chosen:#1d3450; --warn:#ffb4a9;
  --warn-bg:#4a1d18; } }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.45 -apple-system, system-ui, sans-serif; }
header { position:sticky; top:0; z-index:2; background:var(--bg); border-bottom:1px solid var(--line); padding:10px 16px; }
header h1 { font-size:17px; margin:0 0 4px; }
.bar { display:flex; flex-wrap:wrap; gap:8px; align-items:center; color:var(--muted); font-size:13px; }
.bar audio { height:30px; max-width:100%; }
main { display:grid; grid-template-columns:minmax(0,1fr) 260px; gap:16px; padding:16px; max-width:1200px; margin:0 auto; }
@media (max-width: 800px) { main { grid-template-columns:1fr; } }
.card { background:var(--card); border:1px solid var(--line); border-radius:8px; padding:10px 12px; margin-bottom:10px; }
.card.current { outline:2px solid var(--accent); }
.card.decided { opacity:.8; }
.meta { display:flex; gap:8px; align-items:center; font-size:12px; color:var(--muted); margin-bottom:6px; }
.meta button.play { font-size:12px; }
.badge { border:1px solid var(--line); border-radius:10px; padding:0 6px; }
.row { display:grid; grid-template-columns:52px 1fr; gap:6px; margin:2px 0; }
.row .label { font-size:12px; color:var(--muted); padding-top:2px; }
.ctx { color:var(--muted); }
.local b { color:var(--local); } .cloud b { color:var(--cloud); }
textarea { width:100%; font:inherit; padding:4px 6px; border:1px solid var(--line); border-radius:6px;
  background:var(--bg); color:var(--fg); resize:vertical; min-height:32px; }
.choices { display:flex; gap:6px; margin-top:6px; }
button { font:inherit; font-size:13px; border:1px solid var(--line); background:var(--card); color:var(--fg);
  border-radius:6px; padding:2px 10px; cursor:pointer; }
button.on { background:var(--chosen); border-color:var(--accent); }
aside .panel { position:sticky; top:90px; background:var(--card); border:1px solid var(--line); border-radius:8px; padding:10px 12px; }
aside h2 { font-size:14px; margin:0 0 6px; }
aside ul { list-style:none; padding:0; margin:6px 0; }
aside li { display:flex; justify-content:space-between; gap:6px; padding:2px 0; }
.help { font-size:12px; color:var(--muted); margin-top:10px; }
kbd { border:1px solid var(--line); border-radius:3px; padding:0 3px; font-size:11px; }
.warning { margin-top:6px; padding:4px 8px; border-radius:6px; background:var(--warn-bg); color:var(--warn);
  font-size:13px; font-weight:600; }
</style>
</head>
<body>
<header>
  <h1 id="title">Transcript review</h1>
  <div class="bar">
    <span id="progress"></span>
    <span id="player"></span>
    <button id="export">Export decisions</button>
  </div>
  <div id="warning" class="warning" role="alert" hidden></div>
</header>
<main>
  <section id="list"></section>
  <aside><div class="panel">
    <h2>Terms</h2>
    <div>Select words on the page, then <button id="addTerm">Add term</button> (<kbd>t</kbd>)</div>
    <ul id="terms"></ul>
    <div class="help"><kbd>j</kbd>/<kbd>k</kbd> next/previous · <kbd>1</kbd> local · <kbd>2</kbd> cloud ·
      <kbd>e</kbd> edit (<kbd>Esc</kbd> to leave) · <kbd>space</kbd> play · <kbd>t</kbd> add selected term.
      The "Correct" text is what the passage becomes; it starts as the cloud version. Decisions are kept in this
      browser; export them for <code>voiceislocal eval apply</code>.</div>
  </div></aside>
</main>
<script id="review-data" type="application/json">__REVIEW_DATA__</script>
<script>
(function () {
  "use strict";
  var data = JSON.parse(document.getElementById("review-data").textContent);
  var storageKey = "voiceislocal-review:" + data.run + ":" + data.transcriptID;
  // BEGIN review-store
  // Decisions live in localStorage, each passage's under a key of its own ("<key>|d|<id>") and each term's too
  // ("<key>|t|<term in lower case>", a removed one marked removed), so a change writes only its own key and two
  // tabs of this page never save over each other's work (never read, change, and write back one shared value).
  // The page's own state is what counts: a change that could not be stored (storage full or blocked) stays
  // pending, is tried again with the next change, and is applied on top of whatever is read later, so no later
  // edit or other tab's save can drop it; the page warns until it is stored, and Export writes it out either way.
  // Decisions a page kept before (everything under the key itself) are read too, under the newer ones.
  function makeStore(storage, key) {
    var decisionPrefix = key + "|d|", termPrefix = key + "|t|";
    var store = { state: { decisions: {}, terms: [] }, failed: false, pending: [] };
    var sequence = 0;
    function parse(text) {
      try { return JSON.parse(text); } catch (e) { return null; }
    }
    function read() {
      try {
        var decisions = {}, marks = {};
        var legacy = parse(storage.getItem(key));
        if (legacy && typeof legacy === "object") {
          if (legacy.decisions && typeof legacy.decisions === "object") {
            Object.keys(legacy.decisions).forEach(function (id) { decisions[id] = legacy.decisions[id]; });
          }
          if (Array.isArray(legacy.terms)) {
            legacy.terms.forEach(function (term, index) {
              if (typeof term === "string") marks[term.toLowerCase()] = { text: term, at: index - 1e15 };
            });
          }
        }
        for (var i = 0; i < storage.length; i++) {
          var name = storage.key(i);
          if (typeof name !== "string") continue;
          var value;
          if (name.indexOf(decisionPrefix) === 0) {
            value = parse(storage.getItem(name));
            if (value && typeof value === "object") decisions[name.slice(decisionPrefix.length)] = value;
          } else if (name.indexOf(termPrefix) === 0) {
            value = parse(storage.getItem(name));
            if (value && typeof value === "object" && typeof value.text === "string") {
              marks[name.slice(termPrefix.length)] = value;
            }
          }
        }
        var terms = Object.keys(marks).map(function (k) { return marks[k]; })
          .filter(function (mark) { return !mark.removed; })
          .sort(function (a, b) { return (Number(a.at) || 0) - (Number(b.at) || 0); })
          .map(function (mark) { return mark.text; });
        return { decisions: decisions, terms: terms };
      } catch (e) {
        return null;
      }
    }
    function apply(op, state) {
      if (op.kind === "decide") {
        state.decisions[op.id] = op.value;
      } else {
        var lower = op.text.toLowerCase();
        state.terms = state.terms.filter(function (t) { return String(t).toLowerCase() !== lower; });
        if (!op.removed) state.terms.push(op.text);
      }
    }
    function keyOf(op) {
      return op.kind === "decide" ? decisionPrefix + op.id : termPrefix + op.text.toLowerCase();
    }
    function write(op) {
      storage.setItem(keyOf(op), JSON.stringify(op.kind === "decide" ? op.value
                                                : { text: op.text, at: op.at, removed: !!op.removed }));
    }
    function merged() {
      var fresh = read();
      if (!fresh) return null;
      store.pending.forEach(function (op) { apply(op, fresh); });
      return fresh;
    }
    function change(op) {
      // Only the latest change of a key is kept: an older one that could not be stored never comes back.
      var slot = keyOf(op);
      store.pending = store.pending.filter(function (pending) { return keyOf(pending) !== slot; });
      store.pending.push(op);
      var left = [];
      store.pending.forEach(function (pending) {
        try { write(pending); } catch (e) { left.push(pending); }
      });
      store.pending = left;
      store.failed = left.length > 0;
      var fresh = merged();
      if (fresh) { store.state = fresh; } else { apply(op, store.state); }
    }
    store.decide = function (id, choice, text) {
      change({ kind: "decide", id: id, value: { choice: choice, text: text } });
    };
    store.addTerm = function (text) { change({ kind: "term", text: text, at: Date.now() + (sequence++) / 1000 }); };
    store.removeTerm = function (text) { change({ kind: "term", text: text, at: Date.now(), removed: true }); };
    // Another tab saved: take what is stored, with this page's unsaved changes on top.
    store.reload = function () {
      var fresh = merged();
      if (fresh) store.state = fresh;
    };
    var initial = read();
    if (initial) { store.state = initial; } else { store.failed = true; }
    return store;
  }
  // END review-store
  var storage;
  try { storage = window.localStorage; } catch (e) { storage = null; }
  if (!storage) {
    var blocked = function () { throw new Error("no storage"); };
    storage = { length: 0, key: blocked, getItem: blocked, setItem: blocked };
  }
  var store = makeStore(storage, storageKey);
  var state = store.state;
  var changes = 0, exported = 0;
  function unsaved() { return store.failed || store.pending.length > 0; }
  function changed() {
    state = store.state;
    changes += 1;
    refreshAll();
  }
  window.addEventListener("storage", function (e) {
    if (e.key !== null && e.key !== storageKey && String(e.key).indexOf(storageKey + "|") !== 0) return;
    store.reload();
    state = store.state;
    refreshAll();
  });
  window.addEventListener("beforeunload", function (e) {
    if (store.pending.length > 0 && changes !== exported) { e.preventDefault(); e.returnValue = ""; }
  });
  function refreshAll() {
    cards.forEach(function (c) { c.show(); });
    showTerms();
    progress();
  }
  function el(tag, attrs, text) {
    var node = document.createElement(tag);
    if (attrs) for (var k in attrs) node.setAttribute(k, attrs[k]);
    if (text !== undefined) node.textContent = text;
    return node;
  }
  function clock(s) {
    s = Math.max(0, Math.floor(s));
    var h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, sec = s % 60;
    var mm = (h > 0 && m < 10 ? "0" : "") + m, ss = (sec < 10 ? "0" : "") + sec;
    return (h > 0 ? h + ":" : "") + mm + ":" + ss;
  }

  document.getElementById("title").textContent = "Review: " + data.sessionName;
  document.title = "Review: " + data.sessionName;

  var audios = {};
  var player = document.getElementById("player");
  Object.keys(data.audio).sort().forEach(function (track) {
    var audio = el("audio", { controls: "", preload: "metadata", src: data.audio[track], title: track });
    audio.style.display = "none";
    audios[track] = audio;
    player.appendChild(audio);
  });
  var stopAt = null, playing = null;
  function play(item) {
    var audio = audios[item.track];
    if (!audio) return;
    Object.keys(audios).forEach(function (t) {
      audios[t].style.display = t === item.track ? "" : "none";
      if (t !== item.track) audios[t].pause();
    });
    audio.currentTime = Math.max(0, item.renderStart - 1.5);
    stopAt = item.renderEnd + 1.5;
    playing = audio;
    var promise = audio.play();
    if (promise && promise.catch) promise.catch(function () {});
  }
  Object.keys(audios).forEach(function (t) {
    audios[t].addEventListener("timeupdate", function () {
      if (playing === audios[t] && stopAt !== null && audios[t].currentTime >= stopAt) {
        audios[t].pause(); stopAt = null;
      }
    });
  });

  var cards = [];
  var current = 0;
  var list = document.getElementById("list");
  data.items.forEach(function (item, index) {
    var card = el("div", { "class": "card", "data-id": item.id });
    var meta = el("div", { "class": "meta" });
    var playButton = el("button", { "class": "play", title: "Play (space)" }, "▶ " + clock(item.start));
    playButton.addEventListener("click", function () { select(index); play(item); });
    meta.appendChild(playButton);
    meta.appendChild(el("span", { "class": "badge" }, item.track));
    meta.appendChild(el("span", { "class": "badge" }, item.groupTitle));
    card.appendChild(meta);
    function line(label, cls, text, before, after) {
      var row = el("div", { "class": "row " + cls });
      row.appendChild(el("div", { "class": "label" }, label));
      var body = el("div");
      if (before) body.appendChild(el("span", { "class": "ctx" }, "…" + before + " "));
      body.appendChild(el("b", null, text || "—"));
      if (after) body.appendChild(el("span", { "class": "ctx" }, " " + after + "…"));
      row.appendChild(body);
      return row;
    }
    card.appendChild(line("Local", "local", item.local, item.before, item.after));
    card.appendChild(line("Cloud", "cloud", item.cloud, item.cloudBefore, item.cloudAfter));
    var correct = el("div", { "class": "row" });
    correct.appendChild(el("div", { "class": "label" }, "Correct"));
    var area = el("textarea", { rows: "1", "aria-label": "Correct text" });
    correct.appendChild(area);
    card.appendChild(correct);
    var choices = el("div", { "class": "choices" });
    var buttons = {
      local: el("button", { title: "1" }, "Local"),
      cloud: el("button", { title: "2" }, "Cloud"),
      edited: el("button", { title: "e" }, "Edited")
    };
    Object.keys(buttons).forEach(function (k) { choices.appendChild(buttons[k]); });
    card.appendChild(choices);
    list.appendChild(card);

    var entry = { item: item, card: card, area: area, buttons: buttons };
    function show() {
      var d = state.decisions[item.id];
      var text = d && typeof d.text === "string" ? d.text : item.cloud;
      // Never rewrite the field while it is being typed in (the caret would jump).
      if (document.activeElement !== area && area.value !== text) area.value = text;
      Object.keys(buttons).forEach(function (k) { buttons[k].classList.toggle("on", !!d && d.choice === k); });
      card.classList.toggle("decided", !!d);
    }
    entry.show = show;
    entry.choose = function (choice) {
      var text = choice === "local" ? item.local : choice === "cloud" ? item.cloud : area.value;
      if (choice !== "edited") area.value = text;
      store.decide(item.id, choice, text);
      changed();
    };
    buttons.local.addEventListener("click", function () { select(index); entry.choose("local"); });
    buttons.cloud.addEventListener("click", function () { select(index); entry.choose("cloud"); });
    buttons.edited.addEventListener("click", function () { select(index); area.focus(); entry.choose("edited"); });
    area.addEventListener("focus", function () { select(index, true); });
    // A change another tab made while the field was being typed in shows once it is left, so the field always
    // ends up showing what Export writes.
    area.addEventListener("blur", function () {
      if (document.activeElement === area) return;
      show();
    });
    area.addEventListener("input", function () { entry.choose("edited"); });
    card.addEventListener("click", function () { select(index, true); });
    show();
    cards.push(entry);
  });
  if (!cards.length) list.appendChild(el("p", null, "The two transcripts agree word for word; nothing to review."));

  function select(index, keepScroll) {
    if (!cards.length) return;
    current = Math.max(0, Math.min(cards.length - 1, index));
    cards.forEach(function (c, i) { c.card.classList.toggle("current", i === current); });
    if (!keepScroll) cards[current].card.scrollIntoView({ block: "center" });
  }
  function progress() {
    var done = cards.filter(function (c) { return state.decisions[c.item.id]; }).length;
    document.getElementById("progress").textContent = done + " of " + cards.length + " passages decided · run " + data.run;
    var warning = document.getElementById("warning");
    warning.textContent = unsaved() ? "Not saved in this browser (storage is full or blocked): your decisions are "
      + "kept while this page stays open. Export them before closing it." : "";
    warning.hidden = !unsaved();
  }

  var termList = document.getElementById("terms");
  function showTerms() {
    termList.textContent = "";
    state.terms.forEach(function (term) {
      var li = el("li");
      li.appendChild(el("span", null, term));
      var remove = el("button", { title: "Remove" }, "×");
      remove.addEventListener("click", function () {
        store.removeTerm(term);
        changed();
      });
      li.appendChild(remove);
      termList.appendChild(li);
    });
  }
  function addTerm() {
    var text = "";
    var active = document.activeElement;
    if (active && active.tagName === "TEXTAREA" && active.selectionStart !== active.selectionEnd) {
      text = active.value.substring(active.selectionStart, active.selectionEnd);
    } else {
      text = String(window.getSelection ? window.getSelection() : "");
    }
    text = text.replace(/\s+/g, " ").trim();
    if (!text || text.length > 100) return;
    var lower = text.toLowerCase();
    if (state.terms.some(function (t) { return String(t).toLowerCase() === lower; })) return;
    store.addTerm(text);
    changed();
  }
  document.getElementById("addTerm").addEventListener("mousedown", function (e) { e.preventDefault(); });
  document.getElementById("addTerm").addEventListener("click", addTerm);

  document.getElementById("export").addEventListener("click", function () {
    var decisions = data.items.filter(function (item) { return state.decisions[item.id]; }).map(function (item) {
      var d = state.decisions[item.id];
      return { id: item.id, choice: d.choice, text: d.text };
    });
    var out = { schemaVersion: 1, sessionID: data.sessionID, run: data.run, transcriptID: data.transcriptID,
                exportedAt: new Date().toISOString(), decisions: decisions, terms: state.terms };
    var blob = new Blob([JSON.stringify(out, null, 2) + "\n"], { type: "application/json" });
    var link = el("a", { download: "decisions.json" });
    link.href = URL.createObjectURL(blob);
    document.body.appendChild(link);
    link.click();
    setTimeout(function () { URL.revokeObjectURL(link.href); link.remove(); }, 1000);
    exported = changes;
  });

  document.addEventListener("keydown", function (e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    var inText = e.target && e.target.tagName === "TEXTAREA";
    if (inText) {
      if (e.key === "Escape") { e.target.blur(); e.preventDefault(); }
      return;
    }
    // A focused button keeps its own Space and Enter (buttons in the passages give up focus when clicked).
    if (e.target && e.target.tagName === "BUTTON" && (e.key === " " || e.key === "Enter")) return;
    if (!cards.length) return;
    var entry = cards[current];
    switch (e.key) {
      case "j": select(current + 1); break;
      case "k": select(current - 1); break;
      case "1": entry.choose("local"); break;
      case "2": entry.choose("cloud"); break;
      case "e": entry.area.focus(); entry.area.select(); break;
      case "t": addTerm(); break;
      case " ":
        if (playing && !playing.paused) { playing.pause(); } else { play(entry.item); }
        break;
      default: return;
    }
    e.preventDefault();
  });
  document.addEventListener("click", function (e) {
    var button = e.target && e.target.closest ? e.target.closest("button") : null;
    if (button && button.closest(".card")) button.blur();
  });

  showTerms();
  progress();
  select(0, true);
})();
</script>
</body>
</html>
"""#
}
