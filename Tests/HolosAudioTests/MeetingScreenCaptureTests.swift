import CoreGraphics
import Foundation
@testable import HolosAudio
import HolosCore
import HolosStorage
import ImageIO
import ScreenCaptureKit
import Synchronization
import Testing

private func screenCaptureFixture() async throws -> (URL, SessionArchive) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-screen-capture-\(UUID().uuidString)")
    let archive = try SessionArchive.create(root: root, name: "Synthetic slides", source: .microphone,
                                           locale: "en-CA", backend: .speech)
    return (root, archive)
}

private func screenCaptureImage(gray: CGFloat) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
        bytesPerRow: 640, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
    context.setFillColor(gray: gray, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
    return try #require(context.makeImage())
}

/// White 640×360 (16×9 tiles of 40×40) with black rectangles, in pixels.
private func screenCaptureImage(black rectangles: [CGRect]) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
        bytesPerRow: 640, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
    context.setFillColor(gray: 0, alpha: 1)
    for rectangle in rectangles { context.fill(rectangle) }
    return try #require(context.makeImage())
}

/// The display of a single-display synthetic capture.
private let mainDisplay = ScreenDisplay(id: 1, number: 1, isMain: true)

private func deliver(_ receiver: ScreenFrameReceiver, image: CGImage? = nil, time: Double,
                     status: SCFrameStatus = .complete, display: ScreenDisplay = mainDisplay) async {
    await withCheckedContinuation { continuation in
        receiver.queue.async {
            receiver.receive(image, at: time, status: status.rawValue, from: display)
            continuation.resume()
        }
    }
}

@Test @MainActor func screenCaptureDeniedPermissionNeverQueriesDisplaysOrStartsAStream() async throws {
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = MeetingScreenCapture(permissionCheck: { false })
    capture.start(.display, session: archive.directory, origin: 0)
    await capture.stop()
    let record = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(record.failure == "captureFailed" && record.frames.isEmpty && record.captureID == nil)
    #expect(try SessionArchive.readManifest(at: archive.directory).status == ArchiveStatus.recording)
    try await archive.finish(status: ArchiveStatus.audioOnly)
}

@Test func screenCaptureKeepsOnlyChangesAndDoesNotBridgeSuspensionOrLateStop() async throws {
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let receiver = ScreenFrameReceiver(session: archive.directory, origin: 0)
    let first = try screenCaptureImage(gray: 1)
    await deliver(receiver, image: first, time: -1)
    await deliver(receiver, image: first, time: .nan)
    await deliver(receiver, image: first, time: 1)
    await deliver(receiver, image: first, time: 3)
    await deliver(receiver, time: 5, status: .idle)
    await deliver(receiver, time: 6, status: .suspended)
    await deliver(receiver, time: 20, status: .idle)
    await deliver(receiver, image: first, time: 30)
    await receiver.close()
    await deliver(receiver, image: try screenCaptureImage(gray: 0), time: 40)
    let record = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(record.frames.count == 2)
    #expect(record.frames[0].start == 1 && record.frames[0].end == 5)
    #expect(record.frames[1].start == 30 && record.frames[1].end == 30)
    #expect(record.captureID == nil)
    for frame in record.frames {
        #expect(try AtomicFile.readIfPresent(ScreenContextStore.image(frame.id, session: archive.directory), maxBytes: ScreenContextStore.maximumImageBytes) != nil)
    }
    try await archive.finish(status: ArchiveStatus.audioOnly)
}

@Test func screenCaptureStorageLimitStopsOnlyOptionalEvidence() async throws {
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let frames = (0..<ScreenContextStore.maximumFrames).map {
        ScreenKeyframe(start: Double($0), end: Double($0))
    }
    try ScreenContextStore.write(ScreenContextRecord(sessionID: archive.id, frames: frames), session: archive.directory)
    let receiver = ScreenFrameReceiver(session: archive.directory, origin: 0)
    await deliver(receiver, image: try screenCaptureImage(gray: 1), time: 1001)
    await receiver.close()
    let record = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(record.frames.count == ScreenContextStore.maximumFrames && record.failure == "storageLimit")
    #expect(try SessionArchive.readManifest(at: archive.directory).status == ArchiveStatus.recording)
    #expect(try FileManager.default.contentsOfDirectory(atPath: ScreenContextStore.directory(archive.directory).path)
        .filter { $0.hasSuffix(".jpg") }.isEmpty)
    try await archive.finish(status: ArchiveStatus.audioOnly)
}

@Test func screenCaptureFencesOldGenerationBeforeCreatingAnotherImage() async throws {
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = ScreenFrameReceiver(session: archive.directory, origin: 0)
    await deliver(first, image: try screenCaptureImage(gray: 1), time: 1)
    let second = ScreenFrameReceiver(session: archive.directory, origin: 0)
    await deliver(second, image: try screenCaptureImage(gray: 0), time: 10)
    await deliver(first, image: try screenCaptureImage(gray: 0), time: 12)
    await first.close()
    await deliver(second, time: 14, status: .idle)
    await second.close()
    let record = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(record.frames.count == 2 && record.frames[1].end == 14)
    let images = try FileManager.default.contentsOfDirectory(atPath: ScreenContextStore.directory(archive.directory).path)
        .filter { $0.hasSuffix(".jpg") }
    #expect(images.count == 2, "A stale frame must not create an orphan image or replace the newer generation.")
    try await archive.finish(status: ArchiveStatus.audioOnly)
}

@Test(arguments: [false, true])
func screenCaptureEncodedImageAndTotalByteCapsStopRatherThanSilentlyDrop(totalCap: Bool) async throws {
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var record = ScreenContextRecord(sessionID: archive.id)
    record.imageBytes = totalCap ? ScreenContextStore.maximumTotalImageBytes - 1 : 0
    try ScreenContextStore.write(record, session: archive.directory)
    let receiver = ScreenFrameReceiver(session: archive.directory, origin: 0, encoder: { _ in
        Data(repeating: 0, count: totalCap ? 2 : ScreenContextStore.maximumImageBytes + 1)
    })
    await deliver(receiver, image: try screenCaptureImage(gray: 1), time: 1)
    await deliver(receiver, image: try screenCaptureImage(gray: 0), time: 2)
    await receiver.close()
    let result = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(result.failure == "storageLimit" && result.frames.isEmpty && result.captureID == nil)
    #expect(try SessionArchive.readManifest(at: archive.directory).status == ArchiveStatus.recording)
    try await archive.finish(status: ArchiveStatus.audioOnly)
}

@Test func screenCaptureKeepsAChangeOnlyOnceItSettles() async throws {
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let receiver = ScreenFrameReceiver(session: archive.directory, origin: 0)
    let white = try screenCaptureImage(gray: 1), black = try screenCaptureImage(gray: 0)
    let gray = try screenCaptureImage(gray: 0.5)
    await deliver(receiver, image: white, time: 1)
    await deliver(receiver, image: black, time: 3)   // a new slide: not kept yet, and the first frame ends at 1
    await deliver(receiver, image: black, time: 5)   // still there: kept from when it was first seen
    await deliver(receiver, image: gray, time: 7)    // another one, then nothing changes on screen
    await deliver(receiver, time: 9, status: .idle)  // settled: kept from 7 to 9
    await deliver(receiver, image: white, time: 11)  // a video-like flicker that never settles
    await deliver(receiver, image: black, time: 13)
    await receiver.close()
    let record = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(record.frames.map(\.start) == [1, 3, 7])
    #expect(record.frames.map(\.end) == [1, 5, 9])
    let images = try FileManager.default.contentsOfDirectory(atPath: ScreenContextStore.directory(archive.directory).path)
        .filter { $0.hasSuffix(".jpg") }
    #expect(images.count == 3, "An unsettled change is never written.")
    try await archive.finish(status: ArchiveStatus.audioOnly)
}

@Test func aSettledChangeThatStillDiffersFromThePendingSampleStartsAtItsOwnTime() async throws {
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let receiver = ScreenFrameReceiver(session: archive.directory, origin: 0)
    // A slide build: the left half fills in, then a bullet appears on the right while the left half holds still.
    let half = CGRect(x: 0, y: 0, width: 320, height: 360)
    let bullet = CGRect(x: 440, y: 120, width: 40, height: 40)
    let blank = try screenCaptureImage(black: [])
    let built = try screenCaptureImage(black: [half])
    let withBullet = try screenCaptureImage(black: [half, bullet])
    await deliver(receiver, image: blank, time: 1)
    await deliver(receiver, image: built, time: 3)       // pending
    await deliver(receiver, image: withBullet, time: 5)  // the left half settled, but this picture is new at 5
    await deliver(receiver, image: withBullet, time: 7)
    await receiver.close()
    let record = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(record.frames.map(\.start) == [1, 5], "the saved picture, with its bullet, was not on screen at 3")
    #expect(record.frames.map(\.end) == [1, 7])
    try await archive.finish(status: ArchiveStatus.audioOnly)
}

@Test func aTransientChangeThatRevertsLeavesAGapInTheRetainedFrame() async throws {
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let receiver = ScreenFrameReceiver(session: archive.directory, origin: 0)
    let slide = try screenCaptureImage(gray: 1), popup = try screenCaptureImage(gray: 0)
    await deliver(receiver, image: slide, time: 1)
    await deliver(receiver, image: slide, time: 3)
    await deliver(receiver, image: popup, time: 5)   // on screen for one sample only: never settles
    await deliver(receiver, image: slide, time: 7)   // back: a new interval, not 1…7 across the change
    await deliver(receiver, image: slide, time: 9)
    await deliver(receiver, time: 11, status: .idle)
    await receiver.close()
    let record = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(record.frames.map(\.start) == [1, 7])
    #expect(record.frames.map(\.end) == [3, 11], "Nothing claims the slide was visible at 5.")
    let images = try FileManager.default.contentsOfDirectory(atPath: ScreenContextStore.directory(archive.directory).path)
        .filter { $0.hasSuffix(".jpg") }
    #expect(images.count == 2, "The returning interval has its own snapshot.")
    try await archive.finish(status: ArchiveStatus.audioOnly)
}

@Test func fiveKFramesAreStoredWithinTheDimensionAndByteBounds() async throws {
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let receiver = ScreenFrameReceiver(session: archive.directory, origin: 0)
    let display: CGImage = try #require(syntheticDisplay())
    await deliver(receiver, image: display, time: 1)
    await receiver.close()
    let record = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    let frame = try #require(record.frames.first)
    let data = try #require(try AtomicFile.readIfPresent(ScreenContextStore.image(frame.id, session: archive.directory),
                                                         maxBytes: ScreenContextStore.maximumImageBytes))
    let image = try #require(CGImageSourceCreateWithData(data as CFData, nil)
        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    #expect(image.width == 2560 && image.height == 1440)
    #expect(record.imageBytes == data.count && data.count <= ScreenContextStore.maximumImageBytes)
    try await archive.finish(status: ArchiveStatus.audioOnly)
}

@Test func denseFramesAreReencodedSmallerInsteadOfEndingTheCapture() throws {
    // Random noise is the worst case for JPEG: at quality 0.65 a 2560×1440 frame of it is far above 1 MiB.
    let width = 2560, height = 1440
    var generator = SystemRandomNumberGenerator()
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for index in pixels.indices { pixels[index] = UInt8.random(in: 0...255, using: &generator) }
    let image = try pixels.withUnsafeMutableBytes { bytes -> CGImage in
        let context = try #require(CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        return try #require(context.makeImage())
    }
    let data = try ScreenFrameEncoding.jpeg(image)
    #expect(data.count <= ScreenContextStore.maximumImageBytes)
}

@Test func displayFilterLeavesOutOnlyVoiceIsLocal() {
    struct App { var bundle: String; var pid: Int32 }
    let apps = [
        App(bundle: "ca.orlenko.holos.app", pid: 10), App(bundle: "ca.orlenko.holos.cli", pid: 11),
        App(bundle: "com.example.slides", pid: 12), App(bundle: "com.example.call", pid: 13),
        App(bundle: "com.example.dev-build", pid: 14), App(bundle: "", pid: 15),
    ]
    let excluded = ScreenCapturePlan.excluded(apps, bundleIdentifier: \.bundle, processID: \.pid,
                                              currentProcessID: 15, currentBundleIdentifier: nil)
    #expect(excluded.map(\.pid) == [10, 11, 15], "the app, its recorder tool, and this process")
    let devBuild = ScreenCapturePlan.excluded(apps, bundleIdentifier: \.bundle, processID: \.pid,
                                              currentProcessID: 99, currentBundleIdentifier: "com.example.dev-build")
    #expect(devBuild.map(\.pid) == [10, 11, 14])
    #expect(ScreenCapturePlan.excluded(apps, bundleIdentifier: \.bundle, processID: \.pid,
                                       currentProcessID: 99, currentBundleIdentifier: "").map(\.pid) == [10, 11])
}

@Test func displayPlanPicksTheMainDisplayAndBoundsTheFrameSize() {
    #expect(ScreenCapturePlan.display([3, 1, 2] as [CGDirectDisplayID], id: { $0 }, main: 1) == 1)
    #expect(ScreenCapturePlan.display([3, 2] as [CGDirectDisplayID], id: { $0 }, main: 1) == 3)
    #expect(ScreenCapturePlan.display([] as [CGDirectDisplayID], id: { $0 }, main: 1) == nil)
    #expect(ScreenCapturePlan.size(pixelWidth: 5120, pixelHeight: 2880) == (2560, 1440))
    #expect(ScreenCapturePlan.size(pixelWidth: 6016, pixelHeight: 3384) == (2560, 1440))
    #expect(ScreenCapturePlan.size(pixelWidth: 1920, pixelHeight: 1080) == (1920, 1080))
    #expect(ScreenCapturePlan.size(pixelWidth: 2880, pixelHeight: 1864) == (2560, 1657))
    #expect(ScreenCapturePlan.size(pixelWidth: 0, pixelHeight: 0) == (2, 2))
}

/// Process CPU for the per-sample work on synthetic 5K frames: fingerprint every sample, and for kept frames the
/// downscale and JPEG encode. Prints numbers; no timing assertion.
@Test(.enabled(if: ProcessInfo.processInfo.environment["HOLOS_SCREEN_BENCHMARK"] == "1"))
func screenFiveKFrameCPUBenchmark() throws {
    let frames = try (0..<4).map { try #require(syntheticDisplay(offset: $0 * 90)) }
    func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    let samples = 20
    var start = cpu()
    for index in 0..<samples { _ = ScreenFrameDifference.fingerprint(frames[index % frames.count]) }
    let fingerprint = (cpu() - start) / Double(samples)
    start = cpu()
    var bytes = 0
    for index in 0..<samples { bytes += try ScreenFrameEncoding.jpeg(frames[index % frames.count]).count }
    let encode = (cpu() - start) / Double(samples)
    // The stream delivers 2560×1440 BGRA buffers; the receiver copies each through a software CIContext.
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 2560, 1440, kCVPixelFormatType_32BGRA, nil, &buffer)
    let pixels = try #require(buffer)
    let context = CIContext(options: [.useSoftwareRenderer: true])
    start = cpu()
    for _ in 0..<samples {
        let input = CIImage(cvPixelBuffer: pixels)
        _ = try #require(context.createCGImage(input, from: input.extent))
    }
    let convert = (cpu() - start) / Double(samples)
    print("Synthetic 5K: fingerprint \(String(format: "%.1f", fingerprint * 1000)) ms CPU per sample; "
        + "downscale+JPEG \(String(format: "%.1f", encode * 1000)) ms CPU per kept frame; "
        + "\(bytes / samples / 1024) KiB per JPEG; 2560×1440 buffer copy "
        + "\(String(format: "%.1f", convert * 1000)) ms CPU per sample")
}

// MARK: - All displays

private func candidate(_ id: CGDirectDisplayID, x: CGFloat, y: CGFloat = 0, main: Bool = false) -> ScreenDisplayCandidate {
    ScreenDisplayCandidate(id: id, frame: CGRect(x: x, y: y, width: 1920, height: 1080), isMain: main)
}

@Test func displaysAreNumberedByArrangementAndKeepTheirNumberAcrossHotPlug() {
    var roster = ScreenDisplayRoster()
    // Main in the middle, one to its left, one above it: left to right, then top to bottom.
    let first = roster.reconcile([candidate(9, x: 0, main: true), candidate(5, x: -1920), candidate(7, x: 0, y: -1080)])
    #expect(first.start.map(\.id) == [5, 7, 9] && first.start.map(\.number) == [1, 2, 3] && first.stop.isEmpty)
    #expect(first.start.map(\.isMain) == [false, false, true])
    #expect(roster.running == [5, 7, 9])
    // Unchanged: nothing to do.
    let same = roster.reconcile([candidate(9, x: 0, main: true), candidate(5, x: -1920), candidate(7, x: 0, y: -1080)])
    #expect(same.start.isEmpty && same.stop.isEmpty)
    // 5 disconnects; 3 connects to the far left, and takes the next number, not the first place.
    let change = roster.reconcile([candidate(9, x: 0, main: true), candidate(7, x: 0, y: -1080), candidate(3, x: -3840)])
    #expect(change.stop == [5] && change.start.map(\.id) == [3] && change.start.map(\.number) == [4])
    // 5 comes back: its own number again, in a new stream.
    let back = roster.reconcile([candidate(9, x: 0, main: true), candidate(7, x: 0, y: -1080), candidate(3, x: -3840),
                                 candidate(5, x: 1920)])
    #expect(back.start == [ScreenDisplay(id: 5, number: 1, isMain: false)] && back.stop.isEmpty)
    // Every display gone (the lid closed on the last one): every stream ends, none fails.
    let none = roster.reconcile([])
    #expect(none.stop == [3, 5, 7, 9] && roster.running.isEmpty && !roster.anyFailed)
}

@Test func aFailedDisplayIsNotRestartedWhileConnectedButMayComeBackAfterADisconnect() {
    var roster = ScreenDisplayRoster(known: [ScreenDisplay(id: 9, number: 1, isMain: true),
                                             ScreenDisplay(id: 5, number: 2, isMain: false)])
    let first = roster.reconcile([candidate(5, x: -1920), candidate(6, x: 1920), candidate(9, x: 0, main: true)])
    #expect(first.start.map(\.number) == [1, 2, 3], "numbers saved earlier in the meeting are kept; a new one follows")
    roster.failed(5)
    #expect(roster.anyFailed && roster.running == [6, 9])
    #expect(roster.reconcile([candidate(5, x: -1920), candidate(6, x: 1920), candidate(9, x: 0, main: true)]).start.isEmpty,
            "a stream that broke while its display stayed is not restarted in a loop")
    #expect(roster.reconcile([candidate(6, x: 1920), candidate(9, x: 0, main: true)]).stop.isEmpty)
    #expect(!roster.anyFailed, "it was being disconnected after all")
    #expect(roster.reconcile([candidate(5, x: -1920), candidate(6, x: 1920), candidate(9, x: 0, main: true)]).start
        .map(\.id) == [5])
    roster.capped(6)
    #expect(roster.reconcile([candidate(9, x: 0, main: true)]).stop == [5])
    #expect(roster.reconcile([candidate(6, x: 1920), candidate(9, x: 0, main: true)]).start.isEmpty,
            "a display stopped for the storage caps stays stopped")
}

@Test func displayNumbersStayWithinWhatTheStoreAccepts() {
    var roster = ScreenDisplayRoster(known: [ScreenDisplay(id: 1, number: ScreenContextStore.maximumDisplays, isMain: true)])
    let change = roster.reconcile([candidate(1, x: 0, main: true), candidate(2, x: 1920)])
    #expect(change.start.map(\.id) == [1], "a 65th display in one meeting is not captured")
}

@Test func theMainTargetCapturesOnlyTheMainDisplay() {
    let displays = [candidate(5, x: -1920), candidate(9, x: 0, main: true)]
    #expect(ScreenCapturePlan.displays(displays, for: .display).map(\.id) == [5, 9])
    #expect(ScreenCapturePlan.displays(displays, for: .main).map(\.id) == [9])
    #expect(ScreenCapturePlan.displays([candidate(5, x: 0)], for: .main).map(\.id) == [5], "the first while reconfiguring")
    #expect(ScreenCapturePlan.displays([], for: .main).isEmpty)
}

@Test func screenTargetsAreTheRecorderArgumentsAndOffIsNoTarget() {
    #expect(ScreenCaptureTarget(rawValue: "display") == .display)
    #expect(ScreenCaptureTarget(rawValue: "main") == .main)
    #expect(ScreenCaptureTarget(rawValue: "off") == nil)
    #expect(ScreenCaptureTarget.allCases.map(\.rawValue) == ["display", "main"])
}

@Test func sharedCapsStopTheBusiestDisplayFirstThenTheRest() {
    let main = ScreenDisplay(id: 1, number: 1, isMain: true), call = ScreenDisplay(id: 2, number: 2, isMain: false)
    let slides = ScreenDisplay(id: 3, number: 3, isMain: false)
    func usage(_ display: ScreenDisplay, _ keyframes: Int, _ bytes: Int = 0) -> ScreenStoragePolicy.Usage {
        .init(display: display, keyframes: keyframes, bytes: bytes)
    }
    // One display: only the cap itself ends it, as before.
    #expect(ScreenStoragePolicy.displaysToStop([usage(main, 999)], frames: 999, bytes: 0).isEmpty)
    // Two: the busiest stops once 90% of either cap is used, the quieter one runs on to the cap.
    let two = [usage(main, 120), usage(call, 779)]
    #expect(ScreenStoragePolicy.displaysToStop(two, frames: 899, bytes: 0).isEmpty)
    #expect(ScreenStoragePolicy.displaysToStop(two, frames: 900, bytes: 0) == [2])
    #expect(ScreenStoragePolicy.displaysToStop([usage(main, 120)], frames: 999, bytes: 0).isEmpty)
    #expect(ScreenStoragePolicy.full(frames: 1000, bytes: 0) && ScreenStoragePolicy.full(frames: 0, bytes: 256 << 20))
    #expect(!ScreenStoragePolicy.full(frames: 999, bytes: (256 << 20) - 1))
    // Near the byte cap, the display with the most bytes is the busiest even with fewer keyframes.
    let bytes = [usage(main, 300, 60 << 20), usage(call, 100, 180 << 20)]
    #expect(ScreenStoragePolicy.displaysToStop(bytes, frames: 400, bytes: 240 << 20) == [2])
    #expect(ScreenStoragePolicy.displaysToStop(bytes, frames: 900, bytes: 100 << 20) == [1])
    // Three: one stops at 80%, the next at 90%, the last at the cap.
    let three = [usage(main, 100), usage(call, 500), usage(slides, 200)]
    #expect(ScreenStoragePolicy.displaysToStop(three, frames: 799, bytes: 0).isEmpty)
    #expect(ScreenStoragePolicy.displaysToStop(three, frames: 800, bytes: 0) == [2])
    #expect(ScreenStoragePolicy.displaysToStop([usage(main, 100), usage(slides, 200)], frames: 900, bytes: 0) == [3])
    // On a tie the main display stays, then the lower number.
    #expect(ScreenStoragePolicy.displaysToStop([usage(main, 5), usage(call, 5), usage(slides, 5)],
                                               frames: 950, bytes: 0) == [3, 2])
    // Never more than three tenths held back: five displays stop two at 70%.
    let five = (1...5).map { usage(ScreenDisplay(id: UInt32($0), number: $0, isMain: $0 == 1), $0) }
    #expect(ScreenStoragePolicy.displaysToStop(five, frames: 699, bytes: 0).isEmpty)
    #expect(ScreenStoragePolicy.displaysToStop(five, frames: 700, bytes: 0) == [5, 4])
}

@Test(.timeLimit(.minutes(1)))
func eachDisplayKeepsItsOwnRetainedFrameAndAllWriteOneTimeline() async throws {
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let side = ScreenDisplay(id: 2, number: 2, isMain: false)
    let receiver = ScreenFrameReceiver(session: archive.directory, origin: 0)
    let white = try screenCaptureImage(gray: 1), black = try screenCaptureImage(gray: 0)
    await deliver(receiver, image: white, time: 1)                    // main: kept at once
    await deliver(receiver, image: black, time: 2, display: side)     // side: its own first frame, kept at once
    await deliver(receiver, image: black, time: 3)                    // main: a new slide, pending
    await deliver(receiver, image: white, time: 4, display: side)     // side: a change of its own, pending
    await deliver(receiver, image: black, time: 5)                    // main: settled, from 3
    await deliver(receiver, time: 6, status: .idle, display: side)    // side: settled, from 4 to 6
    await deliver(receiver, image: white, time: 7, display: side)     // side: unchanged, extends its own frame only
    await deliver(receiver, time: 8, status: .suspended)              // main: a gap; side is unaffected
    await deliver(receiver, time: 9, status: .idle, display: side)
    await receiver.close()
    let record = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(record.frames.map(\.start) == [1, 2, 3, 4], "one timeline, in start order")
    #expect(record.frames.map(\.end) == [1, 2, 5, 9])
    #expect(record.frames.map { $0.display?.number } == [1, 2, 1, 2])
    #expect(record.displays.map(\.number) == [1, 2] && record.displayLabel(record.frames[1]) == "Display 2")
    let images = try FileManager.default.contentsOfDirectory(atPath: ScreenContextStore.directory(archive.directory).path)
        .filter { $0.hasSuffix(".jpg") }
    #expect(images.count == 4)
    try await archive.finish(status: ArchiveStatus.audioOnly)
}

@Test(.timeLimit(.minutes(1)))
func anEndedDisplayStopsAtItsLastObservationAndStartsAfreshWhenItReturns() async throws {
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let side = ScreenDisplay(id: 2, number: 2, isMain: false)
    let receiver = ScreenFrameReceiver(session: archive.directory, origin: 0)
    let white = try screenCaptureImage(gray: 1), black = try screenCaptureImage(gray: 0)
    receiver.begin(side)
    await deliver(receiver, image: white, time: 1, display: side)
    await deliver(receiver, image: white, time: 3, display: side)
    await deliver(receiver, image: black, time: 5, display: side)     // a change that never settles
    receiver.end(side.id)                                             // disconnected
    await deliver(receiver, image: black, time: 7, display: side)     // a late sample of the ended stream
    await deliver(receiver, time: 9, status: .idle, display: side)
    await deliver(receiver, image: black, time: 9)                    // the main display goes on
    receiver.begin(side)                                              // reconnected: a new stream
    await deliver(receiver, image: white, time: 20, display: side)
    await receiver.close()
    let record = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    let sideFrames = record.frames.filter { $0.display?.id == side.id }
    #expect(sideFrames.map(\.start) == [1, 20] && sideFrames.map(\.end) == [3, 20],
            "nothing claims the display was seen while it was gone")
    #expect(record.frames.count == 3)
    try await archive.finish(status: ArchiveStatus.audioOnly)
}

@Test(.timeLimit(.minutes(1)))
func theBusiestDisplayStopsAtTheSharedCapAndTheQuietOneRunsToTheEnd() async throws {
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let call = ScreenDisplay(id: 1, number: 1, isMain: true), slides = ScreenDisplay(id: 2, number: 2, isMain: false)
    // 899 keyframes of the call's display already saved earlier in the meeting.
    let earlier = (0..<899).map { ScreenKeyframe(start: Double($0), end: Double($0), display: call) }
    try ScreenContextStore.write(ScreenContextRecord(sessionID: archive.id, frames: earlier), session: archive.directory)
    let capped = Mutex<[UInt32]>([]), failures = Mutex(0)
    let receiver = ScreenFrameReceiver(session: archive.directory, origin: 0,
                                       onFailure: { failures.withLock { $0 += 1 } },
                                       onDisplayCapped: { id in capped.withLock { $0.append(id) } },
                                       encoder: { _ in Data([0xFF, 0xD8]) })
    receiver.begin(call)
    receiver.begin(slides)
    let white = try screenCaptureImage(gray: 1), black = try screenCaptureImage(gray: 0)
    await deliver(receiver, image: white, time: 1000, display: slides)   // the 900th keyframe: 90% of the cap
    #expect(capped.withLock { $0 } == [call.id], "the busier display stops; the slides keep coming")
    await deliver(receiver, image: black, time: 1001, display: call)     // ignored from now on
    // The slides' display saves the remaining 100 keyframes: a new slide every other sample.
    var time = 1002.0
    for slide in 0..<100 {
        await deliver(receiver, image: slide % 2 == 0 ? black : white, time: time, display: slides)
        await deliver(receiver, time: time + 1, status: .idle, display: slides)
        time += 2
    }
    #expect(failures.withLock { $0 } == 0)
    await deliver(receiver, image: black, time: time, display: slides)
    await deliver(receiver, time: time + 1, status: .idle, display: slides)  // over the cap: everything stops
    await receiver.close()
    let record = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(record.frames.count == ScreenContextStore.maximumFrames && record.failure == "storageLimit")
    #expect(record.frames.filter { $0.display == slides }.count == 101)
    #expect(record.frames.filter { $0.display == call }.count == 899)
    #expect(failures.withLock { $0 } == 1 && capped.withLock { $0 } == [call.id])
    try await archive.finish(status: ArchiveStatus.audioOnly)
}

/// ScreenCaptureKit and CoreGraphics, scripted: displays come and go as a test says.
@MainActor private final class FakeScreenSystem: ScreenCaptureSystem {
    var connected: [ScreenDisplayCandidate]
    var failing: Set<CGDirectDisplayID> = []
    var unavailable = false
    /// Runs inside a stream's start, before it returns.
    var whileStarting: ((ScreenDisplay) async -> Void)?
    private(set) var started: [ScreenDisplay] = []
    private(set) var stopped: [CGDirectDisplayID] = []
    private(set) var outputs: [CGDirectDisplayID: ScreenDisplayOutput] = [:]

    init(_ connected: [ScreenDisplayCandidate]) { self.connected = connected }

    func connectedDisplayIDs() -> [CGDirectDisplayID] { connected.map(\.id).sorted() }
    func displays() async throws -> [ScreenDisplayCandidate] {
        if unavailable { throw HolosError.unavailable("Synthetic: no shareable content.") }
        return connected
    }
    func start(_ display: ScreenDisplay, output: ScreenDisplayOutput) async throws -> any ScreenStreamControl {
        if failing.contains(display.id) { throw HolosError.unavailable("Synthetic stream failure.") }
        await whileStarting?(display)
        started.append(display)
        outputs[display.id] = output
        return FakeStream { [weak self] in self?.stopped.append(display.id) }
    }
}

@MainActor private final class FakeStream: ScreenStreamControl {
    private let onStop: () -> Void
    init(onStop: @escaping () -> Void) { self.onStop = onStop }
    func stop() async { onStop() }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func hotPlugStartsAndEndsStreamsAndTagsEachKeyframeWithItsDisplay() async throws {
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let system = FakeScreenSystem([candidate(9, x: 0, main: true), candidate(5, x: 1920)])
    let capture = MeetingScreenCapture(permissionCheck: { true }, system: system, pollInterval: .seconds(3600))
    capture.start(.display, session: archive.directory, origin: 0)
    await capture.initial?.value
    #expect(system.started == [ScreenDisplay(id: 9, number: 1, isMain: true), ScreenDisplay(id: 5, number: 2, isMain: false)])
    #expect(capture.capturing == [5, 9])
    let white = try screenCaptureImage(gray: 1)
    for output in system.outputs.values {
        await deliver(output.receiver, image: white, time: Double(output.display.number), display: output.display)
    }

    system.connected = [candidate(9, x: 0, main: true)]                       // 5 is unplugged
    await capture.refresh()
    #expect(system.stopped == [5] && capture.capturing == [9])
    system.connected = [candidate(9, x: 0, main: true), candidate(7, x: -1920)] // another one is plugged in
    await capture.refresh()
    #expect(system.started.last == ScreenDisplay(id: 7, number: 3, isMain: false) && capture.capturing == [7, 9])
    let added = try #require(system.outputs[7])
    await deliver(added.receiver, image: white, time: 10, display: added.display)

    // 7's stream breaks while it stays connected: it is not restarted, and the main display goes on.
    added.stopped()
    await capture.streamStopped(7)
    #expect(capture.capturing == [9] && system.started.count == 3)
    await capture.stop()
    #expect(Set(system.stopped) == [5, 9])
    let record = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(record.frames.map { $0.display?.number } == [1, 2, 3] && record.failure == nil && record.captureID == nil)
    try await archive.finish(status: ArchiveStatus.audioOnly)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func theCaptureFailsOnlyWhenNoDisplayCanBeCaptured() async throws {
    // A broken stream on the last display still connected fails the capture, as one display's did.
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let system = FakeScreenSystem([candidate(9, x: 0, main: true), candidate(5, x: 1920)])
    let capture = MeetingScreenCapture(permissionCheck: { true }, system: system, pollInterval: .seconds(3600))
    capture.start(.display, session: archive.directory, origin: 0)
    await capture.initial?.value
    await capture.streamStopped(5)
    var record = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(record.failure == nil, "the other display still captures")
    await capture.streamStopped(9)
    await capture.stop()
    record = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(record.failure == "captureFailed" && record.captureID == nil)

    // Every display unplugged is not a failure; one that comes back is captured again.
    let (otherRoot, other) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: otherRoot) }
    let lid = FakeScreenSystem([candidate(9, x: 0, main: true)])
    let closed = MeetingScreenCapture(permissionCheck: { true }, system: lid, pollInterval: .seconds(3600))
    closed.start(.main, session: other.directory, origin: 0)
    await closed.initial?.value
    lid.connected = []
    await closed.refresh()
    #expect(closed.capturing.isEmpty)
    lid.connected = [candidate(9, x: 0, main: true)]
    await closed.refresh()
    #expect(closed.capturing == [9] && lid.started.count == 2)
    await closed.stop()
    #expect(try ScreenContextStore.read(session: other.directory, sessionID: other.id)?.failure == nil)

    // No display could be started at all.
    let (thirdRoot, third) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: thirdRoot) }
    let broken = FakeScreenSystem([candidate(9, x: 0, main: true)])
    broken.failing = [9]
    let none = MeetingScreenCapture(permissionCheck: { true }, system: broken, pollInterval: .seconds(3600))
    none.start(.display, session: third.directory, origin: 0)
    await none.initial?.value
    await none.stop()
    #expect(try ScreenContextStore.read(session: third.directory, sessionID: third.id)?.failure == "captureFailed")
    for session in [archive, other, third] { try await session.finish(status: ArchiveStatus.audioOnly) }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func theMainTargetFollowsTheMainDisplayAndACappedDisplayStaysStopped() async throws {
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let system = FakeScreenSystem([candidate(9, x: 0, main: true), candidate(5, x: 1920)])
    let main = MeetingScreenCapture(permissionCheck: { true }, system: system, pollInterval: .seconds(3600))
    main.start(.main, session: archive.directory, origin: 0)
    await main.initial?.value
    #expect(main.capturing == [9] && system.started.map(\.id) == [9])
    await main.stop()

    let all = FakeScreenSystem([candidate(9, x: 0, main: true), candidate(5, x: 1920)])
    let capture = MeetingScreenCapture(permissionCheck: { true }, system: all, pollInterval: .seconds(3600))
    capture.start(.display, session: archive.directory, origin: 0)
    await capture.initial?.value
    #expect(all.started.map(\.number) == [1, 2])
    await capture.capped(5)
    #expect(capture.capturing == [9] && all.stopped == [5])
    all.connected = [candidate(9, x: 0, main: true)]
    await capture.refresh()
    all.connected = [candidate(9, x: 0, main: true), candidate(5, x: 1920)]
    await capture.refresh()
    #expect(capture.capturing == [9] && all.started.count == 2)
    await capture.stop()
    try await archive.finish(status: ArchiveStatus.audioOnly)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aStreamThatBreaksWhileStartingIsNotTakenForARunningOne() async throws {
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let system = FakeScreenSystem([candidate(9, x: 0, main: true), candidate(5, x: 1920)])
    let capture = MeetingScreenCapture(permissionCheck: { true }, system: system, pollInterval: .seconds(3600))
    system.whileStarting = { display in
        if display.id == 5 { await capture.streamStopped(5) }
    }
    capture.start(.display, session: archive.directory, origin: 0)
    await capture.initial?.value
    #expect(capture.capturing == [9] && system.started.map(\.id) == [9, 5])
    system.whileStarting = nil
    system.connected = [candidate(9, x: 0, main: true)]
    await capture.refresh()
    system.connected = [candidate(9, x: 0, main: true), candidate(5, x: 1920)]
    await capture.refresh()
    #expect(capture.capturing == [5, 9], "it was gone in between, so it is captured again")
    await capture.stop()
    #expect(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id)?.failure == nil)
    try await archive.finish(status: ArchiveStatus.audioOnly)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func thePollNoticesADisplayConnectedDuringTheMeeting() async throws {
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let system = FakeScreenSystem([candidate(9, x: 0, main: true)])
    let capture = MeetingScreenCapture(permissionCheck: { true }, system: system, pollInterval: .milliseconds(5))
    capture.start(.display, session: archive.directory, origin: 0)
    await capture.initial?.value
    system.connected.append(candidate(5, x: 1920))
    // Polls a bounded number of times; no assertion on how long it took.
    for _ in 0..<20_000 where capture.capturing != [5, 9] { try await Task.sleep(for: .milliseconds(5)) }
    #expect(capture.capturing == [5, 9])
    await capture.stop()
    try await archive.finish(status: ArchiveStatus.audioOnly)
}

/// Two displays' pipelines on synthetic 2560×1440 frames, as the streams deliver them: each sample drawn into a BGRA
/// pixel buffer, copied through the receiver's software CIContext path, diffed, and (for kept frames) encoded and
/// written to a temporary archive. One display shows a slide that changes every other sample (a busy display), the
/// other holds still (idle samples). Prints process CPU per sample and the peak memory footprint above the start;
/// no timing or memory assertion. Nothing is captured from the real screen.
@Test(.enabled(if: ProcessInfo.processInfo.environment["HOLOS_SCREEN_BENCHMARK"] == "1"))
func screenTwoDisplayPipelineBenchmark() async throws {
    func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
    func buffer(_ image: CGImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: image.width,
            height: image.height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }
    let slides = try (0..<4).map { try buffer(try #require(syntheticDisplay(width: 2560, height: 1440, offset: $0 * 45))) }
    let still = try buffer(try #require(syntheticDisplay(width: 2560, height: 1440, lines: 20)))
    let converter = CIContext(options: [.useSoftwareRenderer: true])
    func sample(_ pixels: CVPixelBuffer) -> CGImage? {
        let input = CIImage(cvPixelBuffer: pixels)
        return converter.createCGImage(input, from: input.extent)
    }
    // The first pass warms the CIContext and the JPEG encoder and is not printed; then one busy display alone, a busy
    // one beside a still one (a call beside slides that hold), and two busy ones (the worst case).
    for (name, displays, bothBusy) in [("warm-up", 1, false), ("one busy display", 1, false),
                                       ("busy + still display", 2, false), ("two busy displays", 2, true)] {
        let (root, archive) = try await screenCaptureFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let busy = ScreenDisplay(id: 1, number: 1, isMain: true), quiet = ScreenDisplay(id: 2, number: 2, isMain: false)
        let receiver = ScreenFrameReceiver(session: archive.directory, origin: 0)
        let rounds = 40
        let baseline = footprint()
        var peak = baseline
        let start = cpu()
        for round in 0..<rounds {
            let time = Double(round * 2)
            await deliver(receiver, image: sample(slides[(round / 2) % slides.count]), time: time, display: busy)
            if displays == 2 {
                if bothBusy {
                    await deliver(receiver, image: sample(slides[(round / 2 + 1) % slides.count]), time: time,
                                  display: quiet)
                } else if round == 0 {
                    await deliver(receiver, image: sample(still), time: time, display: quiet)
                } else {
                    await deliver(receiver, time: time, status: .idle, display: quiet)
                }
            }
            peak = max(peak, footprint())
        }
        let spent = cpu() - start
        await receiver.close()
        let record = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
        if name == "warm-up" { try await archive.finish(status: ArchiveStatus.audioOnly); continue }
        print("Synthetic 2560×1440, \(name), \(rounds) samples each: "
            + "\(String(format: "%.1f", spent / Double(rounds) * 1000)) ms CPU per two-second round "
            + "(\(String(format: "%.2f", spent / Double(rounds) / 2 * 100)) % of one core); "
            + "\(record.frames.count) keyframes, \(record.imageBytes / max(1, record.frames.count) / 1024) KiB each; "
            + "peak footprint +\((peak - baseline) / (1 << 20)) MiB")
        try await archive.finish(status: ArchiveStatus.audioOnly)
    }
}
