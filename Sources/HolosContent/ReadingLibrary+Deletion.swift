import Foundation
import HolosCore
import HolosSynthesis

extension ReadingLibrary {
    /// Whether `path` is a render cache the pipeline made in `readingsRoot` for a reading with an explicit output
    /// (`Output-` and 16 lowercase hex digits, directly inside it): the only kind of folder Delete removes, whatever
    /// the index says.
    public static func isRenderCache(_ path: String, in readingsRoot: URL) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().path == readingsRoot.standardizedFileURL.path else { return false }
        let name = url.lastPathComponent
        let prefix = "Output-"
        guard name.hasPrefix(prefix) else { return false }
        let digest = name.dropFirst(prefix.count)
        return digest.count == 16 && digest.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
    }

    /// What a removal of one of the reading's files left to tell: the problem (nil when the file is gone), and where a
    /// file it moved aside to check stayed because it could not be put back.
    struct RemovalReport: Equatable {
        var problem: String?
        var keptAt: String?
    }

    /// Moves the reading's finished file at `output` to the Trash only once it is the very file that was checked:
    /// it is first moved into a private folder beside it (same volume, same name), where nothing else can take its
    /// place, then checked against `checksums`, then given to `trash`. A file that no longer matches, or that `trash`
    /// refuses, goes back to `output` (never over something put there meanwhile). `token` names the private folder
    /// (see `asideToken`).
    static func trashVerified(_ output: URL, checksums: [String], token: String? = nil,
                              trash: (URL) throws -> Void) -> RemovalReport {
        let name = output.lastPathComponent
        // A file that cannot be read is a failure (it goes back), never "not the reading's".
        let removal = ExclusivePublisher.removeVerified(output, token: token, matches: { staged in
            checksums.contains(try fileSHA256(staged))
        }, dispose: trash)
        return report(removal, name: name, action: "moved to the Trash", reportChanged: true)
    }

    /// Removes the copy into `output` that a crash cut off, only while it is that very file (`identity`), through
    /// the same move-aside-then-check step as the finished file. No problem when it is gone: one replaced by another
    /// file since is gone too (the other file is left alone). `token` names the place aside (see `asideToken`).
    /// `dispose` takes the file (default: removed; a Delete moves it to the Trash, so a file that only looked like a
    /// cut-off copy, the finished one shortened in place, can still be had back).
    static func removePartial(_ output: URL, identity: ReadingFileIdentity, token: String? = nil,
                              dispose: (URL) throws -> Void = ExclusivePublisher.removeFile) -> RemovalReport {
        report(ExclusivePublisher.removeIfIdentical(output, to: identity, token: token, dispose: dispose),
               name: "The partly written \(output.lastPathComponent)", action: "removed", reportChanged: false)
    }

    /// What to tell about a removal of the reading's file `name`. One that no longer matches (a file put there
    /// since) is left alone; it is a problem when `reportChanged` (the Trash: the user expects the file gone) or when
    /// it could not be put back.
    private static func report(_ removal: ExclusivePublisher.Removal, name: String, action: String,
                               reportChanged: Bool) -> RemovalReport {
        func kept(_ path: String?) -> String { path.map { " It is kept at \($0)." } ?? "" }
        switch removal {
        case .removed, .absent:
            return RemovalReport()
        case .notMatching(let keptAt):
            guard reportChanged || keptAt != nil else { return RemovalReport() }
            return RemovalReport(problem: "\(name) changed before it could be \(action), so it was left in place."
                                    + kept(keptAt), keptAt: keptAt)
        case .failed(let reason, let keptAt):
            return RemovalReport(problem: "\(name) could not be \(action): \(reason)"
                                    + (reason.hasSuffix(".") ? "" : ".") + kept(keptAt), keptAt: keptAt)
        }
    }

    /// The private folder beside its file that a reading's Delete moves the file into (under its own name):
    /// `.holos-delete-<entry ID>` for the finished file, that plus ".partial" for the partly written copy. Derived
    /// from the entry, so a Delete that a quit or a crash cut off after the move finds the file there next time.
    static func asideToken(_ id: UUID, partial: Bool) -> String {
        ExclusivePublisher.removalPrefix + id.uuidString + (partial ? ".partial" : "")
    }

    /// Where a Delete of `entry` may have left its file aside: the places `asideToken` names beside its output, the
    /// one its render moves a partly written file into to remove it (`ReadingTemporaries.publicationAside`), and
    /// `outputAside`.
    static func asideCandidates(of entry: ReadingEntry) -> [URL] {
        guard let output = entry.outputURL else { return [] }
        let folder = output.deletingLastPathComponent()
        var candidates = [false, true].map { partial in
            RawFilePath.appending(output.lastPathComponent,
                                  to: RawFilePath.appending(asideToken(entry.id, partial: partial), to: folder))
        }
        if let cache = entry.cache {
            candidates.append(ReadingTemporaries.publicationAside(
                output: output, key: ReadingTemporaries.key(for: URL(fileURLWithPath: cache, isDirectory: true))))
        }
        if let recorded = entry.outputAside,
           !candidates.contains(where: { $0.path.utf8.elementsEqual(recorded.utf8) }) {
            candidates.append(ReadingOutput.fileURL(keepingSpelling: recorded))
        }
        return candidates
    }

    /// What `deleteFiles` did: nil `problem` when every file is gone; otherwise the problems, and `aside`, where a
    /// file of the reading (or one that could not be told) stays after it was moved aside and could not be put back,
    /// for the entry to keep (`ReadingEntry.outputAside`) so the next Delete deals with it.
    public struct DeleteResult: Sendable, Equatable {
        public var problem: String?
        public var aside: String?
        /// With no problem: something to tell although the reading is deleted (its file had changed since it was
        /// made, so it was left in place).
        public var note: String?

        public init(problem: String? = nil, aside: String? = nil, note: String? = nil) {
            self.problem = problem
            self.aside = aside
            self.note = note
        }
    }

    /// Removes a deleted reading's files. Only the reading's own output is touched (see `ownership`): its finished
    /// file goes to `trash`, a copy a crash cut off is removed, and anything else at that path is left alone; the
    /// same, first, for a file an earlier Delete left aside (`asideCandidates`). While such a file is still there the
    /// render cache stays, since its manifest is what identifies the file next time. The cache is removed only when
    /// it is one the pipeline made directly in `readingsRoot` (`isRenderCache`); then the saved text is removed. A
    /// cache or text that cannot be looked up (not "not there") is a problem, so the entry stays for another try.
    ///
    /// All of it happens holding the cache's render lock (`ReadingDirectoryLock`), so a render of the same cache in
    /// another process (`voiceislocal read --resume`) never has its cache removed under it, nor publishes a file
    /// after it was checked for: while one runs, nothing is removed and the entry stays.
    public static func deleteFiles(of entry: ReadingEntry, readingsRoot: URL?, store: ReadingLibraryStore,
                                   trash: (URL) throws -> Void) -> DeleteResult {
        let keep = { (problem: String) in DeleteResult(problem: problem, aside: entry.outputAside) }
        var lock: ReadingDirectoryLock?
        if let cache = entry.cache, let readingsRoot, isRenderCache(cache, in: readingsRoot) {
            let directory = URL(fileURLWithPath: cache, isDirectory: true)
            do {
                // No Readings folder, no cache and no render to wait for.
                if try ReadingOutput.exists(directory.deletingLastPathComponent()) {
                    lock = try ReadingDirectoryLock.acquire(for: directory)
                }
            } catch let error as HolosError {
                if case .unavailable = error {
                    return keep("It is being made by another process (voiceislocal read); stop that first, then "
                        + "Delete again.")
                }
                return keep("Its rendered parts in \(cache) could not be checked: \(error.localizedDescription) "
                    + "Try Delete again.")
            } catch {
                return keep("Its rendered parts in \(cache) could not be checked: \(error.localizedDescription) "
                    + "Try Delete again.")
            }
        }
        return withExtendedLifetime(lock) {
            deleteFilesLocked(of: entry, readingsRoot: readingsRoot, store: store, trash: trash)
        }
    }

    private static func deleteFilesLocked(of entry: ReadingEntry, readingsRoot: URL?, store: ReadingLibraryStore,
                                          trash: (URL) throws -> Void) -> DeleteResult {
        var problems: [String] = []
        var aside: String?
        var note: String?
        if let output = entry.outputURL {
            let cache = entry.cache.map { URL(fileURLWithPath: $0, isDirectory: true) }
            let owned: OutputOwnership?
            let evidence: Evidence
            do {
                let made = entry.state == .done
                owned = try ownership(of: output, sha256: entry.outputSHA256, cache: cache, made: made)
                evidence = try ownershipEvidence(of: output, sha256: entry.outputSHA256, cache: cache, made: made)
            } catch let unreachable as OutputUnreachable {
                // Kept whole (row, cache, text) until the file can be looked for again.
                return DeleteResult(problem: "\(unreachable.file) is unavailable: \(unreachable.reason). "
                                        + "Connect it, then Delete again.", aside: entry.outputAside)
            } catch {
                return DeleteResult(problem: "\(output.lastPathComponent) could not be checked: "
                                        + "\(error.localizedDescription) Try Delete again.", aside: entry.outputAside)
            }
            for candidate in asideCandidates(of: entry) where aside == nil {
                let report = removeAside(candidate, evidence: evidence, trash: trash)
                if let problem = report.problem {
                    problems.append(problem)
                    aside = report.keptAt ?? candidate.path
                }
            }
            if aside == nil {
                // Only ever the entry's own place aside, which the next Delete looks in (a quit or a crash may come
                // before anything records where the file went); something still there (that could not be removed)
                // stops the Delete rather than send the file somewhere no later Delete would find it.
                func blocked(partial: Bool) -> String? {
                    let token = asideToken(entry.id, partial: partial)
                    let place = RawFilePath.appending(token, to: output.deletingLastPathComponent())
                    guard (try? ReadingOutput.exists(place)) != false else { return nil }
                    return "\(output.lastPathComponent) was not moved: \(place.path), left by an earlier Delete, is in "
                        + "the way. Remove it in Finder, then Delete again."
                }
                let report: RemovalReport
                switch owned {
                case .finished? where blocked(partial: false) != nil:
                    report = RemovalReport(problem: blocked(partial: false))
                case .partial? where blocked(partial: true) != nil:
                    report = RemovalReport(problem: blocked(partial: true))
                case .finished?:
                    report = trashVerified(output, checksums: evidence.checksums,
                                           token: asideToken(entry.id, partial: false), trash: trash)
                case .partial(let identity)?:
                    report = removePartial(output, identity: identity, token: asideToken(entry.id, partial: true),
                                           dispose: trash)
                case nil:
                    // A look-up that fails (not "nothing there") tells nothing: the reading stays for another try.
                    let present: Bool
                    do {
                        present = try ReadingOutput.exists(output)
                    } catch {
                        return DeleteResult(problem: "\(output.lastPathComponent) could not be checked: "
                                                + "\(error.localizedDescription) Try Delete again.", aside: entry.outputAside)
                    }
                    // Or a copy it began is named (as large as the finished file: it cannot be told from that
                    // file edited since).
                    if present, entry.state != .done, !evidence.checksums.isEmpty || evidence.publishing != nil {
                        // An unfinished reading whose manifest holds the finished file's checksum was being saved
                        // when it stopped: the file there may be the one it began (created before its identity was
                        // saved). It cannot be told, so the reading stays until the user decides.
                        report = RemovalReport(problem: "A file is at \(output.path), where this reading was being "
                            + "saved when it stopped, and it cannot be told whether it is this reading's. Remove it in "
                            + "Finder if it is, then Delete again.")
                    } else {
                        report = RemovalReport()
                        // A made reading's file that is there but no longer matches (edited in place, or replaced)
                        // is left alone, and said so: Delete promised to move it to the Trash.
                        if present, entry.state == .done {
                            note = "\(output.lastPathComponent) changed since it was made, so it was left in place at "
                                + "\((output.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)."
                        }
                    }
                }
                if let problem = report.problem {
                    problems.append(problem)
                    aside = report.keptAt
                }
            }
        }
        if problems.isEmpty, let cache = entry.cache, let readingsRoot, isRenderCache(cache, in: readingsRoot) {
            // The joined files a render a quit or a crash cut off left beside the output (hidden, named after this
            // cache, whose lock is held: no run of it is under way). The cache (whose key names them) stays until
            // they are gone, or while the folder that holds them cannot be reached.
            if let output = entry.outputURL {
                let directory = URL(fileURLWithPath: cache, isDirectory: true)
                if let reason = ReadingOutput.unreachableReason(for: output) {
                    // Only a render that got to joining leaves something there: every part rendered.
                    if mayHaveJoined(cache: directory) {
                        problems.append("\(output.deletingLastPathComponent().lastPathComponent) is unavailable: "
                            + "\(reason), and what its render left there cannot be removed. Connect it, then Delete "
                            + "again.")
                    }
                } else if let problem = ReadingTemporaries.sweepJoins(outputFolder: output.deletingLastPathComponent(),
                                                                      key: ReadingTemporaries.key(for: directory),
                                                                      currentRun: UUID()) {
                    problems.append(problem)
                }
            }
        }
        if problems.isEmpty, let cache = entry.cache, let readingsRoot, isRenderCache(cache, in: readingsRoot) {
            do {
                let directory = URL(fileURLWithPath: cache, isDirectory: true)
                // Not found is "gone" only where its folder can be reached (the support drive may have gone away
                // since the Delete began).
                if let reason = ReadingOutput.unreachableReason(for: directory) {
                    throw HolosError.unavailable("its folder is unavailable: \(reason).")
                }
                if try ReadingOutput.exists(directory) {
                    try FileManager.default.removeItem(atPath: cache)
                }
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Gone meanwhile.
            } catch {
                problems.append("Its rendered parts in \(cache) could not be removed: \(error.localizedDescription)")
            }
        }
        if problems.isEmpty {
            do {
                try store.removeDocument(for: entry.id)
            } catch {
                problems.append("Its saved text could not be removed: \(error.localizedDescription)")
            }
        }
        return problems.isEmpty ? DeleteResult(note: note)
            : DeleteResult(problem: problems.joined(separator: " ") + " Try Delete again.", aside: aside)
    }

    /// Whether a render of the cache may have got to joining its parts (and left a joined file beside the output):
    /// its manifest says every part is rendered, or it cannot be read. A cache that is not there made nothing.
    static func mayHaveJoined(cache: URL) -> Bool {
        let url = cache.appendingPathComponent(ReadingManifest.fileName)
        guard (try? ReadingOutput.exists(cache)) != false else { return false }
        guard let data = try? readSmallFile(url, maximumBytes: ReadingManifest.maximumBytes),
              let manifest = try? JSONDecoder().decode(ReadingManifest.self, from: data) else { return true }
        return manifest.parts.allSatisfy { $0.status == "complete" }
    }

    /// A file an earlier Delete may have moved aside and left at `url`: moved to the Trash when it is the finished
    /// file, removed when it is the partly written copy. One that is neither (changed since, or another file that
    /// Delete moved aside and could not put back) is left there and is a problem, so the entry keeps pointing at it
    /// until the user deals with it. It is in a place only a Delete of this reading uses, so nothing else takes its
    /// place between the check and the removal. The private folder it was in goes once empty.
    static func removeAside(_ url: URL, evidence: Evidence,
                            trash: (URL) throws -> Void) -> RemovalReport {
        do {
            if try ReadingOutput.exists(url) {
                if !evidence.checksums.isEmpty, evidence.checksums.contains(try fileSHA256(url)) {
                    try trash(url)
                } else if try evidence.isPartial(url) {
                    // To the Trash too: it may be the finished file shortened in place (see `removePartial`).
                    try trash(url)
                } else {
                    return RemovalReport(problem: "An earlier Delete left \(url.lastPathComponent) at \(url.path), and "
                                            + "it is not this reading's file as it was made. Move it back or remove it "
                                            + "in Finder, then Delete again.", keptAt: url.path)
                }
            }
        } catch {
            return RemovalReport(problem: "\(url.lastPathComponent), left at \(url.path) by an earlier Delete, could "
                                    + "not be removed: \(error.localizedDescription)", keptAt: url.path)
        }
        let folder = url.deletingLastPathComponent()
        if folder.lastPathComponent.hasPrefix(ExclusivePublisher.removalPrefix) {
            _ = rmdir(RawFilePath.system(folder))
        }
        return RemovalReport()
    }
}
