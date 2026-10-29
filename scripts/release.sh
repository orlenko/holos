#!/bin/sh
# Releases Voice is Local in two runs, on the Mac that holds the Developer ID key. The first sets the next version
# and opens a pull request for it; once that is merged, the second tags the version commit, pushes the tag, and
# builds, signs, and notarizes the DMG with scripts/release-app.sh.
#
#   scripts/release.sh [patch|minor|major|<version>]
#
# patch (the default), minor, or major raises the version in Resources/App-Info.plist and opens the pull request.
# <version> opens it too, unless origin/main already has that version: then the commit that set it is tagged
# v<version> and built. A version whose tag v<version> already exists (on origin, at the same commit) is built again
# without a new commit: use it to resume after a failed build or notarization.
#   DEVELOPER_ID    signing identity; default "Developer ID Application: Bjola Software Inc. (LC28ZF5453)".
#   NOTARY_PROFILE  notarytool keychain profile; default voiceislocal-notary.
#   BUILD           CFBundleVersion; default the number of v* release tags, this one included (1.0.0 was 1).
# A new version starts from a clean main that matches origin/main. The version commit changes only the three
# version lines (both Info.plists and `voiceislocal --version`) and goes to main through a pull request on
# release/v<version>, which any merge method may merge. Run it in the Mac's own session, not over SSH, so the keychain
# can ask for the signing key. See docs/release.md.
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
# The tag must carry the public key of this Mac's Sparkle key, or no build of it could ever update an installed app.
public_ed_key=$(plutil -extract SUPublicEDKey raw -o - "$app_plist" 2>/dev/null) \
    || fail "$app_plist has no SUPublicEDKey; create the Sparkle key as docs/release.md \"Updates\" says."
generate_keys=.build/artifacts/sparkle/Sparkle/bin/generate_keys
[ -x "$generate_keys" ] || fail "$generate_keys is missing; run swift build once to fetch the Sparkle package."
keychain_ed_key=$("$generate_keys" -p) \
    || fail "No Sparkle signing key in this Mac's keychain; create it (or import its backup) as docs/release.md \"Updates\" says."
[ "$keychain_ed_key" = "$public_ed_key" ] \
    || fail "The Sparkle key in the keychain ($keychain_ed_key) is not SUPublicEDKey in $app_plist ($public_ed_key)."
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
git fetch --quiet --tags origin \
    || fail "Fetching from origin failed; if a local tag differs from origin's, git fetch --tags names it."
# Build numbers count release tags and new versions must not collide with one, so every local release tag must be on
# origin at the same object. Each remote line sits between newlines, so a tag only matches itself.
remote_tags="
$(git ls-remote --tags origin 'v[0-9]*' | tr '\t' ' ')
"
for local_tag in $(git for-each-ref --format='%(objectname)=%(refname)' 'refs/tags/v[0-9]*'); do
    case "$remote_tags" in
        *"
${local_tag%%=*} ${local_tag#*=}
"*) ;;
        *) fail "Tag ${local_tag#*=refs/tags/} is not on origin as it is here; push it or delete it (git tag -d) first." ;;
    esac
done

start_branch=$(git symbolic-ref --quiet --short HEAD || true)
merged_version=$(git show "origin/main:$app_plist" | plutil -extract CFBundleShortVersionString raw -o - - 2>/dev/null \
    || true)
if is_version "$request" && git rev-parse --quiet --verify "refs/tags/v$request" >/dev/null; then
    version=$request
    step "Tag v$version exists; building it again"
    # Back to the starting branch however the build ends: the tag may predate this script, so a retry needs it.
    [ -z "$start_branch" ] || trap 'git switch --quiet "$start_branch"' EXIT
    git switch --quiet --detach "v$version"
elif is_version "$request" && [ "$request" = "$merged_version" ]; then
    version=$request
    # The version pull request is merged, by whatever method: the newest commit on origin/main that changes the
    # version line is the one that set it.
    version_commit=$(git log -1 --format=%H -F \
        -S "<key>CFBundleShortVersionString</key><string>$version</string>" origin/main -- "$app_plist")
    [ -n "$version_commit" ] || fail "No commit on origin/main sets the version to $version."
    git tag -a "v$version" -m "Voice is Local $version" "$version_commit"
    step "Pushing v$version ($(git rev-parse --short "$version_commit"))"
    git push --quiet origin "v$version"
    [ -z "$start_branch" ] || trap 'git switch --quiet "$start_branch"' EXIT
    git switch --quiet --detach "v$version"
else
    command -v gh >/dev/null || fail "The GitHub CLI (gh) opens the version pull request; install it first."
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

    # main takes changes only through pull requests, so the version commit goes on its own branch.
    branch=release/v$version
    git switch --quiet -c "$branch"
    git commit --quiet -m "Set the version to $version" -- "$app_plist" "$cli_plist" "$cli_root"
    step "Opening the pull request for $version"
    git push --quiet origin "$branch"
    git switch --quiet main
    body="The version commit for Voice is Local $version: the three version lines, nothing else. Once it is merged,
\`scripts/release.sh $version\` on the release Mac tags it and builds the release."
    gh pr create --base main --head "$branch" --title "Set the version to $version" --body "$body" \
        || fail "Opening the pull request failed; $branch is pushed, so open it by hand."
    printf '\nMerge the pull request, then run scripts/release.sh %s to tag and build %s.\n' "$version" "$version"
    exit 0
fi

build_number=${BUILD:-$(git tag --list 'v[0-9]*' --merged HEAD | wc -l | tr -d ' ')}
step "Building Voice is Local $version (build $build_number)"
DEVELOPER_ID=$developer_id NOTARY_PROFILE=$notary_profile ./scripts/release-app.sh "$version" "$build_number"
