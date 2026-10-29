import AVFoundation
import Foundation
import HolosCore

/// Where `PartQueuePlayback` plays a reading's parts: PCM buffers one after another (`EngineSegmentOutput`; tests use
/// a stand-in that plays nothing).
@MainActor
public protocol ReadingSegmentOutput: AnyObject {
    /// Queues `buffer` after those queued before; `played` is called once it has played to its end, never after
    /// `stop`. Every buffer has the format of the first.
    func schedule(_ buffer: AVAudioPCMBuffer, played: @escaping @MainActor () -> Void) throws
    /// Starts, or continues after `pause`.
    func play() throws
    func pause()
    /// Stops and drops what is queued, and lets the audio device go; `playedFrames` starts again from 0.
    func stop()
    /// The frames played since the last `stop` (or the start), at the buffers' rate; a pause keeps it.
    var playedFrames: Int64 { get }
    /// The output stopped by itself (the audio device changed); `play` starts it again.
    var onInterrupted: (() -> Void)? { get set }
}

/// Plays buffers through an `AVAudioPlayerNode` on an `AVAudioEngine`, connected with the first buffer's format. With
/// `manualRendering`, the engine renders offline into buffers a test pulls (`renderManually`), and nothing is heard.
@MainActor
public final class EngineSegmentOutput: ReadingSegmentOutput {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private let manualRendering: Bool
    /// Counts the stops, so a buffer's callback that arrives after one is dropped.
    private var generation = 0
    /// The frames played as last seen while playing: a paused node has no player time.
    private var lastPlayed: Int64 = 0
    private var observer: (any NSObjectProtocol)?
    public var onInterrupted: (() -> Void)?

    public init(manualRendering: Bool = false) {
        self.manualRendering = manualRendering
        engine.attach(node)
    }

    public func schedule(_ buffer: AVAudioPCMBuffer, played: @escaping @MainActor () -> Void) throws {
        try connect(buffer.format)
        let scheduled = generation
        // Offline rendering has no playback to wait for: a buffer has played once it is rendered.
        let kind: AVAudioPlayerNodeCompletionCallbackType = manualRendering ? .dataRendered : .dataPlayedBack
        node.scheduleBuffer(buffer, completionCallbackType: kind) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == scheduled else { return }
                played()
            }
        }
    }

    /// The first buffer's format connects the node; another format afterwards is refused (the joined file refuses
    /// parts of different formats as well).
    private func connect(_ buffer: AVAudioFormat) throws {
        if let format {
            guard format == buffer else { throw HolosError.io("The reading's parts do not share one audio format.") }
            return
        }
        if manualRendering {
            try engine.enableManualRenderingMode(.offline, format: buffer, maximumFrameCount: 4_096)
        }
        engine.connect(node, to: engine.mainMixerNode, format: buffer)
        format = buffer
        guard !manualRendering else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.playedFrames
                self?.onInterrupted?()
            }
        }
    }

    public func play() throws {
        guard format != nil else { return }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        node.play()
    }

    public func pause() {
        // Where it pauses, not where the position was last read.
        _ = playedFrames
        node.pause()
    }

    public func stop() {
        generation += 1
        node.stop()
        // An idle engine left running keeps the audio device open; `play` starts it again.
        engine.stop()
        lastPlayed = 0
    }

    public var playedFrames: Int64 {
        if node.isPlaying, let time = node.lastRenderTime, let played = node.playerTime(forNodeTime: time) {
            lastPlayed = max(0, played.sampleTime)
        }
        return lastPlayed
    }

    /// The engine runs (and holds the audio device), for tests.
    var isEngineRunning: Bool { engine.isRunning }

    /// Renders `frames` offline (`manualRendering` only), for tests.
    func renderManually(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = engine.manualRenderingFormat
        guard manualRendering, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw HolosError.unavailable("Manual rendering is not on.")
        }
        while buffer.frameLength < frames {
            let rest = min(frames - buffer.frameLength, engine.manualRenderingMaximumFrameCount)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: rest) else { break }
            let status = try engine.renderOffline(rest, to: chunk)
            guard status == .success, chunk.frameLength > 0 else { break }
            for channel in 0..<Int(format.channelCount) {
                guard let target = buffer.floatChannelData?[channel],
                      let source = chunk.floatChannelData?[channel] else { continue }
                (target + Int(buffer.frameLength)).update(from: source, count: Int(chunk.frameLength))
            }
            buffer.frameLength += chunk.frameLength
        }
        return buffer
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
