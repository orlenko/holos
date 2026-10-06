import AVFoundation
import Foundation
import HolosMeeting
import HolosStorage
import os

/// Plays a meeting's saved audio in the review window (docs/meeting-design.md §5.10): from a time (a turn's
/// timestamp, a word), play/pause, seeking, a speed, and a speaker's sample clips one after the other. Playing from a
/// time goes on through the meeting until paused or the audio ends; only sample clips stop by themselves. The audio
/// is a `SessionAudioComposition` of the chunk files, built off the main actor when the window opens; nothing is
/// copied. When the meeting's echo analysis found echo, the microphone plays only where it has speech of its own
/// (`ReviewMicVolume`, an audio mix on the player item), so the call is not heard twice.
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
    /// Seconds of audio (the composition's length); 0 until it is ready.
    private(set) var duration: Double = 0
    /// Playback speed (1 = as recorded); pitch is kept.
    var rate: Double = 1 {
        didSet {
            guard let player else { return }
            player.defaultRate = Float(rate)
            if isPlaying, player.rate != 0 { player.rate = Float(rate) }
        }
    }
    /// Called on the main actor when the state, the play head, or playing changes.
    var onChange: (() -> Void)?

    private var player: AVPlayer?
    private var timeObserver: Any?
    /// Watches whether AVFoundation plays: it pauses by itself at the end of the audio (or when the output device
    /// goes away), sometimes after the last periodic time.
    private var statusObservation: NSKeyValueObservation?
    /// Builds the composition; done (and empty) once it delivered, failed or not, so `load` can try again.
    private let loader = LatestLoad<SessionAudioComposition.Playback>()
    /// The composition track of the microphone and the volume it plays at (nil: as recorded).
    private var micTrackID: CMPersistentTrackID?
    private(set) var micVolume: ReviewMicVolume?
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
        let make: @Sendable () async throws -> sending SessionAudioComposition.Playback = {
            try await SessionAudioComposition.makePlayback(session: session, manifest: manifest)
        }
        loader.start(make) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let playback):
                self.install(playback)
            case .failure(let error):
                if error is CancellationError { return }
                Self.log.error("Playback unavailable: \(ProcessSpawner.logCategory(error), privacy: .public)")
                self.state = .unavailable("Playback is off: \(error.localizedDescription)")
                self.onChange?()
            }
        }
    }

    /// Plays from `seconds` (session time) on through the meeting until paused.
    func play(from seconds: Double) {
        guard let player, isReady else { return }
        pendingClips = []
        stopAt = nil
        start(player, at: seconds)
    }

    /// Moves the play head to `seconds` (clamped to the audio), playing on from there when playing and staying
    /// paused otherwise. A sample clip being played ends: playback then goes on through the meeting.
    func seek(to seconds: Double) {
        guard let player, isReady else { return }
        pendingClips = []
        stopAt = nil
        let target = clamped(seconds)
        if isPlaying {
            start(player, at: target)
        } else {
            move(player, to: target)
            currentTime = target
            onChange?()
        }
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
            // At the end of the audio, Play starts the meeting over.
            if duration > 0, currentTime >= duration - 0.05 {
                start(player, at: 0)
                return
            }
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
        statusObservation?.invalidate()
        statusObservation = nil
        player = nil
        pendingClips = []
        stopAt = nil
        seeking = false
        isPlaying = false
        duration = 0
        micTrackID = nil
        micVolume = nil
        if state == .ready { state = .loading }
    }

    /// The mix on the player item now (nil: every track as recorded).
    var audioMix: AVAudioMix? { player?.currentItem?.audioMix }

    /// Plays the microphone at `volume` from now on (nil: as recorded), on the current item without rebuilding it,
    /// so playing goes on where it is: the echo analysis changed while the window was open.
    func setMicVolume(_ volume: ReviewMicVolume?) {
        guard volume != micVolume, let item = player?.currentItem, let micTrackID else { return }
        micVolume = volume
        item.audioMix = volume?.audioMix(track: micTrackID)
    }

    // MARK: - Private

    /// Makes the player for a built playback (internal for tests, which install one without building it).
    func install(_ playback: SessionAudioComposition.Playback) {
        let composition = playback.composition
        let item = AVPlayerItem(asset: composition)
        // Faster speeds keep the voices' pitch.
        item.audioTimePitchAlgorithm = .spectral
        micTrackID = playback.micTrackID
        micVolume = playback.micVolume
        item.audioMix = playback.audioMix
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.defaultRate = Float(rate)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        statusObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.statusChanged() }
        }
        self.player = player
        let seconds = composition.duration.seconds
        duration = seconds.isFinite ? max(0, seconds) : 0
        // A new player starts at the beginning.
        currentTime = 0
        state = .ready
        onChange?()
    }

    private func start(_ player: AVPlayer, at seconds: Double) {
        let target = clamped(seconds)
        move(player, to: target)
        // `play` uses `defaultRate`, the chosen speed.
        player.play()
        currentTime = target
        isPlaying = true
        onChange?()
    }

    /// Seeks exactly to `seconds`. Until the seek lands, periodic times still come from before it; they must neither
    /// move the play head back nor end the new clip.
    private func move(_ player: AVPlayer, to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 1_000)
        seekGeneration += 1
        let generation = seekGeneration
        seeking = true
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.seeking = false
            }
        }
    }

    /// `seconds` within the audio (0 when it is not a number).
    private func clamped(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        let upper = duration > 0 ? duration : .greatestFiniteMagnitude
        return min(max(0, seconds), upper)
    }

    private var seekGeneration = 0
    private var seeking = false

    /// AVFoundation started or stopped playing: `isPlaying` follows what it does now (read when this runs, so a
    /// change reported before a newer `play` is never taken for the current one), and the play head where it stopped.
    private func statusChanged() {
        guard let player else { return }
        let playing = player.timeControlStatus != .paused
        guard playing != isPlaying else { return }
        isPlaying = playing
        if !playing, !seeking {
            let seconds = player.currentTime().seconds
            if seconds.isFinite { currentTime = seconds }
        }
        onChange?()
    }

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
