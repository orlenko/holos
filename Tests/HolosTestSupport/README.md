# Test support

Helpers shared by the test targets. Both are ordinary library targets that only test targets depend on.

- **HolosTestSupport** (HolosCore only): `TemporaryDirectory` (made as any new folder is, unless asked to be
  private), `PollBudget` and `eventually` (poll a condition on a budget of polling time, never a wall-clock assert),
  `FileInspection` (modes, entries, file contents; `entryExists` does not follow a symbolic link, `exists` does),
  `isInvalidInput`/`isUnavailable`, `SeededNumbers` and `SplitMix64`, `TranscriptFixtures` (evenly timed words),
  `VersionedFileCorpus` (damaged, newer, and unversioned copies of a versioned JSON file, and what a read made of each),
  and `AudioFixtures` (a constant CAF; any audio file, such as rendered speech, read back as 16 kHz mono).
  Rendering speech itself stays `NativeSpeechRenderer` in HolosSynthesis.
- **HolosSessionTestSupport** (adds HolosStorage): `SessionFixtureBuilder`, an on-disk `.holos` session written
  through `SessionArchive`. Fixtures that need audio chunks from `AudioChunkWriter`, speaker runs, or HolosMeeting
  stay in that target's tests (HolosMeetingTests/SessionFixtures.swift) and can build on it.

HolosStorageTests and HolosSpeakersTests use them; HolosTestSupportTests checks them. Other targets adopt them when they are next touched: drop the target's own copy of a
helper in the same change, keep helpers that differ from these, and add nothing here that pulls a heavy module
(WhisperKit, FluidAudio, the app) into targets that do not need it.
