#!/bin/sh
# Quits Holos, rebuilds build/Holos.app, and opens it again. Compiles first while Holos is still running,
# so the app is down only for the copy and signing. Never force-quits: it waits while Holos asks what to do
# with a meeting in progress or finishes saving one, and gives up (leaving Holos running) after 11 minutes.
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

if pgrep -f "$app/Contents/MacOS/HolosApp" >/dev/null 2>&1; then
    printf 'Asking Holos to quit...\n'
    # Send the quit without waiting for Holos's reply: while it shows a question, the reply would not come.
    osascript -e 'ignoring application responses' -e 'tell application id "ca.orlenko.holos.app" to quit' \
        -e 'end ignoring' >/dev/null 2>&1 || true
    # Holos may take up to 10 minutes to finish saving a meeting it records itself before it quits, so keep
    # waiting rather than leave it to quit after this script has given up.
    waited=0
    while pgrep -f "$app/Contents/MacOS/HolosApp" >/dev/null 2>&1; do
        if [ "$waited" -ge 660 ]; then
            printf 'Holos is still running after 11 minutes. Quit it (or answer its question), then run this again.\n' >&2
            exit 1
        fi
        if [ "$waited" -gt 0 ] && [ $((waited % 30)) -eq 0 ]; then
            printf 'Still waiting for Holos to quit. If it is asking a question, answer it; if you chose to keep it running, press Ctrl-C.\n'
        fi
        sleep 1
        waited=$((waited + 1))
    done
fi

./scripts/build-app.sh "$@"
open "$app"
printf 'Relaunched %s\n' "$app"
