#!/bin/sh
# Size ratchet for the Swift files under Sources/ (AGENTS.md "Size caps").
#
#   scripts/check-size.sh
#       Check the tree against scripts/size-baseline.txt.
#   scripts/check-size.sh --update-baseline [--allow-growth FILE]...
#       Rewrite the baseline from the tree. Refused while a check would fail, unless every failing file is
#       named with --allow-growth (a reason goes in the PR description).
#
# The baseline lists every source file over the soft cap (600 lines) with its line count, one
# "<count> <path>" per line. The check fails when:
#   - a file over the hard cap (1,000 lines) has more lines than its baseline entry, or
#   - a file without a baseline entry is over the hard cap.
# It warns when a file without an entry is over the soft cap, or when a listed file grows but
# stays within the hard cap. Files that shrank or are gone are listed so the baseline can be lowered.
# A missing or empty baseline, or a file that cannot be read, is an error. Tests/ is not checked.
set -eu

soft=600
hard=1000

root=$(cd "$(dirname "$0")/.." && pwd)
baseline="$root/scripts/size-baseline.txt"

usage() {
    echo "usage: scripts/check-size.sh [--update-baseline [--allow-growth FILE]...]" >&2
}

mode=check
work=$(mktemp -d "${TMPDIR:-/tmp}/check-size.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
allowed="$work/allowed"
: >"$allowed"

while [ $# -gt 0 ]; do
    case "$1" in
        --update-baseline) mode=update ;;
        --allow-growth)
            [ $# -ge 2 ] || { usage; exit 64; }
            printf '%s\n' "$2" >>"$allowed"
            shift
            ;;
        -h | --help) usage; exit 0 ;;
        *) usage; exit 64 ;;
    esac
    shift
done
if [ "$mode" = check ] && [ -s "$allowed" ]; then
    echo "check-size: --allow-growth only applies with --update-baseline" >&2
    exit 64
fi

cd "$root"

# Line counts of every Swift file under Sources/. find exits non-zero when it cannot read a
# folder or when wc fails on a file, so a partial scan stops the script instead of passing.
counts="$work/counts"
if ! find Sources -type f -name '*.swift' -exec wc -l {} + >"$counts"; then
    echo "check-size: could not read every file under Sources/" >&2
    exit 2
fi

if [ ! -s "$baseline" ] || ! grep -q '^[0-9]' "$baseline"; then
    echo "check-size: scripts/size-baseline.txt is missing or empty; restore it from git" >&2
    exit 2
fi

next="$work/baseline"
status=0
awk -v soft="$soft" -v hard="$hard" -v mode="$mode" -v base="$baseline" -v allowed="$allowed" -v out="$next" '
    # "<count> <path>": the path is the rest of the line, spaces included.
    function parse(line) {
        count = line; sub(/[ \t].*$/, "", count)
        path = line; sub(/^[ \t]*[0-9]+[ \t]+/, "", path)
    }
    BEGIN {
        entries = 0
        while ((getline line < base) > 0) {
            if (line ~ /^#/ || line !~ /^[0-9]+[ \t]+[^ \t]/) continue
            parse(line); limit[path] = count + 0; entries++
        }
        close(base)
        if (entries == 0) { print "check-size: the baseline has no entries" > "/dev/stderr"; exit 2 }
        while ((getline line < allowed) > 0) if (line != "") allow[line] = 1
        close(allowed)
    }
    {
        line = $0; sub(/^[ \t]+/, "", line)
        parse(line)
        if (path !~ /^Sources\//) next
        n = count + 0; f = path; seen[f] = 1; current[f] = n
        if (f in limit) {
            b = limit[f]
            if (n > b && n > hard) {
                fail(sprintf("%s: %d lines, baseline %d (files over %d lines may not grow)", f, n, b, hard))
            } else if (n > b) {
                printf "warn  %s: grew from %d to %d lines (soft cap %d)\n", f, b, n, soft; warned++
            } else if (n < b) {
                notes = notes sprintf("note  %s: %d lines, baseline %d\n", f, n, b)
            }
        } else if (n > hard) {
            fail(sprintf("%s: %d lines, over the %d-line cap and not in the baseline", f, n, hard))
        } else if (n > soft) {
            printf "warn  %s: %d lines, over the %d-line soft cap\n", f, n, soft; warned++
        }
    }
    function fail(message) {
        if (mode == "update" && (f in allow)) { printf "allow %s\n", message; return }
        printf "FAIL  %s\n", message; failed++
    }
    END {
        if (entries == 0) exit 2
        for (f in limit) if (!(f in seen)) notes = notes sprintf("note  %s: in the baseline but gone\n", f)
        for (f in allow) if (!(f in seen)) { printf "FAIL  --allow-growth %s: no such file under Sources/\n", f; failed++ }
        if (mode == "update") {
            if (failed > 0) {
                printf "check-size: %d failure(s); baseline not written (name intended growth with --allow-growth)\n", failed
                exit 1
            }
            print "# Line counts of Sources/ Swift files over " soft " lines; read by scripts/check-size.sh." > out
            print "# Regenerate with scripts/check-size.sh --update-baseline. A raised entry needs a" > out
            print "# reason in the PR description (AGENTS.md \"Size caps\")." > out
            for (f in current) if (current[f] > soft) printf "%d %s\n", current[f], f > out
            close(out)
            exit 0
        }
        if (notes != "") {
            printf "%s", notes
            print "note  lower the baseline with scripts/check-size.sh --update-baseline"
        }
        printf "check-size: %d failure(s), %d warning(s)\n", failed, warned
        exit (failed > 0)
    }
' "$counts" || status=$?

if [ "$status" -ne 0 ] || [ "$mode" = check ]; then
    exit "$status"
fi

# Header first, then entries sorted by path; written aside and moved into place.
grep '^#' "$next" >"$work/sorted"
grep -v '^#' "$next" >"$work/entries" || true
LC_ALL=C sort -k 2 "$work/entries" >>"$work/sorted"
mv "$work/sorted" "$baseline"
echo "check-size: wrote $(grep -vc '^#' "$baseline") entries to scripts/size-baseline.txt"
