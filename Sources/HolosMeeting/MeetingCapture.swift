import HolosAudio
import HolosCore
import Foundation

/// What one capture epoch records.
public struct CaptureRequest: Sendable, Equatable {
    public var source: AudioSource
    /// Bundle ID whose audio the system track captures (`--app`); nil captures all system audio.
    public var applicationBundleID: String?
    /// Session time of this epoch's first frame (docs/meeting/session-format.md §2.3): 0 for epoch 0, then
    /// max(clock.now(), lastFrameEnd + 0.01).
    public var timelineOffset: Double
    /// Which input device the microphone track records (§4.12). A `source` of `.system` records no microphone: a call
    /// epoch started while the Mac has no input device.
    public var microphone: MicrophoneSelection
    /// Host-clock seconds (`AudioCapture.hostSeconds()`) at which `timelineOffset` was taken from the session clock.
    /// The capture anchors its origin there (`AudioCapture.timelineOrigin`), so the time it spends setting up is
    /// part of the session timeline and of the gap before its first frame. Nil for epoch 0: the timeline starts when
    /// its capture has started.
    public var offsetHostTime: Double?
    /// The optional screen capture (docs/meeting/screen-context.md §4.15), saved into `sessionDirectory`.
    public var screen: ScreenCaptureTarget?
    public var sessionDirectory: URL?
    /// Carry a known system outage into a new epoch; only an accepted system frame clears it.
    public var initialSystemUnavailable: Bool
    /// The recorder already closed the previous epoch for this reason (pause/sleep/restart).
    /// A first system frame must not replace that boundary with a generic startup-gap reason.
    public var boundaryReason: GapReason?

    public init(source: AudioSource, applicationBundleID: String? = nil, timelineOffset: Double = 0,
                microphone: MicrophoneSelection = .systemDefault, offsetHostTime: Double? = nil,
                screen: ScreenCaptureTarget? = nil, sessionDirectory: URL? = nil,
                initialSystemUnavailable: Bool = false, boundaryReason: GapReason? = nil) {
        self.source = source; self.applicationBundleID = applicationBundleID; self.timelineOffset = timelineOffset
        self.microphone = microphone; self.offsetHostTime = offsetHostTime
        self.screen = screen; self.sessionDirectory = sessionDirectory
        self.initialSystemUnavailable = initialSystemUnavailable; self.boundaryReason = boundaryReason
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
    /// Tracks independently retrying while other tracks continue. Cleared only when that track delivers audio.
    var unavailableTracks: Set<String> { get }
    /// Sources whose unwritten tail must be saved at epoch end, including a healthy stream never heard yet.
    /// Separate from warnings: a silent initial stream is not necessarily an outage.
    var unavailableTailTracks: Set<String> { get }
    func start(_ request: CaptureRequest) async throws
    func stop() async throws
}

extension MeetingCapture {
    /// A capture that never drops buffers.
    public var droppedBuffers: Int { 0 }
    public var unavailableTracks: Set<String> { [] }
    public var unavailableTailTracks: Set<String> { unavailableTracks }
}

/// Wraps `AudioCapture`, passing the epoch's timeline offset and microphone selection through.
@MainActor public final class LiveMeetingCapture: MeetingCapture {
    private let capture: AudioCapture
    private var screen: MeetingScreenCapture?
    public nonisolated let frames: AsyncThrowingStream<CapturedAudio, Error>

    /// A full frame stream drops the buffer and counts it; capture continues (§4.3). A configuration change ends the
    /// stream with `CaptureInterruption.configurationChanged`, so the recorder restarts in a new epoch (§4.2).
    public init(bufferCapacity: Int = 4096) {
        capture = AudioCapture(bufferCapacity: bufferCapacity, overflow: .dropAndCount, reportsConfigurationChanges: true)
        frames = capture.frames
    }

    public var hostTimeOrigin: Double { capture.hostTimeOrigin }

    public var droppedBuffers: Int { capture.droppedBuffers }

    public func start(_ request: CaptureRequest) async throws {
        try await capture.start(source: request.source, applicationBundleID: request.applicationBundleID,
                                timelineOffset: request.timelineOffset, microphone: request.microphone,
                                timelineOffsetHostTime: request.offsetHostTime)
        if let target = request.screen, let session = request.sessionDirectory {
            let screen = MeetingScreenCapture()
            self.screen = screen
            screen.start(target, session: session, origin: capture.hostTimeOrigin)
        }
    }

    public func stop() async throws {
        // Audio stops first. Optional visual capture failures never turn a recording into an audio failure.
        do { try await capture.stop() }
        catch { await screen?.stop(); throw error }
        await screen?.stop()
    }
}
