#!/bin/sh
# Quits Holos, rebuilds build/Holos.app, and opens it again. Compiles first while Holos is still running,
# so the app is down only for the copy and signing. Never force-quits: it waits while Holos asks what to do
# with a meeting in progress or finishes saving one (Ctrl-C stops waiting and leaves Holos running).
set -eu
cd "$(dirname "$0")/.."

app="$PWD/build/Holos.app"
if pgrep -f "$app/Contents/MacOS/holos" >/dev/null 2>&1; then
    printf 'A Holos meeting recorder is running from build/Holos.app. Stop the recording and let speaker labelling finish, then try again.\n' >&2
    exit 1
fi

# Compiling does not touch build/Holos.app, so it is safe while Holos runs.
swift build --product HolosApp "$@"
swift build --product holos "$@"

# Any running Holos, from this checkout or another copy: a second one with the same bundle ID refuses to start.
if pgrep -x HolosApp >/dev/null 2>&1; then
    printf 'Asking Holos to quit...\n'
    # Send the quit without waiting for Holos's reply (while it shows a question, the reply would not come),
    # but report a quit that could not be sent, such as when the terminal may not control Holos.
    if ! error=$(osascript -e 'ignoring application responses' \
            -e 'tell application id "ca.orlenko.holos.app" to quit' -e 'end ignoring' 2>&1); then
        printf 'Could not ask Holos to quit: %s\nAllow your terminal to control Holos (System Settings > Privacy & Security > Automation), or quit Holos from its menu, then run this again.\n' "$error" >&2
        exit 1
    fi
    # Holos may ask what to do with a meeting in progress and then take up to 10 minutes to save one it records
    # itself; a quit it has accepted still happens, so wait for it however long it takes.
    waited=0
    while pgrep -x HolosApp >/dev/null 2>&1; do
        if [ "$waited" -gt 0 ] && [ $((waited % 30)) -eq 0 ]; then
            printf 'Still waiting for Holos to quit. Answer its question if it asks one; if you chose to keep it running, press Ctrl-C.\n'
        fi
        sleep 1
        waited=$((waited + 1))
    done
fi

./scripts/build-app.sh "$@"
open "$app"
printf 'Relaunched %s\n' "$app"
