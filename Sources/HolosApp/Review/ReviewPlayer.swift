import AVFoundation
import Foundation
import HolosMeeting
import HolosStorage
import os

/// Plays a meeting's saved audio in the review window (docs/meeting-design.md §5.10): from a time (a turn's
/// timestamp), play/pause, and a speaker's sample clips one after the other. The audio is a
/// `SessionAudioComposition` of the chunk files, built off the main actor when the window opens; nothing is copied.
@MainActor
final class ReviewPlayer {
    enum State: Equatable {
        case loading
        case ready
        /// Why playback is off ("Audio deleted; playback is off.").
        case unavailable(String)
    }

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "review")
    static let audioDeletedText = "Audio deleted; playback is off."

    private(set) var state: State = .loading
    private(set) var isPlaying = false
    /// Session time of the play head.
    private(set) var currentTime: Double = 0
    /// Called on the main actor when the state, the play head, or playing changes.
    var onChange: (() -> Void)?

    private var player: AVPlayer?
    private var timeObserver: Any?
    /// Builds the composition; done (and empty) once it delivered, failed or not, so `load` can try again.
    private let loader = LatestLoad<AVMutableComposition>()
    /// Clips still to play after the current one, and where the current one stops.
    private var pendingClips: [ClosedRange<Double>] = []
    private var stopAt: Double?

    var isReady: Bool { state == .ready }

    /// Playing, ready, or building the audio (not stopped by `invalidate`, not off, not failed to build).
    var hasAudio: Bool { player != nil || loader.isLoading }

    /// Builds the composition for `manifest`'s chunks (none when the audio was deleted).
    func load(session: URL, manifest: SessionManifest, audioDeleted: Bool) {
        invalidate()
        guard !audioDeleted else {
            state = .unavailable(Self.audioDeletedText)
            onChange?()
            return
        }
        state = .loading
        onChange?()
        let make: @Sendable () async throws -> sending AVMutableComposition = {
            try await SessionAudioComposition.make(session: session, manifest: manifest)
        }
        loader.start(make) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let composition):
                self.install(composition)
            case .failure(let error):
                if error is CancellationError { return }
                Self.log.error("Playback unavailable: \(ProcessSpawner.logCategory(error), privacy: .public)")
                self.state = .unavailable("Playback is off: \(error.localizedDescription)")
                self.onChange?()
            }
        }
    }

    /// Plays from `seconds` (session time) until paused.
    func play(from seconds: Double) {
        guard let player, isReady else { return }
        pendingClips = []
        stopAt = nil
        start(player, at: seconds)
    }

    /// Plays each clip in turn, then stops.
    func play(clips: [ClosedRange<Double>]) {
        guard let player, isReady, let first = clips.first else { return }
        pendingClips = Array(clips.dropFirst())
        stopAt = first.upperBound
        start(player, at: first.lowerBound)
    }

    func togglePlayPause() {
        guard let player, isReady else { return }
        if isPlaying {
            pause()
        } else {
            stopAt = nil
            pendingClips = []
            player.play()
            isPlaying = true
            onChange?()
        }
    }

    func pause() {
        player?.pause()
        pendingClips = []
        stopAt = nil
        if isPlaying {
            isPlaying = false
            onChange?()
        }
    }

    /// Stops playback and lets go of the audio (the window closed, or the audio is about to be deleted); `load`
    /// makes it playable again.
    func invalidate() {
        loader.cancel()
        player?.pause()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player = nil
        pendingClips = []
        stopAt = nil
        seeking = false
        isPlaying = false
        if state == .ready { state = .loading }
    }

    // MARK: - Private

    private func install(_ composition: AVMutableComposition) {
        let player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        self.player = player
        state = .ready
        onChange?()
    }

    private func start(_ player: AVPlayer, at seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 1_000)
        // Until the seek lands, periodic times still come from before it; they must not end the new clip.
        seekGeneration += 1
        let generation = seekGeneration
        seeking = true
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.seeking = false
            }
        }
        player.play()
        currentTime = max(0, seconds)
        isPlaying = true
        onChange?()
    }

    private var seekGeneration = 0
    private var seeking = false

    private func tick(_ time: CMTime) {
        guard let player, !seeking else { return }
        let seconds = time.seconds
        if seconds.isFinite { currentTime = seconds }
        if let stopAt, seconds >= stopAt {
            if pendingClips.isEmpty {
                player.pause()
                self.stopAt = nil
            } else {
                let next = pendingClips.removeFirst()
                self.stopAt = next.upperBound
                start(player, at: next.lowerBound)
                return
            }
        }
        isPlaying = player.timeControlStatus != .paused
        onChange?()
    }
}
