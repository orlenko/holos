# HolosStorage

Durable files: the session folder (`<id>.holos`), its locks, and the global stores under Application Support.

**Owns**
- Paths inside a session: `SessionPaths` (one function per file; docs/meeting-design.md §2.1), plus
  `ScreenContextStore`'s `screen/` paths.
- Safe file operations: `AtomicFile` (`write`, `create`, `append`, `readJSON`, `readIfPresent`, `removeTree`, …) and
  `AtomicFile.openFolder` in `FolderChain.swift` (every folder opened with `O_NOFOLLOW` from the session folder
  down), `ChunkFile` (reading finalized audio chunks).
- `SessionArchive`: the actor that is the one mutable owner of an active archive (manifest, event journal,
  transcript revisions), with `openForMaintenance(at:lease:)` and `recover(at:lease:)`. `TranscriptPointer`
  (`transcripts/current.json`).
- Locks (`SessionLocks.swift`): `.writer.lock`, `ProcessingLease` on `.processing.lock`, `withSpeakerLock` /
  `withSpeakerLockAsync` on `.speakers.lock`.
- Stores: `SessionSpeakerStore` (runs, head, edit journal, voice data, recognition), `SpeakerProfileStore`
  (people database and forget journal), `DictationHistoryStore` / `DictationHistoryService`, `WordListStore`,
  `ScreenContextStore`, `SessionDeletion` (Delete Audio, Delete Meeting), `FreeSpaceProvider`.

**Must not own:** transcript interpretation, capture, speaker algorithms, UI.

**Depends on:** HolosCore. Darwin, Synchronization, CryptoKit, AudioToolbox.

**Invariants** (docs/meeting-design.md §1.6, §1.7)
- Writes are atomic (temporary file, fsync, rename, folder fsync); a failed append truncates back, so no partial
  journal line survives.
- Locks are `flock`, one open file description per holder, **not re-entrant**. Waited-on locks are taken in the
  order speakers → profiles. `…Locked` functions document "caller holds the … lock".
- Nothing inside a session is opened through a symbolic link; the threat model is in §1.7.
- Readers refuse a file whose `schemaVersion` is newer than they know (`TranscriptPointer.swift`).
- Directories are `0700` and files `0600` by default (`AtomicFile`'s `permissions:` parameter).

**Known gaps:** `SessionDeletion` hard-codes `screen`, `eval/review` and `derived`; `<id>.holos` folder names are
built and parsed outside this target with different rules (one `SessionPaths.folder`/`parse` is planned).

**Tests:** `Tests/HolosStorageTests` (`AtomicFileTests`, `SessionLocksTests`, `LeaseHandOffTests`, `FolderChainTests`,
`DescriptorSwapTests`, …).
