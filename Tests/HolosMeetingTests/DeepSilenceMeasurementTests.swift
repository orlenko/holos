import AVFoundation
import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import HolosTestSupport
import Testing

// Opt-in measurement behind `DeepTranscriptGuards.silenceThresholdDB` (docs/meeting-design.md §4.16):
// HOLOS_DEEP_MEASURE_SESSION=<a copy of a .holos folder> prints, per track, the loudness of the audio under the
// recorded transcript's words and of one-second windows with no word near them. Reads the session; renders into a
// temporary folder; prints numbers only, never transcript text.

private let measuredSession = ProcessInfo.processInfo.environment["HOLOS_DEEP_MEASURE_SESSION"]

@Test(.enabled(if: measuredSession != nil), .timeLimit(.minutes(30)))
func measureSpeechAndSilenceLevels() async throws {
    let session = URL(fileURLWithPath: try #require(measuredSession), isDirectory: true)
    let manifest = try SessionArchive.readManifest(at: session)
    let transcript = try #require(try SessionFiles.currentTranscript(session: session))
    let temp = try TemporaryDirectory("deep-measure")
    defer { temp.remove() }
    for track in Set(manifest.chunks.map(\.track)).sorted() {
        let rendered = try TrackRenderer.render(session: session, manifest: manifest, track: track,
                                                to: temp.url.appendingPathComponent("\(track).caf"))
        let file = try AVAudioFile(forReading: rendered.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        /// Render seconds of a session time inside a span.
        func renderTime(_ time: Double) -> Double? {
            rendered.timeMap.first { time >= $0.sessionStart && time <= $0.sessionStart + $0.duration }
                .map { $0.renderStart + (time - $0.sessionStart) }
        }
        let words = transcript.segments.filter { ($0.track ?? track) == track }
            .flatMap { WordTiming.effectiveWords(of: $0) }
        var speech: [Double] = []
        for word in words {
            guard let start = renderTime(word.start), let end = renderTime(word.end) else { continue }
            speech.append(DeepAudio.levelDB(samples, from: start, to: end))
        }
        var quiet: [Double] = []
        let starts = words.map(\.start).sorted()
        for span in rendered.timeMap {
            var time = span.sessionStart
            while time + 1 <= span.sessionStart + span.duration {
                let near = starts.contains { $0 >= time - 1 && $0 <= time + 2 }
                if !near, let start = renderTime(time) {
                    quiet.append(DeepAudio.levelDB(samples, from: start, to: start + 1))
                }
                time += 1
            }
        }
        func percentile(_ values: [Double], _ p: Double) -> String {
            guard !values.isEmpty else { return "-" }
            let sorted = values.sorted()
            return String(format: "%.1f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))])
        }
        func below(_ values: [Double], _ threshold: Double) -> Int { values.filter { $0 < threshold }.count }
        print("measure \(track): \(speech.count) words; word level p1 \(percentile(speech, 0.01)) p5 "
            + "\(percentile(speech, 0.05)) p10 \(percentile(speech, 0.1)) p50 \(percentile(speech, 0.5)) dBFS")
        print("measure \(track): \(quiet.count) wordless seconds; level p10 \(percentile(quiet, 0.1)) p50 "
            + "\(percentile(quiet, 0.5)) p90 \(percentile(quiet, 0.9)) p99 \(percentile(quiet, 0.99)) dBFS")
        for threshold in [-40.0, -45, -50, -55, -60] {
            print("measure \(track): below \(Int(threshold)) dBFS: \(below(speech, threshold)) words, "
                + "\(below(quiet, threshold)) wordless seconds")
        }
    }
}
