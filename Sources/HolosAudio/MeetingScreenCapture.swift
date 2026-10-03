import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import HolosCore
import HolosStorage
import ImageIO
import ScreenCaptureKit
import Synchronization
import UniformTypeIdentifiers

/// What a meeting's optional screen capture records (docs/meeting-design.md §4.15).
public enum ScreenCaptureTarget: String, Codable, Sendable, Equatable, CaseIterable {
    /// The main display (the one with the menu bar), every window on it except Voice is Local's own.
    case display
}

/// The pure decisions behind the display filter, testable without ScreenCaptureKit objects or a permission.
public enum ScreenCapturePlan {
    /// The app and its bundled `voiceislocal` tool: the live transcript, Review, and the menu are never captured
    /// and read back into the meeting's context.
    public static let ownBundleIdentifiers: Set<String> = ["ca.orlenko.holos.app", "ca.orlenko.holos.cli"]

    /// Whether an application is Voice is Local itself: one of its bundle identifiers, this process's, or this
    /// process (a development build run under another identifier).
    public static func isOwn(bundleIdentifier: String, processID: Int32,
                             currentProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
                             currentBundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        processID == currentProcessID || ownBundleIdentifiers.contains(bundleIdentifier)
            || (currentBundleIdentifier.map { !$0.isEmpty && $0 == bundleIdentifier } ?? false)
    }

    /// The applications the display filter leaves out (`SCContentFilter(display:excludingApplications:…)`).
    public static func excluded<Application>(_ applications: [Application],
                                             bundleIdentifier: (Application) -> String,
                                             processID: (Application) -> Int32,
                                             currentProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
                                             currentBundleIdentifier: String? = Bundle.main.bundleIdentifier)
        -> [Application] {
        applications.filter {
            isOwn(bundleIdentifier: bundleIdentifier($0), processID: processID($0),
                  currentProcessID: currentProcessID, currentBundleIdentifier: currentBundleIdentifier)
        }
    }

    /// The main display, or the first one when the main display is not listed (it is being reconfigured).
    public static func display<Display>(_ displays: [Display], id: (Display) -> CGDirectDisplayID,
                                        main: CGDirectDisplayID = CGMainDisplayID()) -> Display? {
        displays.first { id($0) == main } ?? displays.first
    }

    /// The stream's frame size: the display's pixels, scaled down so neither side exceeds
    /// `ScreenContextStore.maximumImageDimension` (5K → 2560×1440), never below 2×2.
    public static func size(pixelWidth: Int, pixelHeight: Int,
                            maximum: Int = ScreenContextStore.maximumImageDimension) -> (width: Int, height: Int) {
        let width = max(1, pixelWidth), height = max(1, pixelHeight)
        let scale = min(1, Double(max(1, maximum)) / Double(max(width, height)))
        return (max(2, Int((Double(width) * scale).rounded())), max(2, Int((Double(height) * scale).rounded())))
    }
}

/// One optional screen stream, independent of audio. Startup never delays the audio consumer.
@MainActor public final class MeetingScreenCapture {
    private var starting: Task<Void, Never>?
    private var stream: SCStream?
    private var receiver: ScreenFrameReceiver?
    private var stopped = false
    private let permissionCheck: @MainActor () -> Bool

    public init(permissionCheck: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.permissionCheck = permissionCheck
    }

    public func start(_ target: ScreenCaptureTarget, session: URL, origin: Double) {
        guard starting == nil, !stopped else { return }
        let receiver = ScreenFrameReceiver(session: session, origin: origin) { [weak self] in
            Task { @MainActor in await self?.stop() }
        }
        self.receiver = receiver
        guard permissionCheck() else { receiver.failed(); return }
        starting = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let self, !self.stopped, !Task.isCancelled else { return }
                switch target {
                case .display:
                    guard let display = ScreenCapturePlan.display(content.displays, id: \.displayID) else {
                        throw HolosError.unavailable("No display is available to capture.")
                    }
                    let own = ScreenCapturePlan.excluded(content.applications, bundleIdentifier: \.bundleIdentifier,
                                                         processID: \.processID)
                    let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                    let mode = CGDisplayCopyDisplayMode(display.displayID)
                    let size = ScreenCapturePlan.size(pixelWidth: mode?.pixelWidth ?? display.width,
                                                      pixelHeight: mode?.pixelHeight ?? display.height)
                    let configuration = SCStreamConfiguration()
                    configuration.width = size.width
                    configuration.height = size.height
                    configuration.pixelFormat = kCVPixelFormatType_32BGRA
                    configuration.minimumFrameInterval = CMTime(value: 2, timescale: 1)
                    configuration.queueDepth = 3
                    configuration.showsCursor = false
                    configuration.capturesAudio = false
                    configuration.captureMicrophone = false
                    let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
                    try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
                    self.stream = stream
                    try await stream.startCapture()
                    if self.stopped || Task.isCancelled { try? await stream.stopCapture() }
                }
            } catch { receiver.failed() }
        }
    }

    public func stop() async {
        stopped = true
        starting?.cancel()
        let stream = self.stream
        self.stream = nil
        // Close the receiver first: even a hung/late platform start cannot persist another frame.
        await receiver?.close()
        if let stream { try? await stream.stopCapture() }
    }
}

/// JPEG snapshots within `ScreenContextStore`'s bounds.
enum ScreenFrameEncoding {
    /// Downscaled so neither side exceeds `maximumImageDimension`, then encoded at quality 0.65, 0.5, 0.35 until
    /// it fits `maximumImageBytes`; then at half the size again. A dense full-screen frame is made smaller rather
    /// than ending the capture. Anything still too large is returned and the caller's cap stops the capture.
    static func jpeg(_ image: CGImage) throws -> Data {
        var image = try downscaled(image, maximum: ScreenContextStore.maximumImageDimension)
        var data = Data()
        for attempt in 0..<2 {
            if attempt > 0 { image = try downscaled(image, maximum: max(image.width, image.height) / 2) }
            for quality in [0.65, 0.5, 0.35] {
                data = try encode(image, quality: quality)
                if data.count <= ScreenContextStore.maximumImageBytes { return data }
            }
        }
        return data
    }

    static func downscaled(_ image: CGImage, maximum: Int) throws -> CGImage {
        guard max(image.width, image.height) > maximum else { return image }
        let size = ScreenCapturePlan.size(pixelWidth: image.width, pixelHeight: image.height, maximum: maximum)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw HolosError.unavailable("A screen snapshot could not be scaled.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let scaled = context.makeImage() else { throw HolosError.unavailable("A screen snapshot could not be scaled.") }
        return scaled
    }

    private static func encode(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw HolosError.unavailable("A screen snapshot could not be encoded.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw HolosError.unavailable("A screen snapshot could not be encoded.")
        }
        return data as Data
    }
}

/// All image conversion, diffing, encoding and IO are on this separate serial utility queue.
final class ScreenFrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    let queue = DispatchQueue(label: "ca.orlenko.holos.screen", qos: .utility)
    private let session: URL
    private let origin: Double
    private let captureID = UUID().uuidString
    private let onFailure: @Sendable () -> Void
    private let encoder: @Sendable (CGImage) throws -> Data
    /// One context for every frame; the software renderer keeps conversion off the GPU.
    private let images = CIContext(options: [.useSoftwareRenderer: true])
    /// The last sample seen. Its image is kept only while it is a change that has not settled yet.
    private struct Sample {
        var fingerprint: [UInt8]
        var time: Double
        var image: CGImage?
    }
    private struct State {
        var stopped = false
        var record: ScreenContextRecord?
        /// The retained (last saved) frame's fingerprint.
        var fingerprint: [UInt8]?
        var previous: Sample?
        var bytes = 0
    }
    private let state = Mutex(State())
    private let stopped = Mutex(false)
    init(session: URL, origin: Double, onFailure: @escaping @Sendable () -> Void = {},
         encoder: @escaping @Sendable (CGImage) throws -> Data = ScreenFrameEncoding.jpeg) {
        self.session = session; self.origin = origin; self.onFailure = onFailure
        self.encoder = encoder
        super.init()
        queue.async {
            let initialized = self.state.withLock { value in
                do {
                    let id = try SessionArchive.readManifest(at: session).id
                    value.record = try ScreenContextStore.update(session: session, sessionID: id) {
                        $0.captureID = self.captureID; $0.ocrID = nil; $0.failure = nil
                    }
                    value.bytes = value.record?.imageBytes ?? 0
                    return true
                } catch { value.stopped = true; return false }
            }
            if !initialized { self.failed() }
        }
    }

    func failed() {
        let wasStopped = stopped.withLock { value in let old = value; value = true; return old }
        guard !wasStopped else { return }
        queue.async { self.seal(failure: "captureFailed"); self.onFailure() }
    }

    func close() async {
        stopped.withLock { $0 = true }
        await withCheckedContinuation { continuation in
            queue.async {
                self.seal(failure: nil)
                continuation.resume()
            }
        }
    }

    private func seal(failure: String?) {
        state.withLock { value in
            value.previous = nil
            guard let record = value.record else { return }
            // The final frame is known only through its last sample, not all the way to stop: locking the screen
            // or an idle stream must not invent screen evidence in a later gap. A change that never settled is
            // dropped.
            value.record = try? ScreenContextStore.update(session: session, sessionID: record.sessionID) {
                guard $0.captureID == self.captureID else { return }
                if let failure { $0.failure = failure }
                $0.captureID = nil
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) { failed() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return }
        let stamp = sampleBuffer.presentationTimeStamp.seconds
        guard stamp.isFinite else { return }
        let time = max(0, stamp - origin)
        var image: CGImage?
        if raw == SCFrameStatus.complete.rawValue, let buffer = sampleBuffer.imageBuffer {
            // A rendered copy: the stream's buffer is returned to its pool while a change waits to settle.
            let input = CIImage(cvPixelBuffer: buffer)
            image = images.createCGImage(input, from: input.extent)
        }
        receive(image, at: time, status: raw)
    }

    /// Called on `queue`, also by synthetic-frame tests. No screen/device lookup occurs here.
    func receive(_ image: CGImage?, at time: Double, status raw: Int) {
        if raw != SCFrameStatus.complete.rawValue && raw != SCFrameStatus.idle.rawValue {
            state.withLock { $0.fingerprint = nil; $0.previous = nil }
            return
        }
        guard time.isFinite, time >= 0, !stopped.withLock({ $0 }) else { return }
        state.withLock { value in
            guard !value.stopped else { return }
            do {
                if value.record == nil {
                    let id = try SessionArchive.readManifest(at: session).id
                    value.record = try ScreenContextStore.update(session: session, sessionID: id) {
                        $0.captureID = self.captureID; $0.ocrID = nil
                    }
                }
                guard var record = value.record else { return }
                // The sample that becomes a new keyframe, and when its content was first seen.
                let kept: (image: CGImage, fingerprint: [UInt8], start: Double)
                if raw == SCFrameStatus.idle.rawValue {
                    // Nothing changed on screen since the previous sample: a change waiting to settle has settled.
                    guard value.fingerprint != nil else { return }
                    if let previous = value.previous, let image = previous.image {
                        kept = (image, previous.fingerprint, previous.time)
                    } else {
                        guard !record.frames.isEmpty else { return }
                        record.frames[record.frames.count - 1].end = max(record.frames.last!.end, time)
                        value.record = record
                        try publish(record)
                        return
                    }
                } else {
                    guard let image, let fingerprint = ScreenFrameDifference.fingerprint(image) else { return }
                    let previous = value.previous
                    if ScreenFrameDifference.settledChange(fingerprint, retained: value.fingerprint,
                                                           previousSample: previous?.fingerprint) {
                        kept = (image, fingerprint, value.fingerprint == nil ? time : previous?.time ?? time)
                    } else if ScreenFrameDifference.meaningful(fingerprint, comparedWith: value.fingerprint) {
                        // A slide that just changed, a scroll, or a moving video: wait for the next sample.
                        value.previous = Sample(fingerprint: fingerprint, time: time, image: image)
                        return
                    } else {
                        value.previous = Sample(fingerprint: fingerprint, time: time, image: nil)
                        guard !record.frames.isEmpty else { return }
                        record.frames[record.frames.count - 1].end = max(record.frames.last!.end, time)
                        value.record = record
                        try publish(record)
                        return
                    }
                }
                guard record.frames.count < ScreenContextStore.maximumFrames,
                      value.bytes < ScreenContextStore.maximumTotalImageBytes else {
                    try stopForStorage(&record, &value)
                    return
                }
                let data = try encoder(kept.image)
                guard data.count <= ScreenContextStore.maximumImageBytes,
                      value.bytes + data.count <= ScreenContextStore.maximumTotalImageBytes else {
                    try stopForStorage(&record, &value)
                    return
                }
                let start = max(kept.start, record.frames.last?.end ?? 0)
                let frame = ScreenKeyframe(start: start, end: max(time, start))
                guard !stopped.withLock({ $0 }) else { return }
                record.frames.append(frame)
                value.bytes += data.count
                record.imageBytes = value.bytes
                value.fingerprint = kept.fingerprint
                value.previous = Sample(fingerprint: kept.fingerprint, time: time, image: nil)
                value.record = record
                try publish(record, newImage: (frame.id, data))
            } catch {
                value.stopped = true
                value.previous = nil
                if var record = value.record { record.failure = "storageFailed"; try? publish(record) }
                onFailure()
            }
        }
    }

    private func stopForStorage(_ record: inout ScreenContextRecord, _ value: inout State) throws {
        record.failure = "storageLimit"; value.stopped = true; value.previous = nil
        value.record = record
        try publish(record)
        onFailure()
    }

    private func publish(_ record: ScreenContextRecord, newImage: (id: String, data: Data)? = nil) throws {
        try ScreenContextStore.update(session: session, sessionID: record.sessionID) { current in
            guard current.captureID == captureID else {
                throw HolosError.unavailable("This screen capture generation ended.")
            }
            if let newImage {
                try AtomicFile.ensurePrivateDirectory(ScreenContextStore.directory(session))
                try AtomicFile.create(newImage.data, at: ScreenContextStore.image(newImage.id, session: session))
            }
            current = record
        }
    }
}
