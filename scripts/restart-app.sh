#!/bin/sh
# Quits Voice is Local, rebuilds build/VoiceIsLocal.app, and opens it again. Compiles first while the app is still
# running, so it is down only for the copy and signing. Never force-quits: it waits while the app asks what to do
# with a meeting in progress or finishes saving one (Ctrl-C stops waiting and leaves the app running).
# It also quits the copy built before the rename (build/Holos.app), which has the same bundle ID.
set -eu
cd "$(dirname "$0")/.."

app="$PWD/build/VoiceIsLocal.app"
legacy_app="$PWD/build/Holos.app"
recorder_running() {
    pgrep -f "$app/Contents/MacOS/voiceislocal" >/dev/null 2>&1 \
        || pgrep -f "$legacy_app/Contents/MacOS/holos" >/dev/null 2>&1
}
if recorder_running; then
    printf 'A Voice is Local meeting recorder is running from build/VoiceIsLocal.app or build/Holos.app. Stop the recording and let speaker labelling finish, then try again.\n' >&2
    exit 1
fi

# Compiling does not touch build/VoiceIsLocal.app, so it is safe while the app runs.
swift build --product HolosApp "$@"
swift build --product voiceislocal "$@"

# Any copy of this user's app, from this checkout or another one, old name or new: a second one with the same bundle
# ID refuses to start. Both names run the executable HolosApp. Another login's copy cannot be quit from here and does
# not block this user's copy; build-app.sh still refuses to replace build/VoiceIsLocal.app while any user runs it.
me=$(id -u)
if pgrep -u "$me" -x HolosApp >/dev/null 2>&1; then
    printf 'Asking Voice is Local to quit...\n'
    # Send the quit without waiting for the app's reply (while it shows a question, the reply would not come),
    # but report a quit that could not be sent, such as when the terminal may not control the app.
    if ! error=$(osascript -e 'ignoring application responses' \
            -e 'tell application id "ca.orlenko.holos.app" to quit' -e 'end ignoring' 2>&1); then
        printf 'Could not ask Voice is Local to quit: %s\nAllow your terminal to control Voice is Local (System Settings > Privacy & Security > Automation), or quit Voice is Local from its menu, then run this again.\n' "$error" >&2
        exit 1
    fi
    # The app may ask what to do with a meeting in progress and then take up to 10 minutes to save one it records
    # itself; a quit it has accepted still happens, so wait for it however long it takes.
    waited=0
    while pgrep -u "$me" -x HolosApp >/dev/null 2>&1; do
        if [ "$waited" -gt 0 ] && [ $((waited % 30)) -eq 0 ]; then
            printf 'Still waiting for Voice is Local to quit. Answer its question if it asks one; if you chose to keep it running, press Ctrl-C.\n'
        fi
        sleep 1
        waited=$((waited + 1))
    done
fi

# Quitting during a meeting the app records itself can hand speaker labelling to the bundled command-line tool
# (voiceislocal, or holos in the old build/Holos.app), which keeps running after the app is gone; replacing it now
# would break it, so wait for it to finish.
waited=0
while recorder_running; do
    if [ $((waited % 30)) -eq 0 ]; then
        printf 'Waiting for speaker labelling to finish before rebuilding (Ctrl-C to stop waiting)...\n'
    fi
    sleep 1
    waited=$((waited + 1))
done

./scripts/build-app.sh "$@"
open "$app"
printf 'Relaunched %s\n' "$app"
