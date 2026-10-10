# HolosStorage

Durable files: the session folder (`<id>.holos`), its locks, and the global stores under Application Support.

**Owns**
- Paths inside a session: `SessionPaths` (one function per file; `docs/meeting/session-format.md §2.1`), plus
  `ScreenContextStore`'s `screen/` paths.
- Session folder names (`SessionFolderNames.swift`): `SessionPaths.folder(for:in:)` / `folderName(for:)` build
  `<id>.holos`; `parse(folderName:)` reads the ID back only from an `<uppercase UUID>.holos` name, the only form
  Holos creates; `isSessionFolderName` and `isListedSessionFolderName` also accept folders a user renamed, so they
  are still listed, found, deletable and reached through `AtomicFile.openFolder`.
- Versioned JSON reads (`VersionedFile.swift`): `VersionedFile<T: ValidatedDecodable>` and `SchemaVersion`.
- Safe file operations: `AtomicFile` (`write`, `create`, `append`, `readJSON`, `readIfPresent`, `removeTree`, …) and
  `AtomicFile.openFolder` in `FolderChain.swift` (every folder opened with `O_NOFOLLOW` from the session folder
  down), `ChunkFile` (reading finalized audio chunks).
- `SessionArchive` (an actor, plus static recovery functions): the only writer of an archive's `manifest.json`,
  `events.jsonl` and transcript revisions, under the writer lock (the recorder's archive, or maintenance through
  `withMaintenanceArchive(at:lease:)`, which wraps `openForMaintenance(at:lease:)` and releases the lock however its
  body ends, and `recover(at:lease:)`). `TranscriptPointer` (`transcripts/current.json`).
  `SessionManifest.audioFingerprint(track:)`: a stable hash of a track's chunk list, which echo analysis and
  evaluation runs store to tell whether the audio changed.
- Locks (`SessionLocks.swift`): `.writer.lock`, `ProcessingLease` on `.processing.lock`, `withSpeakerLock` /
  `withSpeakerLockAsync` on `.speakers.lock`.
- Stores: `SessionSpeakerStore` (runs, head, edit journal, voice data, recognition), `SpeakerProfileStore`
  (people database and forget journal), `DictationHistoryStore` / `DictationHistoryService`, `WordListStore`,
  `ScreenContextStore`, `SessionDeletion` (Delete Audio, Delete Meeting), `FreeSpaceProvider`.
- `corrections.json` (`CorrectionsFile.swift`): `CorrectionList.defaultURL`, `load(from:)`, `save(to:)`, and
  `update(at:_:)` / `withFileLock(for:_:)` under its `flock` on `corrections.json.lock`; `FolderWatcher`, which tells
  the app when the folder's files change. The list itself (`CorrectionList`) is a HolosCore value.

**Must not own:** transcript interpretation, capture, speaker algorithms, UI.

**Depends on:** HolosCore. Darwin, Synchronization, CryptoKit, AudioToolbox.

**Invariants** (`docs/conventions.md §1.6`, `docs/conventions.md §1.7`)
- This target writes its data files through `AtomicFile`: a write is atomic (temporary file, fsync, rename, folder
  fsync). A failed append tries to truncate back to the old size, but if that truncation fails too it only logs
  and rethrows, and a crash mid-append can also leave a partial line, so every journal reader tolerates a torn
  last line: `events.jsonl` and `speakers/edits.jsonl` skip it and report `tornTail` (and appenders cut it off,
  keeping a backup, before the next append), the forget journal skips it and starts the next line after it, and
  dictation history counts it as unreadable. Not covered by `AtomicFile`: audio chunks, which HolosAudio streams
  into files as it records (finalized and checked when closed), and `corrections.json`, which `CorrectionList.save(to:)` writes
  with `Data.write(options: .atomic)`.
- Locks are `flock`, one open file description per holder, **not re-entrant**. Waited-on locks are taken in the
  order speakers → profiles. `…Locked` functions document "caller holds the … lock".
- HolosStorage opens folders inside a session through `AtomicFile.openFolder`, which follows no symbolic link
  (threat model: `docs/conventions.md §1.7`). One listing by path remains: `SessionDeletion` lists
  `eval/review` with `FileManager`, then removes through `removeTree`. Code outside this target that opens session
  files by path (such as `AVAudioFile` readers) does not get this guarantee.
- Whole-file readers refuse a `schemaVersion` newer than they know (`VersionedFile`, `SchemaVersion.decode`, the
  people store, `audio-deleted.json`); line files keep going instead: the forget journal skips newer lines, and dictation history
  keeps them unshown. `events.jsonl` lines have no version. Details: docs/contracts.md "Persistence".
- Directories are `0700` and files `0600` by default (`AtomicFile`'s `permissions:` parameter).

**Known gaps:** `SessionDeletion` hard-codes `screen`, `eval/review` and `derived`. Readers not yet on `VersionedFile`: the stores'
`SchemaVersion.decode` callers (`SessionSpeakerStore`, `SessionDeletion`, `ScreenContextStore`,
`SpeakerProfileStore`), the other `SessionFiles.decode` callers in HolosMeeting, line files that skip newer lines,
and hand-written checks with their own policies (`RecorderChannel`, `ControlInbox`, `SessionArchive.readManifest`,
`LiveHints`, `VocabularyFile`, `DeepTranscriptionQueue`, HolosEvaluation's files).

**Tests:** `Tests/HolosStorageTests` (`AtomicFileTests`, `SessionLocksTests`, `LeaseHandOffTests`, `FolderChainTests`,
`DescriptorSwapTests`, …), built on `HolosTestSupport` and `HolosSessionTestSupport`;
`./scripts/test-target.sh HolosStorageTests` builds and runs only them.
