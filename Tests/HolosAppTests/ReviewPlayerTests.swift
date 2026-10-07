import AVFoundation
import Foundation
import HolosMeeting
import HolosSpeakers
import Testing
@testable import HolosApp

/// The review player's audio mix (docs/meeting-design.md §5.10): the microphone's echo-free volume is on the player
/// item when the playback has one, and nothing otherwise. A composition of empty tracks; nothing is played, and no
/// audio goes out.
@MainActor
struct ReviewPlayerTests {
    /// A composition with a microphone track and a system track, both empty.
    static func playback(micVolume: ReviewMicVolume?) throws -> (SessionAudioComposition.Playback,
                                                                CMPersistentTrackID) {
        let composition = AVMutableComposition()
        let mic = try #require(composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid))
        _ = try #require(composition.addMutableTrack(withMediaType: .audio,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid))
        return (SessionAudioComposition.Playback(composition: composition, micTrackID: mic.trackID,
                                                 micVolume: micVolume), mic.trackID)
    }

    nonisolated static let volume = ReviewMicVolume.keeping([AcousticEchoMask.Interval(start: 2, end: 3)], duration: 60)

    @Test func theItemMixesTheMicrophoneWhenThereIsEcho() throws {
        let player = ReviewPlayer()
        defer { player.invalidate() }
        let (playback, mic) = try Self.playback(micVolume: Self.volume)
        player.install(playback)
        let mix = try #require(player.audioMix)
        #expect(mix.inputParameters.map(\.trackID) == [mic])
        #expect(player.micVolume == Self.volume)
        #expect(!player.isPlaying)
    }

    @Test func theItemHasNoMixWithoutEcho() throws {
        let player = ReviewPlayer()
        defer { player.invalidate() }
        player.install(try Self.playback(micVolume: nil).0)
        #expect(player.audioMix == nil)
    }

    @Test func aChangedAnalysisSwapsTheMixOnTheSameItem() throws {
        let player = ReviewPlayer()
        defer { player.invalidate() }
        let (playback, mic) = try Self.playback(micVolume: nil)
        player.install(playback)
        player.setMicVolume(Self.volume)
        #expect(player.audioMix?.inputParameters.map(\.trackID) == [mic])
        // The same volume again: the mix is left as it is.
        let mix = player.audioMix
        player.setMicVolume(Self.volume)
        #expect(player.audioMix === mix)
        // The analysis gone: as recorded again.
        player.setMicVolume(nil)
        #expect(player.audioMix == nil)
    }

    @Test func anOlderRefreshFinishingLastChangesNothing() async throws {
        let player = ReviewPlayer()
        defer { player.invalidate() }
        player.install(try Self.playback(micVolume: nil).0)
        // Refresh A reads an echo mask, and is held; refresh B then reads none (the mask removed) and finishes.
        let (gate, release) = AsyncStream<Void>.makeStream()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let older = Task { @MainActor in
            await player.refreshMicVolume {
                didStart.yield()
                for await _ in gate {}
                return Self.volume
            }
        }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        await player.refreshMicVolume { nil }
        #expect(player.audioMix == nil)
        // A finishes last: its result is dropped.
        release.finish()
        await older.value
        #expect(player.audioMix == nil)
        #expect(player.micVolume == nil)
        // A refresh is dropped too when the playback was rebuilt while it read.
        let (gate2, release2) = AsyncStream<Void>.makeStream()
        let stale = Task { @MainActor in
            await player.refreshMicVolume {
                didStart.yield()
                for await _ in gate2 {}
                return Self.volume
            }
        }
        _ = await starts.next()
        player.install(try Self.playback(micVolume: nil).0)
        release2.finish()
        await stale.value
        #expect(player.audioMix == nil)
        // A refresh alone applies.
        await player.refreshMicVolume { Self.volume }
        #expect(player.micVolume == Self.volume)
    }
}
