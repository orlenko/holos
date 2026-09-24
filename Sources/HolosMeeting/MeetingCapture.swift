import HolosAudio
import HolosCore

/// What one capture epoch records.
public struct CaptureRequest: Sendable, Equatable {
    public var source: AudioSource
    /// Bundle ID whose audio the system track captures (`--app`); nil captures all system audio.
    public var applicationBundleID: String?
    /// Session time of this epoch's first frame (docs/meeting-design.md §2.3): 0 for epoch 0, then
    /// max(clock.now(), lastFrameEnd + 0.01).
    public var timelineOffset: Double
    /// Which input device the microphone track records (§4.12; honoured from PR2b).
    public var microphone: MicrophoneSelection

    public init(source: AudioSource, applicationBundleID: String? = nil, timelineOffset: Double = 0,
                microphone: MicrophoneSelection = .systemDefault) {
        self.source = source; self.applicationBundleID = applicationBundleID; self.timelineOffset = timelineOffset
        self.microphone = microphone
    }
}

/// One capture epoch. `frames` is single-use: it finishes after `stop()` or throws on failure
/// (`CaptureInterruption` for a configuration change or a user who stopped sharing). The first frame delivered after
/// a dropped buffer has `CapturedAudio.followsDrop` set, so the consumer marks the gap where it happened (§4.3).
@MainActor public protocol MeetingCapture: AnyObject, Sendable {
    nonisolated var frames: AsyncThrowingStream<CapturedAudio, Error> { get }
    var hostTimeOrigin: Double { get }
    /// Buffers dropped because the frame stream was full; capture continues after a drop.
    var droppedBuffers: Int { get }
    func start(_ request: CaptureRequest) async throws
    func stop() async throws
}

extension MeetingCapture {
    /// A capture that never drops buffers.
    public var droppedBuffers: Int { 0 }
}

/// Wraps `AudioCapture`, passing the epoch's timeline offset and microphone selection through.
@MainActor public final class LiveMeetingCapture: MeetingCapture {
    private let capture: AudioCapture
    public nonisolated let frames: AsyncThrowingStream<CapturedAudio, Error>

    /// A full frame stream drops the buffer and counts it; capture continues (§4.3).
    public init(bufferCapacity: Int = 4096) {
        capture = AudioCapture(bufferCapacity: bufferCapacity, overflow: .dropAndCount)
        frames = capture.frames
    }

    public var hostTimeOrigin: Double { capture.hostTimeOrigin }

    public var droppedBuffers: Int { capture.droppedBuffers }

    public func start(_ request: CaptureRequest) async throws {
        try await capture.start(source: request.source, applicationBundleID: request.applicationBundleID,
                                timelineOffset: request.timelineOffset, microphone: request.microphone)
    }

    public func stop() async throws { try await capture.stop() }
}
