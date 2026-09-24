import Foundation
import Testing
import HolosCore
@testable import HolosSpeakers

// MARK: - Fixture

private let runID = "RUN-EXPORT"
/// 2026-09-23 14:00:00 UTC.
private let fixedDate = Date(timeIntervalSince1970: 1_790_172_000)

/// One turn with its own segment "seg-<id>": the text split at spaces into measured words, word i at
/// [start + i, start + i + 1), so the turn lasts one second per word.
private struct Spec {
    var id: String
    var start: Double
    var speaker: String?
    var text: String
    var track = "system"
    var others: [String] = []
}

private func spec(_ id: String, _ start: Double, _ speaker: String?, _ text: String, track: String = "system",
                  others: [String] = []) -> Spec {
    Spec(id: id, start: start, speaker: speaker, text: text, track: track, others: others)
}

private func measuredSegment(_ id: String, start: Double, text: String, track: String?) -> TranscriptSegment {
    var words: [TimedWord] = []
    for (index, token) in text.split(separator: " ").enumerated() {
        words.append(TimedWord(text: String(token), start: start + Double(index), end: start + Double(index) + 1,
                               utf16Offset: text.utf16.distance(from: text.startIndex, to: token.startIndex),
                               utf16Length: token.utf16.count))
    }
    return TranscriptSegment(id: id, start: start, end: start + Double(words.count), text: text, words: words,
                             track: track)
}

private let standardSpeakers = [
    SessionSpeaker(id: "system:S1", ordinal: 1, provenance: .diarizer, clusterIDs: ["system:S1"]),
    SessionSpeaker(id: "system:S2", ordinal: 2, provenance: .diarizer, clusterIDs: ["system:S2"]),
    SessionSpeaker(id: "system:S3", ordinal: 3, provenance: .diarizer, clusterIDs: ["system:S3"]),
    SessionSpeaker(id: "mic:me", ordinal: 4, displayName: "Me", provenance: .channelAssumption),
]

private struct Fixture {
    var transcript: Transcript
    var run: DiarizationRun
}

private func fixture(_ specs: [Spec]) -> Fixture {
    let segments = specs.map { measuredSegment("seg-\($0.id)", start: $0.start, text: $0.text, track: $0.track) }
    let transcript = Transcript(id: "TRANSCRIPT", createdAt: fixedDate, source: "mic+system", locale: "en-CA",
                                backend: .speech, segments: segments)
    let turns = zip(specs, segments).map { spec, segment in
        let channel = spec.speaker == "mic:me"
        return SpeakerTurn(
            id: spec.id, track: spec.track, start: segment.start, end: segment.end, speakerID: spec.speaker,
            clusterID: channel ? nil : spec.speaker, spans: [WordSpan(segmentID: segment.id, first: 0, end: segment.words.count)],
            overlap: !spec.others.isEmpty, otherClusters: spec.others,
            assignmentScore: spec.speaker == nil ? 0 : channel ? 1 : 0.9, timing: .measured)
    }
    let run = DiarizationRun(
        id: runID, sessionID: "SESSION", createdAt: fixedDate, transcriptID: "TRANSCRIPT", engine: .fake,
        alignment: AlignmentInfo(version: 1, parameters: .v1, trackOffsets: ["system": 0]),
        tracks: [TrackDiarization(track: "system", policy: .diarized),
                 TrackDiarization(track: "mic", policy: .channel(speakerID: "mic:me", displayName: "Me"))],
        speakers: standardSpeakers, turns: turns)
    return Fixture(transcript: transcript, run: run)
}

private func projection(_ fixture: Fixture, actions: [SpeakerEditAction] = [], recognition: RecognitionResult? = nil,
                        names: [String: String] = [:]) -> SpeakerProjection {
    let edits = actions.enumerated().map { index, action in
        SpeakerEdit(id: "E\(index)", baseRunID: runID, at: fixedDate, source: "cli", action: action)
    }
    return SpeakerProjection.make(run: fixture.run, transcript: fixture.transcript, edits: edits,
                                  recognition: recognition, profileNames: names)
}

private func metadata(duration: Double = 10_692.4, source: AudioSource = .microphoneAndSystem,
                      name: String = "Council meeting") -> ExportMetadata {
    ExportMetadata(sessionID: "SESSION", name: name, createdAt: fixedDate, durationSeconds: duration, source: source,
                   locale: "en-CA", backend: .speech, timeZone: .gmt)
}

private func document(_ fixture: Fixture, projection: SpeakerProjection?, gaps: [TimelineGap] = [],
                      markers: [TimelineMarker] = []) -> ExportDocument {
    ExportDocument(metadata: metadata(), transcript: fixture.transcript, run: projection == nil ? nil : fixture.run,
                   projection: projection, gaps: gaps, markers: markers)
}

private func rendered(_ document: ExportDocument, _ format: ExportFormat) throws -> String {
    String(decoding: try TranscriptExporter.render(document, format: format), as: UTF8.self)
}

private func json(_ document: ExportDocument) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: TranscriptExporter.render(document, format: .json))
    return try #require(object as? [String: Any])
}

/// Every key of every JSON object in `value`, at any depth.
private func allKeys(_ value: Any) -> Set<String> {
    if let object = value as? [String: Any] {
        return object.reduce(into: Set(object.keys)) { $0.formUnion(allKeys($1.value)) }
    }
    if let array = value as? [Any] {
        return array.reduce(into: Set<String>()) { $0.formUnion(allKeys($1)) }
    }
    return []
}

/// The evaluator's Otter header regex (scripts/evaluate-references.swift).
private func matchesEvaluatorHeader(_ line: String) throws -> Bool {
    let pattern = try NSRegularExpression(pattern: #"^\s*\S.*\s{2,}\d{1,2}:\d{2}(?::\d{2})?\s*$"#)
    return pattern.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) != nil
}

// MARK: - Markdown

@Test func markdownShowsHeaderGapsAndMarkers() throws {
    let meeting = fixture([
        spec("T1", 723, "system:S1", "We should move the vote."),
        spec("T2", 760, "system:S2", "Agreed, but later.", others: ["system:S1"]),
        spec("T3", 2830, "system:S1", "Back again."),
        spec("T4", 3730, "system:S2", "Yes."),
    ])
    let view = projection(meeting, actions: [.rename(speakerID: "system:S1", name: "Jim")])
    let exported = document(meeting, projection: view,
                            gaps: [TimelineGap(start: 2710, end: 2822, reason: .paused)],
                            markers: [TimelineMarker(at: 3723, label: "Vote")])
    let markdown = try rendered(exported, .md)
    #expect(markdown == """
        # Council meeting

        - Date: 2026-09-23
        - Started: 14:00
        - Duration: 2:58:12
        - Participants: Jim (00:07), Speaker 2 (00:04)

        **Jim** · 00:12:03

        We should move the vote.

        **Speaker 2** · 00:12:40 · overlapping with Jim

        Agreed, but later.

        _[Recording paused 00:45:10–00:47:02]_

        **Jim** · 00:47:10

        Back again.

        _[Marker 01:02:03: Vote]_

        **Speaker 2** · 01:02:10

        Yes.

        """)
}

@Test func consecutiveSameSpeakerTurnsExportAsOneBlock() throws {
    let meeting = fixture([
        spec("T1", 10, "system:S1", "one two"),
        spec("T2", 14, "system:S1", "three four five"),
        spec("T3", 19, "system:S1", "six seven"),
    ])
    let exported = document(meeting, projection: projection(meeting, actions: [.rename(speakerID: "system:S1", name: "Jim")]))
    #expect(TranscriptExporter.blocks(exported) == [
        ExportBlock(speakerLabel: "Jim", start: 10, turnIDs: ["T1", "T2", "T3"],
                    text: "one two three four five six seven"),
    ])
    let markdown = try rendered(exported, .md)
    #expect(markdown.components(separatedBy: "**Jim**").count == 2)
    #expect(markdown.hasSuffix("**Jim** · 00:00:10\n\none two three four five six seven\n"))
    #expect(try rendered(exported, .txt) == "Jim  00:10\none two three four five six seven\n\n")
}

@Test func blocksBreakAtGapMarkerAndLongSilence() throws {
    let meeting = fixture([
        spec("T1", 10, "system:S1", "a b"),                 // 10–12
        spec("T2", 14, "system:S1", "c d"),                 // marker at 14 comes first
        spec("T3", 18, "system:S1", "e f"),                 // 2 s pause: same block
        spec("T4", 24, "system:S1", "g h"),                 // paused 21–23 in between
        spec("T5", 51, "system:S1", "i j"),                 // 25 s of silence: same block
        spec("T6", 93, "system:S1", "k l"),                 // 40 s of silence
    ])
    let exported = document(meeting, projection: projection(meeting, actions: [.rename(speakerID: "system:S1", name: "Jim")]),
                            gaps: [TimelineGap(start: 21, end: 23, reason: .paused)],
                            markers: [TimelineMarker(at: 14, label: "Break")])
    let blocks = TranscriptExporter.blocks(exported)
    #expect(blocks.map(\.turnIDs) == [["T1"], ["T2", "T3"], ["T4", "T5"], ["T6"]])
    #expect(blocks.map(\.start) == [10, 14, 24, 93])
    #expect(blocks.map(\.text) == ["a b", "c d e f", "g h i j", "k l"])

    let markdown = try rendered(exported, .md)
    let order = ["**Jim** · 00:00:10", "_[Marker 00:00:14: Break]_", "**Jim** · 00:00:14",
                 "_[Recording paused 00:00:21–00:00:23]_", "**Jim** · 00:00:24", "**Jim** · 00:01:33"]
    let positions = try order.map { try #require(markdown.range(of: $0)).lowerBound }
    #expect(positions == positions.sorted())
    #expect(try rendered(exported, .txt).components(separatedBy: "\n").filter { $0.hasPrefix("Jim  ") }
        == ["Jim  00:10", "Jim  00:14", "Jim  00:24", "Jim  01:33"])
}

@Test func unknownSpeakerTurnsMergeOnlyOnOneTrack() {
    let meeting = fixture([
        spec("T1", 10, nil, "who said"),
        spec("T2", 13, nil, "this"),
        spec("T3", 15, nil, "hello", track: "mic"),
    ])
    let blocks = TranscriptExporter.blocks(document(meeting, projection: projection(meeting)))
    #expect(blocks.map(\.speakerLabel) == ["Unknown speaker", "Unknown speaker"])
    #expect(blocks.map(\.turnIDs) == [["T1", "T2"], ["T3"]])
}

@Test func overlapLabelsFollowMergesAndSkipTheSpeakerItself() throws {
    let meeting = fixture([
        spec("T1", 10, "system:S1", "first words", others: ["system:S3"]),
        spec("T2", 20, "system:S2", "second words", others: ["system:S3", "system:S1"]),
        spec("T3", 30, "system:S3", "third words"),
    ])
    let view = projection(meeting, actions: [.rename(speakerID: "system:S1", name: "Jim"),
                                             .merge(from: "system:S3", into: "system:S1")])
    let exported = document(meeting, projection: view)
    let blocks = TranscriptExporter.blocks(exported)
    #expect(blocks.map(\.speakerLabel) == ["Jim", "Speaker 2", "Jim"])
    #expect(blocks.map(\.overlapWith) == [[], ["Jim"], []])
    let turns = try #require(try json(exported)["turns"] as? [[String: Any]])
    #expect(turns.map { $0["otherSpeakers"] as? [String] } == [[], ["system:S1"], []])
}

@Test func markdownEscapesNamesAndParagraphStarts() throws {
    let meeting = fixture([
        spec("T1", 10, "system:S1", "# not a heading"),
        spec("T2", 20, "system:S2", "1. not a list"),
        spec("T3", 30, "system:S1", "- not a bullet"),
    ])
    let view = projection(meeting, actions: [.rename(speakerID: "system:S1", name: "*Jim*\nSmith")])
    let markdown = try rendered(document(meeting, projection: view, markers: [TimelineMarker(at: 25, label: "[a]\n")]), .md)
    #expect(markdown.contains("**\\*Jim\\* Smith** · 00:00:10\n\n\\# not a heading\n"))
    #expect(markdown.contains("**Speaker 2** · 00:00:20\n\n1\\. not a list\n"))
    #expect(markdown.contains("_[Marker 00:00:25: \\[a\\]]_"))
    #expect(markdown.contains("\n\\- not a bullet\n"))
}

@Test func paragraphStartEscapesOnlyBlockSyntax() {
    let cases: [(String, String)] = [
        ("#hashtag", "#hashtag"), ("## two", "\\## two"), ("####### seven", "####### seven"),
        ("> quote", "\\> quote"), ("<b>", "\\<b>"), ("+", "\\+"), ("*bold* word", "*bold* word"),
        ("* * *", "\\* * *"), ("___", "\\___"), ("```code", "\\```code"), ("2) item", "2\\) item"),
        ("2020. A year", "2020\\. A year"), ("1234567890. long", "1234567890. long"), ("3.5 percent", "3.5 percent"),
        ("plain", "plain"), ("", ""),
    ]
    for (line, expected) in cases {
        #expect(MarkdownExport.escapeParagraphStart(line) == expected, "\(line)")
    }
}

@Test func gapLinesNameEveryReason() {
    #expect(MarkdownExport.gapText(.paused) == "Recording paused")
    #expect(MarkdownExport.gapText(.sleep) == "No audio: computer was asleep")
    #expect(MarkdownExport.gapText(.deviceChanged) == "Audio restarted")
    #expect(MarkdownExport.gapText(.captureRestarted) == "Audio restarted")
    #expect(MarkdownExport.gapText(.audioUnavailable) == "No audio: microphone unavailable")
    #expect(MarkdownExport.gapText(.overflow) == "Audio gap")
    #expect(MarkdownExport.gapText(.audioGap) == "Audio gap")
    #expect(MarkdownExport.gapText(GapReason("somethingNew")) == "Audio gap")
}

@Test func markerWithoutLabelAndDuplicateGapPrintOnce() throws {
    let meeting = fixture([spec("T1", 10, "system:S1", "hello"), spec("T2", 200, "system:S1", "again")])
    let exported = document(meeting, projection: projection(meeting),
                            gaps: [TimelineGap(track: "mic", start: 100, end: 110, reason: .sleep),
                                   TimelineGap(track: "system", start: 100, end: 110, reason: .sleep),
                                   TimelineGap(start: .nan, end: 5, reason: .paused)],
                            markers: [TimelineMarker(at: 150), TimelineMarker(at: .infinity, label: "never")])
    let markdown = try rendered(exported, .md)
    #expect(markdown.components(separatedBy: "_[No audio: computer was asleep 00:01:40–00:01:50]_").count == 2)
    #expect(markdown.contains("\n_[Marker 00:02:30]_\n"))
    #expect(!markdown.contains("never") && !markdown.contains("Recording paused"))
}

// MARK: - Text

@Test func textMatchesEvaluatorAndRoundTrips() throws {
    let meeting = fixture([
        spec("T1", 65, "system:S1", "we should vote"),
        spec("T2", 3725, "system:S2", "agreed"),
    ])
    let exported = document(meeting, projection: projection(meeting, actions: [.rename(speakerID: "system:S1", name: "Jim")]))
    let text = try rendered(exported, .txt)
    #expect(text == "Jim  01:05\nwe should vote\n\nSpeaker 2  1:02:05\nagreed\n\n")
    for header in ["Jim  01:05", "Speaker 2  1:02:05"] {
        #expect(try matchesEvaluatorHeader(header))
    }
    for line in ["we should vote", "agreed"] {
        #expect(try !matchesEvaluatorHeader(line))
    }
    #expect(OtterTranscriptParser.parse(text) == [
        ReferenceTurn(speaker: "Jim", start: 65, end: 3725, wordCount: 3),
        ReferenceTurn(speaker: "Speaker 2", start: 3725, end: nil, wordCount: 1),
    ])
}

@Test func textExportKeepsLabelsAndTextOnOneLine() throws {
    // A double space inside the recognizer's text would otherwise make "Item  4:30" read as a header.
    let meeting = fixture([spec("T1", 5, "system:S1", "Item  4:30"), spec("T2", 9, "system:S2", "next")])
    let view = projection(meeting, actions: [.rename(speakerID: "system:S1", name: "Room\t12  A")])
    let text = try rendered(document(meeting, projection: view), .txt)
    #expect(text == "Room 12 A  00:05\nItem 4:30\n\nSpeaker 2  00:09\nnext\n\n")
    #expect(try matchesEvaluatorHeader("Item  4:30"))
    #expect(try !matchesEvaluatorHeader("Item 4:30"))
    #expect(OtterTranscriptParser.parse(text) == [
        ReferenceTurn(speaker: "Room 12 A", start: 5, end: 9, wordCount: 2),
        ReferenceTurn(speaker: "Speaker 2", start: 9, end: nil, wordCount: 1),
    ])
}

@Test func singleLineCollapsesWhitespaceAndControls() {
    #expect(ExportText.singleLine("  a\n\tb\u{7}c  d\u{2028}e ") == "a b c d e")
    #expect(ExportText.singleLine("\n \u{0}") == "")
    #expect(ExportText.headerLabel("\u{7}") == "Unknown speaker")
    #expect(ExportText.headerLabel(" Jim  (auto) ") == "Jim (auto)")
}

// MARK: - JSON

@Test func jsonExportIsDeterministicAndHasNoVectors() throws {
    // Measured words across 20 s of system audio and one microphone phrase; the fake engine returns centroids and
    // windows, which must not reach any export.
    var segments: [TranscriptSegment] = []
    for index in 0..<4 {
        segments.append(measuredSegment("seg-\(index)", start: Double(index) * 5 + 0.5,
                                        text: "alpha beta gamma delta", track: "system"))
    }
    segments.append(measuredSegment("seg-mic", start: 6, text: "yes indeed", track: "mic"))
    let transcript = Transcript(id: "TRANSCRIPT", createdAt: fixedDate, source: "mic+system", locale: "en-CA",
                                backend: .speech, segments: segments)
    let output = FakeDiarizer.alternating(speakers: ["S1", "S2"], turnSeconds: 5, duration: 20)
    let built = SpeakerRunBuilder.build(
        sessionID: "SESSION", transcript: transcript,
        tracks: [.init(track: "mic", policy: .channel(speakerID: "mic:me", displayName: "Me")),
                 .init(track: "system", policy: .diarized, output: output)],
        engine: .fake, id: runID, createdAt: fixedDate)
    #expect(built.voiceData?.centroids.isEmpty == false)
    let meeting = Fixture(transcript: transcript, run: built.run)
    let view = projection(meeting, actions: [.rename(speakerID: "system:S1", name: "Jim"),
                                             .linkProfile(speakerID: "system:S2", profileID: "P-2")],
                          names: ["P-2": "Pat"])
    let exported = document(meeting, projection: view, gaps: [TimelineGap(start: 30, end: 40, reason: .paused)],
                            markers: [TimelineMarker(at: 12, label: "Budget")])

    let first = try TranscriptExporter.render(exported, format: .json)
    let second = try TranscriptExporter.render(exported, format: .json)
    #expect(first == second)
    #expect(first.last == 0x0A)

    let object = try json(exported)
    let forbidden: Set<String> = ["centroid", "centroids", "vector", "embedding", "turnEmbeddings"]
    #expect(allKeys(object).isDisjoint(with: forbidden))
    #expect(Set(object.keys) == ["schemaVersion", "format", "session", "transcriptID", "runID", "engine",
                                 "alignment", "speakers", "turns", "gaps", "markers", "edits"])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["format"] as? String == "holos-transcript")
    #expect(object["transcriptID"] as? String == "TRANSCRIPT")
    #expect(object["runID"] as? String == runID)
    #expect((object["engine"] as? [String: Any])?["engine"] as? String == "Fake")
    #expect((object["alignment"] as? [String: Any])?["version"] as? Int == 1)

    let session = try #require(object["session"] as? [String: Any])
    #expect(session["id"] as? String == "SESSION")
    #expect(session["name"] as? String == "Council meeting")
    #expect(session["createdAt"] as? String == "2026-09-23T14:00:00Z")
    #expect(session["durationSeconds"] as? Double == 10_692.4)
    #expect(session["source"] as? String == "mic+system")
    #expect(session["locale"] as? String == "en-CA")
    #expect(session["backend"] as? String == "speech")

    let speakers = try #require(object["speakers"] as? [[String: Any]])
    #expect(speakers.map { $0["id"] as? String } == view.speakers.map(\.id))
    for speaker in speakers {
        #expect(Set(speaker.keys) == ["id", "ordinal", "name", "label", "provenance", "automatic", "profileID",
                                      "talkSeconds", "turnCount"])
    }
    let jim = try #require(speakers.first { $0["id"] as? String == "system:S1" })
    #expect(jim["label"] as? String == "Jim")
    #expect(jim["profileID"] is NSNull)
    #expect((jim["provenance"] as? [String: Any])?.keys.first == "userRenamed")
    let pat = try #require(speakers.first { $0["id"] as? String == "system:S2" })
    #expect(pat["name"] as? String == "Pat")
    #expect(pat["profileID"] as? String == "P-2")
    #expect((pat["provenance"] as? [String: Any])?.keys.first == "userConfirmed")

    let turns = try #require(object["turns"] as? [[String: Any]])
    #expect(turns.map { $0["id"] as? String } == view.turns.map(\.id))
    for turn in turns {
        #expect(Set(turn.keys) == ["id", "speakerID", "track", "start", "end", "text", "overlap", "otherSpeakers",
                                   "score", "timing", "words"])
    }
    let firstTurn = try #require(turns.first)
    #expect(firstTurn["text"] as? String == "alpha beta gamma delta")
    #expect(firstTurn["timing"] as? String == "measured")
    #expect((firstTurn["words"] as? [[String: Any]])?.first?["segmentID"] as? String == "seg-0")

    #expect((object["gaps"] as? [[String: Any]])?.first?["reason"] as? String == "paused")
    #expect((object["markers"] as? [[String: Any]])?.first?["label"] as? String == "Budget")
    let edits = try #require(object["edits"] as? [String: Int])
    #expect(edits == ["applied": 2, "stale": 0, "otherRuns": 0])
}

@Test func jsonWritesNullForNumbersThatAreNotFinite() throws {
    let meeting = fixture([spec("T1", 10, "system:S1", "hello")])
    var exported = document(meeting, projection: projection(meeting))
    exported.metadata.durationSeconds = .nan
    let object = try json(exported)
    #expect((object["session"] as? [String: Any])?["durationSeconds"] is NSNull)
}

// MARK: - Labels

@Test func autoLabelAndNoSuggestionsInExports() throws {
    let meeting = fixture([
        spec("T1", 10, "system:S1", "hello there"),
        spec("T2", 20, "system:S2", "good morning"),
    ])
    let recognition = RecognitionResult(
        runID: runID, createdAt: fixedDate, embeddingModel: EmbeddingModelID(id: "fake", revision: "1"),
        thresholds: RecognitionThresholds(likelyMaxDistance: 0.2, likelyMinMargin: 0.1, possibleMaxDistance: 0.4,
                                          minSampleSeconds: 20),
        matches: [SpeakerMatch(speakerID: "system:S1", profileID: "P-1", profileName: "Jim", distance: 0.1, tier: .likely),
                  SpeakerMatch(speakerID: "system:S2", profileID: "P-2", profileName: "Maria", distance: 0.3,
                               tier: .possible)])
    let view = projection(meeting, recognition: recognition, names: ["P-1": "Jim", "P-2": "Maria"])
    #expect(view.speakers.first { $0.id == "system:S2" }?.suggestion?.profileName == "Maria")
    let exported = document(meeting, projection: view)
    for format in ExportFormat.allCases {
        let text = try rendered(exported, format)
        #expect(text.contains("Jim (auto)"), "\(format)")
        #expect(!text.contains("Maria"), "\(format)")
    }
    #expect(try rendered(exported, .txt) == "Jim (auto)  00:10\nhello there\n\nSpeaker 2  00:20\ngood morning\n\n")
    let speakers = try #require(try json(exported)["speakers"] as? [[String: Any]])
    #expect(speakers.first?["automatic"] as? Bool == true)
    #expect(speakers.first?["profileID"] is NSNull)
}

@Test func channelSpeakerIsMeAndParticipantsFollowTalkTime() throws {
    let meeting = fixture([
        spec("T1", 5, "system:S2", "short"),
        spec("T2", 8, "mic:me", "a much longer answer here", track: "mic"),
        spec("T3", 20, "system:S1", "two words"),
    ])
    let exported = document(meeting, projection: projection(meeting))
    #expect(try rendered(exported, .txt)
        == "Speaker 2  00:05\nshort\n\nMe  00:08\na much longer answer here\n\nSpeaker 1  00:20\ntwo words\n\n")
    #expect(try rendered(exported, .md).contains("- Participants: Me (00:05), Speaker 1 (00:02), Speaker 2 (00:01)\n"))
}

@Test func speakerlessExportUsesTrackNames() throws {
    let transcript = Transcript(
        id: "TRANSCRIPT", createdAt: fixedDate, source: "mic+system", locale: "en-CA", backend: .speech,
        segments: [measuredSegment("seg-b", start: 3, text: "remote voice", track: "system"),
                   measuredSegment("seg-a", start: 1, text: "hello from the room", track: "mic"),
                   measuredSegment("seg-c", start: 7, text: "again", track: "mic"),
                   TranscriptSegment(id: "seg-empty", start: 8, end: 9, text: "  ", track: "mic")])
    let exported = ExportDocument(metadata: metadata(), transcript: transcript)
    let blocks = TranscriptExporter.blocks(exported)
    #expect(blocks.map(\.speakerLabel) == ["Microphone", "System audio", "Microphone"])
    #expect(blocks.map(\.turnIDs) == [["T1"], ["T2"], ["T3"]])

    let markdown = try rendered(exported, .md)
    #expect(markdown.contains("**Microphone** · 00:00:01\n\nhello from the room\n"))
    #expect(markdown.contains("**System audio** · 00:00:03\n\nremote voice\n"))
    #expect(!markdown.contains("Participants"))
    #expect(try rendered(exported, .txt)
        == "Microphone  00:01\nhello from the room\n\nSystem audio  00:03\nremote voice\n\nMicrophone  00:07\nagain\n\n")

    let object = try json(exported)
    #expect(object["runID"] is NSNull && object["engine"] is NSNull && object["alignment"] is NSNull)
    #expect((object["speakers"] as? [Any])?.isEmpty == true)
    let turns = try #require(object["turns"] as? [[String: Any]])
    #expect(turns.map { $0["track"] as? String } == ["mic", "system", "mic"])
    #expect(turns.allSatisfy { $0["speakerID"] is NSNull })
    #expect((turns.first?["words"] as? [[String: Any]])?.first?["end"] as? Int == 4)
    #expect(object["edits"] as? [String: Int] == ["applied": 0, "stale": 0, "otherRuns": 0])
}

@Test func speakerlessSegmentWithoutTrackUsesTheSource() {
    let transcript = Transcript(id: "TRANSCRIPT", createdAt: fixedDate, source: "system", locale: "en-CA",
                                backend: .speech, segments: [measuredSegment("s", start: 0, text: "hi", track: nil)])
    var exported = ExportDocument(metadata: metadata(source: .system), transcript: transcript)
    #expect(TranscriptExporter.blocks(exported).map(\.speakerLabel) == ["System audio"])
    exported.metadata.source = .microphoneAndSystem
    #expect(TranscriptExporter.blocks(exported).map(\.speakerLabel) == ["Unknown speaker"])
}

@Test func projectionOfAnotherTranscriptIsIgnored() throws {
    let meeting = fixture([spec("T1", 10, "system:S1", "hello there")])
    var exported = document(meeting, projection: projection(meeting, actions: [.rename(speakerID: "system:S1", name: "Jim")]))
    exported.transcript.id = "OTHER"
    #expect(TranscriptExporter.blocks(exported).map(\.speakerLabel) == ["System audio"])
    #expect(try !rendered(exported, .md).contains("Jim"))
    let object = try json(exported)
    #expect(object["runID"] is NSNull && object["engine"] is NSNull && object["alignment"] is NSNull)
    #expect((object["speakers"] as? [Any])?.isEmpty == true)
}

@Test func turnsWithoutPrintableTextAreLeftOutOfBlocks() throws {
    let meeting = fixture([spec("T1", 10, "system:S1", "\u{7}"), spec("T2", 20, "system:S2", "hello")])
    let exported = document(meeting, projection: projection(meeting))
    #expect(TranscriptExporter.blocks(exported).map(\.turnIDs) == [["T2"]])
    #expect(try rendered(exported, .txt) == "Speaker 2  00:20\nhello\n\n")
    // The JSON export still lists every turn.
    #expect((try json(exported)["turns"] as? [Any])?.count == 2)
}

@Test func documentPrintsNoTranscriptText() {
    let meeting = fixture([spec("T1", 10, "system:S1", "private words")])
    let exported = document(meeting, projection: projection(meeting, actions: [.rename(speakerID: "system:S1", name: "Jim")]),
                            markers: [TimelineMarker(at: 1, label: "secret")])
    var dumped = ""
    dump(exported, to: &dumped)
    for text in [String(describing: exported), String(reflecting: exported), dumped] {
        #expect(!text.contains("private") && !text.contains("Jim") && !text.contains("secret"))
        #expect(text.contains("SESSION"))
    }
}

// MARK: - Turn text

@Test func turnTextKeepsPunctuationAndJoinsSpans() {
    let first = measuredSegment("a", start: 0, text: "\u{201C}Hello, world. How are you?", track: "system")
    let second = measuredSegment("b", start: 10, text: "Fine (thanks).", track: "system")
    let transcript = Transcript(id: "T", source: "system", locale: "en-CA", backend: .speech, segments: [first, second])
    #expect(TranscriptExporter.text(of: [WordSpan(segmentID: "a", first: 0, end: 2)], in: transcript)
        == "\u{201C}Hello, world.")
    #expect(TranscriptExporter.text(of: [WordSpan(segmentID: "a", first: 2, end: 5)], in: transcript) == "How are you?")
    #expect(TranscriptExporter.text(of: [WordSpan(segmentID: "a", first: 4, end: 5),
                                         WordSpan(segmentID: "b", first: 0, end: 2)], in: transcript)
        == "you? Fine (thanks).")
}

@Test func turnTextOfUntimedSegmentUsesWhitespaceTokens() {
    let segment = TranscriptSegment(id: "u", start: 0, end: 4, text: "  one  two\tthree ", track: "mic")
    let transcript = Transcript(id: "T", source: "mic", locale: "en-CA", backend: .speech, segments: [segment])
    #expect(TranscriptExporter.text(of: [WordSpan(segmentID: "u", first: 1, end: 3)], in: transcript) == "two\tthree")
    #expect(TranscriptExporter.text(of: [WordSpan(segmentID: "u", first: 0, end: 1)], in: transcript) == "one")
}

@Test func invalidSpansAndOffsetsDoNotTrap() {
    var segment = measuredSegment("a", start: 0, text: "alpha beta gamma", track: "system")
    let transcript = Transcript(id: "T", source: "system", locale: "en-CA", backend: .speech, segments: [segment])
    #expect(TranscriptExporter.text(of: [WordSpan(segmentID: "missing", first: 0, end: 1)], in: transcript) == "")
    #expect(TranscriptExporter.text(of: [WordSpan(segmentID: "a", first: 2, end: 99)], in: transcript) == "gamma")
    #expect(TranscriptExporter.text(of: [WordSpan(segmentID: "a", first: -3, end: 1)], in: transcript) == "alpha")
    #expect(TranscriptExporter.text(of: [WordSpan(segmentID: "a", first: 2, end: 1)], in: transcript) == "")
    // Offsets from a different text: out of order and past the end fall back to the word texts.
    segment.words[1].utf16Offset = 999
    segment.words[2].utf16Offset = 2
    let broken = Transcript(id: "T", source: "system", locale: "en-CA", backend: .speech, segments: [segment])
    #expect(TranscriptExporter.text(of: [WordSpan(segmentID: "a", first: 1, end: 2)], in: broken) == "beta")
    #expect(TranscriptExporter.text(of: [WordSpan(segmentID: "a", first: 0, end: 3)], in: broken) == "alpha beta gamma")
}

// MARK: - Time formats

@Test func timeFormatsRoundDownTimesAndRoundDurations() {
    #expect(TimeFormat.clock(0) == "00:00:00")
    #expect(TimeFormat.clock(3723.9) == "01:02:03")
    #expect(TimeFormat.clock(360_000) == "100:00:00")
    #expect(TimeFormat.compact(65.99) == "01:05")
    #expect(TimeFormat.compact(3599.9) == "59:59")
    #expect(TimeFormat.compact(3600) == "1:00:00")
    #expect(TimeFormat.compact(3725) == "1:02:05")
    #expect(TimeFormat.duration(10_692.4) == "2:58:12")
    #expect(TimeFormat.duration(59.5) == "01:00")
    for bad in [-5, Double.nan, Double.infinity, -Double.infinity] {
        #expect(TimeFormat.clock(bad) == "00:00:00")
        #expect(TimeFormat.compact(bad) == "00:00")
        #expect(TimeFormat.duration(bad) == "00:00")
    }
    #expect(TimeFormat.clock(1e300) == "99999:00:00")
    #expect(TimeFormat.compact(1e300) == "99999:00:00")
}
