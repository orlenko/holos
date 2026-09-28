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

    /// Newest first.
    private(set) var entries: [ReadingEntry] = []
    /// What the list should say about its index (see `ReadingLibraryStore.load`).
    private(set) var notice: String?
    private(set) var activity: [UUID: Activity] = [:]
    /// The list changed (a reading added, removed, or changing state).
    var onChange: (() -> Void)?
    /// One reading's progress changed.
    var onProgress: ((UUID) -> Void)?

    private let store = ReadingLibraryStore.standard()
    private var writable = true
    private var started = false
    /// Readings to delete once their render has stopped.
    private var deleteWhenStopped: Set<UUID> = []
    private lazy var queue: ReadingWorkQueue = {
        let queue = ReadingWorkQueue { [weak self] id in try await self?.make(id) }
        queue.onStart = { [weak self] id in self?.started(id) }
        queue.onEnd = { [weak self] id, outcome in self?.ended(id, outcome) }
        return queue
    }()

    /// Reads the list and continues the readings kept over the last quit. Once.
    func start() {
        guard !started else { return }
        started = true
        let loaded = store.load()
        notice = loaded.notice
        writable = loaded.writable
        let (recovered, resume) = ReadingLibrary.afterLaunch(loaded.entries)
        entries = recovered.sorted { $0.created > $1.created }
        if recovered != loaded.entries { save() }
        resume.forEach(queue.enqueue)
        onChange?()
    }

    func entry(_ id: UUID) -> ReadingEntry? { entries.first { $0.id == id } }

    /// Whether a reading is being made or waits.
    var isBusy: Bool { !queue.isIdle }
    var runningTitle: String? { queue.running.flatMap(entry)?.title }
    var waitingCount: Int { queue.pending.count }

    /// Adds a reading of `source` at the top of the list and queues it. `voice` nil: the best voice for its language.
    @discardableResult
    func add(_ source: ReadingSource, voice: String?, speed: Double) -> UUID {
        let entry = ReadingEntry(source: source, requestedVoice: voice, speed: ReadingSpeed.clamped(speed))
        entries.insert(entry, at: 0)
        save()
        onChange?()
        queue.enqueue(entry.id)
        return entry.id
    }

    /// Stop: a waiting reading leaves the queue, a running one is cancelled; either keeps what it rendered for Resume.
    func stop(_ id: UUID) {
        queue.stop(id)
    }

    /// Try Again or Resume: queues a failed or stopped reading again; its rendered parts are reused.
    func retry(_ id: UUID) {
        guard let entry = entry(id), entry.state == .failed || entry.state == .stopped else { return }
        update(id) {
            $0.state = .queued
            $0.message = nil
        }
        save()
        onChange?()
        queue.enqueue(id)
    }

    /// Deletes a reading: its `.m4a` goes to the Trash, and its render cache and saved text are removed. A reading
    /// being made is stopped first. Returns a problem to show, if the file could not be moved.
    func delete(_ id: UUID) -> String? {
        guard entry(id) != nil else { return nil }
        if queue.running == id {
            deleteWhenStopped.insert(id)
            queue.stop(id)
            return nil
        }
        queue.stop(id)
        let problem = remove(id)
        onChange?()
        return problem
    }

    /// Voice is Local quits with readings waiting or being made: `keep` (Keep Rendering) continues them at the next
    /// launch; otherwise (Stop) they are stopped, with Resume. The render in progress is cancelled either way.
    func prepareForQuit(keep: Bool) {
        entries = ReadingLibrary.forQuit(entries, keep: keep)
        save()
        queue.shutDown()
        activity.removeAll()
    }

    /// The quit was cancelled after `prepareForQuit` (a meeting's question was answered Cancel): the readings kept
    /// for the next launch continue now.
    func quitCancelled() {
        let (recovered, resume) = ReadingLibrary.afterLaunch(entries)
        queue.reopen()
        entries = recovered
        save()
        resume.forEach(queue.enqueue)
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
        if deleteWhenStopped.remove(id) != nil {
            if let problem = remove(id) { notice = problem }
            onChange?()
            return
        }
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
            let folder = ReadingPreferences.folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let taken = Set(entries.filter { $0.id != id }.compactMap(\.output))
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
        save()
        onChange?()

        let result = try await ReadingPipeline().render(
            script: script, voiceIdentifier: voice.id, rate: rate, metadata: metadata, location: location,
            resume: resume) { [weak self] progress in self?.progressed(id, progress) }
        update(id) {
            $0.state = .done
            $0.output = result.output.path
            $0.duration = result.manifest.duration
            $0.chapters = result.manifest.chapters.count
            $0.part = nil
            $0.parts = result.manifest.parts.count
            // Bookkeeping that failed after the file was saved (see `ReadingResult.warnings`).
            $0.message = result.warnings.isEmpty ? nil : result.warnings.joined(separator: " ")
        }
        store.removeDocument(for: id)
    }

    private func loadDocument(_ entry: ReadingEntry) async throws -> ReadableDocument {
        if let saved = store.document(for: entry.id) { return saved }
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
        // Without the copy a resume loads the source again, which refuses a page whose text changed.
        try? store.saveDocument(document, for: entry.id)
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

    /// Removes the reading and its files: the `.m4a` of a finished reading goes to the Trash; the render cache is
    /// removed only when it is one the pipeline made in the support folder.
    private func remove(_ id: UUID) -> String? {
        guard let entry = entry(id) else { return nil }
        var problem: String?
        if entry.state == .done, let output = entry.outputURL, FileManager.default.fileExists(atPath: output.path) {
            do {
                try FileManager.default.trashItem(at: output, resultingItemURL: nil)
            } catch {
                problem = "\(output.lastPathComponent) could not be moved to the Trash: \(error.localizedDescription)"
            }
        }
        if let cache = entry.cache,
           let readings = try? ReadingOutput.readingsRoot(support: HolosPaths.supportRoot,
                                                          configured: ProcessInfo.processInfo.environment["HOLOS_SUPPORT_DIR"],
                                                          create: false),
           ReadingLibrary.isRenderCache(cache, in: readings) {
            try? FileManager.default.removeItem(atPath: cache)
        }
        store.removeDocument(for: id)
        entries.removeAll { $0.id == id }
        activity[id] = nil
        save()
        return problem
    }

    private func update(_ id: UUID, _ change: (inout ReadingEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }

    private func save() {
        guard writable else { return }
        do {
            try store.save(entries)
        } catch {
            notice = "The Reading list could not be saved: \(error.localizedDescription)"
        }
    }
}
