#!/usr/bin/env bash
#
# Stop the local Aspire dashboard. Safe to run when it is not running.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMPOSE_FILE="$HERE/compose-aspire.yaml"
NAME="aspire-dashboard"
RUNTIME=""
PURGE_CERTS=0
CERT_DIR="${OTEL_CERT_DIR:-./.otel-certs}"

usage() {
    cat <<'EOF'
Usage: aspire-down.sh [options]

Options:
  -n, --name NAME       Container name. Default: aspire-dashboard
  -r, --runtime NAME    docker or podman. Default: whichever is found.
  -c, --compose-file F  Compose file to use. Default: compose-aspire.yaml
                        next to this script.
      --purge-certs     Also delete the certificate directory.
  -d, --cert-dir DIR    Certificate directory for --purge-certs.
                        Default: $OTEL_CERT_DIR, else ./.otel-certs
  -h, --help            Show this help.
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        -n | --name)
            NAME="$2"
            shift 2
            ;;
        -r | --runtime)
            RUNTIME="$2"
            shift 2
            ;;
        -c | --compose-file)
            COMPOSE_FILE="$2"
            shift 2
            ;;
        -d | --cert-dir)
            CERT_DIR="$2"
            shift 2
            ;;
        --purge-certs)
            PURGE_CERTS=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

if [ -z "$RUNTIME" ]; then
    for candidate in docker podman; do
        command -v "$candidate" >/dev/null 2>&1 && RUNTIME="$candidate" && break
    done
fi

if [ -n "$RUNTIME" ] && "$RUNTIME" info >/dev/null 2>&1; then
    # shellcheck source=compose.sh
    . "$HERE/compose.sh"
    resolve_compose "$RUNTIME" || exit 1
    [ -f "$COMPOSE_FILE" ] || die "compose file not found: $COMPOSE_FILE"

    # `down` tears the stack down whether or not it is running, so check first
    # rather than claiming to have stopped something that was never there.
    if "$RUNTIME" ps -a --filter "name=^${NAME}$" --format '{{.Names}}' 2>/dev/null |
        grep -qx "$NAME"; then
        export ASPIRE_NAME="$NAME"
        compose "$COMPOSE_FILE" "$NAME" down --remove-orphans >/dev/null 2>&1 ||
            die "failed to stop '$NAME'"
        echo "Stopped '$NAME'."
    else
        echo "'$NAME' is not running."
    fi
else
    echo "No running container runtime; nothing to stop."
fi

if [ "$PURGE_CERTS" -eq 1 ]; then
    if [ -d "$CERT_DIR" ]; then
        # Only remove a directory that actually looks like ours.
        if [ -f "$CERT_DIR/ca.crt" ] && [ -f "$CERT_DIR/otlp.crt" ]; then
            rm -rf "$CERT_DIR"
            echo "Removed certificates in $CERT_DIR."
        else
            die "$CERT_DIR does not look like a generated certificate directory; refusing to delete it"
        fi
    else
        echo "No certificate directory at $CERT_DIR."
    fi
fi
