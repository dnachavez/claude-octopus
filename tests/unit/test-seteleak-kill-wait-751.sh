#!/usr/bin/env bash
# tests/unit/test-seteleak-kill-wait-751.sh
# Regression coverage for #751: bare `kill`/`wait`/`pkill` on an
# already-reaped PID returns non-zero and, under `set -eo pipefail`
# (orchestrate.sh:6), aborts the enclosing function immediately after
# the signal/reap work already succeeded — same defect class as #738/#739.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "set -e status leaks on bare kill/wait/pkill (#751)"

# Sanity check: prove the general failure mode is real, independent of any
# specific file, before asserting the five sites are guarded against it.
test_bare_kill_wait_aborts_under_sete() {
    test_case "bare kill on an already-reaped PID aborts a set -e function before it completes"

    local out
    out=$(bash -c '
        set -e
        ( sleep 0.05 ) & m=$!
        wait "$m"
        kill "$m" 2>/dev/null
        echo REACHED-END
    ' 2>/dev/null || true)

    assert_not_contains "$out" "REACHED-END" \
        "expected the unguarded reproduction to abort before REACHED-END (proves the defect is real)" || return
    test_pass
}

test_guarded_kill_wait_survives_sete() {
    test_case "the || true guard pattern used in the fix prevents the abort"

    local out
    out=$(bash -c '
        set -e
        ( sleep 0.05 ) & m=$!
        wait "$m" 2>/dev/null || true
        kill "$m" 2>/dev/null || true
        echo REACHED-END
    ')

    assert_contains "$out" "REACHED-END" \
        "expected the guarded reproduction to reach the end under set -e" || return
    test_pass
}

# workflows.sh:692-693 — synthesis monitor kill/wait guard (probe_discover()).
# probe_discover() has too much external state (provider dispatch, run
# artifacts) to exercise directly in a unit test; assert statically that the
# specific lines carry the guard, same as the sibling assertions below.
test_workflows_synthesis_monitor_guarded() {
    test_case "workflows.sh: synthesis_monitor_pid kill/wait guarded with || true"

    local file="$PROJECT_ROOT/scripts/lib/workflows.sh"
    local snippet
    snippet=$(grep -A2 'kill "\$synthesis_monitor_pid"' "$file")

    assert_contains "$snippet" 'kill "$synthesis_monitor_pid" 2>/dev/null || true' \
        "kill on synthesis_monitor_pid must be guarded" || return
    assert_contains "$snippet" 'wait "$synthesis_monitor_pid" 2>/dev/null || true' \
        "wait on synthesis_monitor_pid must be guarded" || return
    test_pass
}

# heartbeat.sh — run_with_timeout()'s TERM-then-KILL escalation.
# This one is directly callable and lets us reproduce the exact race from
# the issue: the wrapped command finishes before the monitor's first signal
# fires, so kill -TERM targets an already-dead PID and must not skip the
# pkill/KILL escalation lines that follow it in the same subshell.
test_heartbeat_run_with_timeout_survives_early_exit_race() {
    test_case "heartbeat.sh: run_with_timeout completes cleanup when the target exits before the monitor's first signal"

    local out
    out=$(
        bash -c '
            set -eo pipefail
            source "'"$PROJECT_ROOT"'/scripts/lib/heartbeat.sh"
            fast_ok() { return 0; }
            # timeout_secs=1 with an instantly-returning command guarantees
            # the monitor subshell fires kill -TERM against a PID that is
            # already gone by the time it runs. Capture via `|| rc=$?`
            # (not a bare call) so *this test harness* does not itself
            # trip set -e on a non-zero return — same idiom as the fix.
            rc=0
            run_with_timeout 1 fast_ok || rc=$?
            echo "RC=$rc"
            echo REACHED-END
        ' 2>&1
    ) || true

    assert_contains "$out" "REACHED-END" \
        "run_with_timeout must not abort under set -e when the monitor's kill -TERM races an exited target" || return
    assert_contains "$out" "RC=0" \
        "run_with_timeout must still report the wrapped command's real exit code" || return
    test_pass
}

test_heartbeat_kill_lines_guarded() {
    test_case "heartbeat.sh: process-group TERM/KILL helper is guarded against set -e leaks"

    local file="$PROJECT_ROOT/scripts/lib/heartbeat.sh"
    local snippet
    if ! snippet=$(grep -m1 -A22 '^_octo_timeout_stop_process_group()' "$file"); then
        test_fail "could not locate the process-group signal helper in heartbeat.sh"
        return
    fi

    assert_contains "$snippet" 'kill -"$initial_signal" -- "-$process_group" 2>/dev/null || true' \
        "initial process-group signal must be guarded" || return
    assert_contains "$snippet" 'kill -KILL -- "-$process_group" 2>/dev/null || true' \
        "process-group KILL must be guarded" || return
    if grep -q '_octo_timeout_stop_process_group "$provider_pid"' "$file"; then
        test_pass
    else
        test_fail "timeout fallback must invoke the guarded process-group helper"
    fi
}

# Cursor delegates timeout ownership to heartbeat.sh instead of maintaining a
# second watchdog. The adapter must preserve the shared helper's arguments and
# exit status under the repository's set -e execution mode.
test_cursor_agent_delegates_timeout_and_survives_sete() {
    test_case "cursor-agent.sh: timeout adapter delegates to the shared portable supervisor"

    local out
    out=$(
        bash -c '
            set -eo pipefail
            source "'"$PROJECT_ROOT"'/scripts/lib/cursor-agent.sh"
            run_with_timeout() {
                printf "SHARED_ARGS=%s\n" "$*"
                return 7
            }
            rc=0
            _cursor_agent_run_with_timeout 9 agent --version </dev/null || rc=$?
            echo "RC=$rc"
            echo REACHED-END
        ' 2>&1
    ) || true

    assert_contains "$out" "REACHED-END" \
        "_cursor_agent_run_with_timeout must not abort under set -e" || return
    assert_contains "$out" "SHARED_ARGS=--portable-supervisor 9 agent --version" \
        "_cursor_agent_run_with_timeout must delegate to the shared supervisor" || return
    assert_contains "$out" "RC=7" \
        "_cursor_agent_run_with_timeout must preserve the shared helper's exit status" || return
    test_pass
}

test_bare_kill_wait_aborts_under_sete
test_guarded_kill_wait_survives_sete
test_workflows_synthesis_monitor_guarded
test_heartbeat_run_with_timeout_survives_early_exit_race
test_heartbeat_kill_lines_guarded
test_cursor_agent_delegates_timeout_and_survives_sete

test_summary
