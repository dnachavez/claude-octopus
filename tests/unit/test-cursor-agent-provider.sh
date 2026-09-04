#!/usr/bin/env bash
# Unit tests for Cursor Agent provider wiring.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Cursor Agent provider"

CURSOR_LIB="$PROJECT_ROOT/scripts/lib/cursor-agent.sh"

pass() { test_case "$1"; test_pass; }
fail() { test_case "$1"; test_fail "${2:-$1}"; }

test_case "cursor-agent library has valid bash syntax"
if bash -n "$CURSOR_LIB" 2>/dev/null; then
    test_pass
else
    test_fail "syntax error in cursor-agent.sh"
fi

source "$CURSOR_LIB"

reset_mocks() {
    rm -rf "$MOCK_BIN_DIR"
    mkdir -p "$MOCK_BIN_DIR"
}

test_case "identity probe stays bounded without external timeout support"
reset_mocks
cat > "$MOCK_BIN_DIR/agent" <<'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    /bin/sleep 5
    echo "2026.04.17-test"
    exit 0
fi
exit 2
EOF
chmod +x "$MOCK_BIN_DIR/agent"

SECONDS=0
if PATH="$MOCK_BIN_DIR" OCTOPUS_CURSOR_AGENT_PROBE_TIMEOUT=1 _is_cursor_agent_binary >/dev/null 2>&1; then
    test_fail "identity probe succeeded after a timed-out version probe"
elif [[ $SECONDS -le 3 ]]; then
    test_pass
else
    test_fail "identity probe was not bounded (elapsed ${SECONDS}s)"
fi

test_case "identity probe accepts CalVer Cursor Agent behind timeout wrapper"
reset_mocks
cat > "$MOCK_BIN_DIR/timeout" <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF
cat > "$MOCK_BIN_DIR/agent" <<'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    echo "2026.04.17-test"
    exit 0
fi
echo "unexpected args: $*" >&2
exit 2
EOF
chmod +x "$MOCK_BIN_DIR/timeout" "$MOCK_BIN_DIR/agent"

if PATH="$MOCK_BIN_DIR:/usr/bin:/bin" _is_cursor_agent_binary >/dev/null 2>&1; then
    test_pass
else
    test_fail "identity probe rejected valid Cursor Agent CalVer output"
fi

test_case "cursor_agent_execute sends prompt on stdin, not argv"
reset_mocks
ARGV_FILE="$TEST_TMP_DIR/cursor-argv.txt"
STDIN_FILE="$TEST_TMP_DIR/cursor-stdin.txt"
OUTPUT_FILE="$TEST_TMP_DIR/cursor-output.txt"
cat > "$MOCK_BIN_DIR/timeout" <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF
cat > "$MOCK_BIN_DIR/agent" <<'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    echo "2026.04.17-test"
    exit 0
fi
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p)
            printf '%s' "${2:-}" > "$ARGV_FILE"
            shift 2
            ;;
        --trust|--output-format)
            shift
            [[ "${1:-}" == "text" ]] && shift
            ;;
        *)
            shift
            ;;
    esac
done
cat > "$STDIN_FILE"
echo "cursor response"
EOF
chmod +x "$MOCK_BIN_DIR/timeout" "$MOCK_BIN_DIR/agent"

if PATH="$MOCK_BIN_DIR:/usr/bin:/bin" CURSOR_API_KEY=test ARGV_FILE="$ARGV_FILE" STDIN_FILE="$STDIN_FILE" \
    cursor_agent_execute cursor-agent "sensitive prompt" "$OUTPUT_FILE" >/dev/null 2>&1; then
    if [[ "$(cat "$ARGV_FILE" 2>/dev/null || true)" == "" ]] && \
       [[ "$(cat "$STDIN_FILE" 2>/dev/null || true)" == "sensitive prompt" ]] && \
       grep -q "cursor response" "$OUTPUT_FILE"; then
        test_pass
    else
        test_fail "prompt was not captured through stdin-only execution"
    fi
else
    test_fail "cursor_agent_execute failed with mocked Cursor Agent"
fi

test_case "Cursor Agent probes are timeout-guarded outside the helper"
offenders=$(grep -R "agent --version" "$PROJECT_ROOT/scripts/helpers" "$PROJECT_ROOT/scripts/lib" "$PROJECT_ROOT/scripts/install-deps.sh" 2>/dev/null | grep -v 'scripts/lib/cursor-agent.sh:.*_cursor_agent_run_with_timeout' || true)
if [[ -z "$offenders" ]]; then
    test_pass
else
    test_fail "unbounded agent --version probe remains: $offenders"
fi

test_case "smoke test sends Cursor Agent prompt through stdin"
if awk '
    /\[\[ "\$provider" == "cursor-agent" \]\]/ { in_cursor=1 }
    in_cursor && /echo "Reply with exactly: ok" \| run_with_timeout/ { saw_stdin=1 }
    in_cursor && /\$cmd_str -p "Reply with exactly: ok"/ { saw_argv=1 }
    in_cursor && /^    else$/ { in_cursor=0 }
    END { exit (saw_stdin && !saw_argv) ? 0 : 1 }
' "$PROJECT_ROOT/scripts/lib/smoke.sh"; then
    test_pass
else
    test_fail "Cursor Agent smoke path still passes prompt as argv"
fi

test_case "model config surfaces Cursor Agent override"
if grep -q "OCTOPUS_CURSOR_AGENT_MODEL" "$PROJECT_ROOT/scripts/helpers/octo-model-config.sh"; then
    test_pass
else
    test_fail "OCTOPUS_CURSOR_AGENT_MODEL missing from model config helper"
fi

test_case "E009 recovery text keeps four-field parser shape"
if grep -q 'E009:Invalid agent type:Use:' "$PROJECT_ROOT/scripts/lib/interactive.sh" "$PROJECT_ROOT/scripts/orchestrate.sh"; then
    test_fail "E009 still contains extra colon in fix field"
else
    test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Session auth via `agent status` — 2026.06+ builds keep no authInfo marker in
# ~/.cursor/cli-config.json; the bounded, cached status probe is the only signal.
# ═══════════════════════════════════════════════════════════════════════════════

write_cursor_status_mock() {
    cat > "$MOCK_BIN_DIR/agent" <<'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    echo "${CURSOR_MOCK_VERSION:-2026.06.24-test}"
    exit 0
fi
if [[ "$1" == "status" ]]; then
    [[ -n "${CURSOR_STATUS_CALLS:-}" ]] && echo "status $*" >> "$CURSOR_STATUS_CALLS"
    [[ -n "${CURSOR_MOCK_STATUS_SLEEP:-}" ]] && /bin/sleep "$CURSOR_MOCK_STATUS_SLEEP"
    printf '%s\n' "${CURSOR_MOCK_STATUS_JSON:-{\"isAuthenticated\":false}}"
    exit 0
fi
exit 2
EOF
    cat > "$MOCK_BIN_DIR/timeout" <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF
    chmod +x "$MOCK_BIN_DIR/agent" "$MOCK_BIN_DIR/timeout"
}

EMPTY_CURSOR_HOME="$TEST_TMP_DIR/cursor-home-empty"
mkdir -p "$EMPTY_CURSOR_HOME/.cursor"
printf '{"version":1,"sandbox":{}}\n' > "$EMPTY_CURSOR_HOME/.cursor/cli-config.json"
CURSOR_PROBE_PATH="$MOCK_BIN_DIR:/usr/bin:/bin"
# Probe cases exercise the live status path; the on-disk verdict cache gets its
# own case below.
export OCTOPUS_CURSOR_AGENT_AUTH_CACHE_TTL=0

test_case "session auth is accepted from agent status when cli-config.json has no authInfo"
reset_mocks; write_cursor_status_mock
CALLS_FILE="$TEST_TMP_DIR/status-calls-1.txt"; : > "$CALLS_FILE"
probe_output=$(
    unset CURSOR_API_KEY
    export HOME="$EMPTY_CURSOR_HOME" PATH="$CURSOR_PROBE_PATH" CURSOR_STATUS_CALLS="$CALLS_FILE"
    export CURSOR_MOCK_STATUS_JSON='{"status":"authenticated","isAuthenticated":true,"userInfo":{"email":"secret@example.test"}}'
    _CURSOR_AGENT_SESSION_AUTH_CACHE=""
    if cursor_agent_is_available; then
        echo "available:$(cursor_agent_auth_method)"
    else
        echo "unavailable:$(cursor_agent_auth_method)"
    fi
)
if [[ "$probe_output" == "available:cursor-session" ]] && ! grep -q "secret@example.test" <<< "$probe_output" && grep -q "status --format json" "$CALLS_FILE"; then
    test_pass
else
    test_fail "expected available:cursor-session via status probe, got '$probe_output' (calls: $(cat "$CALLS_FILE" 2>/dev/null))"
fi

test_case "unauthenticated agent status leaves Cursor unavailable"
reset_mocks; write_cursor_status_mock
probe_output=$(
    unset CURSOR_API_KEY
    export HOME="$EMPTY_CURSOR_HOME" PATH="$CURSOR_PROBE_PATH"
    export CURSOR_MOCK_STATUS_JSON='{"status":"unauthenticated","isAuthenticated":false}'
    _CURSOR_AGENT_SESSION_AUTH_CACHE=""
    cursor_agent_is_available && echo "available" || echo "unavailable:$(cursor_agent_auth_method)"
)
if [[ "$probe_output" == "unavailable:none" ]]; then
    test_pass
else
    test_fail "expected unavailable:none, got '$probe_output'"
fi

test_case "session status probe stays bounded by OCTOPUS_CURSOR_AGENT_PROBE_TIMEOUT"
reset_mocks; write_cursor_status_mock
rm -f "$MOCK_BIN_DIR/timeout"   # force the portable fallback watchdog on hosts without coreutils timeout
SECONDS=0
probe_output=$(
    unset CURSOR_API_KEY
    export HOME="$EMPTY_CURSOR_HOME" PATH="$CURSOR_PROBE_PATH"
    export CURSOR_MOCK_STATUS_SLEEP=5 OCTOPUS_CURSOR_AGENT_PROBE_TIMEOUT=1 OCTOPUS_CURSOR_AGENT_STATUS_TIMEOUT=1
    export CURSOR_MOCK_STATUS_JSON='{"isAuthenticated":true}'
    _CURSOR_AGENT_SESSION_AUTH_CACHE=""
    cursor_agent_is_available && echo "available" || echo "unavailable"
)
if [[ "$probe_output" == "unavailable" && $SECONDS -le 3 ]]; then
    test_pass
else
    test_fail "status probe was not bounded (result=$probe_output elapsed=${SECONDS}s)"
fi

test_case "a non-Cursor 'agent' binary short-circuits before the status probe"
reset_mocks; write_cursor_status_mock
CALLS_FILE="$TEST_TMP_DIR/status-calls-2.txt"; : > "$CALLS_FILE"
probe_output=$(
    unset CURSOR_API_KEY
    export HOME="$EMPTY_CURSOR_HOME" PATH="$CURSOR_PROBE_PATH" CURSOR_STATUS_CALLS="$CALLS_FILE"
    export CURSOR_MOCK_VERSION="1.4.2" CURSOR_MOCK_STATUS_JSON='{"isAuthenticated":true}'
    _CURSOR_AGENT_SESSION_AUTH_CACHE=""
    cursor_agent_session_authenticated && echo "authenticated" || echo "rejected"
)
if [[ "$probe_output" == "rejected" && ! -s "$CALLS_FILE" ]]; then
    test_pass
else
    test_fail "semver 'agent' should be rejected without probing status (result=$probe_output calls=$(cat "$CALLS_FILE"))"
fi

test_case "status probe result is cached for the process"
reset_mocks; write_cursor_status_mock
CALLS_FILE="$TEST_TMP_DIR/status-calls-3.txt"; : > "$CALLS_FILE"
probe_output=$(
    unset CURSOR_API_KEY
    export HOME="$EMPTY_CURSOR_HOME" PATH="$CURSOR_PROBE_PATH" CURSOR_STATUS_CALLS="$CALLS_FILE"
    export CURSOR_MOCK_STATUS_JSON='{"isAuthenticated":true}'
    _CURSOR_AGENT_SESSION_AUTH_CACHE=""
    cursor_agent_is_available && cursor_agent_is_available && cursor_agent_auth_method
)
call_count=$(grep -c "status" "$CALLS_FILE" 2>/dev/null || true)
if [[ "$probe_output" == "cursor-session" && "${call_count:-0}" -eq 1 ]]; then
    test_pass
else
    test_fail "expected one cached status probe, got ${call_count:-0} (result=$probe_output)"
fi

test_case "legacy authInfo block still authenticates without probing status"
reset_mocks; write_cursor_status_mock
LEGACY_HOME="$TEST_TMP_DIR/cursor-home-legacy"; mkdir -p "$LEGACY_HOME/.cursor"
printf '{"authInfo": {"accessToken":"redacted"}}\n' > "$LEGACY_HOME/.cursor/cli-config.json"
CALLS_FILE="$TEST_TMP_DIR/status-calls-4.txt"; : > "$CALLS_FILE"
probe_output=$(
    unset CURSOR_API_KEY
    export HOME="$LEGACY_HOME" PATH="$CURSOR_PROBE_PATH" CURSOR_STATUS_CALLS="$CALLS_FILE"
    export CURSOR_MOCK_STATUS_JSON='{"isAuthenticated":false}'
    _CURSOR_AGENT_SESSION_AUTH_CACHE=""
    cursor_agent_auth_method
)
if [[ "$probe_output" == "cursor-session" && ! -s "$CALLS_FILE" ]]; then
    test_pass
else
    test_fail "legacy authInfo should short-circuit (result=$probe_output calls=$(cat "$CALLS_FILE"))"
fi

test_case "status verdict is cached on disk across processes and holds no credentials"
reset_mocks; write_cursor_status_mock
CALLS_FILE="$TEST_TMP_DIR/status-calls-5.txt"; : > "$CALLS_FILE"
AUTH_CACHE="$TEST_TMP_DIR/auth-cache/verdict"
probe_output=$(
    unset CURSOR_API_KEY
    export HOME="$EMPTY_CURSOR_HOME" PATH="$CURSOR_PROBE_PATH" CURSOR_STATUS_CALLS="$CALLS_FILE"
    export OCTOPUS_CURSOR_AGENT_AUTH_CACHE_TTL=600 OCTOPUS_CURSOR_AGENT_AUTH_CACHE_FILE="$AUTH_CACHE"
    export CURSOR_MOCK_STATUS_JSON='{"isAuthenticated":true,"userInfo":{"email":"secret@example.test"}}'
    first=$(bash -c 'source "'"$CURSOR_LIB"'"; cursor_agent_auth_method')
    second=$(bash -c 'source "'"$CURSOR_LIB"'"; cursor_agent_auth_method')
    echo "${first}/${second}"
)
call_count=$(grep -c "status" "$CALLS_FILE" 2>/dev/null || true)
if [[ "$probe_output" == "cursor-session/cursor-session" && "${call_count:-0}" -eq 1 ]] &&
   [[ "$(sed -n '2p' "$AUTH_CACHE")" == "yes" ]] && ! grep -q "secret" "$AUTH_CACHE"; then
    test_pass
else
    test_fail "expected one probe shared via the verdict cache, got calls=${call_count:-0} result=$probe_output cache=$(cat "$AUTH_CACHE" 2>/dev/null | tr '\n' ' ')"
fi

test_case "a stale or negative cached verdict re-probes"
reset_mocks; write_cursor_status_mock
CALLS_FILE="$TEST_TMP_DIR/status-calls-6.txt"; : > "$CALLS_FILE"
AUTH_CACHE="$TEST_TMP_DIR/auth-cache/stale"
mkdir -p "$(dirname "$AUTH_CACHE")"
printf '%s\nyes\n' "$(( $(date +%s) - 7200 ))" > "$AUTH_CACHE"
probe_output=$(
    unset CURSOR_API_KEY
    export HOME="$EMPTY_CURSOR_HOME" PATH="$CURSOR_PROBE_PATH" CURSOR_STATUS_CALLS="$CALLS_FILE"
    export OCTOPUS_CURSOR_AGENT_AUTH_CACHE_TTL=600 OCTOPUS_CURSOR_AGENT_AUTH_CACHE_FILE="$AUTH_CACHE"
    export CURSOR_MOCK_STATUS_JSON='{"isAuthenticated":false}'
    bash -c 'source "'"$CURSOR_LIB"'"; cursor_agent_auth_method'
)
call_count=$(grep -c "status" "$CALLS_FILE" 2>/dev/null || true)
if [[ "$probe_output" == "none" && "${call_count:-0}" -eq 1 && "$(sed -n '2p' "$AUTH_CACHE")" == "no" ]]; then
    test_pass
else
    test_fail "stale cache should re-probe (calls=${call_count:-0} result=$probe_output cache=$(cat "$AUTH_CACHE" 2>/dev/null | tr '\n' ' '))"
fi

test_case "no consumer re-implements the Cursor auth probe"
offenders=$(grep -RnE 'authInfo|agent[[:space:]]+status[[:space:]]+--format' "$PROJECT_ROOT/scripts" --include='*.sh' 2>/dev/null | grep -v 'scripts/lib/cursor-agent.sh' || true)
if [[ -z "$offenders" ]]; then
    test_pass
else
    test_fail "auth probe duplicated outside lib/cursor-agent.sh: $offenders"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Execution mode contract — `agent -p` has write+shell access; seats opt down.
# ═══════════════════════════════════════════════════════════════════════════════

test_case "role table defaults to read-only ask, plan for planners, agent for implementers"
if [[ "$(cursor_agent_mode_for_role researcher)" == "ask" ]] &&
   [[ "$(cursor_agent_mode_for_role "")" == "ask" ]] &&
   [[ "$(cursor_agent_mode_for_role implementation-security-reviewer)" == "ask" ]] &&
   [[ "$(cursor_agent_mode_for_role backend-architect)" == "ask" ]] &&
   [[ "$(cursor_agent_mode_for_role planner)" == "plan" ]] &&
   [[ "$(cursor_agent_mode_for_role architect)" == "plan" ]] &&
   [[ "$(cursor_agent_mode_for_role implementer)" == "agent" ]] &&
   [[ "$(cursor_agent_mode_for_role developer)" == "agent" ]]; then
    test_pass
else
    test_fail "role→mode table drifted"
fi

test_case "OCTOPUS_CURSOR_AGENT_MODE overrides the role default and rejects unknown values"
if [[ "$(OCTOPUS_CURSOR_AGENT_MODE=agent cursor_agent_resolve_mode researcher 2>/dev/null)" == "agent" ]] &&
   [[ "$(OCTOPUS_CURSOR_AGENT_MODE=plan cursor_agent_resolve_mode implementer 2>/dev/null)" == "plan" ]] &&
   [[ "$(OCTOPUS_CURSOR_AGENT_MODE=yolo cursor_agent_resolve_mode implementer 2>/dev/null)" == "agent" ]] &&
   [[ "$(OCTOPUS_CURSOR_AGENT_MODE=yolo cursor_agent_resolve_mode researcher 2>/dev/null)" == "ask" ]] &&
   [[ "$(cursor_agent_mode_flag ask)" == "--mode ask" ]] &&
   [[ -z "$(cursor_agent_mode_flag agent)" ]]; then
    test_pass
else
    test_fail "mode override handling drifted"
fi

test_case "cursor_agent_execute applies the read-only mode for non-implementer roles"
reset_mocks
ARGV_FILE="$TEST_TMP_DIR/cursor-argv-mode.txt"
cat > "$MOCK_BIN_DIR/timeout" <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF
cat > "$MOCK_BIN_DIR/agent" <<'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    echo "2026.06.24-test"
    exit 0
fi
printf '%s\n' "$*" > "$ARGV_FILE"
cat >/dev/null
echo "cursor response"
EOF
chmod +x "$MOCK_BIN_DIR/timeout" "$MOCK_BIN_DIR/agent"
if PATH="$MOCK_BIN_DIR:/usr/bin:/bin" CURSOR_API_KEY=test ARGV_FILE="$ARGV_FILE" \
    cursor_agent_execute cursor-agent "prompt" "" researcher >/dev/null 2>&1 &&
   grep -q -- '--mode ask' "$ARGV_FILE" &&
   PATH="$MOCK_BIN_DIR:/usr/bin:/bin" CURSOR_API_KEY=test ARGV_FILE="$ARGV_FILE" \
    cursor_agent_execute cursor-agent "prompt" "" implementer >/dev/null 2>&1 &&
   ! grep -q -- '--mode' "$ARGV_FILE"; then
    test_pass
else
    test_fail "cursor_agent_execute did not honour the role mode contract: $(cat "$ARGV_FILE" 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Dispatch, environment isolation, registry, and fleet wiring
# ═══════════════════════════════════════════════════════════════════════════════

log() { :; }
PLUGIN_DIR="$PROJECT_ROOT"
export "TMPDIR=${TEST_TMP_DIR}/runtime"; mkdir -p "$TMPDIR"
source "$PROJECT_ROOT/scripts/lib/provider-registry.sh"
source "$PROJECT_ROOT/scripts/lib/utils.sh"
source "$PROJECT_ROOT/scripts/lib/models.sh"
source "$PROJECT_ROOT/scripts/lib/model-resolver.sh"
source "$PROJECT_ROOT/scripts/lib/provider-routing.sh"
source "$PROJECT_ROOT/scripts/lib/dispatch.sh"

test_case "dispatch defaults to --mode ask --model auto and validates the command"
cmd=$(HOME="$EMPTY_CURSOR_HOME" get_agent_command cursor-agent probe researcher 2>/dev/null || true)
if [[ "$cmd" == "agent --trust --output-format text --mode ask --model auto" ]] && validate_agent_command "$cmd" 2>/dev/null; then
    test_pass
else
    test_fail "unexpected researcher dispatch: '$cmd'"
fi

test_case "dispatch omits --mode for implementer roles and uses --mode plan for planners"
impl_cmd=$(HOME="$EMPTY_CURSOR_HOME" get_agent_command cursor-agent tangle implementer 2>/dev/null || true)
plan_cmd=$(HOME="$EMPTY_CURSOR_HOME" get_agent_command cursor-agent grasp planner 2>/dev/null || true)
if [[ "$impl_cmd" == "agent --trust --output-format text --model auto" ]] &&
   [[ "$plan_cmd" == "agent --trust --output-format text --mode plan --model auto" ]]; then
    test_pass
else
    test_fail "implementer='$impl_cmd' planner='$plan_cmd'"
fi

test_case "OCTOPUS_CURSOR_AGENT_MODE reaches dispatch and explicit seats keep their model"
override_cmd=$(HOME="$EMPTY_CURSOR_HOME" OCTOPUS_CURSOR_AGENT_MODE=plan get_agent_command cursor-agent tangle implementer 2>/dev/null || true)
seat_cmd=$(HOME="$EMPTY_CURSOR_HOME" get_agent_command cursor-agent:composer-2.5 probe researcher 2>/dev/null || true)
if [[ "$override_cmd" == *"--mode plan"* ]] && [[ "$seat_cmd" == *"--mode ask --model composer-2.5" ]]; then
    test_pass
else
    test_fail "override='$override_cmd' seat='$seat_cmd'"
fi

test_case "cursor-agent dispatch runs under env -i with CURSOR_API_KEY and HOME only"
(
    export CURSOR_API_KEY=test-key OPENAI_API_KEY=leak OCTOPUS_CURSOR_AGENT_MODE=ask
    build_provider_env cursor-agent
    joined=" ${PROVIDER_ENV_ARRAY[*]} "
    [[ "${PROVIDER_ENV_ARRAY[0]}" == "env" && "${PROVIDER_ENV_ARRAY[1]}" == "-i" ]] &&
    [[ "$joined" == *" CURSOR_API_KEY=test-key "* ]] &&
    [[ "$joined" == *" HOME=$HOME "* ]] &&
    [[ "$joined" == *" OCTOPUS_CURSOR_AGENT_MODE=ask "* ]] &&
    [[ "$joined" != *"OPENAI_API_KEY"* ]]
) && test_pass || test_fail "cursor-agent env isolation drifted"

test_case "OCTOPUS_ALLOW_FULL_CURSOR_AGENT_ENV=true inherits the parent environment"
(
    export OCTOPUS_ALLOW_FULL_CURSOR_AGENT_ENV=true
    build_provider_env cursor-agent
    [[ ${#PROVIDER_ENV_ARRAY[@]} -eq 0 ]]
) && test_pass || test_fail "full-env opt-out should yield an empty env prefix"

test_case "cursor-agent is a council-capable registry provider with a live default model"
if octo_provider_has_capability cursor-agent council &&
   ! octo_provider_limitation_reason cursor-agent council >/dev/null 2>&1 &&
   [[ "$(HOME="$EMPTY_CURSOR_HOME" resolve_octopus_model cursor-agent cursor-agent "" "")" == "auto" ]] &&
   [[ "$(get_model_capability composer-2.5 provider)" == "cursor-agent" ]] &&
   ! is_known_model grok-4-20 2>/dev/null; then
    test_pass
else
    test_fail "registry/catalog wiring for cursor-agent drifted"
fi

test_case "vendor family separates Cursor seats from the standalone grok CLI"
if [[ "$(octo_model_family composer-2.5)" == "cursor" ]] &&
   [[ "$(octo_model_family cursor-grok-4.6-high)" == "xai" ]] &&
   [[ "$(octo_model_family claude-sonnet-5-thinking-high)" == "anthropic" ]] &&
   [[ "$(octo_model_family cursor-agent)" == "cursor" ]]; then
    test_pass
else
    test_fail "octo_model_family: composer=$(octo_model_family composer-2.5) grok=$(octo_model_family cursor-grok-4.6-high) cursor-agent=$(octo_model_family cursor-agent)"
fi

test_case "review and debate cascades seat Cursor when preferred providers are absent"
if grep -q 'cursor-agent:implementation-logic-reviewer' "$PROJECT_ROOT/scripts/lib/review.sh" &&
   grep -q 'cursor-agent:implementation-security-reviewer' "$PROJECT_ROOT/scripts/lib/review.sh" &&
   grep -q 'cursor-agent:implementation-cve-reviewer' "$PROJECT_ROOT/scripts/lib/review.sh" &&
   grep -q 'cursor_agent_is_available' "$PROJECT_ROOT/scripts/lib/review.sh" &&
   grep -q 'is_agent_available_v2 cursor-agent' "$PROJECT_ROOT/scripts/lib/debate.sh" &&
   grep -q '"Cursor Perspective"' "$PROJECT_ROOT/scripts/helpers/build-fleet.sh" &&
   ! grep -q '"XAI Perspective"' "$PROJECT_ROOT/scripts/helpers/build-fleet.sh"; then
    test_pass
else
    test_fail "fleet cascades do not seat cursor-agent"
fi

test_case "provider module and public docs describe Cursor CLI, not Grok-via-Cursor"
if [[ -f "$PROJECT_ROOT/config/providers/cursor-agent/CLAUDE.md" ]] &&
   grep -q 'OCTOPUS_CURSOR_AGENT_MODE' "$PROJECT_ROOT/config/providers/cursor-agent/CLAUDE.md" &&
   grep -q 'Cursor CLI' "$PROJECT_ROOT/docs/TROUBLESHOOTING.md" &&
   ! grep -q 'via cursor-agent' "$PROJECT_ROOT/README.md" &&
   ! grep -rq 'grok-4-20' "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/config"; then
    test_pass
else
    test_fail "public Cursor documentation drifted"
fi

test_summary
