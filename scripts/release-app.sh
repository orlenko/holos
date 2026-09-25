#!/bin/sh
# Builds a release Voice is Local.app for direct download: signed for the hardened runtime, packaged in a DMG, and,
# with credentials, notarized and stapled. Everything goes to build/release; it never touches build/VoiceIsLocal.app
# and never installs, launches, or quits the app. See docs/release.md for the one-time setup.
#
#   scripts/release-app.sh [VERSION [BUILD]]
#
# VERSION (CFBundleShortVersionString) and BUILD (CFBundleVersion) come from the arguments, else from the VERSION and
# BUILD environment variables, else from Resources/App-Info.plist.
#   DEVELOPER_ID    signing identity, e.g. "Developer ID Application: Bjola Software Inc. (TEAMID)". Unset: a dry run, signed
#                   ad-hoc, for local testing only.
#   NOTARY_PROFILE  a keychain profile saved with `xcrun notarytool store-credentials`. With DEVELOPER_ID, the app
#                   and the DMG are notarized and stapled.
set -eu
cd "$(dirname "$0")/.."

case "${1:-}" in
    -h|--help)
        sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
esac

fail() {
    printf 'release-app: %s\n' "$*" >&2
    exit 1
}
step() {
    printf '\n==> %s\n' "$*"
}

app_plist_source=Resources/App-Info.plist
app_entitlements=Resources/VoiceIsLocal.entitlements
cli_entitlements=Resources/voiceislocal-cli.entitlements
icon_source=Resources/Icon/VoiceIsLocal.icns
app_identifier=ca.orlenko.holos.app
cli_identifier=ca.orlenko.holos.cli

version=${1:-${VERSION:-}}
build_number=${2:-${BUILD:-}}
[ -n "$version" ] || version=$(plutil -extract CFBundleShortVersionString raw -o - "$app_plist_source")
[ -n "$build_number" ] || build_number=$(plutil -extract CFBundleVersion raw -o - "$app_plist_source")
# The version names the DMG file; the build number must be what macOS compares (integers separated by dots).
case "$version" in
    *[!A-Za-z0-9.-]*|'') fail "VERSION '$version' may only contain letters, digits, dots, and hyphens." ;;
esac
case "$build_number" in
    *[!0-9.]*|.*|*.|*..*|'') fail "BUILD '$build_number' must be integers separated by dots, such as 12 or 1.0.12." ;;
esac
version_is_numeric=yes
case "$version" in
    *[!0-9.]*|.*|*.|*..*) version_is_numeric=no ;;
esac

developer_id=${DEVELOPER_ID:-}
notary_profile=${NOTARY_PROFILE:-}
if [ -n "$developer_id" ]; then
    # A published version must be one macOS and update tools can compare, such as 1.2.0.
    [ "$version_is_numeric" = yes ] || fail "VERSION '$version' must be integers separated by dots (such as 1.2.0) for a signed release."
    case "$developer_id" in
        "Developer ID Application:"*) ;;
        *) printf 'release-app: warning: DEVELOPER_ID does not start with "Developer ID Application:". Only that certificate type passes Gatekeeper outside the Mac App Store.\n' >&2 ;;
    esac
    sign_identity=$developer_id
    timestamp=--timestamp
else
    [ -z "$notary_profile" ] || fail "NOTARY_PROFILE is set but DEVELOPER_ID is not: Apple does not notarize ad-hoc signed apps."
    sign_identity=-
    # Ad-hoc signatures carry no secure timestamp.
    timestamp=--timestamp=none
fi

release_root="$PWD/build/release"
app_bundle="$release_root/VoiceIsLocal.app"
app_executable="$app_bundle/Contents/MacOS/HolosApp"
cli_executable="$app_bundle/Contents/MacOS/voiceislocal"
dmg_root="$release_root/dmg-root"
dmg="$release_root/VoiceIsLocal-$version.dmg"
app_zip="$release_root/VoiceIsLocal-$version-notarize.zip"

for file in "$app_plist_source" "$app_entitlements" "$cli_entitlements"; do
    plutil -lint "$file" >/dev/null || fail "$file is not a valid property list."
done

# Replacing the files of a running copy invalidates its signature mid-run. Only the release copy is checked: this
# script never writes anywhere else.
if pgrep -f "$app_bundle/Contents/MacOS/" >/dev/null 2>&1; then
    fail "A copy of Voice is Local (or its recorder) is running from build/release/VoiceIsLocal.app. Quit it, then try again."
fi

step "Building release products (version $version, build $build_number)"
swift build -c release --product HolosApp
swift build -c release --product voiceislocal
bin_dir=$(swift build -c release --show-bin-path)

step "Assembling $app_bundle"
rm -rf "$app_bundle" "$dmg_root" "$dmg" "$app_zip"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$app_plist_source" "$app_bundle/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app_bundle/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$app_bundle/Contents/Info.plist"
if [ -f "$icon_source" ]; then
    cp "$icon_source" "$app_bundle/Contents/Resources/VoiceIsLocal.icns"
    plutil -replace CFBundleIconFile -string VoiceIsLocal "$app_bundle/Contents/Info.plist"
else
    printf 'No %s; the app keeps the generic icon.\n' "$icon_source"
fi
plutil -lint "$app_bundle/Contents/Info.plist"
cp LICENSE "$app_bundle/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$app_bundle/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$bin_dir/HolosApp" "$app_executable"
cp "$bin_dir/voiceislocal" "$cli_executable"
# Extended attributes such as Finder info make codesign refuse the bundle.
xattr -cr "$app_bundle"

step "Signing with the hardened runtime (identity: $sign_identity)"
# Inside out: the bundled tool first, then the bundle, whose signature seals the tool's. The identifiers match the
# local builds, so settings keyed to the bundle ID carry over.
codesign --force --options runtime "$timestamp" --entitlements "$cli_entitlements" \
    --identifier "$cli_identifier" --sign "$sign_identity" "$cli_executable"
codesign --force --options runtime "$timestamp" --entitlements "$app_entitlements" \
    --identifier "$app_identifier" --sign "$sign_identity" "$app_bundle"

step "Verifying the signatures"
codesign --verify --deep --strict --verbose=2 "$app_bundle"
verify_binary() {
    # $1: the executable, $2: the identifier it must be signed with.
    name=${1#"$PWD"/}
    printf -- '-- %s\n' "$name"
    codesign -d --entitlements - --verbose=2 "$1" 2>&1
    details=$(codesign -d --verbose=2 "$1" 2>&1)
    printf '%s\n' "$details" | grep -qxF "Identifier=$2" || fail "$name is not signed with the identifier $2."
    case "$details" in
        *'flags='*runtime*) ;;
        *) fail "$name is not signed with the hardened runtime." ;;
    esac
    printf 'Architectures: %s\n' "$(lipo -archs "$1")"
    # Every library should be a system one (/usr/lib, /System): a bundled dynamic library would need to be copied
    # into the app and signed by the same team, or library validation refuses to load it.
    printf 'Linked libraries:\n'
    otool -L "$1" | sed 1d
    if otool -L "$1" | sed 1d | grep -v -e '^[[:space:]]*/usr/lib/' -e '^[[:space:]]*/System/' >/dev/null; then
        fail "$name links a library outside /usr/lib and /System, which this script does not bundle."
    fi
}
verify_binary "$app_executable" "$app_identifier"
verify_binary "$cli_executable" "$cli_identifier"

notarize() {
    # $1: the file to submit. Waits for Apple's verdict and fails unless it is Accepted.
    result="$release_root/notary-$(basename "$1").json"
    printf 'Submitting %s to Apple for notarization (usually a few minutes)...\n' "$(basename "$1")"
    submit_status=0
    xcrun notarytool submit "$1" --keychain-profile "$notary_profile" --wait --output-format json >"$result" \
        || submit_status=$?
    submission_id=$(plutil -extract id raw -o - "$result" 2>/dev/null || true)
    submission_status=$(plutil -extract status raw -o - "$result" 2>/dev/null || true)
    if [ "$submission_status" != Accepted ]; then
        printf '\nNOTARIZATION FAILED for %s: status "%s" (notarytool exit %s).\n' \
            "$(basename "$1")" "${submission_status:-unknown}" "$submit_status" >&2
        cat "$result" >&2 || true
        if [ -n "$submission_id" ]; then
            printf '\nSee why with:\n  xcrun notarytool log %s --keychain-profile "%s"\n' \
                "$submission_id" "$notary_profile" >&2
        fi
        exit 1
    fi
    printf 'Accepted (submission %s).\n' "$submission_id"
    rm -f "$result"
}

notarized=no
if [ -n "$developer_id" ] && [ -n "$notary_profile" ]; then
    # The app is notarized and stapled on its own first, so the copy in the DMG carries its ticket and opens
    # without a network check even after it is dragged out; then the DMG that holds it is notarized and stapled.
    step "Notarizing the app"
    ditto -c -k --keepParent "$app_bundle" "$app_zip"
    notarize "$app_zip"
    rm -f "$app_zip"
    xcrun stapler staple "$app_bundle"
    xcrun stapler validate "$app_bundle"
fi

step "Packaging $dmg"
mkdir -p "$dmg_root"
ditto "$app_bundle" "$dmg_root/VoiceIsLocal.app"
ln -s /Applications "$dmg_root/Applications"
cp LICENSE "$dmg_root/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$dmg_root/THIRD_PARTY_NOTICES.md"
hdiutil create -volname "Voice is Local" -srcfolder "$dmg_root" -format UDZO -ov "$dmg"
rm -rf "$dmg_root"
if [ -n "$developer_id" ]; then
    codesign --force --timestamp --sign "$developer_id" "$dmg"
    codesign --verify --strict --verbose=2 "$dmg"
fi

if [ -n "$developer_id" ] && [ -n "$notary_profile" ]; then
    step "Notarizing the DMG"
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    notarized=yes
fi

if [ -n "$developer_id" ]; then
    step "Gatekeeper assessment"
    if [ "$notarized" = yes ]; then
        spctl --assess --type execute --verbose "$app_bundle"
        spctl --assess --type open --context context:primary-signature --verbose "$dmg"
    else
        # Gatekeeper rejects a Developer ID app until Apple has notarized it.
        spctl --assess --type execute --verbose "$app_bundle" \
            || printf 'Rejected as expected: the app is not notarized. Set NOTARY_PROFILE to notarize it.\n'
    fi
fi

step "Done"
dmg_sha=$(shasum -a 256 "$dmg" | awk '{print $1}')
printf 'DMG:     %s\n' "$dmg"
printf 'SHA-256: %s\n' "$dmg_sha"
if [ -z "$developer_id" ]; then
    printf '\nDRY RUN: signed ad-hoc and not notarized. This build is for local testing only; Gatekeeper blocks it on\n'
    printf 'other Macs. Set DEVELOPER_ID and NOTARY_PROFILE for a release (docs/release.md).\n'
elif [ "$notarized" = no ]; then
    printf '\nSigned with %s but NOT notarized: Gatekeeper blocks it on other Macs.\n' "$developer_id"
    printf 'Set NOTARY_PROFILE to notarize and staple it (docs/release.md).\n'
else
    printf '\nSigned, notarized, and stapled. Publish the DMG and its SHA-256.\n'
fi
