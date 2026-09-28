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
                return URL(fileURLWithPath: path, isDirectory: true)
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
        var entries = plan.entries
        for entry in plan.delete {
            // One whose files cannot be removed comes back, with the reason.
            if let problem = cleanUp(entry) {
                notice = problem
                entries.append(ReadingLibrary.afterFailedDelete(entry, problem: problem))
            }
        }
        all = entries.sorted { $0.created > $1.created }
        if all != loaded.entries { save() }  // never for a newer build's list (`save` checks `writable`)
        plan.resume.forEach(queue.enqueue)
        onChange?()
    }

    func entry(_ id: UUID) -> ReadingEntry? { all.first { $0.id == id } }

    /// Whether a reading is being made or waits.
    var isBusy: Bool { !queue.isIdle }
    var runningTitle: String? { queue.running.flatMap(entry)?.title }
    var waitingCount: Int { queue.pending.count }

    /// Adds a reading of `source` at the top of the list and queues it. `voice` nil: the best voice for its language.
    @discardableResult
    func add(_ source: ReadingSource, voice: String?, speed: Double) -> UUID {
        let entry = ReadingEntry(source: source, requestedVoice: voice, speed: ReadingSpeed.clamped(speed))
        all.insert(entry, at: 0)
        save()
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
    /// what Play, Share…, and Show in Finder use. Nil when it was moved, deleted, or replaced by another file.
    func finishedFile(_ entry: ReadingEntry) -> URL? {
        guard entry.state == .done, let output = entry.outputURL,
              let current = ExclusivePublisher.FileIdentity.of(output) else { return nil }
        if let made = entry.outputIdentity { return current == made ? output : nil }
        return output
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
    func delete(_ id: UUID) -> String? {
        guard !readOnly.contains(id) else { return Self.readOnlyMessage }
        guard entry(id) != nil else { return nil }
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
        let problem = finishDelete(id)
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
            if let problem = finishDelete(id) { notice = problem }
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
        if let problem = finishDelete(id) { notice = problem }
        onChange?()
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
        if deleteWhenStopped.remove(id) != nil, let problem = finishDelete(id) { notice = problem }
        save()
        onChange?()
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
        var output = entry.output.map { URL(fileURLWithPath: $0) }
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
        guard let location, let output else { return }
        let resume = try ReadingOutput.exists(location.workDirectory)
        let voiceName = ReadingVoiceMenu.items(NativeSpeechRenderer.voices(), preferredLanguages: [])
            .first { $0.id == voice.id }?.name ?? voice.name
        update(id) {
            $0.title = metadata.title ?? entry.source.label
            $0.voiceIdentifier = voice.id
            $0.voiceName = voiceName
            $0.output = output.path
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
            $0.outputIdentity = ExclusivePublisher.FileIdentity.of(result.output)
            $0.part = nil
            $0.parts = result.manifest.parts.count
            // Bookkeeping that failed after the file was saved (see `ReadingResult.warnings`).
            $0.message = result.warnings.isEmpty ? nil : result.warnings.joined(separator: " ")
        }
        // The saved text goes only once the index says the reading is made (or keeps nothing of it): a reading the
        // index still calls unfinished always has its text to resume from. One that stays is removed with the reading.
        if save() || !writable { try? store.removeDocument(for: id) }
    }

    /// The folder new files go to. The default one is made when missing; a folder chosen in Settings that is missing
    /// (its disk is not connected) is not, so nothing is written on the startup disk in its place.
    static func outputFolder() throws -> URL {
        let folder = ReadingPreferences.folder
        if ReadingPreferences.isDefaultFolder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } else {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
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
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw HolosError.invalidInput("\(url.lastPathComponent) is no longer at \((url.path as NSString).abbreviatingWithTildeInPath).")
            }
            document = try DocumentLoader.load(url)
        }
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
    /// back to the list (unmarked) and the problem is returned.
    private func finishDelete(_ id: UUID) -> String? {
        guard let entry = entry(id) else { return nil }
        activity[id] = nil
        if let problem = cleanUp(entry) {
            update(id) { $0 = ReadingLibrary.afterFailedDelete($0, problem: problem) }
            save()
            return problem
        }
        all.removeAll { $0.id == id }
        save()
        return nil
    }

    /// Removes a reading's files (see `ReadingLibrary.deleteFiles`): its finished file goes to the Trash. Nil when
    /// all are gone.
    private func cleanUp(_ entry: ReadingEntry) -> String? {
        let readings = try? ReadingOutput.readingsRoot(support: HolosPaths.supportRoot,
                                                       configured: ProcessInfo.processInfo.environment["HOLOS_SUPPORT_DIR"],
                                                       create: false)
        return ReadingLibrary.deleteFiles(of: entry, readingsRoot: readings, store: store) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
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
            return true
        } catch {
            lastSaveFailed = true
            notice = "\(Self.saveFailure) \(error.localizedDescription)"
            return false
        }
    }
}
