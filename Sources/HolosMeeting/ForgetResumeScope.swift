import Foundation

/// Which `voiceislocal` commands first finish a forget of voices that a crash left pending and sweep leftover voice
/// renders (docs/meeting/people-voice.md §4.10; the CLI's `ForgetResume`). That work deletes files and can rewrite people,
/// speaker data and transcript files, so a command that promises to only read is left out of it.
public enum ForgetResumeScope {
    /// The command groups that read or write people and speaker data.
    public static let commands: Set<String> = ["people", "speakers", "session"]
    /// Subcommands of those groups that only read, and so change nothing first either: the group, then the
    /// subcommand's name.
    public static let readOnly: Set<[String]> = [["session", "echo-label-stats"]]

    /// Whether the command line `arguments` (without the program name) runs the forget resume first: its first word is
    /// one of `commands` and its first two words are not one of `readOnly`.
    public static func applies(to arguments: [String]) -> Bool {
        guard let command = arguments.first, commands.contains(command) else { return false }
        return !readOnly.contains(Array(arguments.prefix(2)))
    }
}
