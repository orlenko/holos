# Releasing Voice is Local

Voice is Local ships as a direct download: a DMG with the app, signed with a Developer ID certificate and notarized by
Apple. `scripts/release-app.sh` builds it. It writes only to `build/release/`; it never touches
`build/VoiceIsLocal.app` and never installs, launches, or quits the app.

Facts about Apple's programs, prices, and forms below come from general knowledge, not from a page checked while
writing this. Where a step says **check on developer.apple.com, as of 2026-09**, confirm it there before you rely on
it.

## Build identity

Both packaging scripts record the source revision and build time in UTC in `Info.plist`; About shows them above
the credits. The revision has a `-dirty` suffix when the checkout has changed or untracked files. The metadata
is captured before compilation. A local build uses `git rev-list --count HEAD` as `CFBundleVersion`, so a new
commit changes the number; a release keeps the explicit `BUILD` value described below. The marketing version
comes from `Resources/App-Info.plist` locally, or `VERSION` for a release. Source exports without
Git metadata retain the template build number locally and identify their source as `source-export`;
a release still uses its explicit `BUILD` value.

## One-time setup

Do these once, in this order.

### 1. Enroll in the Apple Developer Program as an organization

The name users see in Gatekeeper and in the notarization record is the enrolled legal entity. To show
**Bjola Software Inc.**, enroll the corporation, not yourself. **Check on developer.apple.com, as of 2026-09.**

What the organization enrollment needs:

- **A D-U-N-S Number** for Bjola Software Inc. It is free. Apple's enrollment flow has a lookup
  (developer.apple.com/enroll/duns-lookup) that finds an existing number or starts a request. A new number from
  Dun & Bradstreet can take several business days, up to about two weeks, and Apple may take a few more days to see
  it. The legal name and address on the D-U-N-S record must match what you enter at Apple.
- **Legal binding authority**: you must be the owner or an officer who can sign agreements for the company.
- **A public company website** on the company's domain, and an Apple Account that uses **an email address on that
  domain**, not a personal address such as Gmail.
- Apple may **call to verify** your identity and authority.
- **Fee**: US$99 per year (or the local equivalent), the same as an individual membership.

Where to click: developer.apple.com/programs/enroll → Start your enrollment (or the Apple Developer app on a Mac or
iPhone) → sign in with the company-domain Apple Account → choose **Company / Organization** → enter the D-U-N-S
Number and legal details → pay once Apple approves the entity.

Once enrolled, the certificate reads `Developer ID Application: Bjola Software Inc. (TEAMID)`, and Gatekeeper and
notarization show that name.

**Alternative:** enroll as an individual now (no D-U-N-S, usually approved within a day or two; the name shown to
users is your legal name), then ask Apple Developer Support to convert the membership to an organization later.
Converting means new Developer ID certificates in the company's name. macOS keys permissions to the bundle ID and
the Team ID in the signature (see [What users see](#what-users-see)): if the conversion changes the Team ID, users
grant Microphone, Accessibility, and Screen & System Audio Recording once more after that update. Ask Apple whether the Team ID
stays. **Check on developer.apple.com, as of 2026-09.**

### 2. Create a Developer ID Application certificate

Only the **Developer ID Application** type passes Gatekeeper outside the Mac App Store ("Apple Development" and
"Apple Distribution" certificates do not). In an organization, creating Developer ID certificates is limited to the
Account Holder (and possibly Admins Apple has granted access). **Check on developer.apple.com, as of 2026-09.**

Either way puts the certificate and its private key in your login keychain:

- **Xcode:** Xcode → Settings… → Accounts → add the Apple Account → select the team (Bjola Software Inc.) →
  **Manage Certificates…** → **+** → **Developer ID Application**.
- **Website:** Keychain Access → Keychain Access menu → Certificate Assistant → **Request a Certificate From a
  Certificate Authority…** → your email, common name, "Saved to disk" → save the `.certSigningRequest`. Then
  developer.apple.com/account → Certificates, IDs & Profiles → Certificates → **+** → **Developer ID Application** →
  upload the request → download the `.cer` and double-click it to add it to the keychain.

Then back it up: Keychain Access → login → My Certificates → right-click the Developer ID Application certificate →
Export… → `.p12` with a strong password, stored somewhere safe. The private key exists only on this Mac; without the
backup, a lost Mac means a new certificate. A new certificate from the same team keeps the same Team ID, so the app's
code-signing identity (bundle ID plus Team ID) and users' permissions stay valid.

### 3. Find the identity string

```sh
security find-identity -v -p codesigning
```

The line to use looks like `1) ABCDEF… "Developer ID Application: Bjola Software Inc. (TEAMID)"`. The quoted text is
the `DEVELOPER_ID` value; `TEAMID` is your 10-character Team ID (also under developer.apple.com/account →
Membership details).

### 4. Store notarization credentials

`notarytool` needs credentials; store them once in the keychain under a profile name.

With an app-specific password (simplest):

1. account.apple.com → sign in with the developer Apple Account → **Sign-In and Security** →
   **App-Specific Passwords** → **+** → name it "notarytool" → copy the password.
2. Store it (the command prompts for the password):

   ```sh
   xcrun notarytool store-credentials voiceislocal-notary --apple-id you@your-company-domain --team-id TEAMID
   ```

With an App Store Connect API key instead (no personal password involved; good for CI later): App Store Connect →
Users and Access → Integrations → **Team Keys** → **+** (Developer access is enough) → download the `.p8` once, note
the Key ID and Issuer ID, then:

```sh
xcrun notarytool store-credentials voiceislocal-notary --key AuthKey_KEYID.p8 --key-id KEYID --issuer ISSUER-UUID
```

## Each release

Voice is Local is licensed under the GPL, version 3 or later. Every build given or sold to anyone must have its
exact source available, so a signed release is built only from a clean checkout of a pushed tag.

### In one command

On the Mac that holds the Developer ID key, in its own session (not over SSH, so the keychain can ask), on a clean
`main`:

```sh
./scripts/release.sh            # the next patch version: 1.0.1 → 1.0.2
./scripts/release.sh minor      # 1.0.1 → 1.1.0; also major, or an exact version such as 1.2.0
./scripts/release.sh 1.0.1      # a version already tagged: build that tag again
```

`scripts/release.sh` stops before changing anything when the signing identity is not in the keychain, the working
tree is not clean, `main` is not checked out or has commits `origin/main` lacks, or `main` has nothing new since the
last release tag. Otherwise it fast-forwards `main`, sets the version in the three places below, and checks that
the commit changes only those three lines. It commits "Set the version to X" directly to `main` without a pull
request, tags it `vX`, pushes both at once (`git push --atomic`), and runs `scripts/release-app.sh` with the
identity, the `voiceislocal-notary` profile, and `BUILD` set to the number of release tags (1.0.0 was build 1,
1.0.1 build 2). `DEVELOPER_ID`, `NOTARY_PROFILE`, and `BUILD` override those defaults. If the build or notarization
fails after the push, fix the cause and run it again with the same version: the tag exists, so it builds that tag
without a new commit.

### By hand

1. Set the version in `Resources/App-Info.plist` (or pass `VERSION` below), and the same version in
   `Resources/CLI-Info.plist` and in `voiceislocal --version` (`Sources/HolosCLI/Holos.swift`), which `VERSION`
   does not change; commit, and push.
2. Tag that commit `v<version>` and push the tag before building:

   ```sh
   git tag v1.0.0
   git push origin v1.0.0
   ```

3. Build from a clean working tree with `HEAD` at that tag (`git status` shows nothing, untracked files included;
   ignored folders such as `build/` and `.build/` do not count):

```sh
DEVELOPER_ID="Developer ID Application: Bjola Software Inc. (TEAMID)" \
NOTARY_PROFILE=voiceislocal-notary \
VERSION=1.0.0 BUILD=1 \
./scripts/release-app.sh
```

`VERSION` becomes `CFBundleShortVersionString` and must be dot-separated integers for a signed release. `BUILD`
becomes `CFBundleVersion`; raise it with every release. Both can also be passed as arguments
(`./scripts/release-app.sh 1.0.0 1`). Without them the script uses the values in `Resources/App-Info.plist`.

The script:

1. checks the source: the working tree is clean (`git status --porcelain --untracked-files=all` is empty), the tag
   `v<VERSION>` exists and is `HEAD`, and `git ls-remote --tags origin` shows the same tag at the same commit. With
   `DEVELOPER_ID` set, any failure stops the script; a dry run prints a warning and goes on;
2. builds `HolosApp` and `voiceislocal` with `swift build -c release --disable-default-traits` (arm64 only), so the
   release `voiceislocal` has no `eval` commands (the Evaluation trait, `Package.swift`; `eval cloud` uploads audio to
   OpenAI), and stops if the OpenAI endpoint is still in the binary; then checks again that `HEAD` did not move and
   the tree is still clean;
3. assembles `build/release/VoiceIsLocal.app`: `Info.plist` with the version and, when the source check passed, the
   tag as `VoiceIsLocalSourceTag` (the About panel then links the source and `TRADEMARKS.md` at that tag instead of
   `main`), the icon when `Resources/Icon/VoiceIsLocal.icns` exists, and `LICENSE.txt`, `TRADEMARKS.md`, and
   `THIRD_PARTY_NOTICES.md` in `Contents/Resources`;
4. signs inside out with the hardened runtime and a secure timestamp: first `Contents/MacOS/voiceislocal`
   (identifier `ca.orlenko.holos.cli`, `Resources/voiceislocal-cli.entitlements`), then the bundle (identifier
   `ca.orlenko.holos.app`, `Resources/VoiceIsLocal.entitlements`). These are the identifiers of the local builds,
   so preferences and data keyed to the bundle ID carry over;
5. verifies with `codesign --verify --deep --strict`, prints both binaries' entitlements and linked libraries, and
   fails if either lacks the hardened runtime or links a library outside `/usr/lib` and `/System`;
6. zips the app, submits it with `notarytool submit --wait`, and staples the ticket to the app, so the copy users
   drag out of the DMG opens without a network check;
7. builds `build/release/VoiceIsLocal-<version>.dmg` (the app, an `Applications` shortcut, `LICENSE.txt`,
   `TRADEMARKS.md`, and `THIRD_PARTY_NOTICES.md`; compressed UDZO) and signs it;
8. submits the DMG, staples it, and validates both staples;
9. runs `spctl --assess` on the app and the DMG, then prints the DMG path, its SHA-256, and the source tag.

Keep the repository and the release tags public, and never move or delete a tag once its DMG is out. The About panel
shows the license notice and points to the `LICENSE.txt` and `TRADEMARKS.md` inside the app. The name Voice is Local
and the icon are not under the GPL: Bjola Software Inc. owns them and grants the permissions in `TRADEMARKS.md`.

A notarization that ends in any status other than Accepted stops the script with the submission ID and the command
that shows Apple's reasons: `xcrun notarytool log <id> --keychain-profile voiceislocal-notary`. Each submission
usually takes a few minutes.

With `DEVELOPER_ID` but no `NOTARY_PROFILE`, the script signs and packages but skips notarization; Gatekeeper
rejects that build on other Macs. Without `DEVELOPER_ID` it is a **dry run**: signed ad-hoc (still with the hardened
runtime and entitlements), not notarized, for local testing only. Gatekeeper blocks it on any other Mac.

The Team ID in the signature must stay the same from release to release: always sign with a Developer ID
Application certificate of the same team.

### Entitlements

The app is not sandboxed. Both entitlement files contain one entitlement,
`com.apple.security.device.audio-input`: under the hardened runtime a process can open the microphone only with it,
and both the app (dictation, in-process recording) and the `voiceislocal` recorder the app starts open the
microphone. Accessibility, the CGEvent tap (and Input Monitoring, only where macOS asks for it), speech recognition, and ScreenCaptureKit system audio
need no entitlement outside the sandbox. Both binaries link only system libraries (FluidAudio and
swift-argument-parser are linked statically), so library validation needs no exception. The app also loads
`Sparkle.framework` from `Contents/Frameworks`, which the script signs with the same identity before the app.

## What users see

- They download the DMG, open it, and drag Voice is Local to Applications. The first open shows macOS's usual
  "downloaded from the Internet" confirmation with the developer name; there is no "cannot be opened" or
  "unidentified developer" warning.
- The first launch opens the Setup Assistant. The Microphone, Accessibility, speech recognition, and system audio
  prompts name Voice is Local. Input Monitoring is not requested (the hotkey's event tap runs on Accessibility);
  Setup shows it only if macOS refuses the tap anyway.
- Permissions persist across updates. macOS ties them to the app's designated requirement, which for a Developer ID
  signature is the bundle ID plus the Team ID, the same for every release. An ad-hoc build's requirement is the hash
  of that exact build, which is why local rebuilds could lose permissions.
- Moving from a local ad-hoc build to the first Developer ID build keeps settings, meetings, voices, and corrections
  (same bundle ID), but macOS asks for the permissions once more, because the signer changed.
- It runs on Apple Silicon Macs with macOS 27 or later only.
- From 1.0.2, the second launch asks once whether to check for updates automatically ("Updates" below).

## Why not the Mac App Store

The Mac App Store requires the App Sandbox. Voice is Local inserts dictated text into other apps through the
Accessibility API, listens for its hold-to-talk shortcut with an active CGEvent tap, records system audio
with ScreenCaptureKit, and starts its bundled `voiceislocal` tool as a recorder that keeps running after the app
quits. The sandbox forbids or heavily restricts controlling other apps and running a long-lived helper this way, so
the app would lose its core features. Developer ID distribution has none of these limits and still gets Apple's
malware scan (notarization).

## Third-party notices

`THIRD_PARTY_NOTICES.md`, the project `LICENSE` (as `LICENSE.txt`), and `TRADEMARKS.md` ship in the app
(`Contents/Resources`) and at the top of the DMG; the script copies them. `scripts/build-app.sh` copies the same
three files into local builds. The `voiceislocal` tool compiles in FluidAudio (Apache 2.0) and the code it bundles, whose
license texts the notices reproduce. The speaker diarization models are not shipped: `voiceislocal setup --speakers`
downloads them at runtime from Hugging Face under their own license (CC BY 4.0), and the notices carry their
attribution. The app includes Sparkle (MIT, with the licenses of the code it bundles), whose license the
notices reproduce too. Apple's speech assets are downloaded by macOS. When a dependency or model changes, update
`THIRD_PARTY_NOTICES.md` before the release.

## Publishing on the website

1. Upload `build/release/VoiceIsLocal-<version>.dmg` to the download page (keep the file name; it carries the
   version).
2. Publish its SHA-256 (printed at the end of the script; `shasum -a 256 <dmg>` repeats it) next to the link, with
   the requirements: macOS 27 or later, Apple Silicon.
3. Publish `build/release/appcast.xml` at `https://voiceislocal.com/downloads/appcast.xml`, byte for byte: its
   signature covers the whole file. Publish it after the DMG, so the app never offers a file that is not there yet.
4. Update the Homebrew cask, `Casks/voiceislocal.rb` in
   [orlenko/homebrew-tap](https://github.com/orlenko/homebrew-tap): its `version` and `sha256`. Users install with
   `brew install --cask orlenko/tap/voiceislocal`.
5. Keep a short changelog per version.

## Updates

The app updates itself with [Sparkle](https://sparkle-project.org) 2.10.0 (`HolosApp+Updates.swift`).

- **What goes online.** Nothing until the user agrees. The first launch of a build with updates says nothing; the
  second asks once, "Check for updates automatically?" (`UpdateCheckConsent`). With a yes, Sparkle downloads
  `SUFeedURL` (`https://voiceislocal.com/downloads/appcast.xml`) about once a day, with a User-Agent that names the
  app and its version. Sparkle's system profile is off (`SUEnableSystemProfiling`). The DMG downloads only when the
  user chooses to install the update it offers. Check for Updates… in the menu bar menu works whatever the answer;
  Settings › General › "Check for updates automatically" changes it.
- **What it trusts.** The app accepts an appcast only with a valid signature (`SURequireSignedFeed`), and an update
  only when the DMG's EdDSA signature matches `SUPublicEDKey` (checked before the DMG is opened,
  `SUVerifyUpdateBeforeExtraction`) and the new app is signed with the same Developer ID.
- **Local builds never check.** `scripts/build-app.sh` removes `SUFeedURL` from the build's Info.plist, so the app
  leaves Sparkle off and Settings shows the checkbox unavailable. They still bundle the framework, which the app
  links.

### One-time: the signing key

The private key lives in the login keychain of the Mac that builds releases, next to the Developer ID key, and
nowhere else. On that Mac, in its own session, after one `swift build` has fetched the Sparkle package:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys      # creates the key, or prints the one already there
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/Desktop/voiceislocal-sparkle-key   # a backup
```

Put the public key it prints in `Resources/App-Info.plist` as `SUPublicEDKey` and commit it. Store the backup
file somewhere safe and offline (a password manager), then delete it from the Desktop. Without the key no update
can ever be signed for the apps already installed, so losing it means users must download the next version by
hand. `generate_keys -f <backup>` imports it on another Mac.

`scripts/release-app.sh` stops a signed release when `SUPublicEDKey` is missing or differs from the keychain's key
(`generate_keys -p`).

### Each release

With `DEVELOPER_ID` and `NOTARY_PROFILE`, the script also writes `build/release/appcast.xml`: one item, this
version, whose enclosure is `$DOWNLOADS_URL/VoiceIsLocal-<version>.dmg` (default
`https://voiceislocal.com/downloads`) with the DMG's EdDSA signature and length, and the minimum macOS and Apple
Silicon requirement. It then signs the feed and checks the signature (`sign_update`, `sign_update --verify`). The
keychain may ask once to let `sign_update` use the key.

Releases before 1.0.2 have no updater: their users download 1.0.2 by hand once.

## Troubleshooting

- `errSecInternalComponent` or a keychain prompt during signing: the login keychain is locked (for example over SSH).
  Unlock it in Keychain Access or sign from a local session.
- `The timestamp service is not available`: Apple's timestamp server did not answer; run the script again.
- Notarization Invalid: run the `notarytool log` command the script prints; common causes are a binary without the
  hardened runtime or without a secure timestamp.
