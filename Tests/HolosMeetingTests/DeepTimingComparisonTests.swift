import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// Opt-in measurement (docs/meeting-design.md §4.16): HOLOS_DEEP_COMPARE_SESSION=<a copy of a .holos folder that
// `session deep-transcribe` ran on> compares, per track, the word times of the deep transcript with the recorded
// transcript's where the two wrote the same word (aligned by text in 5-minute windows). Prints numbers only.

private let comparedSession = ProcessInfo.processInfo.environment["HOLOS_DEEP_COMPARE_SESSION"]

@Test(.enabled(if: comparedSession != nil), .timeLimit(.minutes(30)))
func compareDeepWordTimesWithTheRecordedTranscript() throws {
    let session = URL(fileURLWithPath: try #require(comparedSession), isDirectory: true)
    let current = try #require(try SessionFiles.currentTranscript(session: session))
    let events = try SessionArchive.readEvents(at: session).events
    let base = DeepTranscriptionStage.recordedBase(of: current, events: events, session: session)
    try #require(DeepTranscriptionModel.isWhisper(base.unfixed.engine), "Run session deep-transcribe on it first.")
    let recorded = try #require(base.reference)
    func words(_ transcript: Transcript, _ track: String) -> [EffectiveWord] {
        transcript.segments.filter { $0.track == track }.flatMap { WordTiming.effectiveWords(of: $0) }
            .filter { !$0.estimated }.sorted { $0.start < $1.start }
    }
    let tracks = Set(recorded.segments.compactMap(\.track)).sorted()
    for track in tracks {
        let deep = words(base.unfixed, track)
        let apple = words(recorded, track)
        let end = max(deep.last?.start ?? 0, apple.last?.start ?? 0)
        var deltas: [Double] = []
        var perWindow: [String] = []
        var window = 0.0
        while window <= end {
            let a = apple.filter { $0.start >= window && $0.start < window + 300 }
            // A little wider on the deep side, so a constant offset still finds its words.
            let d = deep.filter { $0.start >= window - 30 && $0.start < window + 330 }
            var here: [Double] = []
            for op in EvalAlignment.align(a.map(\.text), d.map(\.text)) {
                if case .match(let i, let j, _) = op { here.append(d[j].start - a[i].start) }
            }
            deltas += here
            let sorted = here.sorted()
            perWindow.append(sorted.isEmpty ? "-" : String(format: "%.1f", sorted[sorted.count / 2]))
            window += 300
        }
        print("compare \(track): signed median Δstart per 5-minute window: \(perWindow.joined(separator: " "))")
        print("compare \(track): first word at \(String(format: "%.2f", apple.first?.start ?? -1)) (recorded) and "
            + "\(String(format: "%.2f", deep.first?.start ?? -1)) (deep)")
        // Passages the deep transcript may have left out: recorded words with no deep word within 3 s.
        let deepStarts = deep.map(\.start)
        let uncovered = apple.filter { word in
            var low = 0, high = deepStarts.count
            while low < high {
                let middle = (low + high) / 2
                if deepStarts[middle] < word.start - 3 { low = middle + 1 } else { high = middle }
            }
            return !(low < deepStarts.count && deepStarts[low] <= word.start + 3)
        }
        var uncoveredSeconds = 0.0
        var last = -Double.infinity
        for word in uncovered {
            uncoveredSeconds += min(word.end - word.start + 0.3, max(0, word.start - last))
            last = word.start
        }
        print("compare \(track): \(uncovered.count) recorded words with no deep word within 3 s "
            + "(about \(Int(uncoveredSeconds)) s of speech)")
        // The longest such stretches (recorded words less than 5 s apart), by start time and length.
        var runs: [(start: Double, end: Double, words: Int)] = []
        for word in uncovered {
            if let lastRun = runs.last, word.start - lastRun.end < 5 {
                runs[runs.count - 1].end = word.end
                runs[runs.count - 1].words += 1
            } else {
                runs.append((word.start, word.end, 1))
            }
        }
        let longest = runs.sorted { $0.end - $0.start > $1.end - $1.start }.prefix(12)
        print("compare \(track): longest uncovered stretches: " + longest.map {
            String(format: "%.0f+%.0fs(%d)", $0.start, $0.end - $0.start, $0.words)
        }.joined(separator: " "))
        let absolute = deltas.map(abs).sorted()
        let signed = deltas.sorted()
        func at(_ values: [Double], _ p: Double) -> String {
            values.isEmpty ? "-" : String(format: "%.2f", values[min(values.count - 1, Int(Double(values.count) * p))])
        }
        let within = { (limit: Double) in
            absolute.isEmpty ? 0 : Int((Double(absolute.filter { $0 <= limit }.count) / Double(absolute.count) * 100)
                .rounded())
        }
        print("compare \(track): \(apple.count) recorded words, \(deep.count) deep words, \(deltas.count) matched; "
            + "|Δstart| p50 \(at(absolute, 0.5)) p90 \(at(absolute, 0.9)) s; signed p50 \(at(signed, 0.5)) s; "
            + "within 0.25 s \(within(0.25)) %, 0.5 s \(within(0.5)) %, 1 s \(within(1)) %")
    }
}
