# HolosStorage

Durable files: the session folder (`<id>.holos`), its locks, and the global stores under Application Support.

**Owns**
- Paths inside a session: `SessionPaths` (one function per file; `docs/meeting-design.md §2.1`), plus
  `ScreenContextStore`'s `screen/` paths.
- Safe file operations: `AtomicFile` (`write`, `create`, `append`, `readJSON`, `readIfPresent`, `removeTree`, …) and
  `AtomicFile.openFolder` in `FolderChain.swift` (every folder opened with `O_NOFOLLOW` from the session folder
  down), `ChunkFile` (reading finalized audio chunks).
- `SessionArchive`: the actor that is the one mutable owner of an active archive (manifest, event journal,
  transcript revisions), with `openForMaintenance(at:lease:)` and `recover(at:lease:)`. `TranscriptPointer`
  (`transcripts/current.json`). `SessionManifest.audioFingerprint(track:)`: a stable hash of a track's chunk list,
  which echo analysis and evaluation runs store to tell whether the audio changed.
- Locks (`SessionLocks.swift`): `.writer.lock`, `ProcessingLease` on `.processing.lock`, `withSpeakerLock` /
  `withSpeakerLockAsync` on `.speakers.lock`.
- Stores: `SessionSpeakerStore` (runs, head, edit journal, voice data, recognition), `SpeakerProfileStore`
  (people database and forget journal), `DictationHistoryStore` / `DictationHistoryService`, `WordListStore`,
  `ScreenContextStore`, `SessionDeletion` (Delete Audio, Delete Meeting), `FreeSpaceProvider`.

**Must not own:** transcript interpretation, capture, speaker algorithms, UI.

**Depends on:** HolosCore. Darwin, Synchronization, CryptoKit, AudioToolbox.

**Invariants** (`docs/meeting-design.md §1.6`, `docs/meeting-design.md §1.7`)
- This target writes its data files through `AtomicFile`: a write is atomic (temporary file, fsync, rename, folder
  fsync), and a failed append truncates back, so no partial journal line survives. Not covered: audio chunks,
  which HolosAudio streams into files as it records (finalized and checked when closed), and `corrections.json`,
  which HolosCore writes with `Data.write(options: .atomic)`.
- Locks are `flock`, one open file description per holder, **not re-entrant**. Waited-on locks are taken in the
  order speakers → profiles. `…Locked` functions document "caller holds the … lock".
- HolosStorage opens folders inside a session through `AtomicFile.openFolder`, which follows no symbolic link
  (threat model: `docs/meeting-design.md §1.7`). One listing by path remains: `SessionDeletion` lists
  `eval/review` with `FileManager`, then removes through `removeTree`. Code outside this target that opens session
  files by path (such as `AVAudioFile` readers) does not get this guarantee.
- Whole-file readers refuse a `schemaVersion` newer than they know (`TranscriptPointer.swift`, the people store,
  `audio-deleted.json`); line files keep going instead: the forget journal skips newer lines, and dictation history
  keeps them unshown. `events.jsonl` lines have no version. Details: docs/contracts.md "Persistence".
- Directories are `0700` and files `0600` by default (`AtomicFile`'s `permissions:` parameter).

**Known gaps:** `SessionDeletion` hard-codes `screen`, `eval/review` and `derived`; `<id>.holos` folder names are
built and parsed outside this target with different rules (one `SessionPaths.folder`/`parse` is planned).

**Tests:** `Tests/HolosStorageTests` (`AtomicFileTests`, `SessionLocksTests`, `LeaseHandOffTests`, `FolderChainTests`,
`DescriptorSwapTests`, …), built on `HolosTestSupport` and `HolosSessionTestSupport`;
`./scripts/test-target.sh HolosStorageTests` builds and runs only them.
