import AVFoundation
import Foundation
import HolosCore

/// What `ReadingPlayer` plays through: an `AVAudioPlayer` for a finished reading, a `PartQueuePlayback` for one being
/// made (tests use a stand-in).
public protocol ReadingPlayback: AnyObject {
    /// Engaged: playing, or waiting for audio that is not made yet (`isWaiting`).
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    /// The length so far: it grows while the reading is made, until `isDurationFinal`.
    var duration: TimeInterval { get }
    var isWaiting: Bool { get }
    var isDurationFinal: Bool { get }
    /// False when playback could not start.
    func play() -> Bool
    func pause()
    func stop()
    func seek(to time: TimeInterval)
}

extension ReadingPlayback {
    public var isWaiting: Bool { false }
    public var isDurationFinal: Bool { true }
}

extension AVAudioPlayer: ReadingPlayback {
    public func seek(to time: TimeInterval) { currentTime = time }
}

/// A playback opened off the main actor, handed to it (an `AVAudioPlayer` is used from one thread at a time: made on
/// one, then only on the main actor).
public final class OpenedPlayback: @unchecked Sendable {
    let playback: any ReadingPlayback

    public init(_ playback: any ReadingPlayback) { self.playback = playback }
}

/// Plays one reading at a time in the Reading section (▶ Play, Space), with its position: a finished one from its
/// file, one being made from its parts as they are made (`PartQueuePlayback`), handed over to its file once it is
/// finished. A failure while it plays (the file cannot be decoded, for one cut short while open; making it failed) or
/// when it continues is reported (`onError`), never taken for the end of the reading.
@MainActor
public final class ReadingPlayer: NSObject, AVAudioPlayerDelegate {
    /// Opens the file for playing; runs off the main actor (the player reads the file's start, which on a share whose
    /// server stopped answering waits for its timeout).
    public typealias Open = @Sendable (FileHandle) throws -> OpenedPlayback

    /// The reading loaded in the player (playing or paused).
    public private(set) var entryID: UUID?
    private var player: (any ReadingPlayback)?
    private var ticker: Task<Void, Never>?
    /// Counts the plays asked for, so one whose file opened after another was asked for (or a stop) is dropped.
    private var request = 0
    private let open: Open
    /// Where a reading being made plays.
    private let makeOutput: @MainActor () -> any ReadingSegmentOutput
    /// The state or the position changed.
    public var onChange: (() -> Void)?
    /// Playback stopped on an error: what to tell (a sentence).
    public var onError: ((String) -> Void)?
    /// The reading played to its end (never called for a stop, a pause, or another reading played over it).
    public var onEnded: ((UUID) -> Void)?

    public init(open: @escaping Open = ReadingPlayer.openAudio,
                makeOutput: @escaping @MainActor () -> any ReadingSegmentOutput = { EngineSegmentOutput() }) {
        self.open = open
        self.makeOutput = makeOutput
    }

    /// An `AVAudioPlayer` on `file`, a descriptor open on the very file checked: the player reads that object through
    /// `/dev/fd`, never the path, so a file put at the path meanwhile is not the one played. It opens its own
    /// descriptor on that object: `file` can be closed after.
    public static let openAudio: Open = { file in
        let url = URL(fileURLWithPath: "/dev/fd/\(file.fileDescriptor)")
        let player = try AVAudioPlayer(contentsOf: url, fileTypeHint: AVFileType.m4a.rawValue)
        player.prepareToPlay()
        return OpenedPlayback(player)
    }

    public var isPlaying: Bool { player?.isPlaying ?? false }

    /// Where the loaded reading is, and how long it is (so far, while it is made: `isFinal` false).
    public var position: (current: Double, duration: Double, isFinal: Bool)? {
        guard let player else { return nil }
        return (player.currentTime, player.duration, player.isDurationFinal)
    }

    /// The loaded reading waits for a part that is not made yet.
    public var isWaiting: Bool { player?.isWaiting ?? false }

    /// Pauses or continues reading `id` when it is the one loaded; false when it is not. One that cannot continue is
    /// stopped, and the reason reported.
    public func toggleLoaded(_ id: UUID) -> Bool {
        guard entryID == id, let player else { return false }
        // A reading asked for before and not open yet is not played over this.
        request += 1
        if player.isPlaying {
            player.pause()
        } else if !player.play() {
            fail("The audio could not continue playing.")
            return true
        }
        tick()
        onChange?()
        return true
    }

    /// Plays reading `id` from the file `file` gives (the reading's file opened and checked; see `openAudio`), the
    /// player opened off the main actor. The request counts from now: when another reading is asked for, or playing
    /// is stopped, before this one is open, it is dropped (true: nothing to tell). False when `file` gives none;
    /// throws when it cannot start.
    @discardableResult
    public func play(_ id: UUID, file: () async -> FileHandle?) async throws -> Bool {
        if toggleLoaded(id) { return true }
        request += 1
        let asked = request
        guard let handle = await file() else { return asked != request }
        guard asked == request else { return true }
        let open = self.open
        let opened: OpenedPlayback
        do {
            opened = try await Task.detached(priority: .userInitiated) { try open(handle) }.value
        } catch {
            // Superseded meanwhile: nothing to tell about a reading no longer asked for.
            guard asked == request else { return true }
            throw error
        }
        // Another reading was asked for meanwhile, or playing was stopped: this one is not played.
        guard asked == request else {
            opened.playback.stop()
            return true
        }
        unload()
        let player = opened.playback
        (player as? AVAudioPlayer)?.delegate = self
        guard player.play() else { throw HolosError.unavailable("The audio could not start playing.") }
        self.player = player
        entryID = id
        tick()
        onChange?()
        return true
    }

    /// Plays reading `id` while it is being made, from its parts in `feed` (at least its first made). Once making has
    /// finished, the rest plays from the file `finishedFile` gives, from the same place. Throws when it cannot start.
    public func play(_ id: UUID, feed: ReadingPartFeed, finishedFile: @escaping () async -> FileHandle?) throws {
        if toggleLoaded(id) { return }
        // A finished reading asked for before and not open yet is not played over this.
        request += 1
        unload()
        let parts = PartQueuePlayback(feed: feed, output: makeOutput())
        let loaded = ObjectIdentifier(parts)
        parts.onEnd = { [weak self] end in self?.partsEnded(loaded, end) }
        parts.onHandoff = { [weak self] place, playing in
            self?.handOff(loaded, id: id, at: place, playing: playing, file: finishedFile)
        }
        parts.onChange = { [weak self] in
            self?.tick()
            self?.onChange?()
        }
        guard parts.play() else { throw HolosError.unavailable("The audio could not start playing.") }
        player = parts
        entryID = id
        tick()
        onChange?()
    }

    private func partsEnded(_ loaded: ObjectIdentifier, _ end: PartQueuePlayback.End) {
        switch end {
        case .finished: ended(loaded, failure: nil)
        case .failed(let reason): ended(loaded, failure: reason)
        case .stopped:
            guard let player, ObjectIdentifier(player) == loaded else { return }
            unload()
        }
    }

    /// Making finished while its parts played: the rest plays from the finished file (`file`), from `place`, playing or
    /// paused as the parts were. Dropped when another reading was loaded meanwhile.
    private func handOff(_ loaded: ObjectIdentifier, id: UUID, at place: TimeInterval, playing wasPlaying: Bool,
                         file: @escaping () async -> FileHandle?) {
        guard let current = player, ObjectIdentifier(current) == loaded else { return }
        let open = self.open
        Task { [weak self] in
            let opened: OpenedPlayback?
            if let handle = await file() {
                opened = try? await Task.detached(priority: .userInitiated) { try open(handle) }.value
            } else {
                opened = nil
            }
            guard let self, let current = self.player, ObjectIdentifier(current) == loaded, self.entryID == id else {
                opened?.playback.stop()
                return
            }
            guard let opened else { return self.fail("The finished audio file could not be opened.") }
            let playback = opened.playback
            (playback as? AVAudioPlayer)?.delegate = self
            playback.seek(to: place)
            self.player = playback
            if wasPlaying, !playback.play() { return self.fail("The audio could not continue playing.") }
            self.tick()
            self.onChange?()
        }
    }

    /// Pauses the loaded reading (a voice preview is about to speak).
    public func pause() {
        // A reading asked for and not open yet is not played either.
        request += 1
        guard let player, player.isPlaying else { return }
        player.pause()
        ticker?.cancel()
        onChange?()
    }

    /// Stops the loaded reading, and a reading asked for and not open yet is not played either.
    public func stop() {
        request += 1
        unload()
    }

    /// The loaded reading stops and is unloaded; one asked for since and not open yet is left to start (the loaded one
    /// ended, left the list, or is being replaced).
    public func unload() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        guard entryID != nil else { return }
        entryID = nil
        onChange?()
    }

    /// Updates the position twice a second while playing.
    private func tick() {
        ticker?.cancel()
        guard isPlaying else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, self.isPlaying else { return }
                self.onChange?()
            }
        }
    }

    private func fail(_ message: String) {
        unload()
        onError?(message)
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let ended = ObjectIdentifier(player)
        Task { @MainActor in
            self.ended(ended, failure: flag ? nil : "The audio stopped before its end: it could not be decoded.")
        }
    }

    nonisolated public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let ended = ObjectIdentifier(player)
        let reason = error.map { ": \($0.localizedDescription)" } ?? "."
        Task { @MainActor in self.ended(ended, failure: "The audio could not be decoded" + reason) }
    }

    /// A player finished (`failure` nil) or failed: unloaded only when it is still the one loaded (a callback from one
    /// replaced since arrives late and leaves the new reading alone); a failure is reported. A reading asked for
    /// meanwhile still starts once open.
    func ended(_ ended: ObjectIdentifier, failure: String?) {
        guard let player, ObjectIdentifier(player) == ended, let id = entryID else { return }
        if let failure { return fail(failure) }
        unload()
        onEnded?(id)
    }

    /// The playback loaded, for tests.
    var loaded: (any ReadingPlayback)? { player }
}
