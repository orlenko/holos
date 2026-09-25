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
swift build --product HolosApp "$@"
swift build --product voiceislocal "$@"
holos_app_bin_dir=$(swift build --show-bin-path "$@")

# Build locally only. This does not install, launch, or enable a login item.
mkdir -p "$holos_app_bundle/Contents/MacOS"
cp Resources/App-Info.plist "$holos_app_bundle/Contents/Info.plist"
mkdir -p "$holos_app_bundle/Contents/Resources"
cp Resources/Icon/VoiceIsLocal.icns "$holos_app_bundle/Contents/Resources/VoiceIsLocal.icns"
cp "$holos_app_bin_dir/HolosApp" "$holos_app_bundle/Contents/MacOS/HolosApp"
# The recorder and maintenance commands the app starts (docs/meeting-design.md §4.1): signed on its own first,
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
