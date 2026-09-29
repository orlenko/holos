import Foundation
import Testing
@testable import HolosCore

// Spoken paths and commands written as code: the grammar, the verifier of the model's reply, the runs found without
// the model, and streaming.

// MARK: - Grammar

@Test(arguments: [
    "./scripts/restart-app.sh", "/qc", ".zshrc", ".local/bin", "--no-parallel", "~/.config/ghostty/config",
    "HOLOS_AIFIX_MODEL_TESTS=1", "src\\app.js", "*.swift", "a+b", "$HOME", "#channel", "cat|grep", "host:8080",
    "team@example.com", "../x", "v2.1",
])
func aTokenIsSaidByItsVerbalization(_ token: String) {
    #expect(SpokenCode.says(token, SpokenCode.verbalize(token)[...]), "\(SpokenCode.verbalize(token))")
    #expect(SpokenCode.says(token, SpokenCode.verbalize(token, spelling: true)[...]),
            "\(SpokenCode.verbalize(token, spelling: true))")
}

@Test func verbalizingSaysSymbolsByTheirWords() {
    #expect(SpokenCode.verbalize("./scripts/restart-app.sh") == "dot slash scripts slash restart dash app dot sh")
    #expect(SpokenCode.verbalize("/qc", spelling: true) == "slash Q C")
}

@Test(arguments: [
    ("./scripts/restart-app.sh", "dot slash scripts slash restart dash app dot S. H."),
    ("scripts/restart-app.sh", "scripts slash restart dash app dot es aytch"),
    ("/qc", "slash Q C"),
    ("/qc", "slash Q. C."),
    ("/qc", "slash QC"),
    (".zshrc", "dot ZHRC"),
    (".local/bin", "dot local slash bin"),
    ("--no-parallel", "dash dash no dash parallel"),
    ("--no-parallel", "double dash no hyphen parallel"),
    ("~/.config", "tilde slash dot config"),
    ("TranscriptFixer.swift", "transcript fixer dot swift"),
    ("HOLOS_AIFIX=1", "H O L O S underscore A I F I X equals one"),
    ("vlad@example.com", "vlad at example dot com"),
    ("README.md", "README dot MD"),
    ("scripts/restart-app.sh", "scripts/restart dash app dot sh"),
    ("/wq", "slash double you Q"),
    ("~/notes_v2", "tilde slash notes underscore v two"),
    ("src/app.js", "src barre oblique app point js"),
    ("mon_fichier.txt", "mon tiret bas fichier point txt"),
    ("x/y", "x forward slash y"),
    ("résumé.txt", "résumé dot txt"),
])
func aSpokenFormSaysItsToken(_ token: String, _ spoken: String) {
    #expect(SpokenCode.accepts(token, for: spoken[...]), "\(token) ← \(spoken)")
}

@Test(arguments: [
    // A symbol that was not said, one said that is missing, or a reordering.
    ("./scripts/restart-app.sh", "scripts slash restart dash app dot es aytch"),
    ("scripts/restart-app", "scripts slash restart dash app dot es aytch"),
    ("restart/scripts-app.sh", "scripts slash restart dash app dot es aytch"),
    ("source/holos/core", "source slash holos core"),
    ("transcript_fixer.swift", "transcript fixer dot swift"),
    ("--u", "dash U"),
    // Letters off by one in an ordinary word, or in a short run.
    ("/help", "slash yelp"),
    ("/qd", "slash Q C"),
    (".zsh", "dot ZHR"),
    // No symbol word: only wrapping what was written.
    ("e.g.", "e.g."),
    ("/tmp/x", "/tmp/x"),
    // Function words alone, no letter, "@" at an edge, a space.
    ("/the", "slash the"),
    (".a", "dot a"),
    ("2+2=4", "two plus two equals four"),
    ("@home", "at home"),
    ("/the price", "slash the price"),
    ("git push -u", "git push dash U"),
    // Words the token does not have.
    ("/qc", "slash Q C now"),
    ("/qc", "the slash Q C"),
    (".local/bin", "dot local, slash bin"),
    ("fourwordsjoinedhere.txt", "four words joined here dot txt"),
    // A spelled letter's mark is not the token's dot, and a written dot is not a spelled letter's mark.
    ("restart-app.sh.", "restart dash app dot S. H."),
    ("/q.c.", "slash Q. C."),
    ("/ab", "slash a.b"),
    // A weak symbol word alone.
    ("back@noon", "back at noon"),
    ("a+b", "a plus b"),
    // Accents are letters, and a function word is a whole part or none.
    ("resume.txt", "résumé dot txt"),
    ("/theprice", "slash the price"),
])
func aReplyTokenThatWasNotSaidIsRefused(_ token: String, _ spoken: String) {
    #expect(!SpokenCode.accepts(token, for: spoken[...]), "\(token) ← \(spoken)")
}

@Test func frenchFunctionWordsAloneAreNotCode() {
    #expect(!SpokenCode.accepts("/à", for: "barre oblique à", language: "fr-CA"))
    #expect(!SpokenCode.accepts("/été", for: "slash été", language: "fr-CA"))
    #expect(SpokenCode.accepts("/aide", for: "barre oblique aide", language: "fr-CA"))
}

// MARK: - The model's reply

private func formatter(backticks: Bool = true, corrections: CorrectionList = CorrectionList(),
                       reply: @escaping @Sendable (String) -> String) -> SpokenCodeFormatter {
    SpokenCodeFormatter(backticks: backticks, language: "en-US", corrections: corrections, timeout: .seconds(30)) {
        _, prompt in reply(String(prompt.dropFirst("Text: ".count)))
    }
}

private func formatted(_ text: String, reply: String, backticks: Bool = true,
                       corrections: CorrectionList = CorrectionList()) async -> SpokenCodeFormatter.Result {
    await formatter(backticks: backticks, corrections: corrections, reply: { _ in reply }).format(text)
}

@Test func theUsersExamplesAreAccepted() async {
    var result = await formatted(
        "So in my dot ZHRC file, there's a command that exports the path variable and adds dot local slash bin into it.",
        reply: "So in my `.zshrc` file, there's a command that exports the path variable and adds `.local/bin` into it.")
    #expect(result == .init(
        text: "So in my `.zshrc` file, there's a command that exports the path variable and adds `.local/bin` into it.",
        outcome: .model, spans: 2, tokens: ["`.zshrc`", "`.local/bin`"]))
    result = await formatted("I ran the script dot slash scripts slash restart dash app dot S. H.",
                             reply: "I ran the script `./scripts/restart-app.sh`")
    #expect(result.text == "I ran the script `./scripts/restart-app.sh`")
    result = await formatted("I ran the script dot slash scripts slash restart dash app dot S. H.",
                             reply: "I ran the script `./scripts/restart-app.sh`.")
    #expect(result.text == "I ran the script `./scripts/restart-app.sh`.")
    result = await formatted("Execute slash Q. C.", reply: "Execute `/qc`")
    #expect(result.text == "Execute `/qc`")
}

@Test func onlyTheTokensComeFromTheReply() async {
    // Runs of spaces may differ; the text around the spans is the chunk's own.
    let result = await formatted("adds  dot local slash bin into it", reply: "adds `.local/bin` into it")
    #expect(result.text == "adds  `.local/bin` into it")
}

@Test(arguments: [
    // Prose changed, a word added or dropped, a capital, punctuation.
    ("We need to slash the price.", "We need to cut the price."),
    ("adds dot local slash bin into it", "adds `.local/bin` to it"),
    ("adds dot local slash bin into it", "Adds `.local/bin` into it"),
    ("adds dot local slash bin into it", "adds `.local/bin` into it."),
    ("Set H O L O S underscore X equals one.", "Set HOLOS_X equals one."),
    // Unbalanced backticks.
    ("adds dot local slash bin into it", "adds `.local/bin into it"),
    // A span cut out of a word.
    ("Open slash tmpfile.", "Open `/tmp`file."),
    // Two spans where the chunk has text for one.
    ("slash tmp", "`/tmp``/other`"),
])
func aReplyThatChangesProseIsRefused(_ text: String, _ reply: String) async {
    let result = await formatted(text, reply: reply)
    #expect(result.outcome == .rejected)
    // Runs found without the model may still apply; none of these has one.
    #expect(result.text == text)
}

@Test func aRefusedSpanIsReadWithoutTheModelOrLeftAsSaid() async {
    // An added "./": the span's own words, read without the model.
    var result = await formatted("I ran the script scripts slash restart dash app dot es aytch and it worked.",
                                 reply: "I ran the script `./scripts/restart-app.sh` and it worked.")
    #expect(result.text == "I ran the script `scripts/restart-app.sh` and it worked.")
    #expect(result.spans == 1)
    // "the dash": no word on either side.
    result = await formatted("before the dash to the finish, run dash dash verbose",
                             reply: "before the `-` to the finish, run `--verbose`")
    #expect(result.text == "before the dash to the finish, run `--verbose`")
    // A two-word part and an underscore that was not said.
    result = await formatted("Open source slash holos core slash transcript fixer dot swift.",
                             reply: "Open `source/holos/core/transcript_fixer.swift`.")
    #expect(result.text == "Open source slash holos core slash transcript fixer dot swift.")
    // A whole command in backticks.
    result = await formatted("Use git push dash U origin main.", reply: "Use `git push --u origin main`.")
    #expect(result.text == "Use git push dash U origin main.")
}

@Test func aWrittenDotIsNeverASpelledLettersMark() async {
    // "S.file" keeps its dot however the span is cut.
    let result = await formatted("Open slash S.file", reply: "Open `/s`file")
    #expect(result.text == "Open slash S.file")
}

@Test func textAlreadyInBackticksStaysAndTheModelFormatsAroundIt() async {
    let result = await formatted("Open `README.md`, then run slash Q C.",
                                 reply: "Open 'README.md', then run `/qc`.")
    #expect(result.text == "Open `README.md`, then run `/qc`.")
    // The model may not wrap the quoted text itself.
    let wrapped = await formatted("Open `README.md` then slash Q C", reply: "Open `README.md` then `/qc`")
    #expect(wrapped.text == "Open `README.md` then `/qc`")
}

@Test func aTerminalTokenTakesTheSentencesMark() async {
    let result = await formatted("cd tilde slash dot config.", reply: "cd `~/.config`.", backticks: false)
    #expect(result.text == "cd ~/.config")
    #expect(result.endsWithToken)
    let inside = await formatted("cd tilde slash dot config, then look.", reply: "cd `~/.config`, then look.",
                                 backticks: false)
    #expect(inside.text == "cd ~/.config then look.")
}

@Test func slashAsAVerbStays() async {
    for reply in ["We need to `/the` price.", "We need to `/the price`.", "We need to `/`the price."] {
        let result = await formatted("We need to slash the price.", reply: reply)
        #expect(result.text == "We need to slash the price.", "\(reply)")
    }
}

@Test func aTerminalGetsTheTokenWithoutBackticks() async {
    let result = await formatted("cd tilde slash dot config", reply: "cd `~/.config`", backticks: false)
    #expect(result.text == "cd ~/.config")
}

@Test func aChunkWithoutAStrongSymbolWordIsNotSent() async {
    let asked = Asked()
    let formatter = SpokenCodeFormatter(backticks: true, timeout: .seconds(30)) { _, prompt in
        await asked.add(prompt)
        return prompt
    }
    let result = await formatter.format(" Send it to vlad at example point com. ")
    #expect(result == .init(text: " Send it to vlad at example point com. ", outcome: .skipped, spans: 0))
    #expect(await asked.prompts.isEmpty)
}

private actor Asked {
    var prompts: [String] = []
    func add(_ prompt: String) { prompts.append(prompt) }
}

@Test func theChunksEdgesStay() async {
    let result = await formatted(" adds dot local slash bin ", reply: "adds `.local/bin`")
    #expect(result.text == " adds `.local/bin` ")
}

@Test func whatACorrectionProducedIsFrozen() async {
    let corrections = CorrectionList(entries: [Correction(heard: "slash QC", meant: "/qc")])
    // Kept letter for letter inside a longer token.
    var result = await formatted("run /qc dash help now", reply: "run `/qc-help` now", corrections: corrections)
    #expect(result.text == "run `/qc-help` now")
    // Changed: refused.
    result = await formatted("run /qc dash help now", reply: "run `/QC-help` now", corrections: corrections)
    #expect(result.text == "run /qc dash help now")
    // A span with no symbol word never wraps it.
    result = await formatted("run /qc and dash", reply: "run `/qc` and dash", corrections: corrections)
    #expect(result.text == "run /qc and dash")
    // Each occurrence is kept in its own place.
    result = await formatted("run /qc dash /qc now", reply: "run `/QC-/qc` now", corrections: corrections)
    #expect(result.text == "run /qc dash /qc now")
    result = await formatted("run /qc dash /QC now", reply: "run `/QC-/qc` now", corrections: corrections)
    #expect(result.text == "run /qc dash /QC now")
    // Two pairs that produce the same text freeze it once.
    let twice = CorrectionList(entries: [Correction(heard: "slash QC", meant: "/qc"),
                                         Correction(heard: "slash cue see", meant: "/qc")])
    result = await formatted("run /qc dash help now", reply: "run `/qc-help` now", corrections: twice)
    #expect(result.text == "run `/qc-help` now")
}

@Test func textAlreadyInBackticksReachesTheModelAsQuotes() async {
    let asked = Asked()
    let formatter = SpokenCodeFormatter(backticks: true, language: "en-US", timeout: .seconds(30)) { _, prompt in
        await asked.add(prompt)
        return prompt
    }
    _ = await formatter.format("Open `README.md`, then run dash dash no dash parallel.")
    #expect(await asked.prompts == ["Text: Open 'README.md', then run dash dash no dash parallel."])
    // Without the model, runs around it are read on their own.
    let none = SpokenCodeFormatter(backticks: true, language: "en-US", timeout: .seconds(30), model: nil)
    #expect(await none.format("Open `README.md`, then run dash dash no dash parallel.").text
        == "Open `README.md`, then run `--no-parallel`.")
}

@Test func aSymbolPhrasesFirstWordAloneDoesNotAskTheModel() {
    #expect(!SpokenCode.mayContainCode("Please come back at noon.", language: "en-US"))
    #expect(SpokenCode.mayContainCode("Type back slash n.", language: "en-US"))
    #expect(!SpokenCode.mayContainCode("Keep score under ten.", language: "en-US"))
}

@Test func aReplyTooCostlyToReadIsRefused() {
    let original = Array(repeating: "slash yyyyyyyyyyyyyyyyyyyy", count: 120).joined(separator: " ")
    let reply = String(repeating: "`/x`", count: 20)
    #expect(SpokenCode.proposals(original: original, reply: reply, accepted: { _, _ in false }) == nil)
}

@Test func theFixKeepsEveryCodeToken() async {
    let coder = SpokenCodeFormatter(backticks: false, language: "en-US", timeout: .seconds(30), model: codeModel([
        "foo dash bar dot txt": "foo-bar.txt", "slash tmp slash file": "/tmp/file",
    ]))
    // A fix that puts spaces inside a token is dropped.
    let spacing = TranscriptFixer(corrections: CorrectionList(), referenceBudget: 1_000, timeout: .seconds(30)) {
        _, prompt in String(prompt.dropFirst("Text: ".count)).replacingOccurrences(of: "foo-bar", with: "foo - bar")
    }
    var result = await DictationTextPipeline.process("open foo dash bar dot txt now", isFinal: false, coder: coder,
                                                     fixer: spacing)
    #expect(result.text == "open foo-bar.txt now")
    #expect(result.fixOutcome == .rejected)
    // A terminal's last token gets no closing punctuation.
    let closing = TranscriptFixer(corrections: CorrectionList(), referenceBudget: 1_000, timeout: .seconds(30)) {
        _, prompt in String(prompt.dropFirst("Text: ".count)) + "."
    }
    result = await DictationTextPipeline.process("cat slash tmp slash file", isFinal: true, coder: coder,
                                                 fixer: closing)
    #expect(result.text == "cat /tmp/file")
    // So does a token already there, a learned correction's.
    result = await DictationTextPipeline.process("run /qc", isFinal: true, coder: coder, fixer: closing)
    #expect(result.text == "run /qc")
    // In backticks, the sentence may close.
    let wrapping = SpokenCodeFormatter(backticks: true, language: "en-US", timeout: .seconds(30),
                                       model: codeModel(["slash tmp slash file": "/tmp/file"]))
    result = await DictationTextPipeline.process("cat slash tmp slash file", isFinal: true, coder: wrapping,
                                                 fixer: closing)
    #expect(result.text == "cat `/tmp/file`.")
    // What stands next to a token stays: no comma, no join.
    #expect(!DictationTextPipeline.keeps(["/tmp/a", "/tmp/b"], from: "cp /tmp/a /tmp/b", in: "cp /tmp/a, /tmp/b"))
    #expect(!DictationTextPipeline.keeps(["/tmp/a", "/tmp/b"], from: "cp /tmp/a /tmp/b", in: "cp /tmp/a/tmp/b"))
    #expect(DictationTextPipeline.keeps(["/tmp/a"], from: "Copy /tmp/a now", in: "copy /tmp/a now"))
    // A closing mark after a token in backticks at the end.
    #expect(DictationTextPipeline.keeps(["`/qc`"], from: "run `/qc` ", in: "run `/qc`. "))
}

@Test func theFixGetsWhatSpokenCodeLeftOfTheTimeLimit() async {
    let coder = SpokenCodeFormatter(backticks: true, language: "en-US", timeout: .seconds(30),
                                    model: codeModel(["dot local slash bin": ".local/bin"]))
    let fixer = TranscriptFixer(corrections: CorrectionList(), referenceBudget: 1_000, timeout: .milliseconds(100)) {
        _, prompt in String(prompt.dropFirst("Text: ".count))
    }
    let result = await DictationTextPipeline.process("adds dot local slash bin", isFinal: true, coder: coder,
                                                     fixer: fixer)
    #expect(result.text == "adds `.local/bin`")
    #expect(result.fixOutcome == .timedOut)
}

@Test func historyKeepsATerminalDictationForRunAgain() throws {
    let record = DictationRecord(id: UUID(), date: Date(timeIntervalSince1970: 1_790_000_000), app: "ターミナル",
                                 language: "en-US", text: "cd ~/.config", heard: "cd tilde slash dot config",
                                 outcome: .init(kind: .typed), seconds: 1, terminal: true)
    let encoder = JSONEncoder()
    let decoded = try JSONDecoder().decode(DictationRecord.self, from: encoder.encode(record))
    #expect(decoded.terminal == true)
    let other = DictationRecord(id: UUID(), date: Date(), app: "Notes", language: "en-US", text: "x", heard: "x",
                                outcome: .init(kind: .inserted), seconds: 1, terminal: false)
    #expect(other.terminal == nil)
    #expect(!String(decoding: try encoder.encode(other), as: UTF8.self).contains("terminal"))
}

@Test func aFailedModelFallsBackToRunsReadOneWay() async {
    let failing = SpokenCodeFormatter(backticks: true, language: "en-US", timeout: .seconds(30)) { _, _ in
        throw CancellationError()
    }
    let result = await failing.format("Run the tests with dash dash no dash parallel so they finish.")
    #expect(result == .init(text: "Run the tests with `--no-parallel` so they finish.", outcome: .failed, spans: 1,
                            tokens: ["`--no-parallel`"]))
    let none = SpokenCodeFormatter(backticks: true, language: "en-US", timeout: .seconds(30), model: nil)
    #expect(await none.format("Run the tests with dash dash no dash parallel.").outcome == .noModel)
}

// MARK: - Without the model

private func fallback(_ text: String) -> String {
    SpokenCode.render(text, spans: SpokenCode.fallback(text, language: "en-US"), backticks: true)
}

@Test(arguments: [
    ("Run the tests with dash dash no dash parallel so they finish.",
     "Run the tests with `--no-parallel` so they finish."),
    ("I ran the script dot slash scripts slash restart dash app dot S. H. yesterday",
     "I ran the script `./scripts/restart-app.sh` yesterday"),
    ("The config lives in tilde slash dot config slash ghostty slash config.",
     "The config lives in `~/.config/ghostty/config`."),
    ("in the scripts slash restart dash app dot S H file", "in the scripts slash restart dash app dot S H file"),
    ("Look in slash tmp slash cache now.", "Look in `/tmp/cache` now."),
    ("Name it transcript underscore fixer dot swift.", "Name it `transcript_fixer.swift`."),
    ("Set H O L O S underscore MODEL underscore TESTS", "Set `HOLOS_MODEL_TESTS`"),
    ("Scripts slash restart dash app.", "Scripts slash restart dash app."),
    // The last spelled letter's dot ends the sentence at the end, or before a capitalized word.
    ("Run dot slash scripts slash restart dash app dot S. H.", "Run `./scripts/restart-app.sh`."),
    ("Run dot slash scripts slash restart dash app dot S. H. Then wait.", "Run `./scripts/restart-app.sh`. Then wait."),
    // Digits are not capitals, and a letter's name alone is a word.
    ("Run archive underscore 2026 dot S H", "Run `archive_2026.sh`"),
    ("Name it Jay dash Smith dot txt.", "Name it `Jay-Smith.txt`."),
])
func runsReadOneWayAreConvertedWithoutTheModel(_ text: String, _ expected: String) {
    #expect(fallback(text) == expected)
}

@Test(arguments: [
    // One symbol only, or ordinary uses.
    "Execute slash Q C now.",
    "So in my dot ZHRC file.",
    "We need to slash the price and dot every line before the dash to the finish.",
    "He made a dash for the door, dot dot dot.",
    // Ambiguous start: `adds.local/bin` or "adds `.local/bin`".
    "It adds dot local slash bin into it.",
    // Two-word parts.
    "Open the file source slash holos core slash transcript fixer dot swift.",
    // A number word other than a digit's, "at", "plus", "equals".
    "Use python dash three dash eleven",
    "Send it to vlad at example dot com please.",
    "two plus two equals four",
    // A clause's end inside.
    "Cut it, dash, and slash it.",
    // A short word before "slash" may be a directory.
    "ab slash cd slash ef",
    // Symbols that do not stand as in paths or options, or a line break.
    "Draw a dash dot line.",
    "Run dash dash\nverbose",
])
func runsReadMoreThanOneWayStayAsSaid(_ text: String) {
    #expect(fallback(text) == text)
}

// MARK: - Streaming

@Test(arguments: [
    ("I ran scripts slash restart", "I ran"),
    ("I ran scripts slash restart dash app dot", "I ran"),
    ("so we slash the price and then go home", "so we slash the price and then go"),
    ("so we slash the price and then go home.", "so we slash the price and then go home."),
    ("see the file dot", "see the"),
    ("then run it with double", "then run it with"),
    ("the price, then slash", "the price, then"),
    ("run dash dash verbose.", "run dash dash verbose."),
    ("no symbols at all", "no symbols at all"),
    ("I ran scripts", "I ran"),
    // A run of spelled letters counts as one word, and may be a token's first part.
    ("Run tilde slash H O L O", ""),
    ("so run tilde slash H O L O", "so"),
    ("so tilde slash es aytch em el", "so"),
    ("Set H O L O S", "Set"),
    ("Set H O L O S underscore A I F I X", "Set"),
    // A symbol phrase counts whole; its first word alone does not.
    ("open src forward slash", "open"),
    ("Please come back at noon", "Please come back at"),
])
func aTrailingRunIsWithheld(_ text: String, _ expected: String) {
    #expect(SpokenCode.withholdingTrailingRun(text, language: "en-US") == expected)
}

@Test(arguments: [
    "I ran scripts slash restart dash app dot S H and it worked fine at last , then dot local slash bin",
    "Set H O L O S underscore A I F I X underscore MODEL equals one and then come back at noon",
    "open src forward slash app double dash verbose a b c d e f slash g H I J K L M N O P dash q",
    "x slash b c d double check the list back slash y",
])
func whatWasHandedOnStaysAPrefix(_ sentence: String) {
    let words = sentence.split(separator: " ")
    var handed = ""
    for count in 1...words.count {
        let text = words.prefix(count).joined(separator: " ")
        let now = SpokenCode.withholdingTrailingRun(text, language: "en-US")
        #expect(now.hasPrefix(handed), "\(handed) → \(now)")
        handed = now
    }
}

// MARK: - Run Again and History

/// A model that writes the spans it knows between backticks and records each chunk it was asked about.
private func codeModel(_ spans: [String: String], asked: Asked? = nil) -> SpokenCodeFormatter.Model {
    { _, prompt in
        await asked?.add(prompt)
        var text = String(prompt.dropFirst("Text: ".count))
        for (spoken, token) in spans { text = text.replacingOccurrences(of: spoken, with: "`\(token)`") }
        return text
    }
}

@Test func runAgainFormatsCodeAcrossChunksAndCountsIt() async {
    let asked = Asked()
    let coder = SpokenCodeFormatter(backticks: true, language: "en-US", timeout: .seconds(30),
                                    model: codeModel(["scripts slash restart dash app dot S H": "scripts/restart-app.sh"],
                                                     asked: asked))
    let pipeline = DictationTextPipeline(language: "en-US", removeFillers: true, corrections: CorrectionList(),
                                         coder: coder)
    // The recognizer commits the path in two results; streaming holds the first part back until it is whole.
    let output = await pipeline.run(segments: ["I ran scripts slash restart", "dash app dot S H and it worked fine."])
    #expect(output.written == "I ran `scripts/restart-app.sh` and it worked fine.")
    #expect(output.coded == output.written)
    #expect(output.codeSpans == 1)
    #expect(output.aiChangedWords == 0)
    #expect(await asked.prompts == ["Text: scripts slash restart dash app dot S H and it worked fine."])

    let record = DictationRecord(id: UUID(), date: Date(), app: "Notes", language: "en-US",
                                 text: "I ran scripts slash restart dash app dot S H and it worked fine.",
                                 heard: "I ran scripts slash restart dash app dot S H and it worked fine.",
                                 outcome: .init(kind: .inserted), seconds: 3)
    let report = DictationRerunReport(record: record, output: output, pipeline: pipeline)
    #expect(report.changedBy == [.spokenCode])
    #expect(report.fixes.codeSpans == 1)
    #expect(report.steps[3].summary == "Spoken code: “slash restart dash app dot S H” → “`scripts/restart-app.sh`”"
        || report.steps[3].changed)
}

@Test func codeTokensDoNotCountAsAppleIntelligencesWords() async {
    let coder = SpokenCodeFormatter(backticks: true, language: "en-US", timeout: .seconds(30),
                                    model: codeModel(["dot local slash bin": ".local/bin"]))
    let fixer = TranscriptFixer(corrections: CorrectionList(), referenceBudget: 1_000, timeout: .seconds(30)) { _, prompt in
        String(prompt.dropFirst("Text: ".count)).replacingOccurrences(of: "whether", with: "weather")
    }
    let pipeline = DictationTextPipeline(language: "en-US", removeFillers: true, corrections: CorrectionList(),
                                         fixer: fixer, coder: coder)
    let output = await pipeline.run(segments: ["It adds dot local slash bin to the path."])
    #expect(output.written == "It adds `.local/bin` to the path.")
    #expect(output.codeSpans == 1)
    #expect(output.aiChangedWords == 0)
}

@Test func historyNamesSpokenCodeAndReadsOldRecords() throws {
    #expect(DictationRecord.Fixes(codeSpans: 2).isEmpty == false)
    let record = DictationRecord(id: UUID(), date: Date(), app: "Notes", language: "en-US", text: "`/qc`",
                                 heard: "slash Q C", fixes: .init(corrections: 1, codeSpans: 1),
                                 outcome: .init(kind: .inserted), seconds: 1)
    #expect(record.fixesText == "1 spoken path or command as code · 1 correction")
    let old = #"{"fillersRemoved":false,"corrections":1,"aiChangedWords":0}"#
    #expect(try JSONDecoder().decode(DictationRecord.Fixes.self, from: Data(old.utf8)) == .init(corrections: 1))
}

@Test func terminalsAreKnownByName() {
    for name in ["Terminal", "iTerm2", "Ghostty", "WezTerm", "kitty", "Alacritty", "Warp"] {
        #expect(SpokenCode.isTerminal(appName: name))
    }
    #expect(SpokenCode.isTerminal(appName: "com.apple.Terminal"))
    #expect(!SpokenCode.isTerminal(appName: "Notes"))
    #expect(!SpokenCode.isTerminal(appName: nil))
}
