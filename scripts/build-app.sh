#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

plutil -lint Resources/App-Info.plist
app_name="Voice is Local"
holos_app_root="$PWD/build"
holos_app_bundle="$holos_app_root/VoiceIsLocal.app"
# The bundle this app was built as before it was renamed to Voice is Local. It has the same bundle ID.
legacy_app_bundle="$holos_app_root/Holos.app"

# Replacing the executable of a running app invalidates its code signature: macOS then re-prompts
# for the microphone and dictation into a terminal has frozen the terminal until the app quit.
if pgrep -f "$holos_app_bundle/Contents/MacOS/HolosApp" >/dev/null 2>&1; then
    printf '%s is running from build/VoiceIsLocal.app. Quit it first, then rebuild.\n' "$app_name" >&2
    exit 1
fi
# The copy built before the rename has the same bundle ID, so the new build could not start while it runs.
if pgrep -f "$legacy_app_bundle/Contents/MacOS/HolosApp" >/dev/null 2>&1; then
    printf 'The old Holos is running from build/Holos.app. Quit it first, then rebuild.\n' >&2
    exit 1
fi
# The same holds for the bundled voiceislocal tool: a meeting recorder (or its speaker labelling) keeps running
# after the app quits, and replacing its binary would invalidate its signature in the middle of a meeting.
if pgrep -f "$holos_app_bundle/Contents/MacOS/voiceislocal" >/dev/null 2>&1; then
    printf 'A %s meeting recorder is running from build/VoiceIsLocal.app. Stop the recording and let speaker labelling finish, then rebuild.\n' "$app_name" >&2
    exit 1
fi
holos_build_plist=$(mktemp -t holos-build-info)
trap 'rm -f "$holos_build_plist"' EXIT HUP INT TERM
cp Resources/App-Info.plist "$holos_build_plist"
sh scripts/stamp-build-info.sh "$holos_build_plist"
# A local build never checks for updates: without a feed the app leaves Sparkle off (docs/release.md "Updates").
plutil -remove SUFeedURL "$holos_build_plist"
plutil -remove SUPublicEDKey "$holos_build_plist" 2>/dev/null || true
swift build --product HolosApp "$@"
swift build --product voiceislocal "$@"
holos_app_bin_dir=$(swift build --show-bin-path "$@")

# Build locally only. This does not install, launch, or enable a login item.
mkdir -p "$holos_app_bundle/Contents/MacOS"
cp "$holos_build_plist" "$holos_app_bundle/Contents/Info.plist"
mkdir -p "$holos_app_bundle/Contents/Resources"
cp Resources/Icon/VoiceIsLocal.icns "$holos_app_bundle/Contents/Resources/VoiceIsLocal.icns"
# The license, the trademark terms for the name and icon, and the notices the About panel points to, as in a release.
cp LICENSE "$holos_app_bundle/Contents/Resources/LICENSE.txt"
cp TRADEMARKS.md "$holos_app_bundle/Contents/Resources/TRADEMARKS.md"
cp THIRD_PARTY_NOTICES.md "$holos_app_bundle/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$holos_app_bin_dir/HolosApp" "$holos_app_bundle/Contents/MacOS/HolosApp"
# The app links Sparkle (in-app updates), so it needs the framework to start even though this build never checks.
# The framework comes from the package artifacts of the build folder that made the binaries (a --scratch-path too).
sparkle_source=
search_dir=$holos_app_bin_dir
while [ "$search_dir" != / ] && [ -z "$sparkle_source" ]; do
    candidate="$search_dir/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    [ ! -d "$candidate" ] || sparkle_source=$candidate
    search_dir=$(dirname "$search_dir")
done
[ -n "$sparkle_source" ] || { printf 'No Sparkle.framework in the package artifacts above %s.\n' "$holos_app_bin_dir" >&2; exit 1; }
rm -rf "$holos_app_bundle/Contents/Frameworks"
mkdir -p "$holos_app_bundle/Contents/Frameworks"
ditto "$sparkle_source" "$holos_app_bundle/Contents/Frameworks/Sparkle.framework"
# The recorder and maintenance commands the app starts (docs/meeting/recorder.md §4.1): signed on its own first,
# then sealed into the bundle's signature.
cp "$holos_app_bin_dir/voiceislocal" "$holos_app_bundle/Contents/MacOS/voiceislocal"
codesign --force --sign - --identifier ca.orlenko.holos.cli "$holos_app_bundle/Contents/MacOS/voiceislocal"
plutil -lint "$holos_app_bundle/Contents/Info.plist"
codesign --force --sign - --identifier ca.orlenko.holos.app "$holos_app_bundle"
codesign --verify "$holos_app_bundle"
printf 'Built %s (not launched)\n' "$holos_app_bundle"
if [ -d "$legacy_app_bundle" ]; then
    printf 'build/Holos.app is the copy from before the rename. Once you use build/VoiceIsLocal.app, you can delete it: settings, meetings, and voices carry over.\n'
fi
