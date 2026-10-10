import AppKit
import HolosMeeting
import HolosStorage
import os

extension HolosAppDelegate {
    /// People in the main window (docs/meeting/people-voice.md §5.9).
    @objc func showPeople() {
        showMainWindow(.people)
    }
}

/// Launch work for people and voices.
@MainActor
enum PeopleLaunch {
    private nonisolated static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "profiles")
    private static var resumed = false

    /// `VoiceProfileService.resumePendingForgets` once per launch, and the sweep of the voice renders an
    /// interrupted enrollment left in the temporary directory. Called at launch and when People first opens.
    static func resumePendingForgetsOnce() {
        guard !resumed else { return }
        resumed = true
        Task.detached(priority: .utility) {
            DiarizerVoiceSampleExtractor.removeStaleRenders()
            do {
                try VoiceProfileService.resumePendingForgets(store: SpeakerProfileStore())
            } catch {
                log.error("A pending forget of voices is not finished yet: \(ProcessSpawner.logCategory(error), privacy: .public)")
            }
        }
    }
}
