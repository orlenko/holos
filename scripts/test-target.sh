#!/bin/sh
set -eu

# Builds and runs one test target, with the environment and plug-in setup of scripts/test.sh:
#
#   ./scripts/test-target.sh HolosStorageTests
#   ./scripts/test-target.sh HolosStorageTests --filter sessionLocks
#
# Only that target and the modules it depends on are built: not WhisperKit, FluidAudio, the app, or the other test
# targets unless the target needs them. Options after the target (`--filter`, `--skip`, `--no-parallel`, ...) go to
# Swift Testing as `swift test` passes them.

if [ $# -lt 1 ]; then
    echo "usage: $0 <TestTarget> [test options...]" >&2
    exit 64
fi
target=$1
shift
case "$target" in
    *Tests) ;;
    *) echo "Not a test target: $target" >&2; exit 64 ;;
esac
cd "$(dirname "$0")/.."
if [ ! -d "Tests/$target" ]; then
    echo "No such test target: Tests/$target" >&2
    exit 64
fi

holos_test_root=""
cleanup() {
    if [ -n "$holos_test_root" ]; then
        rm -rf "$holos_test_root"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# As in scripts/test.sh: sessions and support files always go to a fresh temporary folder; values already set in
# the environment are replaced, so a shell that points them at real data cannot leak into a test run.
if [ -n "${HOLOS_DATA_DIR:-}" ] || [ -n "${HOLOS_SUPPORT_DIR:-}" ]; then
    echo "test-target.sh: ignoring HOLOS_DATA_DIR/HOLOS_SUPPORT_DIR from the environment; tests use a temporary folder" >&2
fi
temporary_base=${TMPDIR:-/tmp}
holos_test_root=$(mktemp -d "${temporary_base%/}/holos-test.XXXXXX")
HOLOS_DATA_DIR="$holos_test_root/Sessions"
HOLOS_SUPPORT_DIR="$holos_test_root/Support"
mkdir -m 700 "$HOLOS_DATA_DIR" "$HOLOS_SUPPORT_DIR"
export HOLOS_DATA_DIR HOLOS_SUPPORT_DIR

swiftc_path=$(xcrun --find swiftc)
toolchain_usr=${swiftc_path%/bin/swiftc}
plugin="$toolchain_usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
helper="$toolchain_usr/libexec/swift/pm/swiftpm-testing-helper"
if [ "$toolchain_usr" = "$swiftc_path" ] || [ ! -x "$helper" ]; then
    echo "Could not locate the Swift toolchain's test runner from: $swiftc_path" >&2
    exit 1
fi

if [ -f "$plugin" ]; then
    swift build --build-system swiftbuild --target "$target" -Xswiftc -load-plugin-library -Xswiftc "$plugin"
else
    swift build --build-system swiftbuild --target "$target"
fi

# `swift test --skip-build` would open every test target's bundle, and fails on the ones this build did not make.
# Run this target's bundle the way `swift test` does, with SwiftPM's own test runner.
# Like `swift test`, point the loader at the developer folder's Testing.framework (Command Line Tools or Xcode).
bundle="$(swift build --build-system swiftbuild --show-bin-path)/$target.xctest/Contents/MacOS/$target"
developer=$(xcode-select -p)
frameworks=""
libraries=""
for folder in "$developer/Library/Developer" "$developer/Platforms/MacOSX.platform/Developer"; do
    [ -d "$folder/Library/Frameworks" ] && frameworks="$frameworks${frameworks:+:}$folder/Library/Frameworks"
    [ -d "$folder/Frameworks" ] && frameworks="$frameworks${frameworks:+:}$folder/Frameworks"
    [ -d "$folder/usr/lib" ] && libraries="$libraries${libraries:+:}$folder/usr/lib"
done
export DYLD_FRAMEWORK_PATH="$frameworks${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
export DYLD_LIBRARY_PATH="$libraries${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
status=0
"$helper" --test-bundle-path "$bundle" "$@" "$bundle" --testing-library swift-testing || status=$?
exit "$status"
