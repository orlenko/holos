import AppKit
import HolosContent
import HolosCore
import HolosDesktop

/// What `ReadAloud` needs of the Reading list (`ReadingController`; tests use a stand-in).
@MainActor
protocol ReadAloudList: AnyObject {
    func entry(_ id: UUID) -> ReadingEntry?
    func add(_ source: ReadingSource, voice: String?, speed: Double, document: ReadableDocument?) async throws -> UUID
    func openFinishedFile(_ entry: ReadingEntry) async -> FileHandle?
}

extension ReadingController: ReadAloudList {}

/// Read the selection aloud (docs/design.md "Read the selection aloud"): ⌃⌥⌘R in any app reads the text selected
/// there, adds it to the Reading list as a reading with Settings › Reading's voice and speed, and plays it once it is
/// made, after any it added before. The readings stay in the list, with their text (Show Text).
///
/// Invariants:
/// 1. `waiting` holds the readings the shortcut added that have not started playing, in the order asked; one that
///    fails, is stopped or leaves the list leaves `waiting` too.
/// 2. The first of `waiting` starts playing only once it is made and the player is not playing; it then moves to
///    `playing` until it ends, is stopped, or another reading is played over it.
/// 3. The shortcut is registered only while `isOn`, from `start` on; a registration that fails is `problem`.
@MainActor
final class ReadAloud {
    static let defaultsKey = "readSelectionAloud"
    /// The app's one, made at launch (`HolosAppDelegate.readAloud`), for Settings' row.
    static var shared: ReadAloud?
    /// How long a notice stays on screen.
    static let noticeSeconds = 4

    /// The Reading section's player too, so a reading started here shows in its row.
    let player: ReadingPlayer
    private let readings: any ReadAloudList
    private let defaults: UserDefaults
    private var hotkey: ChordHotkey?
    private(set) var waiting: [UUID] = []
    private(set) var playing: UUID?
    /// Why the shortcut is not working; nil when it is, or is off.
    private(set) var problem: String?
    /// The state changed (the menu and Settings show it).
    var onChange: (() -> Void)?
    /// Reads the selection in the front app; tests replace it.
    var readSelection: @MainActor () throws -> (text: String, app: String?) = { try SelectedText.read() }
    /// Shows a notice (a title and a line); the app shows it in an overlay like dictation's, tests record it.
    lazy var notify: (String, String) -> Void = { [weak self] title, text in self?.showNotice(title, text) }
    private lazy var overlay = DictationOverlay()
    private var hideNotice: Task<Void, Never>?

    init(readings: any ReadAloudList, player: ReadingPlayer = ReadingPlayer(), defaults: UserDefaults = .standard) {
        self.readings = readings
        self.player = player
        self.defaults = defaults
        player.onEnded = { [weak self] id in self?.ended(playing: id) }
    }

    /// The shortcut is on unless turned off in Settings › Reading.
    var isOn: Bool { defaults.object(forKey: Self.defaultsKey) as? Bool ?? true }

    /// A reading the shortcut added is playing or waits: Stop Reading Aloud has something to stop.
    var isActive: Bool { !waiting.isEmpty || (playing != nil && player.entryID == playing) }

    /// The chord, as menus write it.
    var chordTitle: String { ChordHotkey.readSelection.title }

    /// At launch: the shortcut, when on (invariant 3).
    func start() {
        guard isOn, hotkey == nil else { return }
        let hotkey = ChordHotkey(ChordHotkey.readSelection) { [weak self] in self?.pressed() }
        do {
            try hotkey.start()
            self.hotkey = hotkey
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        onChange?()
    }

    /// Settings › Reading's Turn On / Turn Off.
    func setOn(_ on: Bool) {
        defaults.set(on, forKey: Self.defaultsKey)
        if on {
            start()
        } else {
            hotkey?.stop()
            hotkey = nil
            problem = nil
            onChange?()
        }
    }

    /// The shortcut: reads the selection, then adds it to the list to be played once made.
    func pressed() {
        let selection: (text: String, app: String?)
        do {
            selection = try readSelection()
        } catch {
            return notify("Nothing to read aloud", error.localizedDescription)
        }
        guard let document = ReadableDocument.selection(selection.text) else {
            return notify("Nothing to read aloud", SelectedTextError.noSelection(app: selection.app).localizedDescription)
        }
        notify(isActive ? "Making audio after the one before…" : "Making audio…", document.title ?? "")
        Task { [weak self] in await self?.add(document, app: selection.app) }
    }

    private func add(_ document: ReadableDocument, app: String?) async {
        do {
            let id = try await readings.add(.selection(app: app), voice: ReadingPreferences.voice,
                                            speed: ReadingPreferences.speed, document: document)
            waiting.append(id)
            onChange?()
            advance()
        } catch {
            notify("The selection could not be read aloud", error.localizedDescription)
        }
    }

    /// A reading's work ended (`ReadingController.onEnded`): a made one may play now; one that failed or stopped
    /// leaves `waiting` (invariant 1).
    func readingEnded(_ id: UUID) {
        guard waiting.contains(id) else { return }
        if let entry = readings.entry(id), entry.state == .failed || entry.state == .stopped {
            waiting.removeAll { $0 == id }
            if entry.state == .failed {
                notify("The selection could not be read aloud", entry.message ?? "Making its audio failed.")
            }
            onChange?()
        }
        advance()
    }

    /// Stop Reading Aloud: the reading playing stops and those waiting will not play (they are still made).
    func stop() {
        waiting = []
        if let playing, player.entryID == playing { player.stop() }
        playing = nil
        onChange?()
    }

    private func ended(playing id: UUID) {
        if playing == id { playing = nil }
        advance()
        onChange?()
    }

    /// Invariant 2: plays the first waiting reading once it is made and nothing else plays.
    private func advance() {
        while let first = waiting.first, readings.entry(first)?.isActive != true, !player.isPlaying {
            waiting.removeFirst()
            guard let entry = readings.entry(first), entry.state == .done else { continue }
            playing = first
            onChange?()
            Task { [weak self] in await self?.play(entry) }
            return
        }
    }

    private func play(_ entry: ReadingEntry) async {
        let readings = readings
        do {
            if try await player.play(entry.id, file: { await readings.openFinishedFile(entry) }) { return }
            notify("The selection could not be played", "Its audio file is not where it was made.")
        } catch {
            notify("The selection could not be played", error.localizedDescription)
        }
        if playing == entry.id { playing = nil }
        advance()
        onChange?()
    }

    private func showNotice(_ title: String, _ text: String) {
        overlay.show(title: title, text: text, force: true)
        let shown = overlay.contentToken
        hideNotice?.cancel()
        hideNotice = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.noticeSeconds))
            guard let self, !Task.isCancelled, overlay.contentToken == shown else { return }
            overlay.hide()
        }
    }
}
