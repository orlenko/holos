#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build "$@"
holos_bin_dir=$(swift build --show-bin-path "$@")
codesign --force --sign - --identifier ca.orlenko.holos.cli "$holos_bin_dir/voiceislocal"
printf 'Built %s/voiceislocal\n' "$holos_bin_dir"
