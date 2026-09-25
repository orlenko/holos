import ArgumentParser
import Foundation
import HolosCore
import HolosSpeech

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Transcribe an existing local audio file with Apple's on-device recognizer.")
    @Argument(help: "Path to an audio file.") var input: String
    @OptionGroup var recognition: RecognitionOptions
    @Option(name: .shortAndLong, help: "Write a timestamped JSON transcript to a new file.") var output: String?
    @Flag(help: "Print JSON on stdout instead of growing timestamped text.") var json = false

    mutating func run() async throws {
        let showLive = !json && output == nil
        let locale = await recognition.resolvedLocale()
        let transcript = try await AppleSpeechEngine.transcribe(file: fileURL(input), locale: locale,
            backend: recognition.backend) { update in
                if showLive && update.isFinal { Console.segment(update.segment) }
            }
        if let output {
            try writeJSON(transcript, to: fileURL(output))
            Console.output(fileURL(output).path)
        } else if json { try Console.json(transcript) }
    }
}
