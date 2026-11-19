import ArgumentParser
import Foundation
import HolosContent
import HolosCore
import HolosDictation

/// `voiceislocal tidy` (docs/design.md "Tidy Up").
struct Tidy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tidy dictated text: rejoin sentences a pause split, add paragraphs, lists and quotes.",
        discussion: """
            A language model on this Mac rereads the text in parts and rejoins sentences that a pause split, fixes \
            punctuation and capitals, breaks the text into paragraphs, lists and quotes, and drops fillers ("um") and \
            false starts. It keeps the speaker's words otherwise: a part whose edit leaves out or adds too many words \
            keeps its own text, and so does a part the model fails on; each is named on standard error. Nothing \
            leaves this Mac and nothing is copied. The tidied text goes to standard output (with --json, the text, \
            each part, and the words changed). Apple's on-device model needs Apple Intelligence turned on and tidies \
            English and French text. Exits 0 when the text was tidied, even if some parts kept their own text, and 1 \
            when no model could run.
            """)

    @Argument(help: "A UTF-8 text file, or - (or nothing) for standard input.") var file: String?
    @Option(help: "The model: apple.") var model: TidyCommand.Engine = .apple
    @Flag(help: "Print the result as JSON.") var json = false

    func run() async throws {
        let text = try input()
        if let reason = OnDeviceTidy.unavailableReason(for: text) {
            Console.error("Cannot tidy with Apple's model: \(reason).")
            throw ExitCode(1)
        }
        let outcome = try await TidyCommand.run(text, engine: model, tidier: OnDeviceTidy.tidier()) { done, total in
            guard total > 1, done < total else { return }
            Console.error("Tidying part \(done + 1) of \(total)…")
        }
        for (index, part) in outcome.parts.enumerated() {
            guard let reason = part.kept else { continue }
            Console.error("Part \(index + 1) of \(outcome.parts.count) is left as it was: \(reason).")
        }
        if json { try Console.json(outcome) } else { Console.output(outcome.text) }
    }

    /// At most 1 MB of UTF-8 text from `file` or standard input.
    private func input() throws -> String {
        let data: Data
        if let file, file != "-" {
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        } else {
            guard isatty(STDIN_FILENO) == 0 else { throw ValidationError("Give a file, or pipe the text on standard input.") }
            data = try FileHandle.standardInput.read(upToCount: Self.maximumBytes + 1) ?? Data()
        }
        guard data.count <= Self.maximumBytes else { throw ValidationError("The text is larger than 1 MB.") }
        guard let text = DocumentText.decode(data), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("The text is empty or is not UTF-8.")
        }
        return text
    }

    static let maximumBytes = 1_000_000
}

extension TidyCommand.Engine: ExpressibleByArgument {}
