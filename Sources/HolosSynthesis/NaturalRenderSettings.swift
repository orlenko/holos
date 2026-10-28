import Foundation

/// What a natural rendering depends on besides its voice, text, and speed: the system voice a failed paragraph is
/// read with, whether paragraphs are checked, and whether the text is first rewritten as it is said (`SpokenForm`). A
/// reading keeps them in its manifest when it starts (`ReadingManifest.rendererSettings`) and gives them back for every
/// part (`render(…settings:)`; the app's parts pass them as `say --fallback-voice`, `--check`, `--spoken-form`), so a
/// resumed reading does not mix fallback voices, check policies, or spoken forms.
public struct NaturalRenderSettings: Codable, Sendable, Equatable {
    public var fallbackVoice: String?
    public var checked: Bool
    /// A reading saved before spoken forms existed has none, so it is resumed without them.
    public var spokenForm: Bool

    public init(fallbackVoice: String?, checked: Bool, spokenForm: Bool = false) {
        self.fallbackVoice = fallbackVoice
        self.checked = checked
        self.spokenForm = spokenForm
    }

    /// As strings, to keep with a caller's own data. `spokenForm` is written only when on, so the values of a reading
    /// saved before it existed read back unchanged.
    public var values: [String: String] {
        var values = ["check": checked ? "on" : "off"]
        if let fallbackVoice { values["fallbackVoice"] = fallbackVoice }
        if spokenForm { values["spokenForm"] = "on" }
        return values
    }

    public init(values: [String: String]) {
        self.init(fallbackVoice: values["fallbackVoice"], checked: values["check"] != "off",
                  spokenForm: values["spokenForm"] == "on")
    }
}
