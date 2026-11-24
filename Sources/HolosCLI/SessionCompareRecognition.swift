import ArgumentParser
import Foundation
import HolosDiarization
import HolosMeeting
import HolosPocket

extension Session {
    struct CompareRecognition: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Compare Parakeet Ultra with a finished meeting’s current transcript.")
        @Argument(help: "Meeting path or ID.") var path: String
        @Flag(help: "Print the two transcripts as JSON.") var json = false

        func run() async throws {
            let session = try SessionLocator.resolve(path)
            let filter = FluidAudioLogFilter.install(on: STDERR_FILENO)
            defer { filter?.finish() }
            do {
                let result = try await EvalInterrupt.run {
                    try await SessionCompareRecognitionCommand.run(session: session) { try ParakeetTranscriber.load() }
                }
                if json { try Console.json(result) }
                else {
                    Console.output("Current transcript\n\(result.current ?? "No current transcript.")\n\nParakeet Ultra\n\(result.candidate)")
                }
            } catch is CancellationError {
                throw ExitCode(EvalInterrupt.lastExitCode)
            }
        }
    }
}
