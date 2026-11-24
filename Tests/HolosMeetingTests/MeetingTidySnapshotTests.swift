import Foundation
import HolosCore
import HolosMeeting
import HolosSpeakers
import Testing

struct MeetingTidySnapshotTests {
    private func snapshot(systemText: String = "The valve opened.") -> MeetingTidySnapshot {
        let metadata = ExportMetadata(sessionID: "sample", name: "Workshop", createdAt: .distantPast,
                                      durationSeconds: 12, source: .microphoneAndSystem, locale: "en-US",
                                      backend: .speech, timeZone: .gmt)
        let transcript = Transcript(source: "fixture", locale: "en-US", backend: .speech, segments: [
            TranscriptSegment(start: 1, end: 5, text: "We tested. The valve.", track: "mic"),
            TranscriptSegment(start: 7, end: 12, text: systemText, track: "system"),
        ])
        return MeetingTidySnapshot(document: ExportDocument(metadata: metadata, transcript: transcript))
    }

    @Test func theModelReceivesOnlyBlockTextAndTheResultKeepsSpeakerTimes() async throws {
        let tidier = TextTidier(partWords: 200, timeout: .seconds(5), edit: { original in
            switch original {
            case "We tested. The valve.": "We tested the valve."
            case "The valve opened.": "The valve opened."
            default: throw HolosError.invalidInput("Unexpected block.")
            }
        })
        let result = try await snapshot().tidy(using: tidier)
        #expect(result.text == "Workshop\n\n00:00:01  Microphone\nWe tested the valve.\n\n00:00:07  System audio\nThe valve opened.\n")
        #expect(result.parts.allSatisfy { $0.kept == nil })
    }

    @Test func wordChangesAndNewComparisonNotationKeepTheOriginalBlocks() async throws {
        let snapshot = snapshot()
        let tidier = TextTidier(partWords: 200, timeout: .seconds(5), edit: { original in
            original.hasPrefix("We") ? "We tested the valves." : "The valve opened =."
        })
        let result = try await snapshot.tidy(using: tidier)
        #expect(result.text == snapshot.original)
        #expect(result.parts.map(\.kept) == ["the model changed the spoken words", "the model added numbers or comparison notation"])
    }

    @Test(arguments: [".5", "5 %", "€ 5", "- 5", "5 °C", "≤ 5", "1.5", "5 €",
                      "<= 5", ">= 5", "x <= y", "x >= y", "Ⅻ", "€ five", "5️⃣"])
    func blocksWithNumericNotationAreKeptVerbatimWithoutCallingTheModel(notation: String) async throws {
        let source = snapshot(systemText: "The result was \(notation).")
        let tidier = TextTidier(partWords: 200, timeout: .seconds(5), edit: { original in
            guard !original.hasPrefix("The result") else { throw HolosError.invalidInput("Unexpected model input.") }
            return original
        })
        let result = try await source.tidy(using: tidier)
        #expect(result.text == source.original)
        #expect(result.parts.last?.kept == "it contains numbers or comparison notation")
    }
}
