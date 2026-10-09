# Retention and deletion

What a meeting keeps and how audio or a whole meeting is deleted.

Sections keep their numbers from the meeting design; a bare `§N.M` names one of them, and
[meeting-design.md](../meeting-design.md) lists the file each is in.

### 4.13 Retention and deletion

Nothing expired meetings before; a 3 h call is about 2 GB even with mono system audio.

- **Storage (PR3, `Sources/HolosStorage/SessionDeletion.swift`).**
  `SessionDeletion.deleteAudio(session:lease:)` requires the lease and no writer, removes
  `audio/`, `derived/`, and `speakers/voice/`, and writes `audio-deleted.json`
  `{schemaVersion, sessionID, deletedAt, chunkCount, seconds}` (`sessionID` optional:
  markers written before it are accepted). The marker is decoded wherever it is read
  (`AudioDeletedRecord.read`/`isDeleted`): one from a newer Holos is refused; a damaged one,
  or another session's, does not count as deleted audio, and Delete Audio replaces it.
  Transcript, runs, edits, and exports
  stay. `SessionDeletion.moveToTrash(session:lease:)` moves the folder to the Trash
  (`FileManager.trashItem`) and deletes `~/Library/Logs/Holos/recorder-<id>.log`.
  Both hold the writer lock (retry 1 s; held means a recorder is running, so they refuse)
  for the whole deletion rather than probing it, because `SessionArchive.open(at:)` does
  not consult the lease; `moveToTrash` also holds the speaker lock from the voice data
  through the trash, so a speaker edit or export regeneration never runs in a folder being
  moved. Lock order: processing → writer → speakers.
  Every delete inside a session folder (these, PR7b's `derived/`, `current.pending`,
  `deleteVoiceData`) goes through `AtomicFile.removeTree(_:in:)` (PR6), never
  `FileManager.removeItem`: it opens each folder on the way with `O_NOFOLLOW`, so a
  symbolic link in place of `speakers/`, `audio/`, `derived/`, or `exports/` is refused
  instead of leading the delete outside the session, and links inside the tree are removed,
  not followed.
- **CLI (PR3).** `holos session delete <path> [--audio-only] --yes`.
- **Catalog (PR3).** `SessionSummary` reports `bytes`, `derivedBytes`, `audioDeleted`.
- **UI (PR4).** Meetings window buttons "Delete Audio (Keep Transcript)…" and "Delete
  Meeting…", a "Clean Up" for leftover `derived/` renders, and a footer "Meetings use
  12.4 GB · 21.3 GB free". The Delete Meeting alert says "Voice samples learned from
  this meeting stay until you forget them in People."; PR9 adds the checkbox "Also
  forget voice samples learned from this meeting" (`VoiceProfileService.forget(sessionID:)`).
  Review disables playback when audio was deleted.
- **Redaction is reserved, not built.** `GapReason.redacted` exists so a later
  `holos session redact --from --until` can mark removed audio without a contract
  change. That command must scrub: the audio chunks (zero the samples and re-hash through
  `openForMaintenance`), `transcriptFinalized` text and words in `events.jsonl`, every
  `transcripts/*.json` revision (write a new one without those words), the head run (a
  new run, names carried over), `exports/`, and `status.json` `lastPhrase`. Until then,
  the remedy for an unpaused in-camera item is Delete Meeting (open question Q7).
