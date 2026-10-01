import CoreGraphics
import CoreText
import Darwin
import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
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

@Test func screenOCRResumesCompletedFramesWithoutReprocessingOrChangingAudio() async throws {
    let temp = try TemporaryDirectory("screen-ocr")
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
    let temp = try TemporaryDirectory("screen-ocr-invalid-image")
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Invented meeting", source: .microphone,
        locale: "en-CA", backend: .speech)
    try await archive.finish(status: ArchiveStatus.audioOnly)
    let frame = ScreenKeyframe(start: 1, end: 2)
    try ScreenContextStore.write(ScreenContextRecord(sessionID: archive.id, frames: [frame]), session: archive.directory)
    if oversized {
        let context = try #require(CGContext(data: nil, width: 2000, height: 2, bitsPerComponent: 8,
            bytesPerRow: 2000, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
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
