import CoreGraphics
import Foundation
@testable import HolosAudio
import HolosCore
import HolosStorage
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

private func deliver(_ receiver: ScreenFrameReceiver, image: CGImage? = nil, time: Double,
                     status: SCFrameStatus = .complete) async {
    await withCheckedContinuation { continuation in
        receiver.queue.async {
            receiver.receive(image, at: time, status: status.rawValue)
            continuation.resume()
        }
    }
}

@Test @MainActor func screenCaptureDeniedPermissionNeverQueriesWindowsOrStartsAStream() async throws {
    let (root, archive) = try await screenCaptureFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = MeetingScreenCapture(permissionCheck: { false })
    capture.start(selection: .init(windowID: 123, ownerPID: 456), session: archive.directory, origin: 0)
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
