import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting
import HolosStorage

@main
struct Holos: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voiceislocal", abstract: "Voice is Local: local speech tools for macOS.", version: "0.1.0-dev",
        subcommands: [
            Doctor.self,
            Setup.self,
            Transcribe.self,
            Record.self,
            Session.self,
            Speakers.self,
            People.self,
            Voices.self,
            Say.self,
            Read.self,
        ]
    )

    /// Before any `people`, `speakers`, or `session` command, finishes a forget of voices that a crash left pending
    /// (docs/meeting-design.md §4.10), then runs the command.
    static func main() async {
        ForgetResume.beforeCommand(Array(CommandLine.arguments.dropFirst()))
        await main(nil)
    }
}

/// Resuming pending forgets, and sweeping leftover voice renders, at the start of the commands that read or write
/// people and speaker data.
enum ForgetResume {
    static let commands: Set<String> = ["people", "speakers", "session"]

    static func beforeCommand(_ arguments: [String]) {
        guard let command = arguments.first, commands.contains(command) else { return }
        DiarizerVoiceSampleExtractor.removeStaleRenders()
        do {
            try VoiceProfileService.resumePendingForgets(store: SpeakerProfileStore())
        } catch {
            Console.error("Note: \(error.localizedDescription)")
        }
    }
}

extension SpeechBackend: ExpressibleByArgument {}
extension AudioSource: ExpressibleByArgument {}

struct RecognitionOptions: ParsableArguments {
    @Option(help: "Recognition locale (for example en-CA, en-US or fr-CA).") var locale = "en-CA"
    @Option(help: "Native recognizer: speech or dictation.") var backend: SpeechBackend = .speech
}
