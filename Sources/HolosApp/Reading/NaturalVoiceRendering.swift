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
    /// The tool's notes already logged.
    private static var notesLogged: Set<String> = []

    private let launch: Launch
    private let installedPacks: () -> Set<NaturalVoicePack>
    private let signal: @Sendable (Int32) -> Void
    private let forceKill: @Sendable (Int32) -> Void
    private let killAfter: Duration
    private let gate: NaturalVoiceHelperGate
    private let currentSettings: (NaturalVoice) -> NaturalRenderSettings

    /// `currentSettings`: what the tool would use now for a voice (a reading saves them when it starts): the best
    /// Apple voice of its language for a paragraph it fails, and the check unless `HOLOS_NATURAL_CHECK=0` (the tool
    /// gets this app's environment). A Stop sends the tool `signal` (SIGTERM); one still running `killAfter` later
    /// gets `forceKill` (SIGKILL), so a wedged tool never holds the helper gate.
    init(launch: @escaping Launch, installedPacks: @escaping () -> Set<NaturalVoicePack> = {
             NaturalVoicesAppState.shared.installed
         }, signal: @escaping @Sendable (Int32) -> Void = { _ = kill($0, SIGTERM) },
         forceKill: @escaping @Sendable (Int32) -> Void = { _ = kill($0, SIGKILL) },
         killAfter: Duration = .seconds(5),
         gate: NaturalVoiceHelperGate = .shared,
         currentSettings: @escaping (NaturalVoice) -> NaturalRenderSettings = { voice in
             NaturalRenderSettings(fallbackVoice: NativeSpeechRenderer.bestVoice(language: voice.pack.languageCode)?.id,
                                   checked: ProcessInfo.processInfo.environment["HOLOS_NATURAL_CHECK"] != "0")
         }) {
        self.launch = launch
        self.installedPacks = installedPacks
        self.signal = signal
        self.forceKill = forceKill
        self.killAfter = killAfter
        self.gate = gate
        self.currentSettings = currentSettings
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

    func renderSettings(for voiceIdentifier: String) -> [String: String]? {
        NaturalVoiceCatalog.voice(id: voiceIdentifier).map { currentSettings($0).values }
    }

    /// The tool's arguments for one part. Its temporary files (the recognizer's and the system voice's) go in
    /// `scratch`, the folder this app tracks and deletes, so stopping the tool leaves nothing behind. `parent` (this
    /// app): the tool stops when it ends, a crash included, and waits for one an ended app left writing `output`.
    /// `settings`: those the reading saved, else the tool's own.
    static func arguments(voice: String, rate: Float?, settings: NaturalRenderSettings?, textFile: URL, scratch: URL,
                          output: URL, parent: Int32 = getpid()) -> [String] {
        var arguments = ["say", "--voice", voice, "--text-file", textFile.path, "--scratch-directory", scratch.path,
                         "--output", output.path, "--parent-pid", "\(parent)"]
        if let settings {
            arguments += ["--check", settings.checked ? "on" : "off"]
            // An empty one: the reading saved no fallback voice (not "use today's").
            arguments += ["--fallback-voice", settings.fallbackVoice ?? ""]
        }
        if let rate { arguments += ["--rate", "\(rate)"] }
        return arguments
    }

    func render(text: String, voiceIdentifier: String?, rate: Float?, to output: URL) async throws -> RenderedAudio {
        try await render(text: text, voiceIdentifier: voiceIdentifier, rate: rate, savedSettings: nil, to: output)
    }

    func render(text: String, voiceIdentifier: String?, rate: Float?, savedSettings: [String: String]?,
                to output: URL) async throws -> RenderedAudio {
        guard let voiceIdentifier else { throw HolosError.invalidInput("A natural voice must be named.") }
        try checkVoice(voiceIdentifier)
        // One helper at a time, app-wide: each loads the model (up to 1.6 GB for French). A Preview waits behind a
        // reading's part, and a Preview started again waits for the one it replaced to have exited.
        try await gate.acquire()
        defer { gate.release() }
        // Made, marked as this app's (its pid: the tool removes it if this app ends, and no other folder), and given
        // the text off the main actor; removed off it too.
        // Made and registered in one step (`NaturalVoiceHelpers.makeFolder`), so a quit's `stopAll` either removes it
        // or comes first and nothing is made: the reading's text is never left behind.
        let folder = try await offMain {
            try NaturalVoiceHelpers.makeFolder {
                let folder = try NaturalHelperScratch.create()
                do {
                    try Data(text.utf8).write(to: folder.appendingPathComponent("part.txt"), options: .atomic)
                } catch {
                    Self.discard(folder)
                    throw error
                }
                return folder
            }
        }
        let textFile = folder.appendingPathComponent("part.txt")
        defer { Task.detached(priority: .utility) { Self.remove(folder) } }
        let errors = folder.appendingPathComponent("stderr.txt")
        let arguments = Self.arguments(voice: voiceIdentifier, rate: rate,
                                       settings: savedSettings.map(NaturalRenderSettings.init(values:)),
                                       textFile: textFile, scratch: folder, output: output)
        let child = ChildState()
        let code: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try Task.checkCancellation()
                    let pid = try launch(arguments, errors) { code in
                        // Ended (and reaped) before anything else hears of it: a Stop after this signals no one, so
                        // never a process that reuses its pid.
                        if let pid = child.ended() { NaturalVoiceHelpers.ended(pid) }
                        continuation.resume(returning: code)
                    }
                    let started = child.started(pid)
                    if started.running {
                        NaturalVoiceHelpers.started(pid)
                        if started.cancelled { stop(pid, child) }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { [stop] in
            if let pid = child.cancel() { stop(pid, child) }
        }
        let said = try await offMain { (try? String(contentsOf: errors, encoding: .utf8)) ?? "" }
        for line in said.split(separator: "\n") where line.hasPrefix("Paragraph") || line.hasPrefix("Note:") {
            // A note (no recognizer for the language) is the same for every part: logged once per launch.
            if line.hasPrefix("Note:"), !Self.notesLogged.insert(String(line)).inserted { continue }
            Self.log.notice("Natural voice: \(line, privacy: .public)")
        }
        try Task.checkCancellation()
        guard code == 0 else {
            let last = said.split(separator: "\n").last.map(String.init)?
                .replacingOccurrences(of: "Error: ", with: "")
            throw HolosError.incomplete(last ?? "The natural voice stopped (code \(code)).")
        }
        let (frames, rate) = try await offMain { () -> (AVAudioFramePosition, Double) in
            let file = try AVAudioFile(forReading: output)
            return (file.length, file.processingFormat.sampleRate)
        }
        return RenderedAudio(url: output, duration: Double(frames) / rate, frameCount: frames, sampleRate: rate)
    }

    /// Stops the tool: SIGTERM now, SIGKILL if it still runs `killAfter` later (its exit then releases the gate).
    private var stop: @Sendable (Int32, ChildState) -> Void {
        { [signal, forceKill, killAfter] pid, child in
            signal(pid)
            Task.detached {
                try? await Task.sleep(for: killAfter)
                if let running = child.running() { forceKill(running) }
            }
        }
    }

    /// Removes a helper's folder and forgets it.
    nonisolated private static func remove(_ folder: URL) {
        discard(folder)
        NaturalVoiceHelpers.done(folder)
    }

    /// Removes a helper's folder; one that cannot be removed is logged (the launch sweep removes it once a day old).
    nonisolated private static func discard(_ folder: URL) {
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            Logger(subsystem: "ca.orlenko.holos.app", category: "reading")
                .error("Could not remove a natural voice folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The child's pid once started, and whether the render was cancelled before or after.
    private final class ChildState: Sendable {
        private let state = Mutex<(pid: Int32?, cancelled: Bool, ended: Bool)>((nil, false, false))

        /// Records the pid of the child just launched: whether it still runs (it may have ended already), and whether
        /// the render was cancelled before (the child is then stopped at once).
        func started(_ pid: Int32) -> (running: Bool, cancelled: Bool) {
            state.withLock { value in
                guard !value.ended else { return (false, value.cancelled) }
                value.pid = pid
                return (true, value.cancelled)
            }
        }

        /// The child has exited and been reaped: its pid, forgotten here so no later cancel signals it.
        func ended() -> Int32? {
            state.withLock { value in
                value.ended = true
                defer { value.pid = nil }
                return value.pid
            }
        }

        /// The child's pid while it runs; nil once it has ended (its pid may belong to another process by then).
        func running() -> Int32? {
            state.withLock { value in value.ended ? nil : value.pid }
        }

        /// Marks the render cancelled; the pid to stop while the child runs, nil once it has ended.
        func cancel() -> Int32? {
            state.withLock { value in
                value.cancelled = true
                return value.ended ? nil : value.pid
            }
        }
    }
}

/// The `voiceislocal` helpers rendering natural voices for this app (a reading's part, a Preview) and the temporary
/// folders they use. They run detached, so a quit stops them here (`stopAll`), from `applicationWillTerminate`:
/// the cancellations that would stop them (a reading's Stop, Preview's stop) end only after the app has exited.
enum NaturalVoiceHelpers {
    private static let state = Mutex<(pids: Set<Int32>, folders: Set<String>, stopped: Bool)>(([], [], false))

    static func started(_ pid: Int32) { _ = state.withLock { $0.pids.insert(pid) } }
    static func ended(_ pid: Int32) { _ = state.withLock { $0.pids.remove(pid) } }
    static func using(_ folder: URL) { _ = state.withLock { $0.folders.insert(folder.path) } }

    /// Makes a helper's folder with `make` and registers it. Refused once a quit has begun (`stopAll`); made outside the
    /// lock, so a quit never waits on file work; then registered, or removed at once when a quit came meanwhile. Either
    /// the quit removes the folder or the folder is removed here: the reading's text is not left behind.
    static func makeFolder(_ make: () throws -> URL) throws -> URL {
        try state.withLock { value throws in if value.stopped { throw CancellationError() } }
        let folder = try make()
        let registered = state.withLock { value -> Bool in
            guard !value.stopped else { return false }
            value.folders.insert(folder.path)
            return true
        }
        guard registered else {
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                Logger(subsystem: "ca.orlenko.holos.app", category: "reading")
                    .error("Could not remove a natural voice folder: \(error.localizedDescription, privacy: .public)")
            }
            throw CancellationError()
        }
        return folder
    }
    static func done(_ folder: URL) { _ = state.withLock { $0.folders.remove(folder.path) } }

    /// Sends every helper still running SIGTERM (the tool stops at once; a reading's part is rendered again on
    /// Resume) and removes the temporary folders in use. Returns the helpers signalled. `ending` (the quit): no
    /// folder is made after this (`makeFolder`); tests that go on pass false.
    @discardableResult
    static func stopAll(ending: Bool = true, signal: (Int32) -> Void = { _ = kill($0, SIGTERM) }) -> [Int32] {
        let (pids, folders) = state.withLock { value in
            let taken = value
            value = ([], [], ending)
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
    /// language once that pack is installed (Alba in English, Estelle in French), else the best Apple voice. `saved`:
    /// the manifest of a reading begun before; one started with another commit of the natural voices is refused
    /// first, before its pack is asked for (installing it again would not help), as `voiceislocal read --resume` does.
    static func choose(fixed: String?, fixedName: String?, language: String?, saved: ReadingManifest? = nil,
                       installed: Set<NaturalVoicePack>, appleVoices: [VoiceDescriptor],
                       bestApple: (String) -> VoiceDescriptor?,
                       appleDefault: () throws -> String) throws -> VoiceDescriptor {
        if let saved {
            try ReadingResumeVoice.checkRevision(saved, again: "Delete this reading and make it again.")
        }
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

    /// The voice the reading was started with; else the one asked for; else the best installed voice for its
    /// language (as `voiceislocal read` picks it).
    static func voice(for entry: ReadingEntry, language: String?, saved: ReadingManifest? = nil) throws
        -> VoiceDescriptor {
        try choose(
            fixed: entry.voiceIdentifier ?? entry.requestedVoice, fixedName: entry.voiceName, language: language,
            saved: saved,
            installed: NaturalVoicesAppState.shared.installed, appleVoices: NativeSpeechRenderer.voices(),
            bestApple: NativeSpeechRenderer.bestVoice(language:),
            appleDefault: NativeSpeechRenderer.defaultVoiceIdentifier)
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

/// Lets one natural-voice helper run at a time in this app (`HelperNaturalRenderer`): the next waits, in order, until
/// the one before has exited. A wait cancelled (Stop) ends at once and starts nothing.
@MainActor final class NaturalVoiceHelperGate {
    static let shared = NaturalVoiceHelperGate()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var busy = false
    private var waiting: [Waiter] = []

    /// Whether a helper holds the gate now.
    var isBusy: Bool { busy }
    /// How many renders wait for the gate.
    var waitingCount: Int { waiting.count }

    func acquire() async throws {
        try Task.checkCancellation()
        guard busy else {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enqueue(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.abandon(id) }
        }
    }

    private func enqueue(_ waiter: Waiter) {
        if Task.isCancelled {
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            waiting.append(waiter)
        }
    }

    /// The helper has exited: the next waiting one goes (the gate stays held for it), else the gate is free.
    func release() {
        guard !waiting.isEmpty else {
            busy = false
            return
        }
        waiting.removeFirst().continuation.resume()
    }

    private func abandon(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

