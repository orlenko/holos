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

    static let volume = ReviewMicVolume.keeping([AcousticEchoMask.Interval(start: 2, end: 3)], duration: 60)

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
}
