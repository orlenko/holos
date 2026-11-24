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
        // Quitting stops a tidy-up and deletes its copy of the text: the tool would otherwise run on for a result
        // nobody reads, with the text in a temporary file until a later launch sweeps it.
        let current = TidyRun()
        current.observer = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { current.stop() }
        }
        return TidyPane(actions: TidyPane.Actions(
            tidy: { [weak self] text, meeting, engine, completion in
                guard let self else { return .failure(HolosError.unavailable("Voice is Local is quitting.")) }
                return self.startTidy(meeting?.encoded ?? Data(text.utf8), isMeeting: meeting != nil,
                                      engine: engine, run: current, completion: completion)
            },
            install: { [weak self] variant, file, progress, done in
                let arguments = ["--tidy-model", "--model", variant.rawValue] + (file.map { ["--from", $0.path] } ?? [])
                return self?.runTidyModelSetup(arguments, progress: progress, done: done) ?? false
            },
            remove: { [weak self] variant, done in
                self?.runTidyModelSetup(["--remove-tidy-model", "--model", variant.rawValue],
                                        progress: { _ in }, done: done) ?? false
            },
            lastDictation: { [weak self] in
                guard let self, !self.lastTranscript.isEmpty else { return nil }
                return self.lastTranscript
            },
            copy: { text in
                guard !text.isEmpty else { return false }
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
    private func startTidy(_ data: Data, isMeeting: Bool, engine: TidyCommand.Engine?, run current: TidyRun,
                           completion: @escaping @MainActor (CommandResult<TidyCommand.Outcome>) -> Void)
        -> Result<CommandHandle, Error> {
        guard let commands = meeting.commands else {
            return .failure(HolosError.unavailable("the voiceislocal tool could not be set up"))
        }
        let input = TemporaryArtifact(kind: "tidy-input")
        guard FileManager.default.createFile(atPath: input.url.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            return .failure(HolosError.io("the text could not be written to a temporary file"))
        }
        do {
            let arguments = ["tidy", "--json"] + (isMeeting ? ["--meeting-snapshot"] : [])
                + (engine.map { ["--model", $0.rawValue] } ?? []) + [input.url.path]
            let handle = try commands.start(arguments, output: "tidy-json",
                                            errors: "tidy-errors", maxOutputBytes: Self.tidyOutputBytes,
                                            as: TidyCommand.Outcome.self) { result in
                input.remove()
                if current.input == input { current.clear() }
                completion(result)
            }
            current.handle = handle
            current.input = input
            return .success(handle)
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
                    progress(line.replacingOccurrences(of: "Tidy Up model:", with: "Installing model:"))
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        return true
    }
}

/// The tidy-up running now, so quitting can stop it and delete its input (main actor only).
@MainActor private final class TidyRun {
    var handle: CommandHandle?
    var input: TemporaryArtifact?
    var observer: NSObjectProtocol?

    func stop() {
        handle?.terminate()
        input?.remove()
        clear()
    }

    func clear() {
        handle = nil
        input = nil
    }
}

/// Whether a setup run has ended, for its progress loop (main actor only).
@MainActor private final class Finished {
    var value = false
}
