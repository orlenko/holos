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

# Any Holos of this user, from this checkout or another copy: a second one with the same bundle ID refuses to
# start. Another login's Holos cannot be quit from here and does not block this user's copy; build-app.sh still
# refuses to replace build/Holos.app while any user runs it.
me=$(id -u)
if pgrep -u "$me" -x HolosApp >/dev/null 2>&1; then
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
    while pgrep -u "$me" -x HolosApp >/dev/null 2>&1; do
        if [ "$waited" -gt 0 ] && [ $((waited % 30)) -eq 0 ]; then
            printf 'Still waiting for Holos to quit. Answer its question if it asks one; if you chose to keep it running, press Ctrl-C.\n'
        fi
        sleep 1
        waited=$((waited + 1))
    done
fi

# Quitting during a meeting Holos records itself can hand speaker labelling to the bundled holos tool, which keeps
# running after the app is gone; replacing it now would break it, so wait for it to finish.
waited=0
while pgrep -f "$app/Contents/MacOS/holos" >/dev/null 2>&1; do
    if [ $((waited % 30)) -eq 0 ]; then
        printf 'Waiting for speaker labelling to finish before rebuilding (Ctrl-C to stop waiting)...\n'
    fi
    sleep 1
    waited=$((waited + 1))
done

./scripts/build-app.sh "$@"
open "$app"
printf 'Relaunched %s\n' "$app"
