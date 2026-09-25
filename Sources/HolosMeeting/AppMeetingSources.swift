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
