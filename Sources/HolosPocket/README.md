# HolosPocket

Natural Reading voices: Kyutai Pocket TTS through FluidAudio (`docs/design.md "Natural voices"`). Of the products,
only `HolosCLI` links it; the app renders natural parts through `voiceislocal say`.

**Owns**
- `PocketSpeechBackend`: the `NaturalSpeechBackend` implementation (protocol, catalog and pack values in
  HolosSynthesis). One `PocketTtsManager` per language pack, loaded from the pack's folder and kept for the
  process; each paragraph is a fresh session with the given seed, so a paragraph and seed always give the same take.
- The install steps `NaturalVoiceModels.setUp` takes (`download`, `verify`, warm-up, tidy-up): the listing of the
  pinned commit of `FluidInference/pocket-tts-coreml` (`NaturalVoiceModels.revision`), FluidAudio's resumable
  download pinned to that commit, the size and SHA-256 check of every file, and the removal of voices not offered.

**Must not own:** which voices are offered and their licences (`NaturalVoiceCatalog`), the install folder, marker
and lock (`NaturalVoiceModels`), paragraphs, checks and files (`NaturalSpeechRenderer`), anything the app links.

**Depends on:** HolosCore, HolosSynthesis. FluidAudio (pinned at 0.17.1 in `Package.swift`).

**Invariants**
- Every request names the reviewed commit, never `main`: the listing, FluidAudio's downloads (its revision
  override for the repository), and the root files.
- A downloaded file that fails the check is removed and the download fails. Rendering uses a pack only once
  `NaturalVoiceModels` has marked it installed; the install's warm-up, before the marker, is the one load before.

**Tests:** `Tests/HolosPocketTests`: `PocketAddressTests` (offline: pinned addresses, a configured mirror, where the
files check looks). `PocketIntegrationTests` renders a sentence twice with a real pack and the same seed, opt-in
(`HOLOS_POCKET_INTEGRATION=1`, `HOLOS_POCKET_MODELS_DIR`); nothing is played aloud.
