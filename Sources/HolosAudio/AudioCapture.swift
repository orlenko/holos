import AVFoundation
import CoreMedia
import Foundation
import HolosCore
import ScreenCaptureKit
import Synchronization

public struct CapturedAudio: Sendable {
    public let track: String
    public let frame: PCMFrame
    /// Buffers of this track were dropped just before this frame because the frame stream was full
    /// (`CaptureOverflow.dropAndCount`): audio is missing between the previous frame and this one.
    public let followsDrop: Bool
    public init(track: String, frame: PCMFrame, followsDrop: Bool = false) {
        self.track = track; self.frame = frame; self.followsDrop = followsDrop
    }
}

/// What `AudioCapture` does when its frame stream is full.
public enum CaptureOverflow: Sendable, Equatable {
    /// End the stream with an error, so a short capture (dictation) never has a silent hole.
    case fail
    /// Drop the buffer, count it (`droppedBuffers`), mark the next delivered frame of the track `followsDrop`, and
    /// keep capturing (meeting recordings, docs/meeting-design.md §4.3).
    case dropAndCount
}

/// Which input device a meeting's microphone track records (docs/meeting-design.md §4.12). PR2a declares it and
/// passes it through; PR2b pins the built-in microphone for `.builtIn`.
public enum MicrophoneSelection: Sendable, Equatable {
    /// The system default input (online calls; dictation).
    case systemDefault
    /// The built-in microphone, whatever the default input is (in-person meetings).
    case builtIn
}

/// Why a capture's frame stream ended with something other than a failure.
public enum CaptureInterruption: Error, Equatable, Sendable {
    /// AVAudioEngineConfigurationChange (reported from PR2b).
    case configurationChanged
    /// The user stopped sharing (`SCStreamError.Code.userStopped` only).
    case userStoppedSharing
}

extension CaptureInterruption: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .configurationChanged: "The audio device configuration changed."
        case .userStoppedSharing: "Screen and system audio sharing was stopped."
        }
    }
}

/// Desktop interaction stays on the main actor; callbacks only copy samples into a bounded queue.
@MainActor
public final class AudioCapture {
    public let frames: AsyncThrowingStream<CapturedAudio, Error>
    public private(set) var hostTimeOrigin: Double
    private let receiver: CaptureReceiver
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private var started = false

    /// `bufferCapacity` buffers wait for the consumer. When the queue is full, `.fail` (dictation's default) ends the
    /// stream with an error; `.dropAndCount` drops the buffer, counts it (`droppedBuffers`), and continues.
    public init(bufferCapacity: Int = 256, overflow: CaptureOverflow = .fail) {
        let pair = AsyncThrowingStream<CapturedAudio, Error>.makeStream(bufferingPolicy: .bufferingOldest(bufferCapacity))
        frames = pair.stream
        hostTimeOrigin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        receiver = CaptureReceiver(origin: hostTimeOrigin, continuation: pair.continuation, overflow: overflow)
    }

    /// Buffers dropped because the frame stream was full.
    public nonisolated var droppedBuffers: Int { receiver.droppedBuffers(track: nil) }

    /// Buffers of `track` ("mic" or "system") dropped because the frame stream was full. Readable from any thread.
    public nonisolated func droppedBuffers(track: String) -> Int { receiver.droppedBuffers(track: track) }

    /// Tests only: delivers `frame` as a capture callback would.
    nonisolated func emitForTesting(track: String, frame: PCMFrame) { receiver.emit(track: track, frame: frame) }

    public static var microphonePermission: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
    }

    /// Starts capture on a timeline that begins now (offset 0) with the system default input. Dictation uses this.
    public func start(source: AudioSource, applicationBundleID: String? = nil) async throws {
        try await start(source: source, applicationBundleID: applicationBundleID, timelineOffset: 0,
                        microphone: .systemDefault)
    }

    /// Starts capture. Frame times are `timelineOffset` plus the seconds since this call: the host-time origin is
    /// set to now − `timelineOffset`, so a restarted capture continues a meeting's session timeline
    /// (docs/meeting-design.md §2.3). System audio is captured mono. `microphone` is honoured from PR2b; until then
    /// the microphone is always the system default input.
    public func start(source: AudioSource, applicationBundleID: String?, timelineOffset: Double,
                      microphone: MicrophoneSelection) async throws {
        try Task.checkCancellation()
        guard !started else { throw HolosError.invalidInput("Capture is already running.") }
        guard timelineOffset.isFinite, timelineOffset >= 0 else {
            throw HolosError.invalidInput("The capture timeline offset must be a finite, non-negative number.")
        }
        if source != .system {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            try Task.checkCancellation()
            guard granted else {
                throw HolosError.permissionDenied("Microphone access is required. Enable it for Holos or your terminal in System Settings > Privacy & Security > Microphone.")
            }
        }
        if source == .microphone {
            let audioEngine = AVAudioEngine()
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite, format.sampleRate > 0,
                  format.sampleRate < Double(UInt32.max), format.channelCount > 0 else {
                throw HolosError.unavailable("No usable microphone input is available.")
            }
            let receiver = self.receiver
            let timeline = Mutex(MicrophoneTimeline(sampleRate: format.sampleRate))
            // The macOS 27 throwing tap supports 100–400 ms buffers.
            let bufferSize = AVAudioFrameCount(max(1, ceil(format.sampleRate * 0.1)))
            try input.installAudioTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, time in
                do {
                    guard time.isHostTimeValid, time.isSampleTimeValid else {
                        throw HolosError.incomplete("Microphone buffer has no host or sample timestamp.")
                    }
                    let hostSeconds = CMClockMakeHostTimeFromSystemUnits(time.hostTime).seconds
                    let timestamp = timeline.withLock { $0.startTime(hostSeconds: hostSeconds, sampleTime: time.sampleTime) }
                    receiver.emit(track: "mic", frame: try PCMConversion.copy(buffer,
                        startTime: max(0, timestamp - receiver.origin)))
                } catch { receiver.fail(error) }
            }
            hostTimeOrigin = CMClockGetTime(CMClockGetHostTimeClock()).seconds - timelineOffset
            receiver.setOrigin(hostTimeOrigin)
            do { try audioEngine.start() }
            catch { input.removeTap(onBus: 0); throw error }
            engine = audioEngine
        } else {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            try Task.checkCancellation()
            guard let display = content.displays.first else {
                throw HolosError.unavailable("System audio capture requires an active display in the logged-in session.")
            }
            let filter: SCContentFilter
            if let applicationBundleID {
                let apps = content.applications.filter { $0.bundleIdentifier == applicationBundleID }
                guard !apps.isEmpty else {
                    throw HolosError.unavailable("No running application matches \(applicationBundleID).")
                }
                filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
            } else {
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
            let config = SCStreamConfiguration()
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 3
            config.capturesAudio = true
            config.sampleRate = 48_000
            // Mono system audio: half the disk of stereo, and diarization mixes to mono anyway (§4.5).
            config.channelCount = 1
            config.excludesCurrentProcessAudio = true
            config.captureMicrophone = source == .microphoneAndSystem
            let captureStream = SCStream(filter: filter, configuration: config, delegate: receiver)
            let queue = DispatchQueue(label: "ca.orlenko.holos.capture", qos: .userInitiated)
            try captureStream.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: queue)
            if config.captureMicrophone {
                try captureStream.addStreamOutput(receiver, type: .microphone, sampleHandlerQueue: queue)
            }
            hostTimeOrigin = CMClockGetTime(CMClockGetHostTimeClock()).seconds - timelineOffset
            receiver.setOrigin(hostTimeOrigin)
            try await captureStream.startCapture()
            stream = captureStream
        }
        started = true
    }

    public func stop() async throws {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        defer { stream = nil; started = false; receiver.finish() }
        if let stream { try await stream.stopCapture() }
    }
}

private final class CaptureReceiver: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    private let originValue: Mutex<Double>
    var origin: Double { originValue.withLock { $0 } }
    let continuation: AsyncThrowingStream<CapturedAudio, Error>.Continuation
    private let ended = Mutex(false)
    private let overflow: CaptureOverflow
    private struct Drops {
        /// Buffers dropped because the stream was full, per track.
        var counts: [String: Int] = [:]
        /// Tracks whose next delivered frame follows a drop.
        var pending: Set<String> = []
    }
    private let drops = Mutex(Drops())

    init(origin: Double, continuation: AsyncThrowingStream<CapturedAudio, Error>.Continuation,
         overflow: CaptureOverflow) {
        self.originValue = Mutex(origin); self.continuation = continuation; self.overflow = overflow
    }

    func setOrigin(_ value: Double) { originValue.withLock { $0 = value } }

    /// Dropped buffers of `track`, or of every track when nil.
    func droppedBuffers(track: String?) -> Int {
        drops.withLock { drops in track.map { drops.counts[$0] ?? 0 } ?? drops.counts.values.reduce(0, +) }
    }

    /// On a full queue, `.fail` ends the stream; `.dropAndCount` drops and counts the buffer, and the next frame of the
    /// track that is delivered carries `followsDrop`, so the consumer marks the gap right before it
    /// (docs/meeting-design.md §4.3). Callbacks of one track arrive in order, never concurrently.
    func emit(track: String, frame: PCMFrame) {
        guard !ended.withLock({ $0 }) else { return }
        let followsDrop = drops.withLock { $0.pending.contains(track) }
        switch continuation.yield(CapturedAudio(track: track, frame: frame, followsDrop: followsDrop)) {
        case .dropped:
            switch overflow {
            case .fail:
                fail(HolosError.incomplete("The audio recording queue overflowed. Capture stopped to avoid an unreported gap."))
            case .dropAndCount:
                drops.withLock { drops in
                    drops.counts[track, default: 0] += 1
                    drops.pending.insert(track)
                }
            }
        case .enqueued:
            if followsDrop { drops.withLock { _ = $0.pending.remove(track) } }
        case .terminated:
            break
        @unknown default:
            break
        }
    }

    func fail(_ error: Error) {
        let first = ended.withLock { value in
            if value { return false }; value = true; return true
        }
        if first { continuation.finish(throwing: error) }
    }

    func finish() {
        ended.withLock { $0 = true }
        continuation.finish()
    }

    /// Only `SCStreamError.Code.userStopped` means the user stopped sharing; every other stop is a failure, so
    /// ScreenCaptureKit stopping by itself (for example under screen lock) is retried (§4.2).
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let code = error as NSError
        if code.domain == SCStreamErrorDomain, code.code == SCStreamError.Code.userStopped.rawValue {
            fail(CaptureInterruption.userStoppedSharing)
        } else {
            fail(error)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone else { return }
        do {
            guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else {
                throw HolosError.incomplete("Capture returned an invalid or unready audio buffer.")
            }
            guard let clock = stream.synchronizationClock else {
                throw HolosError.incomplete("ScreenCaptureKit supplied no synchronization clock.")
            }
            let timestamp = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: clock,
                                               to: CMClockGetHostTimeClock()).seconds
            guard timestamp.isFinite else { throw HolosError.incomplete("Capture returned an invalid audio timestamp.") }
            emit(track: type == .microphone ? "mic" : "system",
                 frame: try PCMConversion.copy(sampleBuffer, startTime: max(0, timestamp - origin)))
        } catch { fail(error) }
    }
}

/// Host timestamps on consecutive tap buffers jitter by several microseconds, so adjacent buffers can
/// appear to overlap. Anchor on the first buffer's host time and advance by sample count instead.
struct MicrophoneTimeline: Sendable {
    let sampleRate: Double
    private var anchor: (hostSeconds: Double, sampleTime: Int64)?

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    mutating func startTime(hostSeconds: Double, sampleTime: Int64) -> Double {
        guard let anchor else {
            self.anchor = (hostSeconds, sampleTime)
            return hostSeconds
        }
        return anchor.hostSeconds + Double(sampleTime - anchor.sampleTime) / sampleRate
    }
}

public enum PCMConversion {
    public static func copy(_ buffer: AVReadOnlyAudioPCMBuffer, startTime: Double) throws -> PCMFrame {
        // Isolate the immutable callback buffer before using the mutable PCM view.
        // Only the owned sample array leaves this function.
        try copy(AVAudioPCMBuffer(copying: buffer), startTime: startTime)
    }

    public static func copy(_ buffer: AVAudioPCMBuffer, startTime: Double) throws -> PCMFrame {
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var samples = [Float](repeating: 0, count: frameCount * channels)
        if let data = buffer.floatChannelData {
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    samples[frame * channels + channel] = buffer.format.isInterleaved
                        ? data[0][frame * channels + channel] : data[channel][frame]
                }
            }
        } else if let data = buffer.int16ChannelData {
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    let value = buffer.format.isInterleaved ? data[0][frame * channels + channel] : data[channel][frame]
                    samples[frame * channels + channel] = Float(value) / 32768
                }
            }
        } else if let data = buffer.int32ChannelData {
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    let value = buffer.format.isInterleaved ? data[0][frame * channels + channel] : data[channel][frame]
                    samples[frame * channels + channel] = Float(value) / 2_147_483_648
                }
            }
        } else { throw HolosError.unavailable("Unsupported microphone PCM format: \(buffer.format).") }
        return try PCMFrame(samples: samples, sampleRate: buffer.format.sampleRate, channels: channels, startTime: startTime)
    }

    public static func makeBuffer(_ frame: PCMFrame) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: frame.sampleRate, channels: AVAudioChannelCount(frame.channels)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.frameCount)),
              let channels = buffer.floatChannelData else {
            throw HolosError.invalidInput("Could not allocate PCM audio buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(frame.frameCount)
        for index in 0..<frame.frameCount {
            for channel in 0..<frame.channels { channels[channel][index] = frame.samples[index * frame.channels + channel] }
        }
        return buffer
    }

    static func copy(_ sample: CMSampleBuffer, startTime: Double) throws -> PCMFrame {
        guard let description = sample.formatDescription else {
            throw HolosError.invalidInput("System capture returned no audio format.")
        }
        guard let format = AVAudioFormat(formatDescription: description) else {
            throw HolosError.invalidInput("System capture returned an unsupported audio format.")
        }
        var size = 0
        let sizing = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &size,
            bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, blockBufferOut: nil)
        guard sizing == noErr, size > 0 else { throw HolosError.io("Cannot inspect captured audio buffers (\(sizing)).") }
        let allocation = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { allocation.deallocate() }
        let list = allocation.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlock: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: size, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, blockBufferOut: &retainedBlock)
        guard status == noErr, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else {
            throw HolosError.io("Cannot read captured audio buffers (\(status)).")
        }
        return try withExtendedLifetime(retainedBlock) { try copy(buffer, startTime: startTime) }
    }
}
