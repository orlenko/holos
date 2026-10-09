#!/bin/sh
# Size ratchet for the Swift files under Sources/ (AGENTS.md "Size caps").
#
#   scripts/check-size.sh
#       Check the tree against scripts/size-baseline.txt.
#   scripts/check-size.sh --update-baseline [--allow-growth FILE]...
#       Rewrite the baseline from the tree. Refused while a check would fail, and while any file in the
#       baseline has grown (even under the hard cap), unless each such file is named with --allow-growth (a
#       reason goes in the PR description). Shrunk, removed and new files under the hard cap are recorded
#       freely. A new file over the hard cap is never accepted; for a file moved whole, rename its path in the
#       baseline.
#
# The baseline lists every source file over the soft cap (600 lines) with its line count, one
# "<count> <path>" per line, and declares how many there are ("# entries: N", which may be 0).
# The check fails when:
#   - a file over the hard cap (1,000 lines) has more lines than its baseline entry, or
#   - a file without a baseline entry is over the hard cap.
# It warns when a file without an entry is over the soft cap, or when a listed file grows but
# stays within the hard cap. Files that shrank or are gone are listed so the baseline can be lowered.
# A missing or unreadable baseline, one whose entries do not match its "# entries:" line, or a
# source file that cannot be read, is an error (exit 2). Tests/ is not checked.
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

if [ ! -f "$baseline" ] || [ ! -r "$baseline" ]; then
    echo "check-size: scripts/size-baseline.txt is missing or unreadable; restore it from git" >&2
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
    function invalid(message) {
        print "check-size: scripts/size-baseline.txt " message "; restore it from git" > "/dev/stderr"
        broken = 1
        exit 2
    }
    BEGIN {
        # The baseline states its own entry count ("# entries: N"), so an empty baseline (no file over the soft
        # cap) is told apart from an emptied or cut-off one.
        entries = 0; declared = -1
        while ((r = (getline line < base)) > 0) {
            if (line ~ /^# entries: [0-9]+$/) { declared = substr(line, 12) + 0; continue }
            if (line ~ /^#/ || line ~ /^[ \t]*$/) continue
            if (line !~ /^[0-9]+[ \t]+[^ \t]/) invalid("has a line that is not \"<count> <path>\": " line)
            parse(line); limit[path] = count + 0; entries++
        }
        if (r < 0) invalid("cannot be read")
        close(base)
        if (declared < 0) invalid("has no \"# entries: N\" line")
        if (declared != entries) invalid(sprintf("lists %d entries but declares %d", entries, declared))
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
                # Under the hard cap growth only warns, but writing it into the baseline needs --allow-growth.
                if (mode == "update") fail(sprintf("%s: grew from %d to %d lines (name it with --allow-growth)", f, b, n))
                else { printf "warn  %s: grew from %d to %d lines (soft cap %d)\n", f, b, n, soft; warned++ }
            } else if (n < b) {
                notes = notes sprintf("note  %s: %d lines, baseline %d\n", f, n, b)
            }
        } else if (n > hard) {
            fail(sprintf("%s: %d lines, over the %d-line cap and not in the baseline", f, n, hard))
        } else if (n > soft) {
            printf "warn  %s: %d lines, over the %d-line soft cap\n", f, n, soft; warned++
        }
    }
    # --allow-growth only lets a file already in the baseline grow; the hard cap for a new file is absolute.
    function fail(message) {
        if (mode == "update" && (f in allow) && (f in limit)) { printf "allow %s\n", message; return }
        if ((f in allow) && !(f in limit)) message = message " (--allow-growth does not apply to new files)"
        printf "FAIL  %s\n", message; failed++
    }
    END {
        if (broken) exit 2
        for (f in limit) if (!(f in seen)) notes = notes sprintf("note  %s: in the baseline but gone\n", f)
        for (f in allow) if (!(f in seen)) { printf "FAIL  --allow-growth %s: no such file under Sources/\n", f; failed++ }
        if (mode == "update") {
            if (failed > 0) {
                printf "check-size: %d failure(s); baseline not written (name each grown baseline file with --allow-growth; a new file over the hard cap is never accepted)\n", failed
                exit 1
            }
            print "# Line counts of Sources/ Swift files over " soft " lines; read by scripts/check-size.sh." > out
            print "# Regenerate with scripts/check-size.sh --update-baseline. A raised entry needs a" > out
            print "# reason in the PR description (AGENTS.md \"Size caps\")." > out
            listed = 0
            for (f in current) if (current[f] > soft) listed++
            print "# entries: " listed > out
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
