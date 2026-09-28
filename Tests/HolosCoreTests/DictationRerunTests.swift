import Foundation
import Synchronization
import Testing
@testable import HolosCore

// Run Again's text steps, comparison, and report shapes (docs/design.md "Dictation audio and Run Again").

private let rerunNow = Date(timeIntervalSince1970: 1_790_000_000)

private func saved(_ text: String, heard: String, fixes: DictationRecord.Fixes = .init(),
                   language: String = "en-US") -> DictationRecord {
    DictationRecord(id: UUID(), date: rerunNow, app: "Notes", language: language, text: text, heard: heard,
                    fixes: fixes, outcome: .init(kind: .inserted), seconds: 3,
                    audio: .init(file: "x.m4a", seconds: 3.2))
}

/// A model that fixes "whether" to "weather" and records each chunk it was asked about.
private final class FakeModel: Sendable {
    let prompts = Mutex<[String]>([])

    var model: TranscriptFixer.Model {
        { [self] _, prompt in
            prompts.withLock { $0.append(prompt) }
            return String(prompt.dropFirst("Text: ".count)).replacingOccurrences(of: "whether", with: "weather")
        }
    }
}

private func fixer(_ model: FakeModel, corrections: CorrectionList = CorrectionList()) -> TranscriptFixer {
    TranscriptFixer(corrections: corrections, referenceBudget: 1_000, timeout: .seconds(30), model: model.model)
}

@Test func wordChangesListWhatWasReplacedAddedAndRemoved() {
    #expect(WordDiff.changes(from: "I use a boon to at work.", to: "I use Ubuntu at work.")
        == [.init(from: "a boon to", to: "Ubuntu")])
    #expect(WordDiff.changes(from: "um send it", to: "send it") == [.init(from: "um", to: "")])
    #expect(WordDiff.changes(from: "send it", to: "send it now") == [.init(from: "", to: "now")])
    #expect(WordDiff.changes(from: "Same words.", to: "same words") == [])
    #expect(WordDiff.changes(from: "a b c d", to: "x b c y")
        == [.init(from: "a", to: "x"), .init(from: "d", to: "y")])
    #expect(WordDiff.describe([.init(from: "a boon to", to: "Ubuntu"), .init(from: "um", to: ""),
                               .init(from: "", to: "now")]) == "“a boon to” → “Ubuntu”; removed “um”; added “now”")
}

@Test func pipelineRemovesFillersThenAppliesCorrectionsAsLiveDictationDoes() async {
    let corrections = CorrectionList(entries: [Correction(heard: "a boon to", meant: "Ubuntu")])
    let pipeline = DictationTextPipeline(language: "en-US", removeFillers: true, corrections: corrections)
    let output = await pipeline.run(segments: [" Um, I installed a boon to ", "", "on the laptop."])
    #expect(output.heard == "Um, I installed a boon to on the laptop.")
    #expect(output.withoutFillers == "I installed a boon to on the laptop.")
    #expect(output.corrected == "I installed Ubuntu on the laptop.")
    #expect(output.written == output.corrected)
    #expect(output.corrections == 1)
    #expect(output.fillersRemoved)
    #expect(!output.aiFixed)

    let keepFillers = DictationTextPipeline(language: "en-US", removeFillers: false, corrections: corrections)
    let kept = await keepFillers.run(segments: ["Um, I installed a boon to."])
    #expect(kept.written == "Um, I installed Ubuntu.")
    #expect(!kept.fillersRemoved)
}

@Test func pipelineFixesCommittedChunksThenTheRestAsFinal() async {
    let model = FakeModel()
    var pipeline = DictationTextPipeline(language: "en-US", removeFillers: true, corrections: CorrectionList())
    pipeline.fixer = fixer(model)
    let output = await pipeline.run(segments: ["I checked whether it rained", "and whether it will."])
    // The first result was committed while speaking: fixed as a chunk; the rest on release.
    #expect(model.prompts.withLock { $0 } == ["Text: I checked whether it rained",
                                              "Text: and whether it will."])
    #expect(output.corrected == "I checked whether it rained and whether it will.")
    #expect(output.written == "I checked weather it rained and weather it will.")
    #expect(output.aiFixed)
    #expect(output.aiChangedWords == 2)
    #expect(output.aiOutcomes == [.fixed, .fixed])
}

@Test func pipelineWithAFixThatChangesNothingKeepsTheText() async {
    let model = FakeModel()
    var pipeline = DictationTextPipeline(language: "en-US", removeFillers: true, corrections: CorrectionList())
    pipeline.fixer = fixer(model)
    let output = await pipeline.run(segments: ["Nothing to change here."])
    #expect(output.written == "Nothing to change here.")
    #expect(output.aiChangedWords == 0)
    #expect(output.aiOutcomes == [.unchanged])
    let empty = await pipeline.run(segments: ["", "  "])
    #expect(empty.written.isEmpty)
    #expect(!empty.aiFixed)
}

@Test func reportComparesThenAndNowAndNamesTheRecognizer() async {
    let pipeline = DictationTextPipeline(language: "en-US", removeFillers: true, corrections: CorrectionList())
    let record = saved("I use a boon to at work.", heard: "I use a boon to at work.")
    let output = await pipeline.run(segments: ["I use Ubuntu at work."])
    let report = DictationRerunReport(record: record, output: output, pipeline: pipeline)
    #expect(report.heard.changed)
    #expect(report.heard.changes == [.init(from: "a boon to", to: "Ubuntu")])
    #expect(report.written.changed)
    #expect(report.changed)
    #expect(report.changedBy == [.recognizer])
    #expect(report.steps.map(\.step) == [.recognizer, .fillers, .corrections, .aiFix])
    #expect(report.steps[0].summary == "Recognizer: heard differently from then: “a boon to” → “Ubuntu”")
    #expect(report.steps[2].summary == "Corrections: nothing replaced")
    #expect(report.steps[3].summary == "Apple Intelligence: off")
    #expect(report.audioSeconds == 3.2)
    #expect(report.fixes == .init())
}

@Test func reportNamesANewCorrection() async {
    let corrections = CorrectionList(entries: [Correction(heard: "a boon to", meant: "Ubuntu")])
    let pipeline = DictationTextPipeline(language: "en-US", removeFillers: true, corrections: corrections)
    let record = saved("I use a boon to at work.", heard: "I use a boon to at work.")
    let output = await pipeline.run(segments: ["I use a boon to at work."])
    let report = DictationRerunReport(record: record, output: output, pipeline: pipeline)
    #expect(!report.heard.changed)
    #expect(report.written.now == "I use Ubuntu at work.")
    #expect(report.changedBy == [.corrections])
    #expect(report.steps[2].summary == "Corrections: “a boon to” → “Ubuntu”")
    #expect(report.fixes.corrections == 1)
    #expect(report.steps[0].summary == "Recognizer: heard the same words as then")
}

@Test func reportNamesFillerRemovalAndTheFix() async {
    // Then: fillers were removed. Now: filler removal is off.
    let off = DictationTextPipeline(language: "en-US", removeFillers: false, corrections: CorrectionList())
    let record = saved("Send it.", heard: "Um, send it.", fixes: .init(fillersRemoved: true))
    let report = DictationRerunReport(record: record, output: await off.run(segments: ["Um, send it."]), pipeline: off,
                                      aiNote: "off")
    #expect(report.changedBy == [.fillers])
    #expect(report.steps[1].summary == "Filler removal: off")

    // Then: the fix changed nothing. Now: it changes a word.
    let model = FakeModel()
    var fixing = DictationTextPipeline(language: "en-US", removeFillers: true, corrections: CorrectionList())
    fixing.fixer = fixer(model)
    let plain = saved("I wonder whether it rains.", heard: "I wonder whether it rains.")
    let fixed = DictationRerunReport(record: plain, output: await fixing.run(segments: ["I wonder whether it rains."]),
                                     pipeline: fixing)
    #expect(fixed.changedBy == [.aiFix])
    #expect(fixed.written.now == "I wonder weather it rains.")
    #expect(fixed.steps[3].summary == "Apple Intelligence: “whether” → “weather”")

    // The same result as then: nothing behaved differently.
    let same = DictationRerunReport(record: saved("Send it.", heard: "Um, send it.", fixes: .init(fillersRemoved: true)),
                                    output: await fixing.run(segments: ["Um, send it."]), pipeline: fixing)
    #expect(!same.changed)
    #expect(same.changedBy == [])
}

@Test func reportAndBatchKeepTheirJSONShape() async throws {
    let pipeline = DictationTextPipeline(language: "fr-CA", removeFillers: true, corrections: CorrectionList())
    let record = saved("Bonjour.", heard: "Bonjour.", language: "fr-CA")
    let report = DictationRerunReport(record: record, output: await pipeline.run(segments: ["Bonjour tout le monde."]),
                                      pipeline: pipeline, aiNote: "off")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(report)) as? [String: Any])
    #expect(Set(object.keys) == ["id", "date", "app", "languageThen", "languageNow", "audioSeconds", "heard",
                                 "written", "steps", "changedBy", "changed", "fixes"])
    let written = try #require(object["written"] as? [String: Any])
    #expect(Set(written.keys) == ["then", "now", "changed", "changes"])
    let steps = try #require(object["steps"] as? [[String: Any]])
    #expect(steps.map { $0["step"] as? String } == ["recognizer", "fillers", "corrections", "aiFix"])
    #expect(Set(steps[0].keys) == ["step", "enabled", "input", "output", "changed", "changes", "note"]
        || Set(steps[0].keys) == ["step", "enabled", "input", "output", "changed", "changes"])
    #expect(object["changedBy"] as? [String] == ["recognizer"])

    let other = saved("Salut.", heard: "Salut.", language: "fr-CA")
    let batch = DictationRerunBatch(
        settings: .init(language: "fr-CA", removeFillers: true, aiFix: false, aiFixUnavailable: nil, corrections: 0),
        dictations: [.init(report: report), .init(record: other, skipped: "no audio kept")])
    #expect(batch.summary.dictations == 2)
    #expect(batch.summary.rerun == 1)
    #expect(batch.summary.changed == 1)
    #expect(batch.summary.skipped == 1)
    #expect(batch.summary.byStep["recognizer"] == 1)
    let batchObject = try #require(try JSONSerialization.jsonObject(with: encoder.encode(batch)) as? [String: Any])
    #expect(Set(batchObject.keys) == ["settings", "dictations", "summary"])
    let items = try #require(batchObject["dictations"] as? [[String: Any]])
    #expect(items[0]["changed"] as? Bool == true)
    #expect(items[0]["changedBy"] as? [String] == ["recognizer"])
    #expect(items[1]["skipped"] as? String == "no audio kept")
    #expect(items[1]["changed"] == nil)
    // Decodes back as it was.
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(DictationRerunBatch.self, from: encoder.encode(batch)) == batch)
}

@Test func recordAudioLinkRoundTripsAndOlderLinesHaveNone() throws {
    let record = saved("Hello.", heard: "Hello.")
    let decoded = try HolosJSON.decoder().decode(DictationRecord.self, from: HolosJSON.line(record).dropLast())
    #expect(decoded.audio == .init(file: "x.m4a", seconds: 3.2))
    var older = record
    older.audio = nil
    let line = try HolosJSON.line(older)
    #expect(!String(decoding: line, as: UTF8.self).contains("audio"))
    #expect(try HolosJSON.decoder().decode(DictationRecord.self, from: line.dropLast()).audio == nil)
    #expect(DictationRecord.Audio.fileName(for: record.id) == "\(record.id.uuidString).m4a")
}

@Test func historyChangesUpdateAndDropAudio() {
    let a = saved("A.", heard: "A.")
    let b = saved("B.", heard: "B.")
    var records = [a, b]
    var changed = b
    changed.text = "Bee."
    DictationHistoryChange.update(changed).apply(to: &records)
    #expect(records.map(\.text) == ["A.", "Bee."])
    DictationHistoryChange.update(saved("C.", heard: "C.")).apply(to: &records)
    #expect(records.count == 2, "An update of a record no longer there adds nothing.")
    DictationHistoryChange.removeAudio.apply(to: &records)
    #expect(records.allSatisfy { $0.audio == nil })
}

@Test func lookupFindsLatestAndIDPrefixes() throws {
    let first = saved("One.", heard: "One.")
    var second = saved("Two.", heard: "Two.")
    second.date = rerunNow.addingTimeInterval(60)
    let third = saved("Three.", heard: "Three.")  // same date as `first`, recorded later
    let records = [first, second, third]
    #expect(try HistoryLookup.find("latest", in: records).id == second.id)
    #expect(try HistoryLookup.find("LATEST", in: [first, third]).id == third.id)
    #expect(try HistoryLookup.find(first.id.uuidString, in: records).id == first.id)
    #expect(try HistoryLookup.find(String(third.id.uuidString.prefix(8)).lowercased(), in: records).id == third.id)
    #expect(throws: HolosError.self) { try HistoryLookup.find("abc", in: records) }
    #expect(throws: HolosError.self) { try HistoryLookup.find("latest", in: []) }
    #expect(throws: HolosError.self) { try HistoryLookup.find("ffffffff-no", in: records) }
}

@Test func sinceTakesMinutesHoursDaysAndWeeks() {
    #expect(HistorySince.interval("90m") == 5_400)
    #expect(HistorySince.interval("12h") == 43_200)
    #expect(HistorySince.interval("7d") == 604_800)
    #expect(HistorySince.interval("2W") == 1_209_600)
    #expect(HistorySince.interval("7") == nil)
    #expect(HistorySince.interval("d") == nil)
    #expect(HistorySince.interval("-1d") == nil)
    #expect(HistorySince.interval("3y") == nil)
}

@Test func audioSettingIsOnUnlessTurnedOffAndReportsItsSize() {
    #expect(HistoryAudio.keeps(nil))
    #expect(!HistoryAudio.keeps(false))
    #expect(HistoryAudio.keeps(true))
    #expect(HistoryAudio.usageText(bytes: 0, keeps: true) == "No dictation audio is kept yet.")
    #expect(HistoryAudio.usageText(bytes: 0, keeps: false) == "No dictation audio is kept.")
    #expect(HistoryAudio.usageText(bytes: nil, keeps: false).hasPrefix("Checking"))
    #expect(HistoryAudio.usageText(bytes: 2_000_000, keeps: false).contains("MB"))
}
