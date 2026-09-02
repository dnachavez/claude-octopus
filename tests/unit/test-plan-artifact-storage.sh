#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "Plan artifact storage"

RESOLVER="$PROJECT_ROOT/scripts/plan-storage.sh"
HOOK="$PROJECT_ROOT/hooks/plan-mode-interceptor.sh"

case_root="$(mktemp -d "${TMPDIR:-/tmp}/octo-plan-storage.XXXXXX")"
trap 'rm -rf "$case_root"' EXIT
test_home="$case_root/home"
mkdir -p "$test_home"
test_home="$(cd "$test_home" && pwd -P)"
case_root="$(cd "$case_root" && pwd -P)"

test_case "home-directory plans use octo-owned storage, never global Claude config"
home_plan_dir="$(HOME="$test_home" CLAUDE_CODE_SESSION_ID="home-session" \
    "$RESOLVER" create "$test_home")"
if [[ -d "$home_plan_dir" && "$home_plan_dir" == "$test_home/.claude-octopus/"* &&
      "$home_plan_dir" != "$test_home/.claude/"* ]]; then
    test_pass
else
    test_fail "unexpected plan directory: $home_plan_dir"
fi

test_case "sequential plans in one non-project session never overwrite"
home_plan_dir_2="$(HOME="$test_home" CLAUDE_CODE_SESSION_ID="home-session" \
    "$RESOLVER" create "$test_home")"
if [[ -d "$home_plan_dir_2" && "$home_plan_dir_2" != "$home_plan_dir" ]]; then
    test_pass
else
    test_fail "resolver reused a run directory: $home_plan_dir_2"
fi

test_case "current returns the latest directory for the same session and workspace"
current_plan_dir="$(HOME="$test_home" CLAUDE_CODE_SESSION_ID="home-session" \
    "$RESOLVER" current "$test_home")"
if [[ "$current_plan_dir" == "$home_plan_dir_2" ]]; then
    test_pass
else
    test_fail "expected $home_plan_dir_2, got $current_plan_dir"
fi

test_case "git projects store plans under a project-owned namespace"
project="$case_root/project"
mkdir -p "$project/subdir"
git -C "$project" init -q
project_plan_dir="$(HOME="$test_home" CLAUDE_CODE_SESSION_ID="project-session" \
    "$RESOLVER" create "$project/subdir")"
if [[ -d "$project_plan_dir" && "$project_plan_dir" == "$project/.octo/plans/"* ]]; then
    test_pass
else
    test_fail "unexpected project plan directory: $project_plan_dir"
fi

test_case "marker-file projects resolve from nested directories"
marker_project="$case_root/marker-project"
mkdir -p "$marker_project/app/src"
: > "$marker_project/package.json"
marker_plan_dir="$(HOME="$test_home" CLAUDE_CODE_SESSION_ID="marker-session" \
    "$RESOLVER" create "$marker_project/app/src")"
if [[ -d "$marker_plan_dir" && "$marker_plan_dir" == "$marker_project/.octo/plans/"* ]]; then
    test_pass
else
    test_fail "unexpected marker plan directory: $marker_plan_dir"
fi

test_case "home-directory marker files cannot redirect plans into global Claude config"
: > "$test_home/package.json"
guarded_home_dir="$(HOME="$test_home" CLAUDE_CODE_SESSION_ID="guard-session" \
    "$RESOLVER" create "$test_home")"
if [[ "$guarded_home_dir" == "$test_home/.claude-octopus/"* &&
      "$guarded_home_dir" != "$test_home/.claude/"* ]]; then
    test_pass
else
    test_fail "home guard failed: $guarded_home_dir"
fi

test_case "relative configured roots fail closed"
if HOME="$test_home" OCTOPUS_SESSION_PLANS="relative/plans" \
    CLAUDE_CODE_SESSION_ID="bad-root" "$RESOLVER" create "$case_root" >/dev/null 2>&1; then
    test_fail "relative OCTOPUS_SESSION_PLANS was accepted"
else
    test_pass
fi

test_case "configured roots cannot target the global Claude config directory"
mkdir -p "$test_home/.claude"
if HOME="$test_home" OCTOPUS_SESSION_PLANS="$test_home/.claude/plans" \
    CLAUDE_CODE_SESSION_ID="bad-global-root" "$RESOLVER" create "$case_root" >/dev/null 2>&1; then
    test_fail "global Claude config storage was accepted"
elif [[ -e "$test_home/.claude/plans" ]]; then
    test_fail "rejected storage still created a directory in global Claude config"
else
    test_pass
fi

test_case "configured roots cannot reach global Claude config through a symlink"
ln -s "$test_home/.claude" "$case_root/global-config-link"
if HOME="$test_home" OCTOPUS_SESSION_PLANS="$case_root/global-config-link/plans" \
    CLAUDE_CODE_SESSION_ID="bad-symlink-root" "$RESOLVER" create "$case_root" >/dev/null 2>&1; then
    test_fail "symlinked global Claude config storage was accepted"
elif [[ -e "$test_home/.claude/plans" ]]; then
    test_fail "rejected symlink storage still created a global config directory"
else
    test_pass
fi

test_case "configured roots cannot reach global Claude config through dot-dot traversal"
mkdir -p "$test_home/work"
if HOME="$test_home" OCTOPUS_SESSION_PLANS="$test_home/work/../.claude/plans" \
    CLAUDE_CODE_SESSION_ID="bad-traversal-root" "$RESOLVER" create "$case_root" >/dev/null 2>&1; then
    test_fail "dot-dot traversal into global Claude config was accepted"
elif [[ -e "$test_home/.claude/plans" ]]; then
    test_fail "rejected dot-dot storage still created a global config directory"
else
    test_pass
fi

test_case "plan-mode hook loads the latest intent contract from the shared resolver"
printf '%s\n' "unique intent contract body" > "$home_plan_dir_2/session-intent.md"
hook_output="$(cd "$case_root" && \
    printf '%s' '{"session_id":"home-session","cwd":"'"$test_home"'"}' | \
    HOME="$test_home" CLAUDE_CODE_SESSION_ID="" CLAUDE_SESSION_ID="" \
    CLAUDE_CODE_SESSION="" CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" "$HOOK")"
if [[ "$hook_output" == *"$home_plan_dir_2/session-intent.md"* &&
      "$hook_output" == *"unique intent contract body"* ]]; then
    test_pass
else
    test_fail "hook did not load the current resolved intent contract"
fi

test_case "plan command and review skills use the shared resolver"
if grep -q 'scripts/plan-storage.sh' "$PROJECT_ROOT/commands/plan.md" &&
   grep -q 'scripts/plan-storage.sh' "$PROJECT_ROOT/.claude/skills/skill-intent-contract/SKILL.md" &&
   grep -q 'scripts/plan-storage.sh' "$PROJECT_ROOT/.claude/skills/skill-staged-review/SKILL.md"; then
    test_pass
else
    test_fail "one or more plan consumers bypass the shared resolver"
fi

test_case "plan examples do not advertise the obsolete project .claude path"
if grep -q '/path/to/project/.claude/session-plan.md' "$PROJECT_ROOT/commands/plan.md"; then
    test_fail "plan example still reports the obsolete project .claude path"
else
    test_pass
fi

test_summary
