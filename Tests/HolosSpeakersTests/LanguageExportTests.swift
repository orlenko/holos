import Foundation
import HolosCore
@testable import HolosSpeakers
import Testing

// Exports of a transcript merged from several languages (docs/meeting-design.md §4.14): the Markdown header names
// them, the JSON export names each turn's, and the text carries no language marks.

private let languageExportDate = Date(timeIntervalSince1970: 1_790_172_000)

private func languageExportSegment(_ id: String, start: Double, text: String,
                                   language: String?) -> TranscriptSegment {
    var words: [TimedWord] = []
    for (index, token) in text.split(separator: " ").enumerated() {
        words.append(TimedWord(text: String(token), start: start + Double(index), end: start + Double(index) + 1,
                               utf16Offset: text.utf16.distance(from: text.startIndex, to: token.startIndex),
                               utf16Length: token.utf16.count))
    }
    return TranscriptSegment(id: id, start: start, end: start + Double(words.count), text: text, words: words,
                             track: "system", language: language)
}

/// French, English, French; merged when `languages` is given.
private func languageExportTranscript(languages: [String]? = ["fr-CA", "en-CA"]) -> Transcript {
    let merged = languages != nil
    return Transcript(id: "TRANSCRIPT", createdAt: languageExportDate, source: "system", locale: "fr-CA",
                      backend: .speech, segments: [
                          languageExportSegment("A", start: 0, text: "bonjour tout le monde",
                                                language: merged ? "fr-CA" : nil),
                          languageExportSegment("B", start: 4, text: "hello there", language: merged ? "en-CA" : nil),
                          languageExportSegment("C", start: 40, text: "merci", language: merged ? "fr-CA" : nil),
                      ], languages: languages)
}

private func languageExportDocument(_ transcript: Transcript, run: DiarizationRun? = nil,
                                    projection: SpeakerProjection? = nil) -> ExportDocument {
    ExportDocument(metadata: ExportMetadata(sessionID: "SESSION", name: "Board", createdAt: languageExportDate,
                                            durationSeconds: 60, source: .system, locale: "fr-CA", backend: .speech,
                                            timeZone: .gmt),
                   transcript: transcript, run: run, projection: projection)
}

private func languageExportJSON(_ document: ExportDocument) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: TranscriptExporter.render(document, format: .json))
    return try #require(object as? [String: Any])
}

private func languageExportText(_ document: ExportDocument, _ format: ExportFormat) throws -> String {
    String(decoding: try TranscriptExporter.render(document, format: format), as: UTF8.self)
}

@Test func markdownHeaderNamesTheLanguagesOfAMergedTranscript() throws {
    let markdown = try languageExportText(languageExportDocument(languageExportTranscript()), .md)
    #expect(markdown.contains("- Duration: 01:00\n- Languages: French (Canada), English (Canada)\n"))
    #expect(markdown.contains("bonjour tout le monde hello there"), "No language marks inside the text.")
    let single = try languageExportText(languageExportDocument(languageExportTranscript(languages: nil)), .md)
    #expect(!single.contains("Languages"))
    // One language asked for by name: nothing to name.
    let one = try languageExportText(languageExportDocument(languageExportTranscript(languages: ["fr-CA"])), .md)
    #expect(!one.contains("Languages"))
}

@Test func textExportIsTheSameWithOrWithoutLanguages() throws {
    #expect(try languageExportText(languageExportDocument(languageExportTranscript()), .txt)
        == languageExportText(languageExportDocument(languageExportTranscript(languages: nil)), .txt))
}

@Test func jsonNamesTheLanguagesOfEachTurn() throws {
    let object = try languageExportJSON(languageExportDocument(languageExportTranscript()))
    #expect(object["languages"] as? [String] == ["fr-CA", "en-CA"])
    let turns = try #require(object["turns"] as? [[String: Any]])
    #expect(turns.map { $0["languages"] as? [String] } == [["fr-CA"], ["en-CA"], ["fr-CA"]])

    // A speaker turn over a French and an English segment names both, in order.
    let transcript = languageExportTranscript()
    let run = DiarizationRun(
        id: "RUN", sessionID: "SESSION", createdAt: languageExportDate, transcriptID: transcript.id, engine: .fake,
        alignment: AlignmentInfo(version: 1, parameters: .v1, trackOffsets: ["system": 0]),
        tracks: [TrackDiarization(track: "system", policy: .diarized)],
        speakers: [SessionSpeaker(id: "system:S1", ordinal: 1, provenance: .diarizer, clusterIDs: ["system:S1"])],
        turns: [
            SpeakerTurn(id: "T1", track: "system", start: 0, end: 6, speakerID: "system:S1", clusterID: "system:S1",
                        spans: [WordSpan(segmentID: "A", first: 0, end: 4), WordSpan(segmentID: "B", first: 0, end: 2)],
                        overlap: false, otherClusters: [], assignmentScore: 0.9, timing: .measured),
            SpeakerTurn(id: "T2", track: "system", start: 40, end: 41, speakerID: "system:S1",
                        clusterID: "system:S1", spans: [WordSpan(segmentID: "C", first: 0, end: 1)],
                        overlap: false, otherClusters: [], assignmentScore: 0.9, timing: .measured),
        ])
    let projection = SpeakerProjection.make(run: run, transcript: transcript, edits: [], recognition: nil,
                                            profileNames: [:])
    let labelled = try languageExportJSON(languageExportDocument(transcript, run: run, projection: projection))
    let labelledTurns = try #require(labelled["turns"] as? [[String: Any]])
    #expect(labelledTurns.map { $0["languages"] as? [String] } == [["fr-CA", "en-CA"], ["fr-CA"]])
}

@Test func jsonOfATranscriptInOneLanguageHasNoLanguageKeys() throws {
    // Also a transcript made one language's alone (`session languages` with one), as the Markdown header.
    for languages in [nil, ["fr-CA"]] as [[String]?] {
        let object = try languageExportJSON(languageExportDocument(languageExportTranscript(languages: languages)))
        #expect(object["languages"] == nil)
        let turns = try #require(object["turns"] as? [[String: Any]])
        #expect(turns.allSatisfy { $0["languages"] == nil })
    }
}
