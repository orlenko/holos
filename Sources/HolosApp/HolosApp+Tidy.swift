import AppKit
import Foundation
import HolosCore
import HolosDictation
import HolosMeeting

/// Tidy Up in the main window (docs/design.md "Tidy Up"): the app runs `voiceislocal tidy --json` on the text, and
/// `setup --tidy-model` / `--remove-tidy-model` for Qwen, as child processes; it never links llama.cpp.
extension HolosAppDelegate {
    /// The most a tidy-up prints: the text, each part as sent and as used, and the changes, for 1 MB of text.
    static let tidyOutputBytes = 16 << 20

    func makeTidyPane() -> TidyPane {
        TidyPane(actions: TidyPane.Actions(
            tidy: { [weak self] text, completion in
                guard let self else { return .failure(HolosError.unavailable("Voice is Local is quitting.")) }
                return self.startTidy(text, completion: completion)
            },
            install: { [weak self] file, progress, done in
                self?.runTidyModelSetup(file.map { ["--tidy-model", "--from", $0.path] } ?? ["--tidy-model"],
                                        progress: progress, done: done) ?? false
            },
            remove: { [weak self] done in
                self?.runTidyModelSetup(["--remove-tidy-model"], progress: { _ in }, done: done) ?? false
            },
            lastDictation: { [weak self] in
                guard let self, !self.lastTranscript.isEmpty else { return nil }
                return self.lastTranscript
            },
            copy: { text in
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(text, forType: .string)
            }))
    }

    /// History's Tidy Up…: the section with that dictation's text.
    func tidyUp(_ record: DictationRecord) {
        showMainWindow(.tidy)
        (mainWindow?.existingController(for: .tidy) as? TidyPane)?.load(record.text)
    }

    /// Writes `text` to a private temporary file (0600), which the tool reads and the completion removes.
    private func startTidy(_ text: String,
                           completion: @escaping @MainActor (CommandResult<TidyCommand.Outcome>) -> Void)
        -> Result<CommandHandle, Error> {
        guard let commands = meeting.commands else {
            return .failure(HolosError.unavailable("the voiceislocal tool could not be set up"))
        }
        let input = TemporaryArtifact(kind: "tidy-input")
        guard FileManager.default.createFile(atPath: input.url.path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            return .failure(HolosError.io("the text could not be written to a temporary file"))
        }
        do {
            return .success(try commands.start(["tidy", "--json", input.url.path], output: "tidy-json",
                                               errors: "tidy-errors", maxOutputBytes: Self.tidyOutputBytes,
                                               as: TidyCommand.Outcome.self) { result in
                input.remove()
                completion(result)
            })
        } catch {
            input.remove()
            return .failure(error)
        }
    }

    /// `voiceislocal setup <arguments>`, its latest progress line to `progress` every half second, and nil or the
    /// failure to `done`. False when it cannot start.
    private func runTidyModelSetup(_ arguments: [String], progress: @escaping @MainActor (String) -> Void,
                                   done: @escaping @MainActor (String?) -> Void) -> Bool {
        guard let maintenance = meeting.maintenance else { return false }
        let output = Self.temporaryFile("setup-tidy")
        let finished = Finished()
        do {
            try maintenance.run(["setup"] + arguments, standardOutput: output, standardError: output) { code in
                finished.value = true
                let last = Self.lastLine(output)
                Self.removeFile(output)
                done(code == 0 ? nil : last ?? "it stopped (code \(code)).")
            }
        } catch {
            Self.removeFile(output)
            return false
        }
        Task {
            while !finished.value {
                if let line = Self.lastLine(output), line.hasPrefix("Tidy Up model:") || line.hasPrefix("Downloading")
                    || line.hasPrefix("Resuming") || line.hasPrefix("Checking") || line.hasPrefix("Copying") {
                    progress(line.replacingOccurrences(of: "Tidy Up model:", with: "Installing Qwen:"))
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        return true
    }
}

/// Whether a setup run has ended, for its progress loop (main actor only).
@MainActor private final class Finished {
    var value = false
}
