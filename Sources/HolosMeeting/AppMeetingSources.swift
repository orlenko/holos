import Foundation
import HolosAudio
import HolosCore

// The one kind of meeting the app records (docs/status.md "Meeting recording"): the system default input and the
// computer's audio, both tracks split into speakers, and the echo filter on (meeting.json `call` with
// `othersInRoom`). The Advanced setting in Setup turns the computer's audio off; without the System audio
// permission the meeting records the microphone alone instead of asking. Either way the microphone track is split
// into speakers (meeting.json `inPerson`). "Me" then comes from the user's remembered voice, or from naming speakers
// in review.

extension MeetingStartSettings {
    /// The menu line of a meeting that records the microphone alone because the System audio permission is missing.
    public static let systemAudioNotAllowedNotice =
        "Recording the microphone only — allow System audio in Setup to include the computer's sound."

    /// The settings of a meeting started from the app. `recordSystemAudio` is the Advanced setting;
    /// `systemAudioAllowed` is `CGPreflightScreenCaptureAccess()` when the meeting starts (never a prompt).
    public static func app(name: String, recordSystemAudio: Bool, systemAudioAllowed: Bool,
                           expectedSpeakers: Int? = nil) -> MeetingStartSettings {
        let both = recordSystemAudio && systemAudioAllowed
        var settings = MeetingStartSettings(name: name, source: both ? .microphoneAndSystem : .microphone,
                                            othersInRoom: both, expectedSpeakers: expectedSpeakers)
        settings.microphone = .systemDefault
        return settings
    }

    /// The start panel's "Records" line: what a meeting started now records.
    public static func sourcesDescription(recordSystemAudio: Bool, systemAudioAllowed: Bool) -> String {
        if !recordSystemAudio { return "Microphone only — the computer's audio is off in Setup › Advanced." }
        return systemAudioAllowed ? "Microphone and the computer's audio" : systemAudioNotAllowedNotice
    }

    /// The menu line for a meeting from the app that records less than the setting asks for: the computer's audio is
    /// on, but the meeting records the microphone alone (the permission was missing at start). Nil otherwise.
    public static func sourceNotice(_ settings: MeetingStartSettings, recordSystemAudio: Bool) -> String? {
        recordSystemAudio && settings.source == .microphone ? systemAudioNotAllowedNotice : nil
    }
}

/// The source notice of the meeting the app last started (`MeetingStartSettings.sourceNotice`), kept in UserDefaults so
/// an app that relaunches while its recorder goes on (a crash, a quit mid-meeting) shows it again once it follows that
/// meeting. It names its session: a meeting started elsewhere (the CLI) or later never shows it.
public struct MeetingSourceNotice: Codable, Sendable, Equatable {
    public static let defaultsKey = "meeting.sourceNotice"

    public var sessionID: String
    public var text: String

    public init(sessionID: String, text: String) {
        self.sessionID = sessionID
        self.text = text
    }

    /// The notice of a meeting just started from the app, or nil when it records what the setting asks for.
    public static func started(_ settings: MeetingStartSettings, sessionID: String?,
                               recordSystemAudio: Bool) -> MeetingSourceNotice? {
        guard let sessionID,
              let text = MeetingStartSettings.sourceNotice(settings, recordSystemAudio: recordSystemAudio) else {
            return nil
        }
        return MeetingSourceNotice(sessionID: sessionID, text: text)
    }

    /// The menu line for the followed meeting, nil when the notice belongs to another one.
    public func text(for followedSessionID: String?) -> String? {
        followedSessionID == sessionID ? text : nil
    }

    public static func load(from defaults: UserDefaults) -> MeetingSourceNotice? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(MeetingSourceNotice.self, from: $0) }
    }

    /// Saves the notice, or removes the saved one for nil (a meeting started without one replaces it).
    public static func save(_ notice: MeetingSourceNotice?, to defaults: UserDefaults) {
        if let notice, let data = try? JSONEncoder().encode(notice) {
            defaults.set(data, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }
}

extension MicrophoneSelection {
    /// The value of `voiceislocal record start --microphone`.
    public var argument: String {
        switch self {
        case .systemDefault: "default"
        case .builtIn: "built-in"
        }
    }

    public init?(argument: String) {
        switch argument {
        case "default": self = .systemDefault
        case "built-in": self = .builtIn
        default: return nil
        }
    }
}
