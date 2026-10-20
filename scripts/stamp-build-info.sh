#!/bin/sh
# Stamp a scratch Info.plist before compilation. Local builds use the checkout's commit count;
# releases pass their explicit build number. Neither mode touches an installed app.
set -eu
cd "$(dirname "$0")/.."

plist=$1
revision=$(git rev-parse --short=12 HEAD)
build_number=${2:-$(git rev-list --count HEAD)}
if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    revision="$revision-dirty"
fi
plutil -replace CFBundleVersion -string "$build_number" "$plist"
plutil -replace VoiceIsLocalSourceRevision -string "$revision" "$plist"
plutil -replace VoiceIsLocalBuiltAt -string "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$plist"
