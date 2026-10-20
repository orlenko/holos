#!/bin/sh
# Stamp a scratch Info.plist before compilation. Local builds use the checkout's commit count;
# releases pass their explicit build number. Neither mode touches an installed app.
set -eu
cd "$(dirname "$0")/.."

plist=$1
if [ -e .git ] && revision=$(git rev-parse --short=12 HEAD 2>/dev/null) && commit_count=$(git rev-list --count HEAD 2>/dev/null); then
    build_number=${2:-$commit_count}
    if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
        revision="$revision-dirty"
    fi
else
    revision="source-export"
    build_number=${2:-$(plutil -extract CFBundleVersion raw "$plist")}
fi
plutil -replace CFBundleVersion -string "$build_number" "$plist"
plutil -replace VoiceIsLocalSourceRevision -string "$revision" "$plist"
plutil -replace VoiceIsLocalBuiltAt -string "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$plist"
