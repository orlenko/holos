import Foundation

/// What Settings says under a setting: one line that shows, and the rest behind a help button. Search looks in both, so
/// shortening a caption never makes a setting harder to find.
struct SettingsCaption: Equatable {
    var short: String
    var more: String

    var searchText: String { short + " " + more }

    static let openAtLaunch = SettingsCaption(
        short: "Closing the window keeps Voice is Local running in the menu bar.",
        more: "Quit in its menu, or ⌘Q, quits it. When this is off, the app starts in the menu bar only (Open Voice is "
            + "Local, ⌘0, opens the window), and Settings still opens while dictation is off.")
    static let updateChecks = SettingsCaption(
        short: "Asks voiceislocal.com about once a day, sending only the app's name and version.",
        more: "It downloads one small file that names the latest version. An update downloads only when you choose to "
            + "install it. Check for Updates… in the menu works either way.")
    static let permissions = SettingsCaption(
        short: "This updates on its own while you change System Settings.",
        more: "After rebuilding Voice is Local, macOS can keep an old entry that looks switched on but no longer matches "
            + "the app: select Voice is Local in that list, remove it with –, then click Allow… here to add it again. "
            + "An entry named Holos is this app from before it was renamed; remove it the same way. Allow… only asks "
            + "macOS (its prompt appears once); System Settings… only opens the page.")
    static let recordSystemAudio = SettingsCaption(
        short: "Off: meetings record the microphone only.",
        more: "On: meetings record your microphone and everything the Mac plays, and speakers are labelled on both.")
    static let screenCapture = SettingsCaption(
        short: "Stays on this Mac, and is deleted with the meeting audio. Needs screen recording.",
        more: MeetingScreenText.settingCaption)
    static let deepTranscription = SettingsCaption(
        short: "A larger model on this Mac, on AC power, one meeting at a time. English meetings only.",
        more: "After a meeting is saved, its audio is transcribed again, prompted with your word list and people's "
            + "names, and the result replaces the transcript (the one before is kept). On battery it waits for the "
            + "power adapter. Right-click a meeting for Make Final Transcript Now or Cancel. Meetings in other "
            + "languages, or in several, keep their transcript.")
    static let meetingSummaries = SettingsCaption(
        short: "Runs on this Mac; nothing leaves it. A name you give a meeting is never replaced.",
        more: "Once a meeting's transcript is final, Apple's on-device model writes a short title and a summary for the "
            + "Meetings list, with key points and action items in the transcript files. Right-click a meeting for "
            + "Summarize Again.")
}
