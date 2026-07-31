#!/usr/bin/env bash
#
# Shared Compose plumbing, sourced by aspire-up.sh and aspire-down.sh.
#
# Compose ships two ways: as a runtime subcommand (`docker compose`, the v2
# plugin) and as a standalone binary (`docker-compose`, `podman-compose`).
# Detect whichever is present instead of assuming.

# Sets COMPOSE_CMD (an array) and COMPOSE_DESC (for messages).
resolve_compose() {
    local runtime="$1"

    if "$runtime" compose version >/dev/null 2>&1; then
        COMPOSE_CMD=("$runtime" compose)
        COMPOSE_DESC="$runtime compose"
        return 0
    fi

    local standalone="${runtime}-compose"
    if command -v "$standalone" >/dev/null 2>&1; then
        COMPOSE_CMD=("$standalone")
        COMPOSE_DESC="$standalone"
        return 0
    fi

    echo "error: no Compose support found for '$runtime'." >&2
    echo "Install the Compose plugin (\`$runtime compose\`) or $standalone." >&2
    return 1
}

# compose <file> <project> [args...]
#
# The project name is pinned rather than derived from the directory, so the
# same stack is addressable from anywhere and two differently named dashboards
# do not collide.
compose() {
    local file="$1" project="$2"
    shift 2
    "${COMPOSE_CMD[@]}" --file "$file" --project-name "$(compose_project_name "$project")" "$@"
}

# Compose project names allow only lowercase letters, digits, dashes and
# underscores, and must start with a letter or digit.
compose_project_name() {
    local name
    name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')"
    case "$name" in
        [a-z0-9]*) printf '%s' "$name" ;;
        *) printf 'x%s' "$name" ;;
    esac
}
