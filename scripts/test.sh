#!/bin/sh
set -eu

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

if [ -f "$plugin" ]; then
    exec swift test --build-system swiftbuild --disable-xctest \
        -Xswiftc -load-plugin-library -Xswiftc "$plugin" "$@"
fi

exec swift test --build-system swiftbuild --disable-xctest "$@"
