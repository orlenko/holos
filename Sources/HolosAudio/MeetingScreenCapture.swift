import CoreImage
import CoreGraphics
import CoreMedia
import Foundation
import HolosCore
import HolosStorage
import ImageIO
import ScreenCaptureKit
import Synchronization
import UniformTypeIdentifiers

public struct ScreenWindowSelection: Codable, Sendable, Equatable {
    public var windowID: UInt32
    public var ownerPID: Int32
    public init(windowID: UInt32, ownerPID: Int32) { self.windowID = windowID; self.ownerPID = ownerPID }
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

    public func start(selection: ScreenWindowSelection, session: URL, origin: Double) {
        guard starting == nil, !stopped else { return }
        let receiver = ScreenFrameReceiver(session: session, origin: origin) { [weak self] in
            Task { @MainActor in await self?.stop() }
        }
        self.receiver = receiver
        guard permissionCheck() else { receiver.failed(); return }
        starting = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let self, !self.stopped, !Task.isCancelled else { return }
                guard let window = content.windows.first(where: {
                    $0.windowID == selection.windowID && $0.owningApplication?.processID == selection.ownerPID
                }) else { throw HolosError.unavailable("The selected meeting window is no longer available.") }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                let scale = min(1, 1600 / max(1, window.frame.width, window.frame.height))
                configuration.width = max(2, Int(window.frame.width * scale))
                configuration.height = max(2, Int(window.frame.height * scale))
                configuration.minimumFrameInterval = CMTime(value: 2, timescale: 1)
                configuration.queueDepth = 3
                configuration.showsCursor = false
                configuration.capturesAudio = false
                configuration.captureMicrophone = false
                configuration.ignoreShadowsSingleWindow = true
                let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
                try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
                self.stream = stream
                try await stream.startCapture()
                if self.stopped || Task.isCancelled { try? await stream.stopCapture() }
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

/// All image conversion, diffing, encoding and IO are on this separate serial utility queue.
final class ScreenFrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    let queue = DispatchQueue(label: "ca.orlenko.holos.screen", qos: .utility)
    private let session: URL
    private let origin: Double
    private let captureID = UUID().uuidString
    private let onFailure: @Sendable () -> Void
    private let encoder: @Sendable (CGImage) throws -> Data
    private struct State {
        var stopped = false
        var record: ScreenContextRecord?
        var fingerprint: [UInt8]?
        var bytes = 0
    }
    private let state = Mutex(State())
    private let stopped = Mutex(false)
    init(session: URL, origin: Double, onFailure: @escaping @Sendable () -> Void = {},
         encoder: @escaping @Sendable (CGImage) throws -> Data = ScreenFrameReceiver.jpeg) {
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
            guard let record = value.record else { return }
            // The final frame is known only through its last sample, not all the way to stop: closing a window,
            // locking the screen, or an idle stream must not invent screen evidence in a later gap.
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
            let input = CIImage(cvPixelBuffer: buffer)
            image = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(input, from: input.extent)
        }
        receive(image, at: time, status: raw)
    }

    /// Called on `queue`, also by synthetic-frame tests. No screen/device lookup occurs here.
    func receive(_ image: CGImage?, at time: Double, status raw: Int) {
        if raw != SCFrameStatus.complete.rawValue && raw != SCFrameStatus.idle.rawValue {
            state.withLock { $0.fingerprint = nil }
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
                var newImage: (id: String, data: Data)?
                if raw == SCFrameStatus.idle.rawValue {
                    if !record.frames.isEmpty, value.fingerprint != nil {
                        record.frames[record.frames.count - 1].end = max(record.frames.last!.end, time)
                        value.record = record
                        try publish(record)
                    }
                    return
                }
                guard let image, let fingerprint = ScreenFrameDifference.fingerprint(image) else { return }
                if ScreenFrameDifference.meaningful(fingerprint, comparedWith: value.fingerprint) {
                    guard record.frames.count < ScreenContextStore.maximumFrames,
                          value.bytes < ScreenContextStore.maximumTotalImageBytes else {
                        record.failure = "storageLimit"; value.stopped = true
                        value.record = record
                        try publish(record)
                        onFailure()
                        return
                    }
                    let data = try encoder(image)
                    guard data.count <= ScreenContextStore.maximumImageBytes,
                          value.bytes + data.count <= ScreenContextStore.maximumTotalImageBytes else {
                        record.failure = "storageLimit"; value.stopped = true
                        value.record = record
                        try publish(record)
                        onFailure()
                        return
                    }
                    let frame = ScreenKeyframe(start: max(time, record.frames.last?.end ?? 0), end: max(time, record.frames.last?.end ?? 0))
                    guard !stopped.withLock({ $0 }) else { return }
                    newImage = (frame.id, data)
                    record.frames.append(frame)
                    value.bytes += data.count
                    record.imageBytes = value.bytes
                    value.fingerprint = fingerprint
                } else if !record.frames.isEmpty {
                    record.frames[record.frames.count - 1].end = max(record.frames.last!.end, time)
                }
                value.record = record
                try publish(record, newImage: newImage)
            } catch {
                value.stopped = true
                if var record = value.record { record.failure = "storageFailed"; try? publish(record) }
                onFailure()
            }
        }
    }

    private static func jpeg(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw HolosError.unavailable("A screen snapshot could not be encoded.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw HolosError.unavailable("A screen snapshot could not be encoded.")
        }
        return data as Data
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
