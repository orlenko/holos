#!/bin/sh
set -eu

# Keep the suite away from the user's real data: HOLOS_DATA_DIR (sessions) and HOLOS_SUPPORT_DIR
# (Application Support files such as speaker models and voice profiles) always point into a fresh
# temporary folder that is removed on exit. Values already set in the environment are replaced,
# so a shell that points them at real data cannot leak into a test run.
holos_test_root=""
cleanup() {
    if [ -n "$holos_test_root" ]; then
        rm -rf "$holos_test_root"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "${HOLOS_DATA_DIR:-}" ] || [ -n "${HOLOS_SUPPORT_DIR:-}" ]; then
    echo "test.sh: ignoring HOLOS_DATA_DIR/HOLOS_SUPPORT_DIR from the environment; tests use a temporary folder" >&2
fi
temporary_base=${TMPDIR:-/tmp}
holos_test_root=$(mktemp -d "${temporary_base%/}/holos-test.XXXXXX")
HOLOS_DATA_DIR="$holos_test_root/Sessions"
HOLOS_SUPPORT_DIR="$holos_test_root/Support"
mkdir -m 700 "$HOLOS_DATA_DIR" "$HOLOS_SUPPORT_DIR"
export HOLOS_DATA_DIR HOLOS_SUPPORT_DIR

# Apple's Command Line Tools can import Testing.framework but its swiftbuild driver
# does not always discover the TestingMacros plugin. Locate it from the selected
# compiler instead of assuming a fixed Command Line Tools installation path.
swiftc_path=$(xcrun --find swiftc)
toolchain_usr=${swiftc_path%/bin/swiftc}
plugin="$toolchain_usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

if [ "$toolchain_usr" = "$swiftc_path" ]; then
    echo "Could not locate the Swift toolchain from: $swiftc_path" >&2
    exit 1
fi

status=0
if [ -f "$plugin" ]; then
    swift test --build-system swiftbuild --disable-xctest \
        -Xswiftc -load-plugin-library -Xswiftc "$plugin" "$@" || status=$?
else
    swift test --build-system swiftbuild --disable-xctest "$@" || status=$?
fi
exit "$status"
