import Foundation
import Testing
@testable import HolosCore

// DictationRecord, HistoryRetention, HistoryDay, and WordDiff (docs/design.md "Dictation history").

private let historyNow = Date(timeIntervalSince1970: 1_790_000_000)

private func record(_ text: String, heard: String? = nil, app: String? = "Mail", date: Date = historyNow,
                    outcome: DictationRecord.Outcome = .init(kind: .inserted),
                    fixes: DictationRecord.Fixes = .init()) -> DictationRecord {
    DictationRecord(id: UUID(), date: date, app: app, language: "en-CA", text: text, heard: heard ?? text,
                    fixes: fixes, outcome: outcome, seconds: 4.4)
}

@Test func recordCountsWordsAndRoundTripsAsOneJSONLine() throws {
    let original = record("Send the pull request today.", heard: "um send the bull request today")
    #expect(original.words == 5)
    let line = try HolosJSON.line(original)
    #expect(line.filter { $0 == 0x0A }.count == 1, "One line per record.")
    let decoded = try HolosJSON.decoder().decode(DictationRecord.self, from: line.dropLast())
    #expect(decoded.text == original.text)
    #expect(decoded.heard == original.heard)
    #expect(decoded.id == original.id)
    #expect(decoded.outcome == original.outcome)
}

@Test func resultTextNamesTheAppAndTheWayIn() {
    #expect(record("hi", app: "Mail").resultText == "Inserted into Mail")
    #expect(record("hi", app: "Terminal", outcome: .init(kind: .typed)).resultText == "Typed into Terminal")
    let copy = record("hi", outcome: .init(kind: .needsCopy, reason: "This field cannot be safely updated; use Copy Result."))
    #expect(copy.resultText == "Not inserted — This field cannot be safely updated. Use Copy.")
    #expect(record("hi", outcome: .init(kind: .targetChanged)).resultText.hasPrefix("Not inserted — the app or field changed"))
    #expect(record("hi", app: nil, outcome: .init(kind: .unverified)).resultText == "Unverified — check the app before using Copy.")
    let partial = record("hi", outcome: .init(kind: .needsCopy, reason: "Insertion stopped.", partial: true))
    #expect(partial.resultText
        == "Partly written into Mail — Insertion stopped. Check the field before using Copy; it has the whole text.",
        "No rest was kept, so Copy has the whole text (partlyWrittenRecordCopiesOnlyTheRestCopyResultOffered).")
}

@Test func badgesSayFixedOrNotInserted() {
    #expect(record("Pull request.", heard: "pull request").badge == nil, "Case and punctuation are not a fix.")
    #expect(record("Pull request.", heard: "bull request").badge == "Fixed")
    #expect(record("x", outcome: .init(kind: .needsCopy)).badge == "Not inserted")
    #expect(record("x", outcome: .init(kind: .targetChanged)).badge == "Not inserted")
    #expect(record("x", outcome: .init(kind: .inserted, partial: true)).badge == "Not inserted")
    #expect(record("x", outcome: .init(kind: .unverified)).badge == "Unverified")
}

@Test func fixesAndLengthTexts() {
    let fixes = DictationRecord.Fixes(fillersRemoved: true, corrections: 1, aiChangedWords: 1)
    #expect(record("a b", fixes: fixes).fixesText == "Apple Intelligence changed 1 word · 1 correction · fillers removed")
    #expect(record("a b").fixesText == "None")
    #expect(record("one two").lengthText == "2 words · 4 seconds")
}

@Test func searchMatchesTextAppAndHeardWithoutCaseOrAccents() {
    let entry = record("Réunion à midi", heard: "reunion a midi", app: "Calendar")
    #expect(entry.matches(""))
    #expect(entry.matches("REUNION"))
    #expect(entry.matches("calen"))
    #expect(!entry.matches("Slack"))
}

@Test func retentionDefaultsToThirtyDaysAndCutsOffOnlyForDayLimits() {
    #expect(HistoryRetention.saved(nil) == .days30)
    #expect(HistoryRetention.saved("bogus") == .days30)
    #expect(HistoryRetention.saved("off") == .off)
    #expect(HistoryRetention.saved("7") == .days7)
    #expect(HistoryRetention.days7.cutoff(now: historyNow) == historyNow.addingTimeInterval(-7 * 86_400))
    #expect(HistoryRetention.days30.cutoff(now: historyNow) == historyNow.addingTimeInterval(-30 * 86_400))
    #expect(HistoryRetention.forever.cutoff(now: historyNow) == nil)
    #expect(HistoryRetention.off.cutoff(now: historyNow) == nil, "Off offers to clear; it never sweeps on its own.")
    #expect(!HistoryRetention.off.records)
    #expect(HistoryRetention.days30.records)
}

@Test func dayTitlesAndGroupsNewestFirst() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Toronto"))
    let locale = Locale(identifier: "en_US")
    let now = historyNow
    let yesterday = now.addingTimeInterval(-86_400)
    let older = now.addingTimeInterval(-5 * 86_400)
    #expect(HistoryDay.title(for: now, now: now, calendar: calendar, locale: locale) == "Today")
    #expect(HistoryDay.title(for: yesterday, now: now, calendar: calendar, locale: locale) == "Yesterday")
    let olderTitle = HistoryDay.title(for: older, now: now, calendar: calendar, locale: locale)
    #expect(olderTitle != "Today" && olderTitle != "Yesterday" && !olderTitle.isEmpty)

    let first = record("first", date: older)
    let second = record("second", date: now)
    let third = record("third", date: now)  // same second as `second`: file order decides
    let groups = HistoryDay.groups([first, second, third], now: now, calendar: calendar, locale: locale)
    #expect(groups.map(\.title) == ["Today", olderTitle])
    #expect(groups[0].records.map(\.text) == ["third", "second"])
    #expect(groups[1].records.map(\.text) == ["first"])
}

@Test func wordDiffFindsChangedHeardWordsAndCounts() {
    let heard = "um send the bull request today"
    let written = "Send the pull request today."
    let changed = WordDiff.changedRanges(in: heard, comparedTo: written).map { String(heard[$0]) }
    #expect(changed == ["um", "bull"])
    #expect(WordDiff.changedWordCount(from: "send the bull request", to: "send the pull request") == 1)
    #expect(WordDiff.changedWordCount(from: "same words", to: "Same words.") == 0)
    #expect(WordDiff.changedRanges(in: "", comparedTo: "anything").isEmpty)
}

@Test func correctionsCountTheirReplacements() {
    let list = CorrectionList(entries: [Correction(heard: "bull request", meant: "pull request"),
                                        Correction(heard: "get hub", meant: "GitHub")])
    let result = list.applyCounting(to: "open a bull request on get hub, then another bull request")
    #expect(result.text == "open a pull request on GitHub, then another pull request")
    #expect(result.count == 3)
    #expect(CorrectionList().applyCounting(to: "nothing").count == 0)
}

// MARK: - How a dictation ends

@Test func partlyWrittenRecordCopiesOnlyTheRestCopyResultOffered() throws {
    let partial = DictationRecord(
        id: UUID(), date: historyNow, app: "Mail", language: "en-CA", text: "Send it today and call Anna.",
        heard: "send it today and call anna", unwritten: " and call Anna.",
        outcome: .init(kind: .needsCopy, reason: "Insertion stopped.", partial: true), seconds: 3)
    #expect(partial.unwritten == " and call Anna.", "The leading space is kept, as Copy Result keeps it.")
    #expect(partial.copyText == " and call Anna.")
    #expect(partial.text == "Send it today and call Anna.", "History still shows the whole dictation.")
    #expect(partial.resultText == "Partly written into Mail — Insertion stopped. Use Copy for the rest.")

    let decoded = try HolosJSON.decoder().decode(DictationRecord.self, from: HolosJSON.line(partial).dropLast())
    #expect(decoded == partial)

    // A dictation that was not partly written copies its whole text, whatever was passed.
    let whole = DictationRecord(id: UUID(), date: historyNow, app: "Mail", language: "en-CA", text: "Hello.",
                                heard: "hello", unwritten: "Hello.", outcome: .init(kind: .needsCopy), seconds: 1)
    #expect(whole.unwritten == nil)
    #expect(whole.copyText == "Hello.")
    // A partial record without a kept rest (an older line) says Copy has the whole text.
    let older = record("x y", outcome: .init(kind: .needsCopy, reason: "Stopped.", partial: true))
    #expect(older.unwritten == nil)
    #expect(older.resultText.hasSuffix("Check the field before using Copy; it has the whole text."))
}

@Test func recordLinesWithoutTheRestStillDecode() throws {
    let line = try HolosJSON.line(record("Old line"))
    let text = try #require(String(data: line, encoding: .utf8))
    #expect(!text.contains("unwritten"), "Nothing is written for a dictation with no rest.")
    let decoded = try HolosJSON.decoder().decode(DictationRecord.self, from: line.dropLast())
    #expect(decoded.unwritten == nil)
}

@Test func failedDictationOutcomeFollowsTheStreamAsTheNormalEndDoes() {
    typealias Outcome = DictationRecord.Outcome
    // An unconfirmed streamed write, then a recognition failure: still unverified, never "Not inserted".
    let unverified = Outcome.afterFailure(reason: "Recognition failed.", rest: " the rest", wroteAny: true,
                                          typed: false, unverified: true, targetMoved: false)
    #expect(unverified == .init(kind: .unverified, reason: "Recognition failed.", partial: true))
    #expect(record("a", outcome: unverified).badge == "Unverified")
    let moved = Outcome.afterFailure(reason: "Recognition failed.", rest: " the rest", wroteAny: true,
                                     typed: false, unverified: false, targetMoved: true)
    #expect(moved.kind == .targetChanged)
    #expect(moved.partial)
    let nothing = Outcome.afterFailure(reason: "Recognition failed.", rest: "all of it", wroteAny: false,
                                       typed: false, unverified: false, targetMoved: false)
    #expect(nothing == .init(kind: .needsCopy, reason: "Recognition failed.", partial: false))
    #expect(Outcome.afterFailure(reason: "x", rest: nil, wroteAny: true, typed: false, unverified: false,
                                 targetMoved: false) == .transcriptDiffers)
    // Every committed word was written before the failure.
    #expect(Outcome.afterFailure(reason: "x", rest: " ", wroteAny: true, typed: true, unverified: false,
                                 targetMoved: false) == .init(kind: .typed))
    #expect(Outcome.afterFailure(reason: "x", rest: "", wroteAny: true, typed: false, unverified: false,
                                 targetMoved: false) == .init(kind: .inserted))
    // The same order as the normal end's blocked outcome: unverified, then target changed, then Copy.
    #expect(Outcome.notWritten(reason: "r", unverified: true, targetMoved: true, partial: false).kind == .unverified)
    #expect(Outcome.notWritten(reason: "r", unverified: false, targetMoved: false, partial: false).kind == .needsCopy)
}

@Test func endTextIsWhatWasWrittenOrOfferedWithTheFix() {
    // Apple Intelligence fixed the streamed chunk; the rest was offered as recognized.
    let fixed = DictationRecord.endText(recognized: "I sent the male to Anna", fixChanged: true,
                                        fixedWritten: "I sent the mail", rest: " to Anna")
    #expect(fixed.text == "I sent the mail to Anna")
    #expect(fixed.aiChangedWords == 1)
    let unchanged = DictationRecord.endText(recognized: "I sent it", fixChanged: false, fixedWritten: "I sent",
                                            rest: " it")
    #expect(unchanged.text == "I sent it")
    #expect(unchanged.aiChangedWords == 0)
    // The transcript no longer extends what was written: the recognized text stays.
    let diverged = DictationRecord.endText(recognized: "Something else", fixChanged: true,
                                           fixedWritten: "I sent the mail", rest: nil)
    #expect(diverged.text == "Something else")
    #expect(diverged.aiChangedWords == 0)
    // The final transcript came back empty after text was written while speaking: what is in the field is kept.
    let emptyFinal = DictationRecord.endText(recognized: "", fixChanged: false, fixedWritten: "", rest: nil,
                                             inserted: "Send the report ")
    #expect(emptyFinal.text == "Send the report ")
    let emptyFinalFixed = DictationRecord.endText(recognized: " ", fixChanged: true, fixedWritten: "I sent the mail",
                                                  rest: nil, inserted: "I sent the male")
    #expect(emptyFinalFixed.text == "I sent the mail")
    #expect(emptyFinalFixed.aiChangedWords == 1)
    #expect(DictationRecord.endText(recognized: "", fixChanged: false, fixedWritten: "", rest: nil).text.isEmpty,
            "Nothing recognized and nothing written: no record.")
    #expect(DictationRecord.Outcome.transcriptEmpty.kind == .unverified)
}

@Test func historyChangesApplyAgainWithoutDuplicates() {
    let old = record("old", date: historyNow.addingTimeInterval(-40 * 86_400))
    let kept = record("kept")
    let added = record("added")
    var records = [old, kept]
    DictationHistoryChange.add(added).apply(to: &records)
    DictationHistoryChange.add(added).apply(to: &records)
    #expect(records == [old, kept, added], "Adding a record already there does nothing.")
    DictationHistoryChange.sweep(before: historyNow.addingTimeInterval(-30 * 86_400)).apply(to: &records)
    #expect(records == [kept, added])
    DictationHistoryChange.delete(kept.id).apply(to: &records)
    #expect(records == [added])
    DictationHistoryChange.clear.apply(to: &records)
    #expect(records.isEmpty)
}
