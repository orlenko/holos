#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build "$@"
holos_bin_dir=$(swift build --show-bin-path "$@")
codesign --force --sign - --identifier ca.orlenko.holos.cli "$holos_bin_dir/holos"
printf 'Built %s/holos\n' "$holos_bin_dir"
