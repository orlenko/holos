import HolosAudio
import HolosCore

/// What one capture epoch records.
public struct CaptureRequest: Sendable, Equatable {
    public var source: AudioSource
    /// Bundle ID whose audio the system track captures (`--app`); nil captures all system audio.
    public var applicationBundleID: String?
    /// Session time of this epoch's first frame (docs/meeting-design.md §2.3). PR1 always passes 0; PR2a uses it.
    public var timelineOffset: Double

    public init(source: AudioSource, applicationBundleID: String? = nil, timelineOffset: Double = 0) {
        self.source = source; self.applicationBundleID = applicationBundleID; self.timelineOffset = timelineOffset
    }
}

/// One capture epoch. `frames` is single-use: it finishes after `stop()` or throws on failure.
@MainActor public protocol MeetingCapture: AnyObject {
    nonisolated var frames: AsyncThrowingStream<CapturedAudio, Error> { get }
    var hostTimeOrigin: Double { get }
    func start(_ request: CaptureRequest) async throws
    func stop() async throws
}

/// Wraps `AudioCapture`. PR1 ignores `timelineOffset` (always 0); PR2a passes it through.
@MainActor public final class LiveMeetingCapture: MeetingCapture {
    private let capture: AudioCapture
    public nonisolated let frames: AsyncThrowingStream<CapturedAudio, Error>

    public init(bufferCapacity: Int = 4096) {
        capture = AudioCapture(bufferCapacity: bufferCapacity)
        frames = capture.frames
    }

    public var hostTimeOrigin: Double { capture.hostTimeOrigin }

    public func start(_ request: CaptureRequest) async throws {
        try await capture.start(source: request.source, applicationBundleID: request.applicationBundleID)
    }

    public func stop() async throws { try await capture.stop() }
}
