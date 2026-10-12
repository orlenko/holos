# Sourced by scripts/test.sh and scripts/test-target.sh, after the scripts have taken their own leading
# arguments. It handles two options of its own and passes every other argument through unchanged:
#
#   --summary             Print only compile errors, "Build complete", the "Test run with ..." verdict and
#                         every failed test or suite ("✘"). The full output goes to a log file whose path is
#                         printed last. The exit status is the test run's.
#   --filter-file PATH    Read test-name patterns from PATH, one per line (blank lines and lines starting with
#                         "#" are skipped), and pass them to Swift Testing as one `--filter` alternation.
#
# It sets `summary` (0 or 1) and defines `run_tests`, which runs its arguments as the test command.

summary=0
remaining=$#
while [ "$remaining" -gt 0 ]; do
    argument=$1
    shift
    remaining=$((remaining - 1))
    case "$argument" in
        --summary)
            summary=1
            ;;
        --filter-file|--filter-file=*)
            if [ "$argument" = "--filter-file" ]; then
                if [ "$remaining" -eq 0 ]; then
                    echo "--filter-file needs a path" >&2
                    exit 64
                fi
                filter_file=$1
                shift
                remaining=$((remaining - 1))
            else
                filter_file=${argument#--filter-file=}
            fi
            if [ ! -r "$filter_file" ]; then
                echo "Cannot read filter file: $filter_file" >&2
                exit 64
            fi
            pattern=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' "$filter_file" | paste -s -d '|' -)
            if [ -z "$pattern" ]; then
                echo "Filter file has no patterns: $filter_file" >&2
                exit 64
            fi
            set -- "$@" --filter "$pattern"
            ;;
        *)
            set -- "$@" "$argument"
            ;;
    esac
done

run_tests() {
    if [ "$summary" -eq 0 ]; then
        "$@"
        return
    fi
    # The log outlives the run (unlike the test data folder) so the lines around a failure can still be read.
    log_base=${TMPDIR:-/tmp}
    test_log=$(mktemp "${log_base%/}/holos-test-log.XXXXXX")
    run_status=0
    "$@" >"$test_log" 2>&1 || run_status=$?
    # Colour codes are stripped. Dropped: SwiftCompile build-step lines, the source excerpt under each diagnostic
    # (lines starting with "|"), and repeats of a line already shown.
    escape=$(printf '\033')
    matched=$(sed "s/${escape}\[[0-9;]*m//g" "$test_log" \
        | grep -E 'error:|Build complete|Test run with|✘' \
        | grep -vE 'SwiftCompile|^[[:space:]]*\|' \
        | awk '!seen[$0]++' || true)
    if [ -n "$matched" ]; then
        printf '%s\n' "$matched"
    fi
    if [ "$run_status" -ne 0 ] && ! printf '%s\n' "$matched" | grep -qE 'error:|✘'; then
        # A failure with no error or failed-test line (a crash, a signal): show how the output ended.
        tail -n 20 "$test_log"
    fi
    echo "Full log: $test_log"
    return "$run_status"
}
