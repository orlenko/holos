import AppKit
import HolosMeeting
import HolosStorage
import os

extension HolosAppDelegate {
    /// "People…" after "Meetings…" (docs/meeting-design.md §5.9). The first call, when the menu is built at launch,
    /// also finishes any forget of voices that a crash left pending (§4.10), off the main actor.
    func addPeopleItem(to menu: NSMenu) {
        PeopleLaunch.resumePendingForgetsOnce()
        menu.addItem(item("People…", #selector(showPeople)))
    }

    @objc func showPeople() {
        let window = PeopleWindowController.shared
        window.onVisibilityChange = { [weak self] visible in self?.setDockPresence(visible, for: "people") }
        window.show()
    }
}

/// Launch work for people and voices.
@MainActor
enum PeopleLaunch {
    private nonisolated static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "profiles")
    private static var resumed = false

    /// `VoiceProfileService.resumePendingForgets` once per launch.
    static func resumePendingForgetsOnce() {
        guard !resumed else { return }
        resumed = true
        Task.detached(priority: .utility) {
            do {
                try VoiceProfileService.resumePendingForgets(store: SpeakerProfileStore())
            } catch {
                log.error("A pending forget of voices is not finished yet: \(ProcessSpawner.logCategory(error), privacy: .public)")
            }
        }
    }
}
