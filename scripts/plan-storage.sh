#!/usr/bin/env bash
# Resolve unique, discoverable storage for /octo:plan artifacts.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/session-id.sh"

plan_storage_error() {
    printf 'plan-storage: %s\n' "$*" >&2
}

plan_storage_physical_dir() {
    [[ -d "$1" ]] || return 1
    (cd "$1" 2>/dev/null && pwd -P)
}

plan_storage_project_root() {
    local working_dir="$1" home_dir="$2" root candidate

    # $HOME is always a user configuration context, even if it happens to have
    # a repository or marker file. Never route plan artifacts into ~/.claude.
    [[ "$working_dir" != "$home_dir" ]] || return 1

    root="$(git -C "$working_dir" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$root" ]]; then
        root="$(plan_storage_physical_dir "$root")" || return 1
        [[ "$root" != "$home_dir" ]] || return 1
        printf '%s\n' "$root"
        return 0
    fi

    candidate="$working_dir"
    while [[ "$candidate" != "/" ]]; do
        if [[ "$candidate" != "$home_dir" ]] &&
           { [[ -f "$candidate/package.json" ]] ||
             [[ -f "$candidate/pyproject.toml" ]] ||
             [[ -f "$candidate/go.mod" ]] ||
             [[ -f "$candidate/Cargo.toml" ]] ||
             [[ -f "$candidate/Gemfile" ]]; }; then
            printf '%s\n' "$candidate"
            return 0
        fi
        candidate="${candidate%/*}"
        [[ -n "$candidate" ]] || candidate="/"
    done
    return 1
}

plan_storage_safe_id() {
    local value
    value="$(printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g')"
    [[ -n "$value" ]] || value="unknown"
    printf '%.120s\n' "$value"
}

plan_storage_pointer_file() {
    local home_dir="$1" session_id="$2" working_dir="$3" checksum
    checksum="$(printf '%s' "$working_dir" | cksum | awk '{print $1}')"
    printf '%s/.claude-octopus/state/plan-artifacts/%s/%s.path\n' \
        "$home_dir" "$(plan_storage_safe_id "$session_id")" "$checksum"
}

plan_storage_base_dir() {
    local working_dir="$1" home_dir="$2" session_id="$3" project_root
    if [[ -n "${OCTOPUS_SESSION_PLANS:-}" ]]; then
        [[ "$OCTOPUS_SESSION_PLANS" == /* ]] || {
            plan_storage_error "OCTOPUS_SESSION_PLANS must be an absolute path"
            return 1
        }
        printf '%s\n' "${OCTOPUS_SESSION_PLANS%/}"
    elif project_root="$(plan_storage_project_root "$working_dir" "$home_dir")"; then
        printf '%s/.octo/plans\n' "$project_root"
    else
        printf '%s/.claude-octopus/sessions/%s/plans\n' \
            "$home_dir" "$(plan_storage_safe_id "$session_id")"
    fi
}

plan_storage_has_symlink_component() {
    local path="$1" current="/" component
    local -a components=()
    IFS='/' read -r -a components <<< "${path#/}"
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || continue
        current="${current%/}/${component}"
        [[ ! -L "$current" ]] || return 0
        [[ -e "$current" ]] || break
    done
    return 1
}

plan_storage_validate_base() {
    local plan_base="$1" home_dir="$2" create_missing="${3:-true}" physical_base
    [[ "$plan_base" == /* && "$plan_base" != "/" ]] || {
        plan_storage_error "plan storage root must be a non-root absolute path"
        return 1
    }
    case "$plan_base" in
        *//*)
            plan_storage_error "plan storage paths cannot contain empty components"
            return 1
            ;;
        */../*|*/..|*/./*|*/.)
            plan_storage_error "plan storage paths cannot contain dot components"
            return 1
            ;;
    esac
    case "$plan_base" in
        "$home_dir/.claude"|"$home_dir/.claude/"*)
            plan_storage_error "plan storage cannot use the global Claude config directory"
            return 1
            ;;
    esac
    plan_storage_has_symlink_component "$plan_base" && {
        plan_storage_error "plan storage paths cannot contain symlink components"
        return 1
    }
    if [[ "$create_missing" == "true" ]]; then
        mkdir -p "$plan_base"
    else
        [[ -d "$plan_base" ]] || return 1
    fi
    physical_base="$(plan_storage_physical_dir "$plan_base")" || return 1
    case "$physical_base" in
        "$home_dir/.claude"|"$home_dir/.claude/"*)
            plan_storage_error "plan storage cannot use the global Claude config directory"
            return 1
            ;;
    esac
    printf '%s\n' "$physical_base"
}

plan_storage_create() {
    local working_dir="$1" hook_input="$2" home_dir session_id plan_base plan_dir
    local pointer_file pointer_dir pointer_tmp

    home_dir="$(plan_storage_physical_dir "${HOME:?HOME is required}")" || {
        plan_storage_error "HOME is not an accessible directory"
        return 1
    }
    working_dir="$(plan_storage_physical_dir "$working_dir")" || {
        plan_storage_error "working directory is not accessible: $working_dir"
        return 1
    }
    session_id="$(octo_resolve_session_id "shell-${PPID}" "$hook_input")"
    plan_base="$(plan_storage_base_dir "$working_dir" "$home_dir" "$session_id")" || return 1
    plan_base="$(plan_storage_validate_base "$plan_base" "$home_dir" true)" || return 1
    plan_dir="$(mktemp -d "${plan_base}/plan-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"

    pointer_file="$(plan_storage_pointer_file "$home_dir" "$session_id" "$working_dir")"
    pointer_dir="${pointer_file%/*}"
    mkdir -p "$pointer_dir"
    pointer_tmp="$(mktemp "${pointer_file}.tmp.XXXXXX")"
    printf '%s\n%s\n' "$working_dir" "$plan_dir" > "$pointer_tmp"
    mv "$pointer_tmp" "$pointer_file"
    printf '%s\n' "$plan_dir"
}

plan_storage_current() {
    local working_dir="$1" hook_input="$2" home_dir session_id pointer_file
    local recorded_working_dir="" plan_dir="" plan_base physical_plan_dir

    home_dir="$(plan_storage_physical_dir "${HOME:?HOME is required}")" || return 1
    working_dir="$(plan_storage_physical_dir "$working_dir")" || return 1
    session_id="$(octo_resolve_session_id "shell-${PPID}" "$hook_input")"
    pointer_file="$(plan_storage_pointer_file "$home_dir" "$session_id" "$working_dir")"
    [[ -f "$pointer_file" && ! -L "$pointer_file" ]] || return 1
    IFS= read -r recorded_working_dir < "$pointer_file" || return 1
    IFS= read -r plan_dir < <(sed -n '2p' "$pointer_file") || return 1
    [[ "$recorded_working_dir" == "$working_dir" && -d "$plan_dir" && "$plan_dir" == /* ]] || return 1
    plan_base="$(plan_storage_base_dir "$working_dir" "$home_dir" "$session_id")" || return 1
    plan_base="$(plan_storage_validate_base "$plan_base" "$home_dir" false)" || return 1
    [[ ! -L "$plan_dir" ]] || return 1
    physical_plan_dir="$(plan_storage_physical_dir "$plan_dir")" || return 1
    [[ "$physical_plan_dir" == "$plan_base/"* ]] || return 1
    printf '%s\n' "$physical_plan_dir"
}

command_name="${1:-}"
working_dir="${2:-$PWD}"
hook_input="${3:-}"

case "$command_name" in
    create)  plan_storage_create "$working_dir" "$hook_input" ;;
    current) plan_storage_current "$working_dir" "$hook_input" ;;
    *)
        plan_storage_error "usage: plan-storage.sh {create|current} [working-directory] [hook-json]"
        exit 64
        ;;
esac
