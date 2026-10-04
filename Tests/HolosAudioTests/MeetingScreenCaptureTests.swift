import CoreGraphics
import Foundation
@testable import HolosAudio
import HolosCore
import HolosStorage
import ImageIO
import ScreenCaptureKit
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

private func deliver(_ receiver: ScreenFrameReceiver, image: CGImage? = nil, time: Double,
                     status: SCFrameStatus = .complete) async {
    await withCheckedContinuation { continuation in
        receiver.queue.async {
            receiver.receive(image, at: time, status: status.rawValue)
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
