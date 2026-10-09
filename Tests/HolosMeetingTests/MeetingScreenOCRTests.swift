import CoreGraphics
import CoreText
import Darwin
import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
import HolosTestSupport
import ImageIO
import Testing
import UniformTypeIdentifiers

private func screenOCRImage() throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8,
        bytesPerRow: 1280 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
    let text = NSAttributedString(string: "ExampleTool Cloud Infrastructure", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 36, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
    context.textPosition = CGPoint(x: 40, y: 600)
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
    return try #require(context.makeImage())
}

private func screenOCRBatchFixture(_ count: Int) async throws -> (TemporaryDirectory, SessionArchive) {
    let temp = try TemporaryDirectory("screen-ocr-batch", permissions: 0o700)
    let archive = try SessionArchive.create(root: temp.url, name: "Invented meeting", source: .microphone,
        locale: "en-CA", backend: .speech)
    let transcript = Transcript(source: "synthetic", locale: "en-CA", backend: .speech,
        segments: [TranscriptSegment(start: 0, end: 1, text: "Invented example", track: "mic")])
    try await archive.saveTranscript(transcript, writeLegacyExports: false)
    try await archive.finish(status: ArchiveStatus.complete)
    let bytes = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try screenOCRImage(), nil)
    #expect(CGImageDestinationFinalize(destination))
    let frames = (0..<count).map { ScreenKeyframe(start: Double($0 * 10), end: Double($0 * 10 + 5)) }
    try ScreenContextStore.write(ScreenContextRecord(sessionID: archive.id, frames: frames), session: archive.directory)
    for frame in frames { try AtomicFile.create(bytes as Data, at: ScreenContextStore.image(frame.id, session: archive.directory)) }
    return (temp, archive)
}

private func screenOCRLine(_ text: String) -> [ScreenTextLine] {
    [.init(text: text, x: 0, y: 0, width: 0.5, height: 0.1, confidence: 0.9)]
}

@Test func screenOCRBatchResumesOnlyItsWorkBudget() async throws {
    let (temp, archive) = try await screenOCRBatchFixture(3)
    defer { temp.remove() }
    let calls = SharedValue(0)
    let recognizer: MeetingScreenOCR.Recognizer = { _, _ in calls.update { $0 += 1 }; return screenOCRLine("ExampleTool") }
    let first = try await MeetingScreenOCR.processBounded(session: archive.directory, sessionID: archive.id,
        languages: ["en-CA"], timeout: .seconds(30), maximumFrames: 1, recognizer: recognizer)
    #expect(!first && calls.value == 1)
    let partial = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(partial.frames[0].lines != nil && partial.frames[1].lines == nil && partial.ocrID == nil)
    let second = try await MeetingScreenOCR.processBounded(session: archive.directory, sessionID: archive.id,
        languages: ["en-CA"], timeout: .seconds(30), maximumFrames: 2, recognizer: recognizer)
    #expect(second && calls.value == 3)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func screenOCRDeadlineAbandonsHungRecognitionAndFencesLateResults() async throws {
    let (temp, archive) = try await screenOCRBatchFixture(1)
    defer { temp.remove() }
    let deadline = SharedDeadline()
    let started = SharedValue(false), ended = SharedValue(false)
    let release = DispatchSemaphore(value: 0)
    let run = Task {
        try await MeetingScreenOCR.$deadlineForTesting.withValue(deadline) {
            try await MeetingScreenOCR.$didEndForTesting.withValue({ ended.set(true) }) {
                try await MeetingScreenOCR.processBounded(session: archive.directory, sessionID: archive.id,
                    languages: ["en-CA"], timeout: .seconds(30), recognizer: { _, _ in
                        started.set(true); release.wait(); return screenOCRLine("OldResult")
                    })
            }
        }
    }
    defer { release.signal() }
    #expect(await eventually { started.value })
    deadline.set(ContinuousClock.now)
    let completed = try await run.value
    #expect(!completed)
    #expect(!ended.value, "The bounded caller returns while a native recognizer is still blocked.")
    let partial = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(partial.frames[0].lines == nil && partial.ocrID == nil)
    // The successor must finish: a limit no load reaches (the default 5 s could cut it short on a loaded machine).
    _ = try await MeetingScreenOCR.processBounded(session: archive.directory, sessionID: archive.id,
        languages: ["en-CA"], timeout: .seconds(60), recognizer: { _, _ in screenOCRLine("NewResult") })
    release.signal()
    #expect(await eventually { ended.value })
    let result = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(result.frames[0].lines == screenOCRLine("NewResult") && result.ocrID == nil)
}

@Test(.timeLimit(.minutes(1))) func screenOCRRecoveryRunsWithoutWordFixPairsOrEvenATranscript() async throws {
    // The post-processor's OCR batch has a real 5 s limit; here recognition must finish, so the batches get a limit
    // no load reaches (the test's time limit ends a hang).
    try await MeetingScreenOCR.$batchTimeoutForTesting.withValue(.seconds(60)) {
        try await screenOCRRecoveryRuns()
    }
}

private func screenOCRRecoveryRuns() async throws {
    let (temp, archive) = try await screenOCRBatchFixture(1)
    defer { temp.remove() }
    let calls = SharedValue(0)
    let processor = MeetingPostProcessor(voiceSamples: .none, freeSpace: FixedFreeSpace(.max), wordFixes: .none,
        screenOCR: { _, _ in calls.update { $0 += 1 }; return screenOCRLine("ExampleTool") })
    let record = try await processor.run(session: archive.directory, lease: nil)
    #expect(calls.value == 1 && !record.stages.contains { $0.stage == .wordFixes })
    let result = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(result.frames[0].lines == screenOCRLine("ExampleTool"))
    let audioOnly = try SessionArchive.create(root: temp.url, name: "Invented audio-only", source: .microphone,
        locale: "en-CA", backend: .speech)
    try await audioOnly.finish(status: ArchiveStatus.audioOnly)
    // Reuse only synthetic pixels, not a transcript; the early no-transcript path still completes a frame.
    let frame = ScreenKeyframe(start: 1, end: 2)
    try ScreenContextStore.write(ScreenContextRecord(sessionID: audioOnly.id, frames: [frame]), session: audioOnly.directory)
    let source = try ScreenContextStore.image(result.frames[0].id, session: archive.directory)
    let bytes = try #require(try AtomicFile.readIfPresent(source, maxBytes: ScreenContextStore.maximumImageBytes))
    try AtomicFile.create(bytes, at: ScreenContextStore.image(frame.id, session: audioOnly.directory))
    _ = try await processor.run(session: audioOnly.directory, lease: nil)
    #expect(calls.value == 2)
}

@Test func screenOCRResumesCompletedFramesWithoutReprocessingOrChangingAudio() async throws {
    let temp = try TemporaryDirectory("screen-ocr", permissions: 0o700)
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Invented meeting", source: .microphone,
        locale: "en-CA", backend: .speech)
    try await archive.finish(status: ArchiveStatus.audioOnly)
    let image = try screenOCRImage()
    let bytes = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let frame = ScreenKeyframe(start: 4, end: 12)
    try ScreenContextStore.write(ScreenContextRecord(sessionID: archive.id, frames: [frame]), session: archive.directory)
    try AtomicFile.create(bytes as Data, at: ScreenContextStore.image(frame.id, session: archive.directory))
    let calls = SharedValue(0)
    let recognize: MeetingScreenOCR.Recognizer = { _, languages in
        calls.update { $0 += 1 }
        #expect(languages == ["en-CA", "fr-CA"])
        return [ScreenTextLine(text: "ExampleTool", x: 0.1, y: 0.2, width: 0.4, height: 0.1, confidence: 0.9)]
    }
    try await MeetingScreenOCR.process(session: archive.directory, sessionID: archive.id,
        languages: ["en-CA", "fr-CA"], recognizer: recognize)
    try await MeetingScreenOCR.process(session: archive.directory, sessionID: archive.id,
        languages: ["en-CA", "fr-CA"], recognizer: recognize)
    #expect(calls.value == 1)
    let result = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(result.words(from: 5, to: 6) == ["ExampleTool"])
    #expect(try SessionArchive.readManifest(at: archive.directory).status == ArchiveStatus.audioOnly)
}

@Test func screenOCRHintsReachOnlyMatchingTermQuestionsAndNeverForceChanges() async throws {
    let segment = TranscriptSegment(start: 10, end: 12, text: "backups in the cloud", track: "mic")
    let transcript = Transcript(source: "synthetic", locale: "en-CA", backend: .speech, segments: [segment])
    let line = ScreenTextLine(text: "Claude", x: 0, y: 0, width: 0.3, height: 0.1, confidence: 0.9)
    let evidence = ScreenContextRecord(sessionID: "id", frames: [ScreenKeyframe(start: 10, end: 13, lines: [line])])
    let prompts = SharedValue<[String]>([])
    let dependencies = WordFixDependencies(corrections: { CorrectionList() }, wordList: { WordList() }, model: { _ in
        .available { _, prompt in prompts.update { $0.append(prompt) }; return "cloud" }
    })
    let terms = CorrectionList(entries: [Correction(heard: "cloud", meant: "Claude")])
    let result = try await WordFixStage.fix(transcript, title: "Synthetic", corrections: CorrectionList(),
        terms: terms, dependencies: dependencies, screenContext: evidence)
    #expect(result.transcript.segments.first?.text == segment.text)
    #expect(prompts.value.count == 1)
    #expect(prompts.value[0].contains("Nearby screen OCR"))
    #expect(prompts.value[0].contains("not proof of what was said"))
    let absent = ScreenContextRecord(sessionID: "id", frames: [ScreenKeyframe(start: 20, end: 30, lines: [line])])
    _ = try await WordFixStage.fix(transcript, title: "Synthetic", corrections: CorrectionList(), terms: terms,
        dependencies: dependencies, screenContext: absent)
    #expect(!prompts.value[1].contains("Nearby screen OCR"))
}

@Test(arguments: [false, true])
func screenOCRRejectsMissingOrOversizedImages(oversized: Bool) async throws {
    let temp = try TemporaryDirectory("screen-ocr-invalid-image", permissions: 0o700)
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Invented meeting", source: .microphone,
        locale: "en-CA", backend: .speech)
    try await archive.finish(status: ArchiveStatus.audioOnly)
    let frame = ScreenKeyframe(start: 1, end: 2)
    try ScreenContextStore.write(ScreenContextRecord(sessionID: archive.id, frames: [frame]), session: archive.directory)
    if oversized {
        let width = ScreenContextStore.maximumImageDimension + 1
        let context = try #require(CGContext(data: nil, width: width, height: 2, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        let image = try #require(context.makeImage())
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        try AtomicFile.create(bytes as Data, at: ScreenContextStore.image(frame.id, session: archive.directory))
    }
    let calls = SharedValue(0)
    try await MeetingScreenOCR.process(session: archive.directory, sessionID: archive.id, languages: ["en-CA"],
        recognizer: { _, _ in calls.update { $0 += 1 }; return [] })
    let result = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(calls.value == 0 && result.failure == "imageUnavailable" && result.frames[0].lines == nil)
    #expect(try SessionArchive.readManifest(at: archive.directory).status == ArchiveStatus.audioOnly)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HOLOS_SCREEN_BENCHMARK"] == "1"))
func screenSyntheticOCRAndDiffBenchmark() throws {
    let image = try screenOCRImage()
    var before = rusage(); getrusage(RUSAGE_SELF, &before)
    let start = ContinuousClock.now
    var recognized = 0
    for _ in 0..<5 { recognized += try MeetingScreenOCR.recognize(image, languages: ["en-CA"]).count }
    var after = rusage(); getrusage(RUSAGE_SELF, &after)
    func cpu(_ value: rusage) -> Double {
        Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }
    print("Synthetic OCR: 5 frames; lines=\(recognized); elapsed=\(start.duration(to: .now)); CPU seconds=\(cpu(after) - cpu(before))")
    let fingerprint = try #require(ScreenFrameDifference.fingerprint(image))
    let diffStart = ContinuousClock.now
    for _ in 0..<1000 { _ = ScreenFrameDifference.meaningful(fingerprint, comparedWith: fingerprint) }
    print("Synthetic diff: 1000 frames; elapsed=\(diffStart.duration(to: .now))")
}

/// Keyframes of two displays overlap in time; OCR goes keyframe by keyframe and keeps each one's display, and
/// nearby text comes from both displays.
@Test(.timeLimit(.minutes(1)))
func screenOCRReadsEveryDisplaysKeyframes() async throws {
    let (temp, archive) = try await screenOCRBatchFixture(0)
    defer { temp.remove() }
    let main = ScreenDisplay(id: 4, number: 1, isMain: true), side = ScreenDisplay(id: 7, number: 2, isMain: false)
    let frames = [ScreenKeyframe(start: 0, end: 20, display: main), ScreenKeyframe(start: 5, end: 8, display: side),
                  ScreenKeyframe(start: 10, end: 15, display: side)]
    try ScreenContextStore.write(ScreenContextRecord(sessionID: archive.id, frames: frames), session: archive.directory)
    let bytes = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try screenOCRImage(), nil)
    #expect(CGImageDestinationFinalize(destination))
    for frame in frames { try AtomicFile.create(bytes as Data, at: ScreenContextStore.image(frame.id, session: archive.directory)) }
    let texts = SharedValue(["Roadmap", "Agenda", "Budget"])
    let recognizer: MeetingScreenOCR.Recognizer = { _, _ in screenOCRLine(texts.update { $0.removeFirst() }) }
    let done = try await MeetingScreenOCR.processBounded(session: archive.directory, sessionID: archive.id,
        languages: ["en-CA"], timeout: .seconds(30), maximumFrames: 8, recognizer: recognizer)
    let record = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(done && record.frames.map { $0.display?.number } == [1, 2, 2])
    #expect(record.frames.compactMap { $0.lines?.first?.text } == ["Roadmap", "Agenda", "Budget"])
    #expect(record.words(from: 6, to: 7) == ["Roadmap", "Agenda"])
}
