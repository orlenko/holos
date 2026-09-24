#!/bin/sh
# Quits Holos, rebuilds build/Holos.app, and opens it again. Compiles first while Holos is still running,
# so the app is down only for the copy and signing. Never force-quits: if Holos does not quit (for example
# it is asking what to do with a meeting in progress), this stops and leaves it running.
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
    printf 'Quitting Holos...\n'
    osascript -e 'tell application id "ca.orlenko.holos.app" to quit' >/dev/null 2>&1 || true
    waited=0
    while pgrep -f "$app/Contents/MacOS/HolosApp" >/dev/null 2>&1; do
        if [ "$waited" -ge 30 ]; then
            printf 'Holos did not quit within 30 seconds (it may be showing a question). Answer it or quit Holos, then run this again.\n' >&2
            exit 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
fi

./scripts/build-app.sh "$@"
open "$app"
printf 'Relaunched %s\n' "$app"
