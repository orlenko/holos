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
        NaturalVoiceHelpers.using(folder)
        defer {
            try? FileManager.default.removeItem(at: folder)
            NaturalVoiceHelpers.done(folder)
        }
        let textFile = folder.appendingPathComponent("part.txt")
        let errors = folder.appendingPathComponent("stderr.txt")
        try Data(text.utf8).write(to: textFile, options: .atomic)
        let arguments = Self.arguments(voice: voiceIdentifier, rate: rate, textFile: textFile, output: output)
        let child = ChildState()
        let code: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try Task.checkCancellation()
                    let pid = try launch(arguments, errors) { code in
                        if let pid = child.pid { NaturalVoiceHelpers.ended(pid) }
                        continuation.resume(returning: code)
                    }
                    NaturalVoiceHelpers.started(pid)
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

        var pid: Int32? { state.withLock { $0.pid } }

        /// Marks the render cancelled; the pid to stop when the child is running.
        func cancel() -> Int32? {
            state.withLock { value in
                value.cancelled = true
                return value.pid
            }
        }
    }
}

/// The `voiceislocal` helpers rendering natural voices for this app (a reading's part, a Preview) and the temporary
/// folders they use. They run detached, so a quit stops them here (`stopAll`), from `applicationWillTerminate`:
/// the cancellations that would stop them (a reading's Stop, Preview's stop) end only after the app has exited.
enum NaturalVoiceHelpers {
    private static let state = Mutex<(pids: Set<Int32>, folders: Set<String>)>(([], []))

    static func started(_ pid: Int32) { _ = state.withLock { $0.pids.insert(pid) } }
    static func ended(_ pid: Int32) { _ = state.withLock { $0.pids.remove(pid) } }
    static func using(_ folder: URL) { _ = state.withLock { $0.folders.insert(folder.path) } }
    static func done(_ folder: URL) { _ = state.withLock { $0.folders.remove(folder.path) } }

    /// Sends every helper still running SIGTERM (the tool stops at once; a reading's part is rendered again on
    /// Resume) and removes the temporary folders in use. Returns the helpers signalled.
    @discardableResult
    static func stopAll(signal: (Int32) -> Void = { _ = kill($0, SIGTERM) }) -> [Int32] {
        let (pids, folders) = state.withLock { value in
            let taken = value
            value = ([], [])
            return (taken.pids, taken.folders)
        }
        for pid in pids where pid > 0 { signal(pid) }
        for folder in folders { try? FileManager.default.removeItem(atPath: folder) }
        return pids.sorted()
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
        if let voice = automatic(language: wanted, installed: installed, bestApple: bestApple) { return voice }
        let fallback = try appleDefault()
        guard let voice = appleVoices.first(where: { $0.id == fallback }) else {
            throw HolosError.unavailable("No speech voice is installed. Add one in System Settings › Accessibility › "
                + "Spoken Content › System Voice › Manage Voices.")
        }
        return voice
    }

    /// What Automatic means for `language`, for Make Audio and Preview alike: the pack's natural voice once it is
    /// installed (Alba, Estelle), else the best Apple voice; nil when no voice speaks it.
    static func automatic(language: String, installed: Set<NaturalVoicePack>,
                          bestApple: (String) -> VoiceDescriptor?) -> VoiceDescriptor? {
        NaturalVoiceCatalog.defaultVoice(language: language, installed: installed)?.descriptor ?? bestApple(language)
    }

    /// Posted when natural voices were installed: the voice menus are filled again, keeping their choice. Not
    /// `ReadingPreferences.changed`, which would put the Reading card back to the saved defaults.
    static let installedChanged = Notification.Name("VoiceIsLocalNaturalVoicesInstalled")

    static func announceInstalled() {
        NotificationCenter.default.post(name: installedChanged, object: nil)
    }

    /// How a reading's row names its voice.
    static func name(of voice: VoiceDescriptor) -> String {
        if let natural = NaturalVoiceCatalog.voice(id: voice.id) { return natural.title }
        return ReadingVoiceMenu.items(NativeSpeechRenderer.voices(), preferredLanguages: [])
            .first { $0.id == voice.id }?.name ?? voice.name
    }
}
