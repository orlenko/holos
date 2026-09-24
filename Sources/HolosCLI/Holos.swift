import ArgumentParser
import Foundation
import HolosCore

@main
struct Holos: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "holos", abstract: "Local speech tools for macOS.", version: "0.1.0-dev",
        subcommands: [
            Doctor.self,
            Setup.self,
            Transcribe.self,
            Record.self,
            Session.self,
            Voices.self,
            Say.self,
            Read.self,
        ]
    )
}

extension SpeechBackend: ExpressibleByArgument {}
extension AudioSource: ExpressibleByArgument {}

struct RecognitionOptions: ParsableArguments {
    @Option(help: "English locale (for example en-CA or en-US).") var locale = "en-CA"
    @Option(help: "Native recognizer: speech or dictation.") var backend: SpeechBackend = .speech
}
