#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

plutil -lint Resources/App-Info.plist
# Replacing the executable of a running Holos invalidates its code signature: macOS then re-prompts
# for the microphone and dictation into a terminal has frozen the terminal until Holos quit.
if pgrep -f "$PWD/build/Holos.app/Contents/MacOS/HolosApp" >/dev/null 2>&1; then
    printf 'Holos is running from build/Holos.app. Quit it first, then rebuild.\n' >&2
    exit 1
fi
swift build --product HolosApp "$@"
holos_app_bin_dir=$(swift build --show-bin-path "$@")
holos_app_root="$PWD/build"
holos_app_bundle="$holos_app_root/Holos.app"

# Build locally only. This does not install, launch, or enable a login item.
mkdir -p "$holos_app_bundle/Contents/MacOS"
cp Resources/App-Info.plist "$holos_app_bundle/Contents/Info.plist"
cp "$holos_app_bin_dir/HolosApp" "$holos_app_bundle/Contents/MacOS/HolosApp"
plutil -lint "$holos_app_bundle/Contents/Info.plist"
codesign --force --sign - --identifier ca.orlenko.holos.app "$holos_app_bundle"
codesign --verify "$holos_app_bundle"
printf 'Built %s (not launched)\n' "$holos_app_bundle"
