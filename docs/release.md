# Releasing Voice is Local

Voice is Local ships as a direct download: a DMG with the app, signed with a Developer ID certificate and notarized by
Apple. `scripts/release-app.sh` builds it. It writes only to `build/release/`; it never touches
`build/VoiceIsLocal.app` and never installs, launches, or quits the app.

Facts about Apple's programs, prices, and forms below come from general knowledge, not from a page checked while
writing this. Where a step says **check on developer.apple.com, as of 2026-09**, confirm it there before you rely on
it.

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
grant Microphone, Accessibility, and Input Monitoring once more after that update. Ask Apple whether the Team ID
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

1. builds `HolosApp` and `voiceislocal` with `swift build -c release` (arm64 only);
2. assembles `build/release/VoiceIsLocal.app`: `Info.plist` with the version, the icon when
   `Resources/Icon/VoiceIsLocal.icns` exists, `LICENSE.txt` and `THIRD_PARTY_NOTICES.md` in `Contents/Resources`;
3. signs inside out with the hardened runtime and a secure timestamp: first `Contents/MacOS/voiceislocal`
   (identifier `ca.orlenko.holos.cli`, `Resources/voiceislocal-cli.entitlements`), then the bundle (identifier
   `ca.orlenko.holos.app`, `Resources/VoiceIsLocal.entitlements`). These are the identifiers of the local builds,
   so preferences and data keyed to the bundle ID carry over;
4. verifies with `codesign --verify --deep --strict`, prints both binaries' entitlements and linked libraries, and
   fails if either lacks the hardened runtime or links a library outside `/usr/lib` and `/System`;
5. zips the app, submits it with `notarytool submit --wait`, and staples the ticket to the app, so the copy users
   drag out of the DMG opens without a network check;
6. builds `build/release/VoiceIsLocal-<version>.dmg` (the app, an `Applications` shortcut, the license and notices;
   compressed UDZO) and signs it;
7. submits the DMG, staples it, and validates both staples;
8. runs `spctl --assess` on the app and the DMG, then prints the DMG path and its SHA-256.

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
microphone. Accessibility, Input Monitoring, the CGEvent tap, speech recognition, and ScreenCaptureKit system audio
need no entitlement outside the sandbox. Both binaries link only system libraries (FluidAudio and
swift-argument-parser are linked statically), so library validation needs no exception.

## What users see

- They download the DMG, open it, and drag Voice is Local to Applications. The first open shows macOS's usual
  "downloaded from the Internet" confirmation with the developer name; there is no "cannot be opened" or
  "unidentified developer" warning.
- The Microphone, Accessibility, Input Monitoring, speech recognition, and system audio prompts name Voice is Local.
- Permissions persist across updates. macOS ties them to the app's designated requirement, which for a Developer ID
  signature is the bundle ID plus the Team ID, the same for every release. An ad-hoc build's requirement is the hash
  of that exact build, which is why local rebuilds could lose permissions.
- Moving from a local ad-hoc build to the first Developer ID build keeps settings, meetings, voices, and corrections
  (same bundle ID), but macOS asks for the permissions once more, because the signer changed.
- It runs on Apple Silicon Macs with macOS 27 or later only.

## Why not the Mac App Store

The Mac App Store requires the App Sandbox. Voice is Local inserts dictated text into other apps through the
Accessibility API, listens for its hold-to-talk shortcut with a CGEvent tap (Input Monitoring), records system audio
with ScreenCaptureKit, and starts its bundled `voiceislocal` tool as a recorder that keeps running after the app
quits. The sandbox forbids or heavily restricts controlling other apps and running a long-lived helper this way, so
the app would lose its core features. Developer ID distribution has none of these limits and still gets Apple's
malware scan (notarization).

## Third-party notices

`THIRD_PARTY_NOTICES.md` and the project `LICENSE` ship in the app (`Contents/Resources`) and at the top of the DMG;
the script copies them. The `voiceislocal` tool compiles in FluidAudio (Apache 2.0) and the code it bundles, whose
license texts the notices reproduce. The speaker diarization models are not shipped: `voiceislocal setup --speakers`
downloads them at runtime from Hugging Face under their own license (CC BY 4.0), and the notices carry their
attribution. Apple's speech assets are downloaded by macOS. When a dependency or model changes, update
`THIRD_PARTY_NOTICES.md` before the release.

## Publishing on the website

1. Upload `build/release/VoiceIsLocal-<version>.dmg` to the download page (keep the file name; it carries the
   version).
2. Publish its SHA-256 (printed at the end of the script; `shasum -a 256 <dmg>` repeats it) next to the link, with
   the requirements: macOS 27 or later, Apple Silicon.
3. Keep a short changelog per version.

Later, optionally:

- **Sparkle** for in-app updates: add the framework, publish an appcast signed with Sparkle's EdDSA key. The
  framework is a dynamic library inside the app, so the script would have to copy it into `Contents/Frameworks` and
  sign its helpers before the app.
- **A Homebrew cask** (`brew install --cask voice-is-local`): needs a stable versioned download URL and the SHA-256.

## Troubleshooting

- `errSecInternalComponent` or a keychain prompt during signing: the login keychain is locked (for example over SSH).
  Unlock it in Keychain Access or sign from a local session.
- `The timestamp service is not available`: Apple's timestamp server did not answer; run the script again.
- Notarization Invalid: run the `notarytool log` command the script prints; common causes are a binary without the
  hardened runtime or without a secure timestamp.
- On macOS 27, `hdiutil` prints a deprecation warning suggesting `diskutil image`; the DMG is still created.
