#!/bin/sh
# Releases Voice is Local in one command, on the Mac that holds the Developer ID key: sets the next version, commits
# and tags it on main, pushes both, and builds, signs, and notarizes the DMG with scripts/release-app.sh.
#
#   scripts/release.sh [patch|minor|major|<version>]
#
# patch (the default), minor, or major raises the version in Resources/App-Info.plist. A version whose tag v<version>
# already exists (on origin, at the same commit) is built again without a new commit: use it to resume after a failed
# build or notarization.
#   DEVELOPER_ID    signing identity; default "Developer ID Application: Bjola Software Inc. (LC28ZF5453)".
#   NOTARY_PROFILE  notarytool keychain profile; default voiceislocal-notary.
#   BUILD           CFBundleVersion; default the number of v* release tags, this one included (1.0.0 was 1).
# A new version starts from a clean main that matches origin/main. The version commit changes only the three
# version lines (both Info.plists and `voiceislocal --version`) and goes to main without a pull request. Run it in
# the Mac's own session, not over SSH, so the keychain can ask for the signing key. See docs/release.md.
set -eu
cd "$(dirname "$0")/.."

case "${1:-}" in
    -h|--help)
        sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
esac

fail() {
    printf 'release: %s\n' "$*" >&2
    exit 1
}
step() {
    printf '\n==> %s\n' "$*"
}

app_plist=Resources/App-Info.plist
cli_plist=Resources/CLI-Info.plist
cli_root=Sources/HolosCLI/Holos.swift
developer_id=${DEVELOPER_ID:-"Developer ID Application: Bjola Software Inc. (LC28ZF5453)"}
notary_profile=${NOTARY_PROFILE:-voiceislocal-notary}

# Before anything is committed or pushed: a Mac without the key stops here.
security find-identity -v -p codesigning | grep -Fq "\"$developer_id\"" \
    || fail "No valid signing identity \"$developer_id\" in the keychain; release from the Mac that holds the key."
[ -z "$(git status --porcelain --untracked-files=all)" ] \
    || fail "The working tree has changes or untracked files; commit, stash, or remove them first."
# The build number counts the release tags HEAD contains, which a shallow clone may not reach.
[ "$(git rev-parse --is-shallow-repository)" = false ] \
    || fail "This is a shallow clone; run git fetch --unshallow first."

is_version() {
    case "$1" in
        ''|*[!0-9.]*|.*|*.|*..*|0[0-9]*|*.0[0-9]*) return 1 ;;
    esac
    [ "$(printf '%s' "$1" | tr -cd . | wc -c | tr -d ' ')" -eq 2 ]
}

request=${1:-patch}
case "$request" in
    patch|minor|major) ;;
    *) is_version "$request" || fail "'$request' is not patch, minor, major, or a version such as 1.0.2." ;;
esac

step "Fetching origin"
git fetch --quiet --tags origin

start_branch=$(git symbolic-ref --quiet --short HEAD || true)
if is_version "$request" && git rev-parse --quiet --verify "refs/tags/v$request" >/dev/null; then
    version=$request
    step "Tag v$version exists; building it again"
    # Back to the starting branch however the build ends: the tag may predate this script, so a retry needs it.
    [ -z "$start_branch" ] || trap 'git switch --quiet "$start_branch"' EXIT
    git switch --quiet --detach "v$version"
else
    [ "$start_branch" = main ] || fail "Switch to main first (git switch main)."
    [ -z "$(git rev-list origin/main..HEAD)" ] || fail "main has commits origin/main lacks; push or drop them first."
    git merge --quiet --ff-only origin/main

    current=$(plutil -extract CFBundleShortVersionString raw -o - "$app_plist")
    is_version "$current" || fail "$app_plist has version '$current'; expected three numbers such as 1.0.1."
    for file in "$cli_plist" "$cli_root"; do
        grep -Fq "$current" "$file" || fail "$file does not have version $current like $app_plist; fix it by hand first."
    done
    major=${current%%.*}
    rest=${current#*.}
    minor=${rest%%.*}
    patch=${rest#*.}
    case "$request" in
        patch) version=$major.$minor.$((patch + 1)) ;;
        minor) version=$major.$((minor + 1)).0 ;;
        major) version=$((major + 1)).0.0 ;;
        *) version=$request ;;
    esac
    [ "$(printf '%s\n%s\n' "$current" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$version" ] \
        && [ "$version" != "$current" ] || fail "Version $version is not above the current $current."
    [ "$(git rev-parse "v$current^{commit}" 2>/dev/null || true)" != "$(git rev-parse HEAD)" ] \
        || fail "main has nothing new since v$current; to build v$current again, run scripts/release.sh $current."
    git ls-remote --exit-code --tags origin "refs/tags/v$version" >/dev/null \
        && fail "Tag v$version is on origin but not here; run git fetch --tags and try again."

    step "Setting the version to $version (was $current)"
    sed -i '' "s|<key>CFBundleShortVersionString</key><string>$current</string>|<key>CFBundleShortVersionString</key><string>$version</string>|" \
        "$app_plist" "$cli_plist"
    sed -i '' "s|version: \"$current\"|version: \"$version\"|" "$cli_root"
    # Exactly one line in each of the three files, and nothing else.
    changes=$(git diff --numstat)
    expected=$(printf '1\t1\t%s\n' "$app_plist" "$cli_plist" "$cli_root" | sort -k3)
    [ "$(printf '%s\n' "$changes" | sort -k3)" = "$expected" ] || {
        git checkout -- "$app_plist" "$cli_plist" "$cli_root"
        fail "The version change touched more than the three version lines; nothing was committed."
    }
    plutil -lint -s "$app_plist" "$cli_plist" || fail "An Info.plist no longer parses after the version change."

    git commit --quiet -m "Set the version to $version" -- "$app_plist" "$cli_plist" "$cli_root"
    git tag -a "v$version" -m "Voice is Local $version"
    step "Pushing main and v$version"
    git push --atomic origin main "v$version"
fi

build_number=${BUILD:-$(git tag --list 'v[0-9]*' --merged HEAD | wc -l | tr -d ' ')}
step "Building Voice is Local $version (build $build_number)"
DEVELOPER_ID=$developer_id NOTARY_PROFILE=$notary_profile ./scripts/release-app.sh "$version" "$build_number"
