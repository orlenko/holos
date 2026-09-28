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
    private var writable = true
    /// Readings of an index a newer Voice is Local wrote: shown, never changed here.
    private var readOnly: Set<UUID> = []
    private var started = false
    /// `prepareForQuit` ran and no quit has been cancelled since.
    private var preparedForQuit = false
    /// Readings to delete once their render has stopped.
    private var deleteWhenStopped: Set<UUID> = []
    /// Readings whose files are being removed (off the main actor), so one is never removed twice at once.
    private var deleting: Set<UUID> = []
    /// Made readings whose file identity is being checked (see `recordMissingIdentities`).
    private var identityChecks: Set<UUID> = []
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
        let loaded = store.load()
        notice = loaded.notice
        writable = loaded.writable
        if !writable { readOnly = Set(loaded.entries.map(\.id)) }
        let plan = ReadingLibrary.launchPlan(loaded)
        // The deletions a quit interrupted stay in the index, marked (hidden), while they finish off the main actor;
        // one whose files cannot be removed comes back, with the reason.
        all = (plan.entries + plan.delete).sorted { $0.created > $1.created }
        if all != loaded.entries { save() }  // never for a newer build's list (`save` checks `writable`)
        // Saved text a made reading still has (its removal failed, or the save before it did) goes now.
        if writable { removeFinishedSnapshots() }
        plan.resume.forEach(queue.enqueue)
        plan.delete.forEach { finishDeleteLater($0.id) }
        recordMissingIdentities()
        onChange?()
    }

    func entry(_ id: UUID) -> ReadingEntry? { all.first { $0.id == id } }

    /// Whether a reading is being made or waits.
    var isBusy: Bool { !queue.isIdle }
    var runningTitle: String? { queue.running.flatMap(entry)?.title }
    var waitingCount: Int { queue.pending.count }

    /// Adds a reading of `source` at the top of the list and queues it. `voice` nil: the best voice for its language.
    @discardableResult
    /// Refused while the list is not saved (its index could not be read, or a newer build wrote it): a reading made
    /// then would leave the list at the next launch while its cache stayed, with no row to delete it from.
    func add(_ source: ReadingSource, voice: String?, speed: Double) throws -> UUID {
        guard writable else {
            throw HolosError.unavailable("New readings are not made while the Reading list cannot be saved"
                + (notice.map { ": \($0)" } ?? "."))
        }
        let entry = ReadingEntry(source: source, requestedVoice: voice, speed: ReadingSpeed.clamped(speed))
        all.insert(entry, at: 0)
        // Nothing is made for a reading the index does not keep: its saved text and cache would have no entry to be
        // found or deleted through after a quit.
        guard save() else {
            all.removeAll { $0.id == entry.id }
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

    /// The reading's finished file when it is still the one it made (the same file identity as when it was made):
    /// what Play, Share…, and Show in Finder use. Nil when it was moved, deleted, or replaced by another file, and
    /// while its identity is unknown (it could not be read when the reading was made; see `recordMissingIdentities`).
    func finishedFile(_ entry: ReadingEntry) -> URL? {
        guard entry.state == .done, let output = entry.outputURL, let made = entry.outputIdentity,
              ExclusivePublisher.FileIdentity.of(output) == made else { return nil }
        return output
    }

    /// Made readings whose file identity is unknown get it once the file at their path is shown to be theirs by its
    /// checksum (read off the main actor); until then they show as missing. Tried at launch and after each make.
    private func recordMissingIdentities() {
        let pending = all.filter {
            $0.state == .done && $0.outputIdentity == nil && $0.outputSHA256 != nil && $0.output != nil
                && $0.deletePending != true && !readOnly.contains($0.id) && !identityChecks.contains($0.id)
        }
        guard !pending.isEmpty else { return }
        identityChecks.formUnion(pending.map(\.id))
        Task {
            for entry in pending {
                defer { identityChecks.remove(entry.id) }
                guard let output = entry.outputURL, let sha256 = entry.outputSHA256 else { continue }
                let identity = await Task.detached(priority: .utility) {
                    ReadingLibrary.verifiedIdentity(of: output, sha256: sha256)
                }.value
                guard let identity, let current = self.entry(entry.id), current.state == .done,
                      current.output == entry.output, current.outputIdentity == nil else { continue }
                update(entry.id) { $0.outputIdentity = identity }
                save()
                onChange?()
            }
        }
    }

    /// Why a made reading's file cannot be used (`finishedFile` is nil).
    enum FileProblem: Equatable {
        /// It was moved, deleted, or replaced by another file.
        case missing
        /// The folder that holds it cannot be reached (its drive or share is not connected): it may come back.
        case unavailable(String)
    }

    /// Nil when the reading is not made, or its file is there (see `finishedFile`).
    func fileProblem(_ entry: ReadingEntry) -> FileProblem? {
        guard entry.state == .done, finishedFile(entry) == nil else { return nil }
        if let output = entry.outputURL, let reason = ReadingOutput.unreachableReason(for: output) {
            return .unavailable(reason)
        }
        return .missing
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
    func delete(_ id: UUID) async -> String? {
        guard !readOnly.contains(id) else { return Self.readOnlyMessage }
        guard entry(id) != nil, !deleting.contains(id) else { return nil }
        update(id) { $0.deletePending = true }
        // Nothing is stopped or removed unless the mark is saved: otherwise the reading would come back at the next
        // launch with its files gone. (A list that is not saved at all keeps nothing to come back.)
        if writable && !save() {
            update(id) { $0.deletePending = nil }
            return "“\(entry(id)?.title ?? "The reading")” was not deleted: "
                + (notice ?? "the Reading list could not be saved.")
        }
        if queue.running == id {
            deleteWhenStopped.insert(id)
            queue.stop(id)
            onChange?()
            return nil
        }
        queue.stop(id)
        onChange?()
        let problem = await finishDelete(id)
        onChange?()
        return problem
    }

    /// Voice is Local quits with readings waiting or being made: `keep` (Keep Rendering) continues them at the next
    /// launch; otherwise (Stop) they are stopped, with Resume. The render in progress is cancelled either way. Returns
    /// whether the saved list now says so (false: the save failed, and the saved list may still say otherwise).
    @discardableResult
    func prepareForQuit(keep: Bool) -> Bool {
        all = ReadingLibrary.forQuit(all, keep: keep)
        // A list that is never saved (a newer build's) keeps no request to continue anything: nothing to save.
        let saved = save() || !writable
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
            // Its work returned without making the file (it cannot, but a row must never stay "rendering").
            if entry(id)?.state == .rendering {
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
        let readings = try ReadingOutput.readingsRoot(support: HolosPaths.supportRoot,
                                                      configured: ProcessInfo.processInfo.environment["HOLOS_SUPPORT_DIR"],
                                                      create: true)
        try FileManager.default.createDirectory(at: readings, withIntermediateDirectories: true)
        let identity = ReadingPipeline.identity(script: script, voiceIdentifier: voice.id, rate: rate, metadata: metadata)
        let name = ReadingOutput.fileName(title: metadata.title, fallback: entry.source.fallbackName)

        // The file: the one chosen when the reading first started, else a new name in the output folder. A name that
        // something else took since (no render cache of this reading, but a file there) is replaced by a new one.
        var output = entry.outputURL
        var location: ReadingLocation?
        if let chosen = output {
            let found = try ReadingOutput.locate(output: chosen.path, name: name, identity: identity,
                                                 readingsRoot: readings, resume: true)
            if try ReadingOutput.exists(found.workDirectory) || !ReadingOutput.exists(found.output) { location = found }
        }
        if location == nil {
            let folder = try Self.outputFolder()
            let taken = Set(all.filter { $0.id != id }.compactMap(\.output))
            let chosen = ReadingLibrary.outputURL(in: folder, title: metadata.title, fallback: entry.source.fallbackName,
                                                  taken: taken) { url in (try? ReadingOutput.exists(url)) ?? true }
            output = chosen
            location = try ReadingOutput.locate(output: chosen.path, name: name, identity: identity,
                                                readingsRoot: readings, resume: false)
        }
        guard let location, output != nil else { return }
        let resume = try ReadingOutput.exists(location.workDirectory)
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
        if writable && !save() {
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
        // One kept because the save failed goes after the next save that works (`removeFinishedSnapshots`).
        if !save() && !writable { removeFinishedSnapshots() }
        // Its identity could not be read just now (a network volume): it is checked by checksum instead.
        recordMissingIdentities()
    }

    /// The folder new files go to. The default one is made when missing; a folder chosen in Settings that is missing
    /// (its disk is not connected) is not, so nothing is written on the startup disk in its place.
    static func outputFolder() throws -> URL {
        let folder = ReadingPreferences.folder
        if ReadingPreferences.isDefaultFolder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } else {
            // `stat` on the path as spelled (`FileManager` would decompose it).
            var metadata = stat()
            guard stat(folder.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw HolosError.unavailable("The folder \(ReadingPreferences.folderText) chosen in Settings › Reading is "
                    + "not available. Connect its disk, or choose another folder there, then Try Again.")
            }
        }
        return folder
    }

    /// The reading's text: the copy saved when it was first loaded, else its source, loaded now and saved before
    /// anything is rendered, so Resume and Try Again read exactly this text. A copy that cannot be saved fails the
    /// reading: without it a resume would load the source again and could read different text.
    private func loadDocument(_ entry: ReadingEntry) async throws -> ReadableDocument {
        let saved: ReadableDocument?
        do {
            saved = try store.document(for: entry.id)
        } catch {
            // Never loaded again in its place: the source may have changed since.
            throw HolosError.io("The text saved for this reading could not be read: \(error.localizedDescription)")
        }
        if let saved { return saved }
        let document: ReadableDocument
        switch entry.source {
        case .web(let url):
            document = try await WebArticleExtractor().extract(from: url).document
        case .file(let url):
            // Looked up as spelled (`FileManager` would decompose the path).
            guard (try? ReadingOutput.exists(url)) == true else {
                throw HolosError.invalidInput("\(url.lastPathComponent) is no longer at \((url.path as NSString).abbreviatingWithTildeInPath).")
            }
            // Off the main actor: a long PDF or Word file takes a while to read, and the window must stay responsive.
            // A Stop cancels it too (a PDF stops between pages).
            let load = Task.detached(priority: .userInitiated) { try DocumentLoader.load(url) }
            document = try await withTaskCancellationHandler { try await load.value } onCancel: { load.cancel() }
        }
        // Stopped while it loaded: nothing is saved for it.
        try Task.checkCancellation()
        do {
            try store.saveDocument(document, for: entry.id)
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

    /// Removes a reading marked for deletion once its files are gone; when one cannot be removed, the reading comes
    /// back to the list (unmarked) and the problem is returned. The entry stays marked (hidden, and saved so) while
    /// its files are removed off the main actor; a second call for it meanwhile does nothing.
    private func finishDelete(_ id: UUID) async -> String? {
        guard let entry = entry(id), deleting.insert(id).inserted else { return nil }
        defer { deleting.remove(id) }
        activity[id] = nil
        let result = await cleanUp(entry)
        if let problem = result.problem {
            update(id) { $0 = ReadingLibrary.afterFailedDelete($0, problem: problem, aside: result.aside) }
            save()
            return problem
        }
        all.removeAll { $0.id == id }
        save()
        clearDeleteNotice(id)
        return nil
    }

    /// `finishDelete` for a deletion nobody waits for (a launch, a render that ended): a problem becomes the notice.
    private func finishDeleteLater(_ id: UUID) {
        Task {
            if let problem = await finishDelete(id) {
                notice = problem
                deleteNotices[id] = problem
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

    /// Saves the index; false when it was not saved (a newer build's list, or the write failed).
    @discardableResult
    private func save() -> Bool {
        guard writable else { return false }
        do {
            try store.save(all)
            if lastSaveFailed {
                lastSaveFailed = false
                if notice?.hasPrefix(Self.saveFailure) == true { notice = nil }
            }
            removeFinishedSnapshots()
            return true
        } catch {
            lastSaveFailed = true
            notice = "\(Self.saveFailure) \(error.localizedDescription)"
            return false
        }
    }

    /// Saves the index again if the last save failed (a quit with nothing rendering), so what the user did since
    /// (a Stop, a Delete) is what the next launch finds. False when it still cannot be saved.
    func saveBeforeQuit() -> Bool {
        guard writable, lastSaveFailed else { return true }
        return save()
    }

    /// Removes the saved text of every reading the index (as just saved, or as never saved at all) records as made:
    /// retried after each save, so one kept because a save or a removal failed goes once they work. A removal that
    /// fails is shown and tried again after the next save.
    private func removeFinishedSnapshots() {
        var failed = false
        for entry in all where entry.state == .done && !readOnly.contains(entry.id) && store.hasDocument(for: entry.id) {
            do {
                try store.removeDocument(for: entry.id)
            } catch {
                failed = true
                notice = "\(Self.snapshotFailure) “\(entry.title)” could not be removed: \(error.localizedDescription)"
            }
        }
        // All gone now: a warning from an earlier try no longer holds.
        if !failed, notice?.hasPrefix(Self.snapshotFailure) == true { notice = nil }
    }

    static let snapshotFailure = "The saved text of"
}
