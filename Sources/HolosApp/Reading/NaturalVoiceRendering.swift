import AVFoundation
import Darwin
import Foundation
import HolosContent
import HolosCore
import HolosMeeting
import HolosSynthesis
import os
import Synchronization

/// Renders a reading's part with a natural voice through the bundled `voiceislocal` tool (docs/design.md "Natural
/// voices"): `voiceislocal say --voice pocket:… --text-file <part text> --output <part file>`. The app does not link
/// FluidAudio, so the model's memory (about 1 GB while it speaks) lives in that process and goes with it; each part
/// loads the compiled model again (a few seconds against minutes of rendering). A Stop sends it SIGTERM.
@MainActor final class HelperNaturalRenderer: ReadingAudioRenderer {
    /// Starts `voiceislocal <arguments>` with stderr written to `standardError`; returns its pid. `onExit` gets the
    /// exit code (128 + the signal for a killed child).
    typealias Launch = @MainActor (_ arguments: [String], _ standardError: URL,
                                   _ onExit: @escaping @MainActor (Int32) -> Void) throws -> Int32

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "reading")

    private let launch: Launch
    private let installedPacks: () -> Set<NaturalVoicePack>
    private let signal: @Sendable (Int32) -> Void

    init(launch: @escaping Launch, installedPacks: @escaping () -> Set<NaturalVoicePack> = {
             NaturalVoiceModels.installedPacks()
         }, signal: @escaping @Sendable (Int32) -> Void = { _ = kill($0, SIGTERM) }) {
        self.launch = launch
        self.installedPacks = installedPacks
        self.signal = signal
    }

    /// Through a `MaintenanceLauncher` of the bundled tool.
    convenience init(launcher: MaintenanceLauncher) {
        self.init(launch: { arguments, standardError, onExit in
            try launcher.run(arguments, standardOutput: nil, standardError: standardError, onExit: onExit)
        })
    }

    func checkVoice(_ identifier: String) throws {
        guard let voice = NaturalVoiceCatalog.voice(id: identifier) else {
            throw HolosError.unavailable("Speech voice is unavailable: \(identifier)")
        }
        guard installedPacks().contains(voice.pack) else {
            throw HolosError.unavailable("The \(voice.pack.languageName) natural voices are not installed. Download "
                + "them in Settings › Reading, then try again.")
        }
    }

    /// The tool's arguments for one part.
    static func arguments(voice: String, rate: Float?, textFile: URL, output: URL) -> [String] {
        ["say", "--voice", voice, "--text-file", textFile.path, "--output", output.path]
            + (rate.map { ["--rate", "\($0)"] } ?? [])
    }

    func render(text: String, voiceIdentifier: String?, rate: Float?, to output: URL) async throws -> RenderedAudio {
        guard let voiceIdentifier else { throw HolosError.invalidInput("A natural voice must be named.") }
        try checkVoice(voiceIdentifier)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("holos-natural-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let textFile = folder.appendingPathComponent("part.txt")
        let errors = folder.appendingPathComponent("stderr.txt")
        try Data(text.utf8).write(to: textFile, options: .atomic)
        let arguments = Self.arguments(voice: voiceIdentifier, rate: rate, textFile: textFile, output: output)
        let child = ChildState()
        let code: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try Task.checkCancellation()
                    let pid = try launch(arguments, errors) { code in continuation.resume(returning: code) }
                    if child.started(pid) { signal(pid) }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { [signal] in
            if let pid = child.cancel() { signal(pid) }
        }
        let said = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
        for line in said.split(separator: "\n") where line.hasPrefix("Paragraph") || line.hasPrefix("Note:") {
            Self.log.notice("Natural voice: \(line, privacy: .public)")
        }
        try Task.checkCancellation()
        guard code == 0 else {
            let last = said.split(separator: "\n").last.map(String.init)?
                .replacingOccurrences(of: "Error: ", with: "")
            throw HolosError.incomplete(last ?? "The natural voice stopped (code \(code)).")
        }
        let file = try AVAudioFile(forReading: output)
        let rate = file.processingFormat.sampleRate
        return RenderedAudio(url: output, duration: Double(file.length) / rate, frameCount: file.length,
                             sampleRate: rate)
    }

    /// The child's pid once started, and whether the render was cancelled before or after.
    private final class ChildState: Sendable {
        private let state = Mutex<(pid: Int32?, cancelled: Bool)>((nil, false))

        /// Records the pid; true when the render was cancelled before it started (the child is stopped at once).
        func started(_ pid: Int32) -> Bool {
            state.withLock { value in
                value.pid = pid
                return value.cancelled
            }
        }

        /// Marks the render cancelled; the pid to stop when the child is running.
        func cancel() -> Int32? {
            state.withLock { value in
                value.cancelled = true
                return value.pid
            }
        }
    }
}

/// The voices the Reading section and Settings offer, and which one a reading gets.
@MainActor enum ReadingVoices {
    /// A reading's voice: the one it was started with, else the one asked for, else the natural voice for its
    /// language once that pack is installed (Alba in English, Estelle in French), else the best Apple voice.
    static func choose(fixed: String?, fixedName: String?, language: String?, installed: Set<NaturalVoicePack>,
                       appleVoices: [VoiceDescriptor], bestApple: (String) -> VoiceDescriptor?,
                       appleDefault: () throws -> String) throws -> VoiceDescriptor {
        if let fixed {
            if NaturalVoiceCatalog.isNatural(fixed) {
                guard let natural = NaturalVoiceCatalog.voice(id: fixed) else {
                    throw HolosError.unavailable("The voice \(fixedName ?? fixed) is not available. Delete this "
                        + "reading and make it again with another voice.")
                }
                guard installed.contains(natural.pack) else {
                    throw HolosError.unavailable("The \(natural.pack.languageName) natural voices are not installed. "
                        + "Download them in Settings › Reading, then choose Resume.")
                }
                return natural.descriptor
            }
            guard let voice = appleVoices.first(where: { $0.id == fixed }) else {
                throw HolosError.unavailable("The voice \(fixedName ?? fixed) is not installed any more. "
                    + "Delete this reading and make it again with another voice.")
            }
            return voice
        }
        let wanted = language ?? Locale.preferredLanguages.first ?? "en-US"
        if let natural = NaturalVoiceCatalog.defaultVoice(language: wanted, installed: installed) {
            return natural.descriptor
        }
        if let best = bestApple(wanted) { return best }
        let fallback = try appleDefault()
        guard let voice = appleVoices.first(where: { $0.id == fallback }) else {
            throw HolosError.unavailable("No speech voice is installed. Add one in System Settings › Accessibility › "
                + "Spoken Content › System Voice › Manage Voices.")
        }
        return voice
    }

    /// How a reading's row names its voice.
    static func name(of voice: VoiceDescriptor) -> String {
        if let natural = NaturalVoiceCatalog.voice(id: voice.id) { return natural.title }
        return ReadingVoiceMenu.items(NativeSpeechRenderer.voices(), preferredLanguages: [])
            .first { $0.id == voice.id }?.name ?? voice.name
    }
}
