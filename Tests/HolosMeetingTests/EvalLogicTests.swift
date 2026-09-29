import Foundation
import JavaScriptCore
import Testing
import HolosCore
import HolosSpeakers
@testable import HolosMeeting

// `voiceislocal eval` pure logic (docs/reference-evaluation.md, "Cloud reference"): segmenting and stitching, cost,
// consent, alignment and WER, grouping, the review page, and decisions.

// MARK: - Segmenting and stitching

private func evalSettings(max: Double = 10, search: Double = 4) -> CloudSegmentation.Settings {
    var settings = CloudSegmentation.Settings()
    settings.maxSeconds = max
    settings.searchSeconds = search
    return settings
}

@Test func evalSegmentsCutAtTheQuietestPauseBeforeTheLimit() {
    // 25 s of speech (RMS 0.1) at 100 ms windows, with a pause at 8.0–8.6 s and one at 17.0–17.6 s.
    var rms = [Float](repeating: 0.1, count: 250)
    for window in 80..<86 { rms[window] = 0.001 }
    for window in 170..<176 { rms[window] = 0.001 }
    let plan = CloudSegmentation.plan(frameCount: 25 * 16_000, sampleRate: 16_000, rms: rms, settings: evalSettings())
    #expect(plan.count == 3)
    #expect(plan.allSatisfy { $0.endFrame - $0.startFrame <= 10 * 16_000 })
    // Cuts inside the pauses, without overlap.
    #expect((8 * 16_000)...(Int(8.6 * 16_000)) ~= plan[0].endFrame)
    #expect(plan[1].startFrame == plan[0].endFrame)
    #expect((17 * 16_000)...(Int(17.6 * 16_000)) ~= plan[1].endFrame)
    #expect(plan.allSatisfy { $0.overlapSeconds == 0 && !$0.silent })
    #expect(plan.last?.endFrame == 25 * 16_000)
}

@Test func evalSegmentsOverlapWhenNoPauseIsFound() {
    let rms = [Float](repeating: 0.1, count: 150)
    let plan = CloudSegmentation.plan(frameCount: 15 * 16_000, sampleRate: 16_000, rms: rms, settings: evalSettings())
    #expect(plan.count == 2)
    #expect(plan[1].overlapSeconds == 1.0)
    #expect(plan[1].startFrame == plan[0].endFrame - 16_000)
    #expect(plan[0].endFrame - plan[0].startFrame <= 10 * 16_000)
}

@Test func evalSilentSegmentsAreMarkedAndShortTailsMerge() {
    var rms = [Float](repeating: 0.0001, count: 200)
    for window in 0..<50 { rms[window] = 0.1 }
    let plan = CloudSegmentation.plan(frameCount: 20 * 16_000, sampleRate: 16_000, rms: rms, settings: evalSettings())
    #expect(plan.first?.silent == false)
    #expect(plan.last?.silent == true)
    // A 1 s tail after a 10 s limit joins the segment before.
    let tail = CloudSegmentation.plan(frameCount: Int(10.5 * 16_000), sampleRate: 16_000,
                                      rms: [Float](repeating: 0.0001, count: 105), settings: evalSettings(search: 0.5))
    #expect(tail.count == 1)
    #expect(tail[0].endFrame == Int(10.5 * 16_000))
    #expect(CloudSegmentation.plan(frameCount: 0, sampleRate: 16_000, rms: []).isEmpty)
}

@Test func evalStitchDropsWordsTheOverlapRepeated() {
    let stitched = CloudSegmentation.stitch([
        ("We deploy on Kubernetes every", 0),
        ("Kubernetes, every Friday at noon.", 1.0),
        ("Then we rest.", 0),
        ("rest. Then more.", 0),
    ])
    #expect(stitched[1] == ["Friday", "at", "noon."])
    #expect(stitched[2] == ["Then", "we", "rest."])
    // Without overlap nothing is dropped, even when words repeat.
    #expect(stitched[3] == ["rest.", "Then", "more."])
    // A second of overlap drops at most four words: a phrase said again after it stays.
    let repeated = CloudSegmentation.stitch([
        ("thank you thank you thank you", 0),
        ("thank you thank you thank you", 1.0),
    ])
    #expect(repeated[1] == ["thank", "you"])
    // The overlap repeats only the segment just before: after an empty answer nothing is dropped.
    let afterEmpty = CloudSegmentation.stitch([("Ready.", 0), ("", 1.0), ("Ready for the next item.", 1.0)])
    #expect(afterEmpty[2] == ["Ready", "for", "the", "next", "item."])
}

// MARK: - Cost and consent

@Test func evalCostEstimateUsesTheListPrice() throws {
    #expect(try #require(CloudModels.estimate(model: "gpt-transcribe", seconds: 600)) == 0.045)
    #expect(try #require(CloudModels.estimate(model: "whisper-1", seconds: 60)) == 0.006)
    #expect(CloudModels.estimate(model: "someday-model", seconds: 60) == nil)
    #expect(CloudModels.isValidName("gpt-4o-mini-transcribe"))
    #expect(!CloudModels.isValidName("../x"))
    #expect(!CloudModels.isValidName("a.b"))
}

@Test func evalPreparedEstimateCountsPendingSegmentsAndTheTimestampPass() throws {
    let track = CloudTrackPlan(track: "mic", sampleRate: 16_000, frameCount: 16_000 * 700, timeMap: [],
                               audioFingerprint: "x", segments: [
                                   CloudSegmentPlan(index: 0, startFrame: 0, endFrame: 16_000 * 300),
                                   CloudSegmentPlan(index: 1, startFrame: 16_000 * 300, endFrame: 16_000 * 600),
                                   CloudSegmentPlan(index: 2, startFrame: 16_000 * 600, endFrame: 16_000 * 700,
                                                    silent: true),
                               ])
    var record = CloudRunRecord(id: "gpt-transcribe-20260929T000000Z", sessionID: "S", createdAt: Date(),
                                request: CloudRequestFields(model: "gpt-transcribe"), timestampRequest: nil,
                                vocabulary: false, maxSegmentSeconds: 300, tracks: [track])
    var prepared = CloudEvaluation.Prepared(session: URL(fileURLWithPath: "/tmp/x.holos"), sessionName: "Standup",
                                            record: record, resumed: false, pending: ["mic": [0, 1]], renders: [:])
    #expect(prepared.pendingSeconds == 600)
    #expect(prepared.pendingRequests == 2)
    #expect(abs(try #require(prepared.estimatedCost) - 0.045) < 1e-9)
    #expect(record.uploadCount == 2)
    record.timestampRequest = CloudRequestFields(model: "whisper-1", responseFormat: "verbose_json")
    prepared.record = record
    prepared.pending = ["mic": [1]]
    #expect(prepared.pendingRequests == 2)
    #expect(abs(try #require(prepared.estimatedCost) - (0.0225 + 0.03)) < 1e-9)
    let summary = prepared.summaryLines.joined(separator: "\n")
    #expect(summary.contains("Standup"))
    #expect(summary.contains("5.0 min of audio in 2 requests"))
    #expect(summary.contains("US$0.05"))
    #expect(summary.contains("1 silent, not sent"))
}

@Test func evalConsentNeedsAnExplicitYes() {
    var asked = 0
    let answer: (String?) -> () -> String? = { text in { asked += 1; return text } }
    #expect(ConsentGate.decide(assumeYes: true, isTerminal: false, readAnswer: answer("n")) == .proceed)
    #expect(asked == 0)
    #expect(ConsentGate.decide(assumeYes: false, isTerminal: false, readAnswer: answer("y")) == .noTerminal)
    #expect(asked == 0)
    #expect(ConsentGate.decide(assumeYes: false, isTerminal: true, readAnswer: answer(" Yes\n")) == .proceed)
    #expect(ConsentGate.decide(assumeYes: false, isTerminal: true, readAnswer: answer("y")) == .proceed)
    #expect(ConsentGate.decide(assumeYes: false, isTerminal: true, readAnswer: answer("")) == .declined)
    #expect(ConsentGate.decide(assumeYes: false, isTerminal: true, readAnswer: answer(nil)) == .declined)
    #expect(ConsentGate.decide(assumeYes: false, isTerminal: true, readAnswer: answer("sure")) == .declined)
}

// MARK: - Vocabulary

@Test func evalVocabularyBuildsKeywordsAndABoundedPrompt() throws {
    // The recognizer's order: the word list, then names, then correction words; each once in any case or spacing.
    let built = CloudVocabulary.build(languages: ["en-CA", "fr-CA"], wordList: ["Keycloak", "Urban  Sky", "jim"],
                                      names: ["Maria Chen", "maria  chen", "Jim", "urban sky"],
                                      terms: ["Kubernetes", "bad<term>", "two\nlines", "Jim", "keycloak"])
    #expect(built.keywords == ["Keycloak", "Urban Sky", "jim", "Maria Chen", "Kubernetes"])
    #expect(built.prompt == "A meeting in English and French. Terms: Keycloak, Urban Sky, jim. People: Maria Chen. "
        + "Other words: Kubernetes.")
    // At most the recognizer's 100: a long correction list never pushes out the word list or the names.
    let many = CloudVocabulary.build(languages: ["en-US"], wordList: (0..<60).map { "Listed\($0)" },
                                     names: (0..<30).map { "Name\($0)" }, terms: (0..<500).map { "Term\($0)" })
    #expect(many.keywords.count == CloudVocabulary.maxKeywords)
    #expect(Array(many.keywords.prefix(90)) == (0..<60).map { "Listed\($0)" } + (0..<30).map { "Name\($0)" })
    #expect(many.keywords.last == "Term9")
    // The prompt keeps the order too, and ends at the first string that does not fit.
    let prompt = try #require(many.prompt)
    #expect(prompt.count <= CloudVocabulary.maxPromptCharacters)
    #expect(prompt.contains("Terms: Listed0, Listed1") && !prompt.contains("Other words"))
    let longList = CloudVocabulary.build(languages: ["en-US"], wordList: (0..<100).map { "Listed\($0)" },
                                         names: ["Al"], terms: [])
    #expect(longList.prompt?.contains("People") == false)
    #expect(CloudVocabulary.build(languages: ["en-US"], wordList: [], names: [], terms: []).prompt == nil)
    #expect(CloudVocabulary.languageCodes(["fr-CA", "fr-FR", "en-US"]) == ["fr", "en"])
}

@Test func evalRequestFieldsFollowEachModel() {
    let fields = CloudRequestFields(model: "gpt-transcribe", languages: ["en", "fr"], prompt: "A meeting.",
                                    keywords: ["Kubernetes"])
    #expect(fields.formFields.map(\.0) == ["model", "response_format", "languages[]", "languages[]", "prompt",
                                           "keywords[]"])
    let older = CloudRequestFields(model: "gpt-4o-transcribe", languages: ["fr"], prompt: "P", keywords: ["K"])
    #expect(older.formFields.map(\.0) == ["model", "response_format", "language", "prompt"])
    let bilingual = CloudRequestFields(model: "whisper-1", languages: ["en", "fr"])
    #expect(!bilingual.formFields.contains { $0.0 == "language" })
    let diarize = CloudEvaluation.requestFields(model: "gpt-4o-transcribe-diarize", languages: ["en-US"],
                                                vocabulary: .init(prompt: "P", keywords: []))
    #expect(diarize.formFields.contains { $0 == ("chunking_strategy", "auto") })
    #expect(!diarize.formFields.contains { $0.0 == "prompt" })
}

// MARK: - Alignment, WER, grouping

private func timed(_ words: [String], from start: Double = 0, echo: Set<Int> = []) -> [EvalToken] {
    words.enumerated().map { index, word in
        EvalToken(text: word, start: start + Double(index), end: start + Double(index) + 0.8,
                  echo: echo.contains(index))
    }
}

private func untimed(_ text: String) -> [EvalToken] { EvalText.tokens(text).map { EvalToken(text: $0) } }

@Test func evalAlignmentFindsTheMinimumEdits() {
    let ops = EvalAlignment.align(["we", "use", "cube", "control", "daily"], ["We", "use", "kubectl", "daily."])
    #expect(ops == [.match(0, 0, exact: false), .match(1, 1, exact: true), .localOnly(2), .substitute(3, 2),
                    .match(4, 3, exact: false)])
    #expect(EvalAlignment.align([], ["a"]) == [.cloudOnly(0)])
    #expect(EvalAlignment.align(["a"], []) == [.localOnly(0)])
}

@Test func evalWindowScoresBothWaysAndGroupsPassages() {
    let local = timed(["we", "ship", "on", "cube", "control", "at", "five", "o'clock", "okay"])
    let cloud = untimed("We ship on Kubernetes at 5 o'clock, okay so")
    let result = WindowComparer.compare(track: "mic", local: local, cloud: cloud, start: 0, end: 20)
    let score = result.score
    #expect(score.localWords == 9)
    #expect(score.cloudWords == 9)
    #expect(score.substitutions == 2)  // cube→Kubernetes, five→5
    #expect(score.localOnly == 1)  // control
    #expect(score.cloudOnly == 1)  // so
    #expect(score.edits == 4)
    #expect(abs((score.werAgainstLocal ?? 0) - 4.0 / 9) < 1e-9)
    #expect(abs((score.werAgainstCloud ?? 0) - 4.0 / 9) < 1e-9)
    let words = result.passages.filter { $0.group != .caseOrPunctuation }
    #expect(words.map(\.local) == ["cube control", "five", ""])
    #expect(words.map(\.cloud) == ["Kubernetes", "5", "so"])
    #expect(words.map(\.group) == [.namesAndTerms, .numbers, .droppedOrAdded])
    #expect(words[0].start == 3 && words[0].end == 4.8)
    #expect(words[0].localFirst == 3 && words[0].localEnd == 5)
    // The cloud-only "so" lies after the last local word.
    #expect(words[2].start >= 8.8 && words[2].localFirst == 9 && words[2].localEnd == 9)
    #expect(words[0].before == "we ship on")
    #expect(words[0].after.hasPrefix("at"))
    // "we"→"We", "o'clock"→"o'clock," differ only in case or punctuation.
    #expect(score.caseOrPunctuationOnly == 2)
    #expect(result.passages.filter { $0.group == .caseOrPunctuation }.count == 2)
}

@Test func evalEchoWordsAreLeftOutOfScoresAndPassages() {
    // Local mic words 2–4 are echo of the system track; the cloud heard them too, and one more echo word.
    let local = timed(["hello", "there", "the", "quarterly", "numbers", "right"], echo: [2, 3, 4])
    let cloud = untimed("hello there the quarterly figures look right")
    let result = WindowComparer.compare(track: "mic", local: local, cloud: cloud, start: 0, end: 10)
    #expect(result.score.localWords == 3)
    #expect(result.score.cloudWords == 3)
    #expect(result.score.edits == 0)
    #expect(result.score.echoLocalWords == 3)
    #expect(result.score.echoCloudWords == 4)
    #expect(result.passages.isEmpty)
}

@Test func evalGroupingRules() {
    #expect(PassageGrouping.group(local: ["twenty"], cloud: ["20"]) == .numbers)
    #expect(PassageGrouping.group(local: ["maria"], cloud: ["Maria"], localSentenceStart: [false],
                                  cloudSentenceStart: [false]) == .namesAndTerms)
    #expect(PassageGrouping.group(local: ["so"], cloud: ["So"], localSentenceStart: [true],
                                  cloudSentenceStart: [true]) == .otherWords)
    #expect(PassageGrouping.group(local: ["API"], cloud: ["a", "pie"]) == .namesAndTerms)
    #expect(PassageGrouping.group(local: ["um"], cloud: []) == .droppedOrAdded)
    #expect(PassageGrouping.group(local: ["their"], cloud: ["there"]) == .otherWords)
    #expect(PassageGrouping.opensSentence(after: nil))
    #expect(PassageGrouping.opensSentence(after: "done."))
    #expect(PassageGrouping.opensSentence(after: "done?\""))
    #expect(!PassageGrouping.opensSentence(after: "done,"))
}

@Test func evalCompareTrackUsesEachSegmentsWindow() {
    // Two segments: [0, 10) and [10, 20); the second repeats 1 s of the first.
    let local = timed(["alpha", "beta", "gamma"], from: 2) + timed(["delta", "epsilon"], from: 12)
    let cloud = CloudTrackResult(run: "r", track: "system", model: "m", segments: [
        .init(index: 0, sessionStart: 0, sessionEnd: 10, renderStart: 0, renderEnd: 10, overlapSeconds: 0,
              silent: false, text: "alpha beta gamma", words: ["alpha", "beta", "gamma"], timedWords: nil),
        .init(index: 1, sessionStart: 9, sessionEnd: 20, renderStart: 9, renderEnd: 20, overlapSeconds: 1,
              silent: false, text: "delta epsilons", words: ["delta", "epsilons"], timedWords: nil),
    ], text: "")
    let compared = EvalCompare.compareTrack(track: "system", local: local, cloud: cloud)
    #expect(compared.report.score.localWords == 5)
    #expect(compared.report.score.substitutions == 1)
    #expect(compared.passages.map(\.id) == ["system-1"])
    #expect(compared.passages[0].start == 13)
    #expect(compared.passages[0].localFirst == 4)
    #expect(compared.report.warnings.isEmpty)
}

@Test func evalAWordSaidAcrossACutIsNotCountedTwice() {
    // "gamma" starts just before the cut at 10 s locally, but the cloud heard it only in the second segment.
    let local = timed(["alpha", "beta"], from: 7) + [EvalToken(text: "gamma", start: 9.9, end: 10.3)]
        + timed(["delta"], from: 11)
    let cloud = CloudTrackResult(run: "r", track: "mic", model: "m", segments: [
        .init(index: 0, sessionStart: 0, sessionEnd: 10, renderStart: 0, renderEnd: 10, overlapSeconds: 0,
              silent: false, text: "", words: ["alpha", "beta"], timedWords: nil),
        .init(index: 1, sessionStart: 10, sessionEnd: 20, renderStart: 10, renderEnd: 20, overlapSeconds: 0,
              silent: false, text: "", words: ["gamma", "delta"], timedWords: nil),
    ], text: "")
    let compared = EvalCompare.compareTrack(track: "mic", local: local, cloud: cloud)
    #expect(compared.report.score.edits == 0)
    #expect(compared.passages.isEmpty)
}

private func cloudTrack(_ windows: [[String]]) -> CloudTrackResult {
    CloudTrackResult(run: "r", track: "mic", model: "m", segments: windows.enumerated().map { index, words in
        .init(index: index, sessionStart: Double(index) * 10, sessionEnd: Double(index + 1) * 10,
              renderStart: Double(index) * 10, renderEnd: Double(index + 1) * 10, overlapSeconds: 0, silent: false,
              text: words.joined(separator: " "), words: words, timedWords: nil)
    }, text: "")
}

@Test func evalBoundaryRepairsThatTouchAreMadeTogether() {
    // Windows 2 and 3 are empty on both sides: their boundaries fall on the same operation.
    let local = timed(["hello"], from: 1) + timed(["yes"], from: 31)
    let compared = EvalCompare.compareTrack(track: "mic", local: local, cloud: cloudTrack([[], ["hello", "no"], [], []]))
    // Aligned as one stretch: "hello" matches, "yes" and "no" are one substitution.
    #expect(compared.report.score.matches == 1)
    #expect(compared.report.score.edits == 1)
}

@Test func evalBoundaryRepairLooksPastMatchedWords() {
    // The same words, cut in another place: "I think that that | works" and "I think that | that works".
    let local = timed(["I", "think", "that", "that"], from: 5) + timed(["works"], from: 11)
    let compared = EvalCompare.compareTrack(track: "mic", local: local,
                                            cloud: cloudTrack([["I", "think", "that"], ["that", "works"]]))
    #expect(compared.report.score.edits == 0)
    #expect(compared.passages.isEmpty)
}

@Test func evalBoundaryRepairRealignsAWholeRunAcrossTheCut() {
    // Coarse local timing put the whole sentence before the cut; the cloud heard all of it in the next segment.
    let local = timed(["we", "need", "to", "ship", "this", "change", "today"], from: 1) + timed(["okay"], from: 11)
    let compared = EvalCompare.compareTrack(
        track: "mic", local: local,
        cloud: cloudTrack([[], ["we", "need", "to", "ship", "this", "change", "today", "okay"]]))
    #expect(compared.report.score.edits == 0)
    #expect(compared.report.score.matches == 8)
    #expect(compared.passages.isEmpty)
}

@Test func evalBoundaryRepairReachesToThreeMatchesInARow() {
    // Twelve words moved across the cut, with matched words before and after them.
    let moved = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
    let first = ["alpha", "beta", "gamma"] + moved
    let local = first.enumerated().map { index, word in
        EvalToken(text: word, start: Double(index) * 0.5, end: Double(index) * 0.5 + 0.4)
    } + timed(["delta", "epsilon", "zeta"], from: 11)
    let compared = EvalCompare.compareTrack(
        track: "mic", local: local,
        cloud: cloudTrack([["alpha", "beta", "gamma"], moved + ["delta", "epsilon", "zeta"]]))
    #expect(compared.report.score.edits == 0)
    #expect(compared.report.score.matches == 18)
    // A real difference past the moved words is still one.
    let changed = EvalCompare.compareTrack(
        track: "mic", local: local,
        cloud: cloudTrack([["alpha", "beta", "gamma"], moved + ["delta", "epsilons", "zeta"]]))
    #expect(changed.report.score.edits == 1)
}

@Test func evalTimedCloudWordsAwayFromEchoAreKept() {
    // Echo "thanks for joining" at 0–3 s; the cloud also has "I disagree" at 10–12 s, which the microphone missed.
    let local = timed(["thanks", "for", "joining"], echo: [0, 1, 2]) + timed(["next"], from: 20)
    var cloud = untimed("thanks for joining I disagree next")
    for (index, time) in [0.0, 1, 2, 10, 11, 20].enumerated() {
        cloud[index].start = time
        cloud[index].end = time + 0.8
    }
    let result = WindowComparer.compare(track: "mic", local: local, cloud: cloud, start: 0, end: 30)
    #expect(result.score.cloudOnly == 2)
    #expect(result.passages.map(\.cloud) == ["I disagree"])
    // Said while the echo played, they are echo.
    cloud[3].start = 3.2; cloud[3].end = 3.5
    cloud[4].start = 3.5; cloud[4].end = 3.9
    let during = WindowComparer.compare(track: "mic", local: local, cloud: cloud, start: 0, end: 30)
    #expect(during.score.cloudOnly == 0)
    #expect(during.passages.isEmpty)
    // The cloud did not hear the echo, and aligned what was said later with it: those words are kept all the same.
    var later = untimed("I disagree next")
    for (index, time) in [10.0, 11, 20].enumerated() {
        later[index].start = time
        later[index].end = time + 0.8
    }
    let aligned = WindowComparer.compare(track: "mic", local: local, cloud: later, start: 0, end: 30)
    #expect(aligned.score.echoLocalWords == 3)
    #expect(aligned.score.cloudOnly == 2)
    #expect(aligned.passages.map(\.cloud) == ["I disagree"])
    // Speech between two echo stretches stays whole and in order, and the gold keeps that order.
    let twoEchoes = timed(["thank", "you", "all"], echo: [0, 1, 2]) + timed(["see", "you", "later"], from: 20,
                                                                            echo: [0, 1, 2])
    var between = untimed("I cannot agree with that proposal")
    for index in between.indices {
        between[index].start = 10 + Double(index)
        between[index].end = 10.8 + Double(index)
    }
    let middle = WindowComparer.compare(track: "mic", local: twoEchoes, cloud: between, start: 0, end: 30)
    #expect(middle.score.echoLocalWords == 6)
    #expect(middle.score.cloudOnly == 6)
    #expect(middle.passages.map(\.cloud) == ["I cannot agree with that proposal"])
    let accepted = middle.passages.map { ($0, ReviewDecisions.Decision(id: $0.id, choice: .cloud, text: $0.cloud)) }
    #expect(EvalApply.goldTrack(track: "mic", local: twoEchoes, replacements: accepted).text
        == "I cannot agree with that proposal")
    // Untimed, the alignment with the echo stands.
    let untimedLater = WindowComparer.compare(track: "mic", local: local, cloud: untimed("I disagree next"),
                                              start: 0, end: 30)
    #expect(untimedLater.passages.isEmpty)
}

@Test func evalGoldSplicesKeepWordsApart() {
    // An insertion between a spaced word and an unspaced script, and a deletion between two spaced words.
    let insertion = EvalCompare.segmentTokens(
        words: WordTiming.effectiveWords(of: TranscriptSegment(start: 0, end: 3, text: "use苹果")), text: "use苹果",
        isEcho: [false])
    #expect(insertion.map(\.text) == ["use", "苹", "果"])
    let added = EvalPassage(id: "mic-1", track: "mic", start: 1, end: 1, local: "", cloud: "the",
                            group: .droppedOrAdded, before: "use", after: "苹果", localFirst: 1, localEnd: 1)
    let inserted = EvalApply.goldTrack(track: "mic", local: insertion, replacements: [
        (added, .init(id: "mic-1", choice: .cloud, text: "the")),
    ]).text
    #expect(inserted.contains("use the"))
    let deletion = EvalCompare.segmentTokens(
        words: WordTiming.effectiveWords(of: TranscriptSegment(start: 0, end: 3, text: "hello中world")),
        text: "hello中world", isEcho: [false])
    #expect(deletion.map(\.text) == ["hello", "中", "world"])
    let removed = EvalPassage(id: "mic-1", track: "mic", start: 1, end: 2, local: "中", cloud: "",
                              group: .droppedOrAdded, before: "hello", after: "world", localFirst: 1, localEnd: 2)
    #expect(EvalApply.goldTrack(track: "mic", local: deletion, replacements: [
        (removed, .init(id: "mic-1", choice: .cloud, text: "")),
    ]).text == "hello world")
    // Replacing a spaced word keeps the transcript's spacing on both sides.
    let latin = timed(["we", "run", "cube", "daily"])
    let swapped = EvalPassage(id: "mic-1", track: "mic", start: 2, end: 3, local: "cube", cloud: "kubectl",
                              group: .otherWords, before: "we run", after: "daily", localFirst: 2, localEnd: 3)
    #expect(EvalApply.goldTrack(track: "mic", local: latin, replacements: [
        (swapped, .init(id: "mic-1", choice: .cloud, text: "kubectl")),
    ]).text == "we run kubectl daily")
}

@Test func evalALongCloudOnlyRunBesideEchoIsKept() {
    let local = timed(["the", "quarterly", "numbers", "fine"], echo: [0, 1, 2])
    let cloud = untimed("the quarterly numbers we never heard locally at all fine")
    let result = WindowComparer.compare(track: "mic", local: local, cloud: cloud, start: 0, end: 10)
    #expect(result.score.cloudOnly == 6)
    #expect(result.passages.first?.cloud == "we never heard locally at all")
}

@Test func evalMarkdownKeepsTranscriptTextInert() {
    let escaped = EvalCompare.escape("see ![x](https://example.com/a.png) <img src=y> a|b")
    #expect(!escaped.contains("<img"))
    #expect(escaped.contains("\\!\\[x\\]\\("))
    #expect(escaped.contains("a\\|b"))
}

@Test func evalTimestampPassTimesCloudOnlyWords() {
    let segment = CloudTrackResult.Segment(
        index: 0, sessionStart: 0, sessionEnd: 10, renderStart: 0, renderEnd: 10, overlapSeconds: 0, silent: false,
        text: "", words: ["hello", "Maria", "Chen"],
        timedWords: [.init(word: "Hello", start: 1, end: 1.4), .init(word: "Maria", start: 5, end: 5.3),
                     .init(word: "Chen", start: 5.3, end: 5.6)])
    let tokens = EvalCompare.cloudTokens(segment)
    #expect(tokens.map(\.start) == [1, 5, 5.3])
    let result = WindowComparer.compare(track: "mic", local: timed(["hello"], from: 1), cloud: tokens, start: 0,
                                        end: 10)
    #expect(result.passages.first?.start == 5)
    #expect(result.passages.first?.end == 5.6)
}

// MARK: - Review page and decisions

private func evalReport(passages: [EvalPassage]) -> CompareReport {
    CompareReport(sessionID: "SESSION", run: "gpt-transcribe-20260929T000000Z", model: "gpt-transcribe",
                  transcriptID: "T1", createdAt: Date(timeIntervalSince1970: 0), total: EvalScore(),
                  tracks: [.init(track: "mic", score: EvalScore(), groups: [:], warnings: [])], passages: passages)
}

@Test func evalReviewPageHoldsThePassagesAndNoNetworkReference() throws {
    let passages = [
        EvalPassage(id: "mic-1", track: "mic", start: 125, end: 126, local: "cube control",
                    cloud: "kubectl</script><img src=x onerror=alert(1)>", group: .namesAndTerms,
                    before: "we run", after: "every day", localFirst: 2, localEnd: 4),
        EvalPassage(id: "mic-2", track: "mic", start: 130, end: 130, local: "We", cloud: "we",
                    group: .caseOrPunctuation, before: "", after: "", localFirst: 5, localEnd: 6),
    ]
    let track = CloudTrackPlan(track: "mic", sampleRate: 16_000, frameCount: 1,
                               timeMap: [EvalSpan(.init(renderStart: 0, sessionStart: 0, duration: 100)),
                                         EvalSpan(.init(renderStart: 105, sessionStart: 120, duration: 100))],
                               audioFingerprint: "x", segments: [])
    let run = CloudRunRecord(id: "gpt-transcribe-20260929T000000Z", sessionID: "SESSION", createdAt: Date(),
                             request: CloudRequestFields(model: "gpt-transcribe"), timestampRequest: nil,
                             vocabulary: false, maxSegmentSeconds: 300, tracks: [track])
    let data = EvalReviewPage.pageData(report: evalReport(passages: passages), run: run, sessionName: "Standup")
    #expect(data.items.map(\.id) == ["mic-1"])
    #expect(data.items[0].renderStart == 110)
    #expect(data.audio == ["mic": "review-audio/mic.m4a"])
    let html = try EvalReviewPage.html(data)
    #expect(html.contains("\"mic-1\""))
    #expect(html.contains("cube control"))
    #expect(!html.contains("</script><img"))
    #expect(html.contains("kubectl\\u003c/script\\u003e"))
    #expect(!html.contains("http://") && !html.contains("https://"))
    #expect(!html.contains("__REVIEW_DATA__"))
    #expect(html.contains("connect-src 'none'"))
    #expect(html.contains("localStorage"))
    #expect(html.contains("decisions.json"))
}

@Test func evalTimeMapGoesBothWays() {
    let map = [EvalSpan(.init(renderStart: 0, sessionStart: 0, duration: 100)),
               EvalSpan(.init(renderStart: 105, sessionStart: 300, duration: 50))]
    #expect(EvalTimeMap.renderTime(50, map: map) == 50)
    #expect(EvalTimeMap.renderTime(200, map: map) == 105)
    #expect(EvalTimeMap.renderTime(310, map: map) == 115)
    #expect(EvalTimeMap.sessionTime(115, map: map) == 310)
    #expect(EvalTimeMap.renderTime(1_000, map: map) == 155)
}

@Test func evalDecisionsParse() throws {
    let good = """
        {"schemaVersion":1,"sessionID":"S","run":"r","transcriptID":"T","exportedAt":"2026-09-29T10:00:00Z",
         "decisions":[{"id":"mic-1","choice":"edited","text":"kubectl"},{"id":"mic-2","choice":"local","text":"x"}],
         "terms":["kubectl"]}
        """
    let parsed = try ReviewDecisions.parse(Data(good.utf8))
    #expect(parsed.decisions.map(\.choice) == [.edited, .local])
    #expect(parsed.terms == ["kubectl"])
    let noTerms = #"{"schemaVersion":1,"sessionID":"S","run":"r","transcriptID":"T","decisions":[]}"#
    #expect(try ReviewDecisions.parse(Data(noTerms.utf8)).terms.isEmpty)
    for bad in [
        #"{"schemaVersion":2,"sessionID":"S","run":"r","transcriptID":"T","decisions":[]}"#,
        #"{"schemaVersion":1,"sessionID":"S","run":"r","transcriptID":"T","decisions":[{"id":"a","choice":"maybe","text":""}]}"#,
        #"{"schemaVersion":1,"sessionID":"S","run":"r","transcriptID":"T","decisions":[{"id":"a","choice":"local","text":""},{"id":"a","choice":"cloud","text":""}]}"#,
        "not json",
    ] {
        #expect(throws: HolosError.self) { _ = try ReviewDecisions.parse(Data(bad.utf8)) }
    }
}

@Test func evalGoldTrackReplacesReviewedPassagesAndSkipsEcho() {
    let local = timed(["we", "run", "cube", "control", "every", "day", "echo"], echo: [6])
    let passage = EvalPassage(id: "mic-1", track: "mic", start: 2, end: 3.8, local: "cube control", cloud: "kubectl",
                              group: .namesAndTerms, before: "we run", after: "every day", localFirst: 2, localEnd: 4)
    let insertion = EvalPassage(id: "mic-2", track: "mic", start: 6, end: 6, local: "", cloud: "please",
                                group: .droppedOrAdded, before: "", after: "", localFirst: 6, localEnd: 6)
    let gold = EvalApply.goldTrack(track: "mic", local: local, replacements: [
        (passage, .init(id: "mic-1", choice: .edited, text: "kubectl")),
        (insertion, .init(id: "mic-2", choice: .cloud, text: "please")),
    ])
    #expect(gold.text == "we run kubectl every day please")
    #expect(gold.pieces.map(\.passage) == [nil, "mic-1", nil, "mic-2"])
}

@Test func evalCorrectionPairsAreShortWordSubstitutions() {
    func passage(_ local: String, before: String = "we use", after: String = "for this") -> EvalPassage {
        EvalPassage(id: "mic-1", track: "mic", start: 0, end: 1, local: local, cloud: "", group: .otherWords,
                    before: before, after: after, localFirst: 0, localEnd: 1)
    }
    #expect(EvalApply.correctionPairs(passage: passage("cube control"), final: "kubectl",
                                      isDictionaryWord: { _ in false })
        == [Correction(heard: "cube control", meant: "kubectl")])
    // A lone dictionary word keeps a neighbour.
    #expect(EvalApply.correctionPairs(passage: passage("bull", before: "a", after: "request"), final: "pull",
                                      isDictionaryWord: { _ in true })
        == [Correction(heard: "bull request", meant: "pull request")])
    // Longer rewrites, case-only changes, and deletions propose nothing.
    #expect(EvalApply.correctionPairs(passage: passage("one two three four"), final: "five six seven eight",
                                      isDictionaryWord: { _ in false }).isEmpty)
    #expect(EvalApply.correctionPairs(passage: passage("maria"), final: "Maria", isDictionaryWord: { _ in false })
        .isEmpty)
    #expect(EvalApply.correctionPairs(passage: passage("um"), final: "", isDictionaryWord: { _ in false }).isEmpty)
}

@Test func evalRedactsKeysInMessages() {
    #expect(CloudTranscriptionClient.redacted("Incorrect API key provided: sk-proj-abc123***xyz9.")
        == "Incorrect API key provided: sk-….")
    #expect(CloudTranscriptionClient.errorMessage(Data(#"{"error":{"message":"key sk-abcdefgh"}}"#.utf8),
                                                  status: 401).contains("401"))
    #expect(!CloudTranscriptionClient.errorMessage(Data(#"{"error":{"message":"key sk-abcdefgh"}}"#.utf8),
                                                   status: 401).contains("sk-"))
}

// MARK: - Numbers, unspaced scripts, and the review page's storage

@Test func evalNumberPunctuationIsAWordDifference() {
    #expect(EvalText.key("1.5") != EvalText.key("15"))
    #expect(EvalText.key("-5") != EvalText.key("5"))
    #expect(EvalText.key("−5") == EvalText.key("-5"))
    #expect(EvalText.key("(-5)") == "-5")
    #expect(EvalText.key("3:30") != EvalText.key("330"))
    #expect(EvalText.key("1-2") != EvalText.key("12"))
    #expect(EvalText.key("1.5.") == EvalText.key("1.5"))
    // A leading decimal separator, with or without a minus sign, is part of the number.
    #expect(EvalText.key(".5") == ".5" && EvalText.key(".5") != EvalText.key("5"))
    #expect(EvalText.key("-.5") == "-.5" && EvalText.key("-.5") != EvalText.key(".5"))
    // An exponent's sign too.
    #expect(EvalText.key("1e-5") == "1e-5" && EvalText.key("1E-5") != EvalText.key("1e5"))
    #expect(EvalText.key("type-2") == "type2")
    #expect(EvalText.key("(,5)") == ",5")
    #expect(EvalText.key("v.2") == "v2")
    #expect(EvalText.key("COVID-19") == "covid19")
    #expect(EvalText.key("well-known,") == "wellknown")
    #expect(EvalText.key("5%") != EvalText.key("5"))
    #expect(EvalText.key("$50") != EvalText.key("€50"))
    #expect(EvalText.key("$50.") == EvalText.key("$50"))
    #expect(EvalText.tokens("50 € today").map(EvalText.key) == ["50€", "today"])
    #expect(EvalText.key("100%,") == "100%")
    #expect(EvalText.tokens("5 % more").map(EvalText.key) == ["5%", "more"])
    #expect(EvalText.tokens("5\u{00A0}% more").map(EvalText.key) == ["5%", "more"])
    #expect(EvalText.key("5‰") != EvalText.key("5%"))
    #expect(EvalText.key("-$50") != EvalText.key("$50"))
    #expect(EvalText.key("−€5") == "-€5")
    #expect(EvalText.tokens("it costs $ 50 now") == ["it", "costs", "$ 50", "now"])
    #expect(EvalText.tokens("costs $ 50").map(EvalText.key) != EvalText.tokens("costs € 50").map(EvalText.key))
    #expect(EvalText.tokens("costs $ 50").map(EvalText.key) == EvalText.tokens("costs $50").map(EvalText.key))
    #expect(EvalText.tokens("it costs $") == ["it", "costs $"])
    for (localWord, cloudWord) in [("1.5", "15"), ("-5", "5"), ("5%", "5"), ("$50", "€50"), ("-$50", "$50"),
                                   (".5", "5"), ("-.5", "5"), ("1e-5", "1e5")] {
        let result = WindowComparer.compare(track: "mic", local: timed(["it", "is", localWord, "degrees"]),
                                            cloud: untimed("it is \(cloudWord) degrees"), start: 0, end: 10)
        #expect(result.score.substitutions == 1)
        #expect(result.passages.map(\.group) == [.numbers])
        #expect(result.passages.map(\.local) == [localWord])
        let data = EvalReviewPage.pageData(
            report: evalReport(passages: result.passages.map { var p = $0; p.id = "mic-1"; return p }),
            run: CloudRunRecord(id: "r", sessionID: "SESSION", createdAt: Date(), request: .init(model: "m"),
                                timestampRequest: nil, vocabulary: false, maxSegmentSeconds: 300, tracks: []),
            sessionName: "S")
        #expect(data.items.map(\.local) == [localWord])
    }
}

@Test func evalUnspacedScriptsAreCutTheSameWayOnBothSides() {
    #expect(EvalText.tokens("你好世界") == ["你", "好", "世", "界"])
    #expect(EvalText.tokens("我用iPhone手机。") == ["我", "用", "iPhone", "手", "机。"])
    #expect(EvalText.tokens("hello — there") == ["hello —", "there"])
    #expect(EvalText.pieces("你好 世界").map(\.spaceBefore) == [true, false, true, false])

    // The recognizer timed "你好" and "世界" as two words; the text has no space.
    let segment = TranscriptSegment(start: 1, end: 3, text: "你好世界", words: [
        TimedWord(text: "你好", start: 1, end: 2, utf16Offset: 0, utf16Length: 2),
        TimedWord(text: "世界", start: 2, end: 3, utf16Offset: 2, utf16Length: 2),
    ], track: "mic")
    let local = EvalCompare.segmentTokens(words: WordTiming.effectiveWords(of: segment), text: segment.text,
                                          isEcho: [false, true])
    #expect(local.map(\.text) == ["你", "好", "世", "界"])
    #expect(local.map(\.start) == [1, 1, 2, 2])
    #expect(local.map(\.echo) == [false, false, true, true])
    #expect(EvalText.join(local) == "你好世界")

    // A second of overlap holds about ten characters: the five repeated ones go.
    #expect(CloudSegmentation.stitch([("开始你好世界啊", 0), ("你好世界啊再见", 1)])
        == [["开", "始", "你", "好", "世", "界", "啊"], ["再", "见"]])
    let words = CloudSegmentation.stitchPieces([("你好世界", 0)])[0].map(\.text)
    let cloud = CloudTrackResult(run: "r", track: "mic", model: "m", segments: [
        .init(index: 0, sessionStart: 0, sessionEnd: 10, renderStart: 0, renderEnd: 10, overlapSeconds: 0,
              silent: false, text: "你好世界", words: words, timedWords: nil),
    ], text: "")
    let plain = local.map { var token = $0; token.echo = false; return token }
    let compared = EvalCompare.compareTrack(track: "mic", local: plain, cloud: cloud)
    #expect(compared.report.score.edits == 0)
    #expect(compared.passages.isEmpty)
    // An older run's words, stitched at whitespace, are cut again.
    let older = CloudTrackResult.Segment(index: 0, sessionStart: 0, sessionEnd: 10, renderStart: 0, renderEnd: 10,
                                         overlapSeconds: 0, silent: false, text: "", words: ["你好世界"],
                                         timedWords: nil)
    #expect(EvalCompare.cloudTokens(older).map(\.text) == ["你", "好", "世", "界"])

    // The gold keeps the text as written; a reviewed character goes back without spaces.
    #expect(EvalApply.goldTrack(track: "mic", local: plain, replacements: []).text == "你好世界")
    let passage = EvalPassage(id: "mic-1", track: "mic", start: 2, end: 2.5, local: "世", cloud: "视",
                              group: .otherWords, before: "你好", after: "界", localFirst: 2, localEnd: 3)
    #expect(EvalApply.goldTrack(track: "mic", local: plain, replacements: [
        (passage, .init(id: "mic-1", choice: .cloud, text: "视")),
    ]).text == "你好视界")
    let mixed = TranscriptSegment(start: 0, end: 2, text: "hello 世界 again",
                                  words: [TimedWord(text: "hello", start: 0, end: 1, utf16Offset: 0, utf16Length: 5)])
    let mixedTokens = EvalCompare.segmentTokens(words: WordTiming.effectiveWords(of: mixed), text: mixed.text,
                                                isEcho: [false])
    #expect(EvalText.join(mixedTokens) == "hello 世界 again")
    // Words that do not lie in the text (an edited segment) are written out and cut instead.
    let edited = TranscriptSegment(start: 0, end: 2, text: "totally different", words: [
        TimedWord(text: "你好", start: 0, end: 1, utf16Offset: 0, utf16Length: 2),
        TimedWord(text: "世界", start: 1, end: 2, utf16Offset: 2, utf16Length: 2),
    ])
    let editedTokens = EvalCompare.segmentTokens(words: WordTiming.effectiveWords(of: edited), text: edited.text,
                                                 isEcho: [false, false])
    #expect(EvalText.join(editedTokens) == "你好世界")
    #expect(editedTokens.map(\.start) == [0, 0, 1, 1])
}

/// The review page's storage code (between its BEGIN/END review-store marks) in JavaScriptCore, with a storage
/// whose writes can be made to fail.
@Test func evalReviewPageKeepsDecisionsItCouldNotStore() throws {
    let template = EvalReviewPage.template
    let begin = try #require(template.range(of: "// BEGIN review-store"))
    let end = try #require(template.range(of: "// END review-store"))
    let code = String(template[begin.upperBound..<end.lowerBound])
    let context = try #require(JSContext())
    var failure: String?
    context.exceptionHandler = { _, value in failure = value?.toString() }
    context.evaluateScript(code)
    // A localStorage stand-in: string keys in insertion order, writes that can be made to fail.
    context.evaluateScript("""
        function makeStorage() {
          var items = {}, order = [];
          var s = { failWrites: false, items: items };
          Object.defineProperty(s, "length", { get: function () { return order.length; } });
          s.key = function (i) { return order[i] === undefined ? null : order[i]; };
          s.getItem = function (k) { return Object.prototype.hasOwnProperty.call(items, k) ? items[k] : null; };
          s.setItem = function (k, v) {
            if (s.failWrites) throw new Error("QuotaExceededError");
            if (!Object.prototype.hasOwnProperty.call(items, k)) order.push(k);
            items[k] = String(v);
          };
          return s;
        }
        var storage = makeStorage();
        var store = makeStore(storage, "k");
        function ids(s) { return Object.keys(s.state.decisions).sort().join(","); }
        function stored() {
          return Object.keys(storage.items).filter(function (k) { return k.indexOf("k|d|") === 0; })
            .map(function (k) { return k.slice(4); }).sort().join(",");
        }
        store.decide("a", "edited", "1");
        storage.failWrites = true;
        store.decide("b", "edited", "2");
        store.decide("c", "edited", "3");
        """)
    #expect(failure == nil)
    #expect(context.evaluateScript("ids(store)").toString() == "a,b,c")
    #expect(context.evaluateScript("store.failed").toBool())
    #expect(context.evaluateScript("store.pending.length").toInt32() == 2)
    #expect(context.evaluateScript("stored()").toString() == "a")
    // Another tab stores "d": this page takes it and keeps its own unsaved decisions on top.
    context.evaluateScript("""
        storage.failWrites = false;
        var other = makeStore(storage, "k");
        other.decide("d", "cloud", "4");
        storage.failWrites = true;
        store.reload();
        """)
    #expect(context.evaluateScript("ids(store)").toString() == "a,b,c,d")
    // Once storage works again, the next change stores everything.
    context.evaluateScript("storage.failWrites = false; store.decide(\"e\", \"edited\", \"5\");")
    #expect(context.evaluateScript("stored()").toString() == "a,b,c,d,e")
    #expect(!context.evaluateScript("store.failed").toBool())
    #expect(context.evaluateScript("store.pending.length").toInt32() == 0)
    // Two tabs that both read before either wrote keep each other's decisions and terms.
    context.evaluateScript("""
        var shared = makeStorage();
        var left = makeStore(shared, "k"), right = makeStore(shared, "k");
        left.decide("p", "local", "x");
        right.decide("q", "cloud", "y");
        left.addTerm("Kubernetes");
        right.addTerm("Grafana");
        right.removeTerm("Kubernetes");
        left.reload();
        """)
    #expect(context.evaluateScript("ids(left)").toString() == "p,q")
    #expect(context.evaluateScript("left.state.terms.join(',')").toString() == "Grafana")
    #expect(context.evaluateScript("ids(makeStore(shared, 'k'))").toString() == "p,q")
    // Decisions a page kept under the key itself are read under the newer ones.
    context.evaluateScript("""
        var old = makeStorage();
        old.setItem("k", JSON.stringify({ decisions: { m: { choice: "local", text: "" } }, terms: ["Priya"] }));
        var upgraded = makeStore(old, "k");
        upgraded.removeTerm("Priya");
        """)
    #expect(context.evaluateScript("ids(makeStore(old, 'k'))").toString() == "m")
    #expect(context.evaluateScript("makeStore(old, 'k').state.terms.length").toInt32() == 0)
    // Storage that cannot even be read keeps every decision in the page.
    context.evaluateScript("""
        var blocked = function () { throw new Error("blocked"); };
        var broken = makeStore({ length: 0, key: blocked, getItem: blocked, setItem: blocked }, "k");
        broken.decide("x", "local", "");
        broken.decide("y", "cloud", "");
        """)
    #expect(context.evaluateScript("Object.keys(broken.state.decisions).join(',')").toString() == "x,y")
    #expect(context.evaluateScript("broken.failed").toBool())
    // A long edit the storage refuses, then a short one of the same passage that fits: the short one stays.
    context.evaluateScript("""
        var small = makeStorage();
        var realSet = small.setItem;
        small.setItem = function (k, v) { if (String(v).length > 60) throw new Error("QuotaExceededError"); realSet(k, v); };
        var editing = makeStore(small, "k");
        editing.decide("z", "edited", new Array(100).join("long "));
        editing.decide("z", "edited", "short");
        """)
    #expect(context.evaluateScript("editing.state.decisions.z.text").toString() == "short")
    #expect(context.evaluateScript("editing.pending.length").toInt32() == 0)
    #expect(context.evaluateScript("JSON.parse(small.getItem('k|d|z')).text").toString() == "short")
    // Terms and IDs are arbitrary text: ones named like Object's own properties are kept, stored, and read back.
    context.evaluateScript("""
        var names = makeStorage();
        names.setItem("k", JSON.stringify({ terms: ["hasOwnProperty"] }));
        var naming = makeStore(names, "k");
        naming.addTerm("__proto__");
        naming.addTerm("constructor");
        naming.decide("__proto__", "local", "x");
        var reread = makeStore(names, "k");
        """)
    #expect(context.evaluateScript("naming.state.terms.join(',')").toString()
        == "hasOwnProperty,__proto__,constructor")
    #expect(context.evaluateScript("reread.state.terms.join(',')").toString()
        == "hasOwnProperty,__proto__,constructor")
    #expect(context.evaluateScript("Object.keys(reread.state.decisions).join(',')").toString() == "__proto__")
    #expect(context.evaluateScript("reread.state.decisions['__proto__'].text").toString() == "x")
    #expect(failure == nil)
}

@Test func evalCloudWordFreedFromDistantEchoPairsWithTheLocalWordItStandsFor() {
    // Local "yes" at 0 s is echo; local "no" at 10 s; the cloud heard "yes" at 10 s. Without the echo the two
    // transcripts differ by one substitution, not a deletion and an insertion.
    let local = [EvalToken(text: "yes", start: 0, end: 0.5, echo: true), EvalToken(text: "no", start: 10, end: 10.5)]
    let cloud = [EvalToken(text: "yes", start: 10, end: 10.5)]
    let result = WindowComparer.compare(track: "mic", local: local, cloud: cloud, start: 0, end: 20)
    #expect(result.score.substitutions == 1)
    #expect(result.score.localOnly == 0 && result.score.cloudOnly == 0)
    #expect(abs((result.score.werAgainstLocal ?? 0) - 1) < 1e-9)
}

@Test func evalCurrencyStaysPartOfSignedAndFractionalAmounts() {
    #expect(EvalText.key("$-50") != EvalText.key("-50"))
    #expect(EvalText.key("€-50") != EvalText.key("$-50"))
    #expect(EvalText.key("$.5") != EvalText.key(".5"))
    #expect(EvalText.key("$50,") == EvalText.key("$50"))
    #expect(EvalText.key("(50%)") == EvalText.key("50 %"))
}

@Test func evalSpacedCurrencyJoinsSignedAndFractionalAmounts() {
    #expect(EvalText.tokens("balance $ -50") == ["balance", "$ -50"])
    #expect(EvalText.key("$ -50") != EvalText.key("€ -50"))
    #expect(EvalText.tokens("$ -50 now") == ["$ -50", "now"])
    #expect(EvalText.tokens("€ .5") == ["€ .5"])
    // A currency sign before a word is not part of it.
    #expect(!EvalText.tokens("$ and more").contains("$ and"))
}

@Test func evalStandaloneSignsJoinTheAmountAfterThem() {
    #expect(EvalText.tokens("it was - 5 degrees") == ["it", "was", "- 5", "degrees"])
    #expect(EvalText.tokens("- 5 degrees") == ["- 5", "degrees"])
    #expect(EvalText.tokens("up + 3 points") == ["up", "+ 3", "points"])
    #expect(EvalText.tokens("a \u{2212} 2 drop") == ["a", "\u{2212} 2", "drop"])
    #expect(EvalText.tokens("owes - $ 50") == ["owes", "- $ 50"])
    #expect(EvalText.tokens("owes - $50") == ["owes", "- $50"])
    #expect(EvalText.tokens("down - .5 today") == ["down", "- .5", "today"])
    #expect(EvalText.key("- 5") == EvalText.key("-5"))
    #expect(EvalText.key("- 5") != EvalText.key("5"))
    #expect(EvalText.key("+ 3") != EvalText.key("3"))
    // Before anything but an amount, a sign is punctuation of the word before.
    #expect(EvalText.tokens("well - I think") == ["well -", "I", "think"])
    #expect(EvalText.tokens("it ends -") == ["it", "ends -"])
    // So a dropped sign is a word difference, shown for review.
    let result = WindowComparer.compare(track: "mic", local: timed(EvalText.tokens("- 5 degrees")),
                                        cloud: untimed("5 degrees"), start: 0, end: 10)
    #expect(result.score.substitutions == 1)
    #expect(result.passages.count == 1)
    // The gold transcript keeps it.
    let local = timed(EvalText.tokens("it was - 5 degrees"))
    #expect(EvalApply.goldTrack(track: "mic", local: local, replacements: []).text == "it was - 5 degrees")
}
