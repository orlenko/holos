import AppKit
import HolosContent
import HolosCore
import HolosSynthesis

/// Settings › Reading: the default voice and speed of new readings, and the folder their files go to. Kept in
/// UserDefaults; a change posts `changed`, so the Reading section follows it.
@MainActor
enum ReadingPreferences {
    static let voiceKey = "readingVoice"
    static let speedKey = "readingSpeed"
    static let folderKey = "readingFolder"
    static let changed = Notification.Name("VoiceIsLocalReadingPreferencesChanged")

    /// The voice's identifier; nil for the best installed voice for the text's language.
    static var voice: String? {
        get { UserDefaults.standard.string(forKey: voiceKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: voiceKey) }
            else { UserDefaults.standard.removeObject(forKey: voiceKey) }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static var speed: Double {
        get { ReadingSpeed.clamped(UserDefaults.standard.object(forKey: speedKey) as? Double ?? ReadingSpeed.standard) }
        set {
            UserDefaults.standard.set(ReadingSpeed.clamped(newValue), forKey: speedKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Where new readings' files go: the folder chosen in Settings, else `defaultFolder`.
    static var folder: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: folderKey), !path.isEmpty {
                // Spelled as saved: `URL(fileURLWithPath:)` would decompose an NFC name, which a volume that keeps
                // the spellings apart takes for another folder.
                return ReadingOutput.fileURL(keepingSpelling: path, isDirectory: true)
            }
            return defaultFolder
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: folderKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// ~/Music/Voice is Local/Readings: a folder the user sees in Finder that, unlike Documents and Desktop, iCloud
    /// Drive's "Desktop & Documents Folders" never uploads.
    static var defaultFolder: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music", isDirectory: true)
        return music.appendingPathComponent("Voice is Local", isDirectory: true)
            .appendingPathComponent("Readings", isDirectory: true)
    }

    /// Whether new files go to `defaultFolder` (none chosen in Settings, or that same folder chosen).
    static var isDefaultFolder: Bool {
        folder.standardizedFileURL.path == defaultFolder.standardizedFileURL.path
    }

    /// The folder as the Reading section and Settings show it ("~/Music/Voice is Local/Readings").
    static var folderText: String { (folder.path as NSString).abbreviatingWithTildeInPath }
}

/// The Reading list and the readings being made (docs/design.md "Reading section"): the index
/// (`ReadingLibraryStore`), one reading at a time through `ReadingWorkQueue`, each loaded with `DocumentLoader` or
/// `WebArticleExtractor` and rendered in this process with `ReadingPipeline` into the output folder. Created at
/// launch, so readings the user kept rendering over a quit continue.
@MainActor
final class ReadingController {
    /// What a reading being made is doing, for its row.
    enum Activity: Equatable {
        case loading
        case rendering(part: Int, of: Int)
        case joining(parts: Int)
    }

    /// The list as shown, newest first: without the readings being deleted.
    var entries: [ReadingEntry] { all.filter { $0.deletePending != true } }
    /// What the list should say about its index (see `ReadingLibraryStore.load`).
    private(set) var notice: String?
    private(set) var activity: [UUID: Activity] = [:]
    /// The list changed (a reading added, removed, or changing state).
    var onChange: (() -> Void)?
    /// One reading's progress changed.
    var onProgress: ((UUID) -> Void)?

    /// Every entry of the index, those being deleted included (they are saved marked, so a quit or a crash before
    /// their files are gone finishes the deletion at the next launch).
    private var all: [ReadingEntry] = []
    private let store = ReadingLibraryStore.standard()
    /// Whether the list is saved; false until it is read (see `start`).
    private var writable = false
    /// The list has been read (see `start`).
    private var listLoaded = false
    /// Readings of an index a newer Voice is Local wrote: shown, never changed here.
    private var readOnly: Set<UUID> = []
    private var started = false
    /// `prepareForQuit` ran and no quit has been cancelled since.
    private var preparedForQuit = false
    /// Readings to delete once their render has stopped.
    private var deleteWhenStopped: Set<UUID> = []
    /// Readings whose files are being removed (off the main actor), so one is never removed twice at once.
    private var deleting: Set<UUID> = []
    /// What is known of each made reading's file (see `refreshFiles`): the rows and playback use only this, so no
    /// file is looked up on the main actor. None yet for one not checked.
    private var files: [UUID: ReadingLibrary.FileStatus] = [:]
    /// The check of the files running (`refreshFiles`), and whether another was asked for meanwhile.
    private var filesCheck: Task<Void, Never>?
    private var filesCheckAgain = false
    /// For a made reading whose file's identity did not match (see `ReadingLibrary.FileStatus.changed`): the file
    /// whose checksum was read, so the same file is not read again at each check.
    private var checksummed: [UUID: ReadingLibrary.FileVersion] = [:]
    /// The made readings whose file's checksum is being read.
    private var checksumming: Set<UUID> = []
    /// The file whose checksum could not be read (tried again at the next check).
    private var unreadable: [UUID: ReadingLibrary.FileVersion] = [:]
    /// The index's folder could not be reached at launch (see `ReadingLibraryStore.Loaded.unavailable`): it is read
    /// again when the section shows or its window comes back, and nothing is saved until it is.
    private var indexUnavailable = false
    private lazy var queue: ReadingWorkQueue = {
        let queue = ReadingWorkQueue { [weak self] id in try await self?.make(id) }
        queue.onStart = { [weak self] id in self?.started(id) }
        queue.onEnd = { [weak self] id, outcome in self?.ended(id, outcome) }
        queue.onAbandonedEnd = { [weak self] id in self?.abandonedEnded(id) }
        return queue
    }()

    /// Whether the list is saved (it is not when its index could not be read or a newer build wrote it): only then
    /// can a reading continue at the next launch.
    var canPersist: Bool { writable && !lastSaveFailed }
    /// The last save of the index failed (a full disk, a permission changed); the next one that works clears it.
    private var lastSaveFailed = false

    static let saveFailure = "The Reading list could not be saved:"
    static let readOnlyMessage = "This reading belongs to a list a newer Voice is Local saved; it is shown here but not changed."

    /// Reads the list, finishes the deletions a quit interrupted, and continues the readings kept over the last quit.
    /// Once. A list a newer build wrote is only shown.
    func start() {
        guard !started else { return }
        started = true
        let (store, share) = (store, Self.shareFolder)
        // Read off the main actor (the support folder may be on a slow share); nothing is saved or added until then
        // (`writable` is false).
        Task {
            let loaded = try? await offMain {
                // Copies an earlier session made for Share… (their services are done with them by now).
                try? FileManager.default.removeItem(at: share)
                return Self.load(store)
            }
            adopt(loaded ?? .init(entries: [], notice: "The Reading list could not be read.", writable: false,
                                  unavailable: true))
        }
    }

    /// The list as saved, and, when it can be written, the saves a quit or a crash cut off removed (nothing is being
    /// saved yet). Not on the main actor.
    nonisolated private static func load(_ store: ReadingLibraryStore) -> ReadingLibraryStore.Loaded {
        let loaded = store.load()
        if loaded.writable { store.sweepTemporaries() }
        return loaded
    }

    /// Takes the list as loaded: finishes the deletions a quit interrupted and continues the readings kept over it.
    private func adopt(_ loaded: ReadingLibraryStore.Loaded) {
        listLoaded = true
        notice = loaded.notice
        writable = loaded.writable
        indexUnavailable = loaded.unavailable
        readOnly = writable ? [] : Set(loaded.entries.map(\.id))
        let plan = ReadingLibrary.launchPlan(loaded)
        // The deletions a quit interrupted stay in the index, marked (hidden), while they finish off the main actor;
        // one whose files cannot be removed comes back, with the reason.
        all = (plan.entries + plan.delete).sorted { $0.created > $1.created }
        if all != loaded.entries { save() }  // never for a newer build's list (`save` checks `writable`)
        // Saved text a made reading still has (its removal failed, or the save before it did) goes now.
        if writable { removeFinishedSnapshots() }
        plan.resume.forEach(queue.enqueue)
        plan.delete.forEach { finishDeleteLater($0.id) }
        refreshFiles()
        onChange?()
    }

    /// The index's folder could not be reached at launch: it is read again (off the main actor), and taken once it is
    /// there (a drive or share connected since). Nothing was added meanwhile (nothing is added to a list that is not
    /// saved), so the list found there is the whole list.
    private func reloadIfUnavailable() {
        guard listLoaded, indexUnavailable, !reloading, all.isEmpty else { return }
        reloading = true
        let store = store
        Task {
            let loaded = try? await offMain { Self.load(store) }
            reloading = false
            guard let loaded, !loaded.unavailable, indexUnavailable, all.isEmpty else { return }
            adopt(loaded)
        }
    }

    /// `reloadIfUnavailable` is reading the index.
    private var reloading = false

    func entry(_ id: UUID) -> ReadingEntry? { all.first { $0.id == id } }

    /// Whether a reading is being made or waits.
    var isBusy: Bool { !queue.isIdle }
    var runningTitle: String? { queue.running.flatMap(entry)?.title }
    var waitingCount: Int { queue.pending.count }

    /// Adds a reading of `source` at the top of the list and queues it. `voice` nil: the best voice for its language.
    @discardableResult
    /// Refused while the list is not saved (its index could not be read, or a newer build wrote it): a reading made
    /// then would leave the list at the next launch while its cache stayed, with no row to delete it from.
    func add(_ source: ReadingSource, voice: String?, speed: Double) async throws -> UUID {
        guard listLoaded else {
            throw HolosError.unavailable("The Reading list is still being read; try again in a moment.")
        }
        guard writable else {
            // Its folder may be back: the list there is read (never written over), for the next try.
            reloadIfUnavailable()
            throw HolosError.unavailable("New readings are not made while the Reading list cannot be saved"
                + (notice.map { ": \($0)" } ?? "."))
        }
        let entry = ReadingEntry(source: source, requestedVoice: voice, speed: ReadingSpeed.clamped(speed))
        all.insert(entry, at: 0)
        // Nothing is made for a reading the index does not keep: its saved text and cache would have no entry to be
        // found or deleted through after a quit.
        guard await saved(growing: true) else {
            all.removeAll { $0.id == entry.id }
            onChange?()
            throw HolosError.io("The reading was not added: " + (notice ?? "the Reading list could not be saved."))
        }
        onChange?()
        queue.enqueue(entry.id)
        return entry.id
    }

    /// Stop: a waiting reading leaves the queue, a running one is cancelled; either keeps what it rendered for Resume.
    /// Returns a problem to show when it cannot (a newer build's reading, which is not made here).
    func stop(_ id: UUID) -> String? {
        guard !readOnly.contains(id) else { return Self.readOnlyMessage }
        queue.stop(id)
        return nil
    }

    /// The reading's finished file when the last check found it still the one it made (the same file identity as
    /// when it was made, see `refreshFiles`), with its size; nil otherwise, and until it is checked. Looks nothing
    /// up: what a row shows.
    func finishedFile(_ entry: ReadingEntry) -> (url: URL, size: Int64?)? {
        guard entry.state == .done, let output = entry.outputURL,
              case .available(let size)? = files[entry.id] else { return nil }
        return (output, size)
    }

    /// The reading's finished file opened, when the object opened is still the one it made (checked on the open file,
    /// see `ReadingLibrary.openVerified`), opened off the main actor: what Play, Share…, and Show in Finder use, so a
    /// file put at its path meanwhile is never the one used. Nil (and the files checked again) when it is not.
    func openFinishedFile(_ entry: ReadingEntry) async -> FileHandle? {
        guard entry.state == .done, let output = entry.outputURL, let made = entry.outputIdentity else { return nil }
        let file = try? await offMain { ReadingLibrary.openVerified(output, identity: made) }
        if file == nil { refreshFiles() }
        return file ?? nil
    }

    /// A copy of the reading's finished file for Share…, made off the main actor from the file opened and checked
    /// (a clone where the volume can), so what the services read later is that very file.
    func shareableCopy(_ entry: ReadingEntry) async throws -> URL {
        guard let file = await openFinishedFile(entry), let name = entry.outputURL?.lastPathComponent else {
            throw HolosError.unavailable("Its file is no longer the one it made.")
        }
        let folder = Self.shareFolder
        return try await offMain { try ReadingLibrary.copyForSharing(file, name: name, into: folder) }
    }

    /// Where Share…'s copies go (the temporary folder); emptied at each launch.
    static var shareFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Voice is Local Share", isDirectory: true)
    }

    /// When the Reading section shows or its window comes back (a drive reconnected, a file moved in Finder): the
    /// index is read again when its folder could not be reached, and the files are checked again.
    func recheck() {
        reloadIfUnavailable()
        refreshFiles()
    }

    /// Checks the made readings' files off the main actor (`ReadingLibrary.fileStatus`: their metadata only) and
    /// keeps what it finds for the rows (`finishedFile`, `fileProblem`), then says so (`onChange`). A file whose
    /// identity is not the recorded one (or none was recorded: a network volume) is read, once per file found, to
    /// compare its checksum with the reading's: when it is the reading's file (a share mounted again gets a new
    /// device number) its identity is recorded anew. One check runs at a time; one asked for meanwhile follows it.
    /// Run at launch, after a reading is made or deleted, and when the section shows or its window comes back.
    func refreshFiles() {
        filesCheckAgain = true
        guard filesCheck == nil else { return }
        filesCheck = Task {
            while filesCheckAgain {
                filesCheckAgain = false
                await checkFiles()
            }
            filesCheck = nil
        }
    }

    private func checkFiles() async {
        let made = all.filter { $0.state == .done && $0.deletePending != true }
        let statuses = (try? await offMain { made.map(ReadingLibrary.fileStatus(of:)) }) ?? []
        // Only for entries unchanged meanwhile (a Delete, a new identity recorded).
        func current(_ entry: ReadingEntry) -> Bool {
            guard let now = self.entry(entry.id) else { return false }
            return now.state == .done && now.output == entry.output && now.outputIdentity == entry.outputIdentity
        }
        var found: [UUID: ReadingLibrary.FileStatus] = [:]
        for (entry, status) in zip(made, statuses) where current(entry) { found[entry.id] = status }
        if found != files {
            files = found
            onChange?()
        }
        for (entry, status) in zip(made, statuses) {
            guard case .changed(let version) = status, entry.outputSHA256 != nil, !readOnly.contains(entry.id),
                  checksummed[entry.id] != version, current(entry) else { continue }
            checksumming.insert(entry.id)
            let result = try? await offMain(priority: .utility) { ReadingLibrary.revalidate(entry, found: version) }
            checksumming.remove(entry.id)
            // A file that could not be read (a share that stopped answering), or that changed while it was read (one
            // being copied back), is read again at the next check; a file whose size or last change differs later is
            // another version, read again too.
            if let result, result != .unknown {
                checksummed[entry.id] = version
                unreadable[entry.id] = nil
            } else {
                unreadable[entry.id] = version
            }
            guard case .same(let verified)? = result, current(entry) else {
                onChange?()
                continue
            }
            update(entry.id) { $0.outputIdentity = verified }
            save()
            // Shown with its size by the next check.
            filesCheckAgain = true
        }
        checksummed = checksummed.filter { id, _ in all.contains { $0.id == id } }
        unreadable = unreadable.filter { id, _ in all.contains { $0.id == id } }
    }

    /// Why a made reading's file cannot be used (`finishedFile` is nil).
    enum FileProblem: Equatable {
        /// It was moved, deleted, or replaced by another file.
        case missing
        /// The folder that holds it cannot be reached (its drive or share is not connected): it may come back.
        case unavailable(String)
        /// A file is at its path whose identity is not the one recorded: its checksum is being read to tell whether
        /// it is the reading's.
        case checking
    }

    /// Nil when the reading is not made, its file is there (see `finishedFile`), or it has not been checked yet.
    func fileProblem(_ entry: ReadingEntry) -> FileProblem? {
        guard entry.state == .done else { return nil }
        switch files[entry.id] {
        case nil, .available?:
            return nil
        case .missing?:
            return .missing
        case .unavailable(let reason)?:
            return .unavailable(reason)
        case .changed(let found)?:
            if checksumming.contains(entry.id) { return .checking }
            if unreadable[entry.id] == found {
                return .unavailable("its file could not be read to check it; it is checked again when you come back "
                    + "to this window")
            }
            // Its checksum will be read.
            let pending = entry.outputSHA256 != nil && !readOnly.contains(entry.id) && checksummed[entry.id] != found
            return pending ? .checking : .missing
        }
    }

    /// Try Again or Resume: queues a failed or stopped reading again; its rendered parts are reused. Returns a
    /// problem to show when it cannot.
    func retry(_ id: UUID) -> String? {
        guard !readOnly.contains(id) else { return Self.readOnlyMessage }
        guard let entry = entry(id), entry.state == .failed || entry.state == .stopped else { return nil }
        update(id) {
            $0.state = .queued
            $0.message = nil
        }
        save()
        onChange?()
        queue.enqueue(id)
        return nil
    }

    /// Deletes a reading: its `.m4a` goes to the Trash, and its render cache and saved text are removed. The entry is
    /// saved marked first, so it never comes back; a reading being made is stopped, then deleted. When a file cannot
    /// be removed the reading stays in the list, and the problem is returned (or, after a stop, shown as the notice).
    /// The row leaves the list at once; its files are checked and removed off the main actor (a long reading's
    /// checksum takes a while on a slow drive), so this returns when they are.
    func delete(_ id: UUID) async -> DeleteOutcome {
        guard !readOnly.contains(id) else { return .kept(Self.readOnlyMessage) }
        // One mark at a time: a save of another Delete's mark must not carry this one before it is known.
        while holdingWrites > 0 { await withCheckedContinuation { heldWaiters.append($0) } }
        guard let current = entry(id), current.deletePending != true, !deleting.contains(id) else {
            return .deleted(note: nil)
        }
        update(id) { $0.deletePending = true }
        onChange?()
        // Nothing is stopped or removed unless the mark is saved: otherwise the reading would come back at the next
        // launch with its files gone. (A list that is not saved at all keeps nothing to come back.) Other saves wait
        // until it is known: one that wrote the mark while its own save failed would delete the reading at the next
        // launch although the user was told it stays.
        holdingWrites += 1
        let marked = writable ? await saved(holding: true) : true
        if !marked { update(id) { $0.deletePending = nil } }
        releaseWrites()
        if !marked {
            onChange?()
            return .kept("“\(entry(id)?.title ?? "The reading")” was not deleted: "
                + (notice ?? "the Reading list could not be saved."))
        }
        if queue.running == id {
            deleteWhenStopped.insert(id)
            queue.stop(id)
            onChange?()
            return .deleted(note: nil)
        }
        queue.stop(id)
        onChange?()
        let outcome = await finishDelete(id)
        onChange?()
        return outcome
    }

    /// Voice is Local quits with readings waiting or being made: `keep` (Keep Rendering) continues them at the next
    /// launch; otherwise (Stop) they are stopped, with Resume. The render in progress is cancelled either way. Returns
    /// whether the saved list now says so (false: the save failed, and the saved list may still say otherwise).
    @discardableResult
    func prepareForQuit(keep: Bool) -> Bool {
        all = ReadingLibrary.forQuit(all, keep: keep)
        // A list that is never saved (a newer build's) keeps no request to continue anything: nothing to save. Saved
        // now, on the main actor, after the writes queued before: the app quits next.
        let saved = saveNow() || !writable
        queue.shutDown()
        activity.removeAll()
        preparedForQuit = true
        return saved
    }

    /// The quit was cancelled, at once or later (a meeting that could not be stopped): after `prepareForQuit`, the
    /// readings kept for the next launch continue now. Otherwise nothing happens.
    func quitCancelled() {
        guard preparedForQuit else { return }
        preparedForQuit = false
        let (recovered, resume) = ReadingLibrary.afterLaunch(all)
        queue.reopen()
        all = recovered
        // Deletions waiting for a render the quit stopped: those whose render has ended finish now, the others when
        // it ends (`abandonedEnded`).
        for id in deleteWhenStopped where queue.running != id {
            deleteWhenStopped.remove(id)
            finishDeleteLater(id)
        }
        save()
        resume.forEach(queue.enqueue)
        onChange?()
    }

    /// The render the quit stopped has ended. While the quit goes on nothing more is done (the index is saved); after
    /// a cancelled quit, a deletion that waited for it finishes.
    private func abandonedEnded(_ id: UUID) {
        activity[id] = nil
        // It may have made its file after all.
        refreshFiles()
        guard !preparedForQuit, deleteWhenStopped.remove(id) != nil else { return }
        finishDeleteLater(id)
    }

    // MARK: - Making a reading

    private func started(_ id: UUID) {
        update(id) {
            $0.state = .rendering
            $0.message = nil
        }
        activity[id] = .loading
        save()
        onChange?()
    }

    private func ended(_ id: UUID, _ outcome: ReadingWorkQueue.Outcome) {
        activity[id] = nil
        switch outcome {
        case .finished:
            // Its work returned without making the file (it cannot, but a row must never stay "rendering" or
            // "waiting": a run a quit stopped may end so after the reading was queued again).
            if entry(id)?.isActive == true {
                update(id) { $0.state = .stopped }
            }
        case .failed(let error):
            update(id) {
                $0.state = .failed
                $0.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        case .stopped:
            update(id) {
                $0.state = .stopped
                $0.message = nil
            }
        }
        save()
        onChange?()
        refreshFiles()
        if deleteWhenStopped.remove(id) != nil { finishDeleteLater(id) }
    }

    /// Loads the reading's text (the saved copy, when an earlier run loaded it), fixes its voice and file, and
    /// renders it, resuming from its cache when there is one.
    private func make(_ id: UUID) async throws {
        guard let entry = entry(id) else { return }
        let document = try await loadDocument(entry)
        try Task.checkCancellation()
        let script = ReadingScript(document: document)
        // A declared language that is not a usable tag ("english") is ignored, as in `voiceislocal read`.
        let language = AudioBookMetadata.languageTag(document.language) ?? ReadingLanguage.detect(script.text)
        let voice = try Self.voice(for: entry, language: language)
        let rate = ReadingSpeed.rate(for: entry.speed)
        let metadata = AudioBookMetadata(
            title: [document.title, entry.source.fallbackName].lazy.compactMap(AudioBookMetadata.usableTitle).first,
            author: document.author, language: language)
        let identity = ReadingPipeline.identity(script: script, voiceIdentifier: voice.id, rate: rate, metadata: metadata)
        let name = ReadingOutput.fileName(title: metadata.title, fallback: entry.source.fallbackName)

        // The file: the one chosen when the reading first started, else a new name in the output folder. A name that
        // something else took since (no render cache of this reading, but a file there), or whose cache another
        // reading of the list holds, is replaced by a new one (see `ReadingLibrary.location`). Chosen off the main
        // actor: it looks into the output folder, which may be on a slow share.
        let others = all.filter { $0.id != id }
        let (taken, otherCaches) = (others.compactMap(\.output), others.compactMap(\.cache))
        let (chosen, title, fallback) = (entry.outputURL, metadata.title, entry.source.fallbackName)
        let (folder, isDefault, shown) = (ReadingPreferences.folder, ReadingPreferences.isDefaultFolder,
                                          ReadingPreferences.folderText)
        let support = HolosPaths.supportRoot
        let configured = ProcessInfo.processInfo.environment["HOLOS_SUPPORT_DIR"]
        let (location, resume) = try await offMain { () -> (ReadingLocation, Bool) in
            let readings = try ReadingOutput.readingsRoot(support: support, configured: configured, create: true)
            try FileManager.default.createDirectory(at: readings, withIntermediateDirectories: true)
            let location = try ReadingLibrary.location(
                chosen: chosen, folder: { try ReadingLibrary.outputFolder(folder, isDefault: isDefault, shown: shown) },
                title: title, fallback: fallback, name: name, identity: identity, readingsRoot: readings, taken: taken,
                otherCaches: otherCaches)
            return (location, try ReadingOutput.exists(location.workDirectory))
        }
        try Task.checkCancellation()
        let voiceName = ReadingVoiceMenu.items(NativeSpeechRenderer.voices(), preferredLanguages: [])
            .first { $0.id == voice.id }?.name ?? voice.name
        update(id) {
            $0.title = metadata.title ?? entry.source.label
            $0.voiceIdentifier = voice.id
            $0.voiceName = voiceName
            // The path the pipeline writes and its manifest names (links in the folder resolved), so the entry and
            // the manifest name the file alike even before it is made.
            $0.output = location.output.path
            $0.cache = location.workDirectory.path
        }
        // Nothing is rendered until the index knows where: otherwise a resume after an exit would pick another name
        // and cache, render the reading twice, and leave the first file and cache unknown.
        if writable, !(await saved()) {
            throw HolosError.io("The Reading list could not be saved, so the reading was not started: "
                + (notice ?? "unknown error"))
        }
        onChange?()

        let result = try await ReadingPipeline().render(
            script: script, voiceIdentifier: voice.id, rate: rate, metadata: metadata, location: location,
            resume: resume) { [weak self] progress in self?.progressed(id, progress) }
        update(id) {
            $0.state = .done
            $0.output = result.output.path
            $0.duration = result.manifest.duration
            $0.chapters = result.manifest.chapters.count
            $0.outputSHA256 = result.manifest.outputSHA256
            $0.outputIdentity = result.outputIdentity
            $0.part = nil
            $0.parts = result.manifest.parts.count
            // Bookkeeping that failed after the file was saved (see `ReadingResult.warnings`).
            $0.message = result.warnings.isEmpty ? nil : result.warnings.joined(separator: " ")
        }
        // The saved text goes only once the index says the reading is made (a successful save removes it), or when
        // the index keeps nothing: a reading the index still calls unfinished always has its text to resume from.
        // One kept because the save failed goes after the next save that works (`writeWork`).
        if writable { save() } else { removeFinishedSnapshots() }
        // Its file is checked (off the main actor) for its row; one whose identity could not be read just now (a
        // network volume) is checked by checksum.
        refreshFiles()
    }

    /// The reading's text: the copy saved when it was first loaded, else its source, loaded now and saved before
    /// anything is rendered, so Resume and Try Again read exactly this text. A copy that cannot be saved fails the
    /// reading: without it a resume would load the source again and could read different text.
    private func loadDocument(_ entry: ReadingEntry) async throws -> ReadableDocument {
        // The saved text is read and written off the main actor too: a book's snapshot is megabytes of JSON.
        let store = store
        let id = entry.id
        let saved: ReadableDocument?
        do {
            saved = try await Task.detached(priority: .userInitiated) { try store.document(for: id) }.value
        } catch {
            // Never loaded again in its place: the source may have changed since.
            throw HolosError.io("The text saved for this reading could not be read: \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        if let saved { return saved }
        let document: ReadableDocument
        switch entry.source {
        case .web(let url):
            document = try await WebArticleExtractor().extract(from: url).document
        case .file(let url):
            // Off the main actor, the look-up included (the file may be on a share that stopped answering): a long PDF
            // or Word file takes a while to read, and the window must stay responsive. A Stop cancels it too (a PDF
            // stops between pages).
            let load = Task.detached(priority: .userInitiated) {
                // Looked up as spelled (`FileManager` would decompose the path).
                guard (try? ReadingOutput.exists(url)) == true else {
                    throw HolosError.invalidInput("\(url.lastPathComponent) is no longer at "
                        + "\((url.path as NSString).abbreviatingWithTildeInPath).")
                }
                return try DocumentLoader.load(url)
            }
            document = try await withTaskCancellationHandler { try await load.value } onCancel: { load.cancel() }
        }
        // Stopped while it loaded: nothing is saved for it.
        try Task.checkCancellation()
        do {
            try await Task.detached(priority: .userInitiated) { try store.saveDocument(document, for: id) }.value
        } catch {
            throw HolosError.io("The text to read could not be saved for Resume in \(store.folder.path): "
                + error.localizedDescription)
        }
        return document
    }

    /// The voice the reading was started with; else the one asked for; else the best installed voice for its
    /// language (as `voiceislocal read` picks it).
    static func voice(for entry: ReadingEntry, language: String?) throws -> VoiceDescriptor {
        let voices = NativeSpeechRenderer.voices()
        if let fixed = entry.voiceIdentifier ?? entry.requestedVoice {
            guard let voice = voices.first(where: { $0.id == fixed }) else {
                throw HolosError.unavailable("The voice \(entry.voiceName ?? fixed) is not installed any more. "
                    + "Delete this reading and make it again with another voice.")
            }
            return voice
        }
        let wanted = language ?? Locale.preferredLanguages.first ?? "en-US"
        if let best = NativeSpeechRenderer.bestVoice(language: wanted) { return best }
        let fallback = try NativeSpeechRenderer.defaultVoiceIdentifier()
        guard let voice = voices.first(where: { $0.id == fallback }) else {
            throw HolosError.unavailable("No speech voice is installed. Add one in System Settings › Accessibility › "
                + "Spoken Content › System Voice › Manage Voices.")
        }
        return voice
    }

    private func progressed(_ id: UUID, _ progress: ReadingRenderProgress) {
        switch progress {
        case .rendering(let part, let total):
            activity[id] = .rendering(part: part, of: total)
            update(id) {
                $0.part = part
                $0.parts = total
            }
        case .joining(let parts):
            activity[id] = .joining(parts: parts)
        }
        onProgress?(id)
    }

    // MARK: - Storage
    /// What a Delete came to.
    enum DeleteOutcome: Equatable {
        /// The reading is deleted (or will be once its render has stopped); `note` is something the user should know
        /// (its file had changed, so it was left in place).
        case deleted(note: String?)
        /// The reading stays in the list, for the reason given.
        case kept(String)
    }

    /// Removes a reading marked for deletion once its files are gone; when one cannot be removed, the reading comes
    /// back to the list (unmarked) with the reason. The entry stays marked (hidden, and saved so) while its files are
    /// removed off the main actor; a second call for it meanwhile does nothing.
    private func finishDelete(_ id: UUID) async -> DeleteOutcome {
        guard let entry = entry(id), deleting.insert(id).inserted else { return .deleted(note: nil) }
        defer { deleting.remove(id) }
        activity[id] = nil
        let result = await cleanUp(entry)
        if let problem = result.problem {
            update(id) { $0 = ReadingLibrary.afterFailedDelete($0, problem: problem, aside: result.aside) }
            save()
            return .kept(problem)
        }
        all.removeAll { $0.id == id }
        files[id] = nil
        checksummed[id] = nil
        unreadable[id] = nil
        save()
        clearDeleteNotice(id)
        return .deleted(note: result.note)
    }

    /// `finishDelete` for a deletion nobody waits for (a launch, a render that ended): what it says becomes the notice.
    private func finishDeleteLater(_ id: UUID) {
        Task {
            switch await finishDelete(id) {
            case .kept(let problem):
                notice = problem
                deleteNotices[id] = problem
            case .deleted(let note?):
                notice = note
            case .deleted(nil):
                break
            }
            onChange?()
        }
    }

    /// The notice each reading's failed deletion left, so the one that later succeeds clears it.
    private var deleteNotices: [UUID: String] = [:]

    /// A deletion of `id` succeeded: the notice an earlier failed one left goes, unless something else replaced it.
    private func clearDeleteNotice(_ id: UUID) {
        guard let left = deleteNotices.removeValue(forKey: id), notice == left else { return }
        notice = nil
    }

    /// Removes a reading's files (see `ReadingLibrary.deleteFiles`), off the main actor: its finished file goes to the
    /// Trash.
    private func cleanUp(_ entry: ReadingEntry) async -> ReadingLibrary.DeleteResult {
        let store = store
        return await Task.detached(priority: .userInitiated) {
            let readings: URL
            do {
                readings = try ReadingOutput.readingsRoot(
                    support: HolosPaths.supportRoot, configured: ProcessInfo.processInfo.environment["HOLOS_SUPPORT_DIR"],
                    create: false)
                // The support folder must be there (its volume connected): otherwise the cache and saved text would
                // read as gone while they are only out of reach.
                let support = readings.deletingLastPathComponent()
                guard try ReadingOutput.exists(support) else {
                    throw HolosError.unavailable("\(support.path) is not available.")
                }
            } catch {
                // Without it the cache cannot be told or locked: the entry stays for another try.
                return ReadingLibrary.DeleteResult(
                    problem: "Its rendered parts could not be found: \(error.localizedDescription) Try Delete again.",
                    aside: entry.outputAside)
            }
            return ReadingLibrary.deleteFiles(of: entry, readingsRoot: readings, store: store) { url in
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }.value
    }

    private func update(_ id: UUID, _ change: (inout ReadingEntry) -> Void) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[index])
    }

    // MARK: Writing the index

    /// What one write of the index did: why it failed (nil: saved, or nothing to save), and what removing the saved
    /// texts of made readings after it left to tell.
    private struct WriteResult: Sendable {
        var failure: String?
        var snapshotProblem: String?
    }

    /// Writes of the index and removals of saved texts, off the main actor (the support folder may be on a slow
    /// share), one at a time in the order they were asked for: each writes the list as it was when asked, so the
    /// last one leaves the list as it is.
    private let writes = DispatchQueue(label: "VoiceIsLocal.ReadingIndex", qos: .userInitiated)
    private var writeSequence = 0
    private var appliedSequence = 0

    /// The work of one save of the list as it is now (nil `saving`: only the saved texts are removed). After a save
    /// that works (or with a list that is not saved at all), the saved text of every reading the list records as made
    /// is removed: retried after each save, so one kept because a save or a removal failed goes once they work.
    private func writeWork(saving: Bool, growing: Bool) -> @Sendable () -> WriteResult {
        let (store, entries, readOnly) = (store, all, readOnly)
        return {
            if saving {
                do {
                    try store.save(entries, growing: growing)
                } catch {
                    return WriteResult(failure: error.localizedDescription)
                }
            }
            var problem: String?
            for entry in entries where entry.state == .done && !readOnly.contains(entry.id)
                && store.hasDocument(for: entry.id) {
                do {
                    try store.removeDocument(for: entry.id)
                } catch {
                    problem = "\(Self.snapshotFailure) “\(entry.title)” could not be removed: \(error.localizedDescription)"
                }
            }
            return WriteResult(snapshotProblem: problem)
        }
    }

    /// Queues a write (see `writeWork`); `done` gets whether the list was saved, once it is known, on the main actor.
    private func enqueueWrite(saving: Bool = true, growing: Bool = false,
                              done: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        let saving = saving && writable
        let work = writeWork(saving: saving, growing: growing)
        writeSequence += 1
        let sequence = writeSequence
        writes.async {
            let result = work()
            Task { @MainActor in
                self.apply(result, sequence: sequence)
                done?(saving && result.failure == nil)
            }
        }
    }

    /// What a write that ended says: only the latest one to end counts (an earlier one ending later says nothing).
    private func apply(_ result: WriteResult, sequence: Int) {
        guard sequence > appliedSequence else { return }
        appliedSequence = sequence
        let before = notice
        if let failure = result.failure {
            lastSaveFailed = true
            notice = "\(Self.saveFailure) \(failure)"
        } else {
            if lastSaveFailed {
                lastSaveFailed = false
                if notice?.hasPrefix(Self.saveFailure) == true { notice = nil }
            }
            if let problem = result.snapshotProblem {
                notice = problem
            } else if notice?.hasPrefix(Self.snapshotFailure) == true {
                // All gone now: a warning from an earlier try no longer holds.
                notice = nil
            }
        }
        if notice != before { onChange?() }
    }

    /// Saves the index, off the main actor, without waiting (a list that is not saved is left alone). While a
    /// Delete's mark is being saved (`holdingWrites`), it is saved once that is known instead.
    private func save() {
        guard holdingWrites == 0 else {
            heldSave = true
            return
        }
        enqueueWrite()
    }

    /// Saves the index and waits: false when it was not saved (a list that is not saved, or the write failed).
    /// `growing`: the save adds a reading (see `ReadingLibraryStore.save`). While a Delete's mark is being saved, it
    /// waits until that is known; `holding`: it is that save.
    private func saved(growing: Bool = false, holding: Bool = false) async -> Bool {
        while !holding && holdingWrites > 0 {
            await withCheckedContinuation { heldWaiters.append($0) }
        }
        return await withCheckedContinuation { continuation in
            enqueueWrite(growing: growing) { continuation.resume(returning: $0) }
        }
    }

    /// Saves under way that change a Delete's mark: other saves wait for them (see `save`, `saved`).
    private var holdingWrites = 0
    private var heldSave = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    /// A Delete's mark is saved (or taken back): the saves that waited go now, with the list as it is.
    private func releaseWrites() {
        holdingWrites -= 1
        guard holdingWrites == 0 else { return }
        if heldSave {
            heldSave = false
            enqueueWrite()
        }
        let waiters = heldWaiters
        heldWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Saves the index now, after the writes queued before, and waits for it on the main actor (for a quit, which
    /// cannot wait), at most `quitSaveLimit`: a support folder that does not answer (a share whose server stopped)
    /// makes it a failure, which the quit says, rather than freeze the app.
    private func saveNow() -> Bool {
        guard writable else { return false }
        let work = writeWork(saving: true, growing: false)
        writeSequence += 1
        let sequence = writeSequence
        let outcome = SaveOutcome()
        writes.async { outcome.finish(work()) }
        guard let result = outcome.wait(upTo: Self.quitSaveLimit) else {
            let failure = WriteResult(failure: "its folder did not answer in time.")
            apply(failure, sequence: sequence)
            return false
        }
        apply(result, sequence: sequence)
        return result.failure == nil
    }

    /// How long a quit waits for the index to be saved.
    static let quitSaveLimit: DispatchTimeInterval = .seconds(10)

    /// The result of a write the main actor waits for (see `saveNow`).
    private final class SaveOutcome: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: WriteResult?

        func finish(_ result: WriteResult) {
            lock.lock()
            self.result = result
            lock.unlock()
            done.signal()
        }

        func wait(upTo limit: DispatchTimeInterval) -> WriteResult? {
            guard done.wait(timeout: .now() + limit) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    /// Removes the saved text of the readings the list records as made (see `writeWork`), off the main actor.
    private func removeFinishedSnapshots() {
        enqueueWrite(saving: false)
    }

    /// Saves the index again when a quit with nothing rendering comes (a write may have failed meanwhile), so what
    /// the user did since (a Stop, a Delete) is what the next launch finds. False when it cannot be saved.
    func saveBeforeQuit() -> Bool {
        // Nothing to do when the last write worked and none is under way.
        guard writable, lastSaveFailed || writeSequence > appliedSequence else { return true }
        return saveNow()
    }

    nonisolated static let snapshotFailure = "The saved text of"
}
