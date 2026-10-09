#!/bin/sh
# Size ratchet for the Swift files under Sources/ (AGENTS.md "Size caps").
#
#   scripts/check-size.sh                    check the tree against scripts/size-baseline.txt
#   scripts/check-size.sh --update-baseline  rewrite the baseline from the tree
#
# The baseline lists every source file over the soft cap (600 lines) with its line count.
# The check fails when:
#   - a file over the hard cap (1,000 lines) has more lines than its baseline entry, or
#   - a file without a baseline entry is over the hard cap.
# It warns when a file without an entry is over the soft cap, or when a listed file grows but
# stays within the hard cap. Files that shrank are listed so the baseline can be lowered.
# Tests/ is not checked.
set -eu

soft=600
hard=1000

root=$(cd "$(dirname "$0")/.." && pwd)
baseline="$root/scripts/size-baseline.txt"

usage() {
    echo "usage: scripts/check-size.sh [--update-baseline]" >&2
}

update=false
case "${1:-}" in
    "") ;;
    --update-baseline) update=true ;;
    -h | --help) usage; exit 0 ;;
    *) usage; exit 64 ;;
esac

cd "$root"

# "<lines> <path>" for every Swift file under Sources/, sorted by path. `wc` prints "total"
# lines when given several files; only paths under Sources/ are kept.
counts() {
    find Sources -type f -name '*.swift' -exec wc -l {} + |
        awk '$2 ~ /^Sources\// { print $1, $2 }' |
        LC_ALL=C sort -k 2
}

if [ "$update" = true ]; then
    {
        echo "# Line counts of Sources/ Swift files over $soft lines; read by scripts/check-size.sh."
        echo "# Regenerate with scripts/check-size.sh --update-baseline. A raised entry needs a"
        echo "# reason in the PR description (AGENTS.md \"Size caps\")."
        counts | awk -v soft="$soft" '$1 > soft'
    } >"$baseline"
    echo "check-size: wrote $(grep -vc '^#' "$baseline") entries to scripts/size-baseline.txt"
    exit 0
fi

if [ ! -f "$baseline" ]; then
    echo "check-size: scripts/size-baseline.txt is missing; run scripts/check-size.sh --update-baseline" >&2
    exit 1
fi

counts | awk -v soft="$soft" -v hard="$hard" '
    NR == FNR {
        if ($0 ~ /^#/ || NF < 2) next
        base[$2] = $1
        next
    }
    {
        n = $1; f = $2; seen[f] = 1
        if (f in base) {
            b = base[f]
            if (n > b && n > hard) {
                printf "FAIL  %s: %d lines, baseline %d (files over %d lines may not grow)\n", f, n, b, hard
                failed++
            } else if (n > b) {
                printf "warn  %s: grew from %d to %d lines (soft cap %d)\n", f, b, n, soft
                warned++
            } else if (n < b) {
                shrunk = shrunk sprintf("note  %s: %d lines, baseline %d\n", f, n, b)
            }
        } else if (n > hard) {
            printf "FAIL  %s: %d lines, over the %d-line cap and not in the baseline\n", f, n, hard
            failed++
        } else if (n > soft) {
            printf "warn  %s: %d lines, over the %d-line soft cap\n", f, n, soft
            warned++
        }
    }
    END {
        for (f in base) if (!(f in seen)) shrunk = shrunk sprintf("note  %s: in the baseline but gone\n", f)
        if (shrunk != "") {
            printf "%s", shrunk
            print "note  lower the baseline with scripts/check-size.sh --update-baseline"
        }
        printf "check-size: %d failure(s), %d warning(s)\n", failed, warned
        exit (failed > 0)
    }
' "$baseline" -
