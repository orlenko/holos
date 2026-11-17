#!/bin/sh
# Releases Voice is Local in two runs, on the Mac that holds the Developer ID key. The first sets the next version
# and opens a pull request for it; once that is merged, the second tags the version commit, pushes the tag, builds,
# signs, and notarizes the DMG with scripts/release-app.sh, and publishes it: the GitHub release, voiceislocal.com
# (the site's scripts/publish-release.sh), and the Homebrew cask.
#
#   scripts/release.sh [patch|minor|major|<version>] [--notes FILE] [--no-publish]
#
# patch (the default), minor, or major raises the version in Resources/App-Info.plist and opens the pull request.
# <version> opens it too, unless origin/main already has that version: then the commit that set it is tagged
# v<version> and built. A version whose tag v<version> already exists (on origin, at the same commit) is built again
# without a new commit: use it to resume after a failed build or notarization. A finished build of it (the DMG,
# stapled, and an appcast offering it) is published without building again, and one whose DMG is already on GitHub
# is never rebuilt: a rebuilt DMG differs from the published one, which the website refuses.
#   DEVELOPER_ID    signing identity; default "Developer ID Application: Bjola Software Inc. (LC28ZF5453)".
#   NOTARY_PROFILE  notarytool keychain profile; default voiceislocal-notary.
#   BUILD           CFBundleVersion; default the number of v* release tags, this one included (1.0.0 was 1).
# --notes FILE: the release's "## What's new" section in Markdown; the GitHub release adds the install steps and the
# SHA-256. Needed unless the GitHub release v<version> exists. --no-publish stops after the build.
#   SITE_PUBLISHER  the site's publisher; default ../voiceislocal.com/scripts/publish-release.sh next to this clone.
# A new version starts from a clean main that matches origin/main. The version commit changes only the three
# version lines (both Info.plists and `voiceislocal --version`) and goes to main through a pull request on
# release/v<version>, which any merge method may merge. Run it in the Mac's own session, not over SSH, so the keychain
# can ask for the signing key. See docs/release.md.
set -eu

usage() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

request="patch"
notes=
publish=yes
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --notes)
            [ $# -ge 2 ] || { printf 'release: --notes needs a file.\n' >&2; exit 1; }
            # Absolute, since the script runs from the repository root.
            case "$2" in /*) notes=$2 ;; *) notes=$PWD/$2 ;; esac
            shift 2
            ;;
        --no-publish) publish=no; shift ;;
        -*) printf 'release: unknown option %s\n' "$1" >&2; exit 1 ;;
        *)
            [ -z "${request_given:-}" ] \
                || { printf 'release: more than one version given (%s, %s).\n' "$request" "$1" >&2; exit 1; }
            request=$1
            request_given=yes
            shift
            ;;
    esac
done
cd "$(dirname "$0")/.."

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
sparkle_bin=$PWD/.build/artifacts/sparkle/Sparkle/bin
generate_keys=$sparkle_bin/generate_keys
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

# The rest is one function, read whole before it runs: switching to a tag below replaces this file on disk.
main() {
start_branch=$(git symbolic-ref --quiet --short HEAD || true)
work=$(mktemp -d)
switched=no
# However the run ends: temporary files go, and a run that switched to the tag returns to the starting branch.
trap 'rm -rf "$work"; [ "$switched" = no ] || [ -z "$start_branch" ] || git switch --quiet "$start_branch" || true' EXIT
merged_version=$(git show "origin/main:$app_plist" | plutil -extract CFBundleShortVersionString raw -o - - 2>/dev/null \
    || true)
if is_version "$request" && git rev-parse --quiet --verify "refs/tags/v$request" >/dev/null; then
    version=$request
    check_publishing
    step "Tag v$version exists; building and publishing it from there"
    # Back to the starting branch however the build ends: the tag may predate this script, so a retry needs it.
    switched=yes
    git switch --quiet --detach "v$version"
elif is_version "$request" && [ "$request" = "$merged_version" ]; then
    version=$request
    check_publishing
    # The version pull request is merged, by whatever method: the newest commit on origin/main that changes the
    # version line is the one that set it.
    version_commit=$(git log -1 --format=%H -F \
        -S "<key>CFBundleShortVersionString</key><string>$version</string>" origin/main -- "$app_plist")
    [ -n "$version_commit" ] || fail "No commit on origin/main sets the version to $version."
    git tag -a "v$version" -m "Voice is Local $version" "$version_commit"
    step "Pushing v$version ($(git rev-parse --short "$version_commit"))"
    git push --quiet origin "v$version"
    switched=yes
    git switch --quiet --detach "v$version"
else
    command -v gh >/dev/null || fail "The GitHub CLI (gh) opens the version pull request; install it first."
    [ "$start_branch" = main ] || fail "Switch to main first (git switch main)."
    [ -z "$notes" ] && [ "$publish" = yes ] \
        || fail "--notes and --no-publish are for the second run, which builds; this run only opens the version pull request."
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

release_dir=$PWD/build/release
dmg=$release_dir/VoiceIsLocal-$version.dmg
# A plain assignment, so a gh failure stops the script under set -e.
# With --no-publish too: a rebuild would delete a published DMG and its signed appcast.
published_digest=$(github_dmg_digest)
if built; then
    step "VoiceIsLocal-$version.dmg is built, notarized and stapled; not building it again"
elif [ -n "$published_digest" ]; then
    # A rebuild would differ from the DMG already published, and release-app.sh deletes the files it replaces.
    fail "GitHub release v$version already has VoiceIsLocal-$version.dmg (or an upload of it), but $release_dir does not hold that finished build (missing, not stapled, or its appcast does not verify: sign_update --verify says why). Not rebuilding a published version: restore the build, or release a new version."
else
    build_number=${BUILD:-$(git tag --list 'v[0-9]*' --merged HEAD | wc -l | tr -d ' ')}
    step "Building Voice is Local $version (build $build_number)"
    DEVELOPER_ID=$developer_id NOTARY_PROFILE=$notary_profile ./scripts/release-app.sh "$version" "$build_number"
    built || fail "The build did not leave a stapled $dmg and an appcast offering it."
fi
[ "$publish" = yes ] || { printf '\nNot published (--no-publish).\n'; exit 0; }
publish_github
publish_site
publish_cask
printf '\nVoice is Local %s is published: GitHub, voiceislocal.com, and the Homebrew cask.\n' "$version"
}

app_repo=orlenko/holos
site_publisher=${SITE_PUBLISHER:-$(cd .. && pwd)/voiceislocal.com/scripts/publish-release.sh}

# Before tagging or building: what publishing needs is here.
check_publishing() {
    # Also without publishing: gh tells whether the DMG is already on GitHub, which must never be rebuilt.
    command -v gh >/dev/null || fail "The GitHub CLI (gh) is needed to build and publish a release; install it first."
    [ "$publish" = yes ] || return 0
    [ -x "$site_publisher" ] \
        || fail "No website publisher at $site_publisher; clone orlenko/voiceislocal.com next to this clone, set SITE_PUBLISHER, or pass --no-publish."
    if [ -n "$notes" ]; then
        [ -s "$notes" ] || fail "$notes is missing or empty."
        # The heading the site's publisher looks for.
        grep -Eiq "^## +What['’]s new[[:space:]]*\$" "$notes" || fail "$notes has no \"## What's new\" heading line."
    fi
    if github_release_exists; then
        [ -z "$notes" ] || printf 'release: the GitHub release v%s exists, so --notes is not used; edit it there.\n' "$version" >&2
    elif [ -z "$notes" ]; then
        fail "No GitHub release v$version yet: pass --notes FILE with its \"## What's new\" section, or --no-publish."
    fi
}

# Whether orlenko/holos has a release v<version> (a draft too); any other gh failure stops the script.
github_release_exists() {
    if gh release view "v$version" -R "$app_repo" --json tagName >/dev/null 2>"$work/gh.err"; then
        return 0
    fi
    grep -q 'release not found' "$work/gh.err" && return 1
    fail "gh release view v$version failed: $(cat "$work/gh.err")"
}

# The digest GitHub has for the release's DMG ("pending" while an upload is unfinished), or nothing.
github_dmg_digest() {
    github_release_exists || return 0
    gh release view "v$version" -R "$app_repo" --json assets \
        --jq "[.assets[] | select(.name == \"VoiceIsLocal-$version.dmg\") | .digest // \"pending\"] | first // \"\"" \
        || fail "Reading the GitHub release v$version failed."
}

# This version's finished build: the DMG with its notarization ticket stapled, and the appcast release-app.sh writes
# last, offering this DMG at its length and signed with the Sparkle key (a run that stopped before signing it is not
# finished).
built() {
    [ -f "$dmg" ] && [ -f "$release_dir/appcast.xml" ] || return 1
    grep -Fq "/VoiceIsLocal-$version.dmg\"" "$release_dir/appcast.xml" || return 1
    grep -Fq "length=\"$(stat -f %z "$dmg")\"" "$release_dir/appcast.xml" || return 1
    xcrun stapler validate -q "$dmg" >/dev/null 2>&1 || return 1
    "$sparkle_bin/sign_update" --verify "$release_dir/appcast.xml" >/dev/null
}

dmg_sha() {
    shasum -a 256 "$dmg" | awk '{print $1}'
}

# The GitHub release: the notes' "What's new", then how to install, with the DMG attached. A release an earlier run
# left as a draft, or without the DMG, is finished here.
publish_github() {
    step "GitHub release v$version"
    if github_release_exists; then
        digest=$(github_dmg_digest)
        if [ -z "$digest" ] || [ "$digest" = pending ]; then
            # Missing, or an upload an earlier run left unfinished.
            gh release upload "v$version" "$dmg" -R "$app_repo" --clobber \
                || fail "Uploading the DMG to the GitHub release failed; run this again."
        elif [ "$digest" != "sha256:$(dmg_sha)" ]; then
            fail "The GitHub release v$version has a different VoiceIsLocal-$version.dmg ($digest)."
        fi
        is_draft=$(gh release view "v$version" -R "$app_repo" --json isDraft --jq .isDraft) \
            || fail "Reading whether GitHub release v$version is a draft failed; run this again."
        if [ "$is_draft" = true ]; then
            gh release edit "v$version" -R "$app_repo" --draft=false >/dev/null \
                || fail "Publishing the draft release failed; run this again."
        fi
        printf '    published\n'
        return 0
    fi
    # The site's checks first, the notes' Markdown included, so a release it would refuse is not published anywhere.
    "$site_publisher" "$version" "$release_dir" --notes "$notes" --dry-run >/dev/null \
        || fail "The website's publisher refused this release (dry run above); nothing is published."
    body=$work/notes.md
    {
        cat "$notes"
        cat <<NOTES

## Install

- **Download:** \`VoiceIsLocal-$version.dmg\` below, or from [voiceislocal.com](https://voiceislocal.com/).
- **Homebrew:** Homebrew loads casks from other taps only once you trust them, so run both:

  \`\`\`sh
  brew trust --cask orlenko/tap/voiceislocal
  brew install --cask orlenko/tap/voiceislocal
  \`\`\`
- **Update from 1.0.2 or later:** Check for Updates… in the app's Voice is Local menu (in the menu bar menu before 1.0.7).

Needs macOS 27 or later, on Apple Silicon. Signed by Bjola Software Inc. and notarized by Apple.

SHA-256: \`$(dmg_sha)\`
NOTES
    } >"$body"
    gh release create "v$version" "$dmg" -R "$app_repo" --verify-tag --title "Voice is Local $version" --notes-file "$body" \
        || fail "Creating the GitHub release failed; run this again."
}

# voiceislocal.com: the DMG, the pages, then the appcast, each checked over HTTPS (the site's README, "Releases").
publish_site() {
    step "voiceislocal.com"
    "$site_publisher" "$version" "$release_dir" \
        || fail "The website's publisher stopped (its message is above); fix the cause and run this again."
}

# The Homebrew cask's version and sha256, through a pull request on orlenko/homebrew-tap, once the DMG is live.
publish_cask() {
    step "Homebrew cask"
    sha=$(dmg_sha)
    tap=$work/tap
    gh repo clone orlenko/homebrew-tap "$tap" -- --quiet || fail "Cloning orlenko/homebrew-tap failed."
    cask=$tap/Casks/voiceislocal.rb
    [ -f "$cask" ] || fail "orlenko/homebrew-tap has no Casks/voiceislocal.rb."
    if grep -Fq "  version \"$version\"" "$cask" && grep -Fq "  sha256 \"$sha\"" "$cask"; then
        printf '    already at %s\n' "$version"
        return 0
    fi
    current=$(sed -n 's/^  version "\(.*\)"$/\1/p' "$cask")
    if [ "$(printf '%s\n%s\n' "$current" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" != "$version" ]; then
        printf '    the cask is at %s, newer than %s; left as it is\n' "$current" "$version"
        return 0
    fi
    sed -i '' -e "s|^  version \".*\"$|  version \"$version\"|" -e "s|^  sha256 \".*\"$|  sha256 \"$sha\"|" "$cask"
    [ "$(git -C "$tap" diff --numstat)" = "$(printf '2\t2\tCasks/voiceislocal.rb')" ] \
        || fail "The cask change is not exactly its version and sha256 lines; nothing was pushed ($tap)."
    branch=voiceislocal-$version
    git -C "$tap" switch --quiet -c "$branch"
    git -C "$tap" commit --quiet -am "voiceislocal $version"
    # A failed earlier run may have left the branch and its pull request: this commit replaces them.
    git -C "$tap" push --quiet --force origin "$branch" || fail "Pushing $branch to orlenko/homebrew-tap failed."
    # An open pull request from an earlier run takes the new commit; a closed or merged one does not count.
    [ "$(gh pr view "$branch" -R orlenko/homebrew-tap --json state --jq .state 2>/dev/null)" = OPEN ] \
        || gh pr create -R orlenko/homebrew-tap --base main --head "$branch" --title "voiceislocal $version" \
            --body "Bumps the cask to $version: the DMG is live at the cask's URL; sha256 $sha." >/dev/null \
        || fail "Opening the cask pull request failed; $branch is pushed."
    gh pr merge "$branch" -R orlenko/homebrew-tap --squash --delete-branch >/dev/null \
        || printf 'release: merging the cask pull request failed (above); checking the cask anyway.\n' >&2
    live=$(gh api repos/orlenko/homebrew-tap/contents/Casks/voiceislocal.rb --jq .content) \
        || fail "Reading the cask back from orlenko/homebrew-tap failed; run this again."
    live=$(printf '%s' "$live" | base64 -d) || fail "The cask read back from orlenko/homebrew-tap is not valid base64."
    printf '%s\n' "$live" | grep -Fq "  sha256 \"$sha\"" \
        || fail "The cask pull request for $version is not merged; merge it on orlenko/homebrew-tap and run this again."
    printf '    merged: version %s, sha256 %s\n' "$version" "$sha"
}

main; exit $?
