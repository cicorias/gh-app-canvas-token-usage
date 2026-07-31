#!/usr/bin/env bash
#
# Run the .NET Aspire dashboard as a local OTLP target for GitHub Copilot CLI,
# with TLS on the OTLP/HTTP endpoint.
#
# TLS is not optional here. Copilot disables OTLP export rather than send it
# over cleartext http://, and says so only in its process log — so the Aspire
# quickstart's http://localhost:4318 appears to work and silently drops
# everything.
#
# Rerunnable: an already-running dashboard is left alone unless --force.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CERT_DIR="${OTEL_CERT_DIR:-./.otel-certs}"
NAME="aspire-dashboard"
UI_PORT=18888
OTLP_PORT=4318
IMAGE="mcr.microsoft.com/dotnet/aspire-dashboard:latest"
RUNTIME=""
FORCE=0
SKIP_CERTS=0
CERT_ARGS=()

COMPOSE_FILE="$HERE/compose-aspire.yaml"

usage() {
    cat <<'EOF'
Usage: aspire-up.sh [options]

Starts the Aspire dashboard with its OTLP/HTTP endpoint served over TLS,
generating certificates first if they are missing.

Options:
  -d, --cert-dir DIR    Certificate directory on the host. Any location works;
                        it is bind-mounted into the container.
                        Default: $OTEL_CERT_DIR, else ./.otel-certs
  -n, --name NAME       Container name. Default: aspire-dashboard
  -u, --ui-port PORT    Host port for the dashboard UI. Default: 18888
  -o, --otlp-port PORT  Host port for OTLP/HTTP over TLS. Default: 4318
  -i, --image REF       Container image. Default:
                        mcr.microsoft.com/dotnet/aspire-dashboard:latest
  -r, --runtime NAME    docker or podman. Default: whichever is found.
  -c, --compose-file F  Compose file to use. Default: compose-aspire.yaml
                        next to this script.
  -H, --host NAME       Extra hostname for the certificate. Repeatable.
                        Passed through to otel-certs.sh.
      --relax-key-perms Passed through to otel-certs.sh. Needed only when a
                        native Linux runtime cannot read a 0600 key.
      --no-certs        Do not create certificates; fail if they are absent.
  -f, --force           Replace a container that is already running, and
                        regenerate certificates.
  -h, --help            Show this help.

Examples:
  aspire-up.sh
  aspire-up.sh --cert-dir ~/.otel/certs --otlp-port 4319
  aspire-up.sh --force
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d | --cert-dir)
            [ $# -ge 2 ] || die "$1 requires a value"
            CERT_DIR="$2"
            shift 2
            ;;
        -n | --name)
            [ $# -ge 2 ] || die "$1 requires a value"
            NAME="$2"
            shift 2
            ;;
        -u | --ui-port)
            [ $# -ge 2 ] || die "$1 requires a value"
            UI_PORT="$2"
            shift 2
            ;;
        -o | --otlp-port)
            [ $# -ge 2 ] || die "$1 requires a value"
            OTLP_PORT="$2"
            shift 2
            ;;
        -i | --image)
            [ $# -ge 2 ] || die "$1 requires a value"
            IMAGE="$2"
            shift 2
            ;;
        -r | --runtime)
            [ $# -ge 2 ] || die "$1 requires a value"
            RUNTIME="$2"
            shift 2
            ;;
        -c | --compose-file)
            [ $# -ge 2 ] || die "$1 requires a value"
            COMPOSE_FILE="$2"
            shift 2
            ;;
        -H | --host)
            [ $# -ge 2 ] || die "$1 requires a value"
            CERT_ARGS+=(--host "$2")
            shift 2
            ;;
        --relax-key-perms)
            CERT_ARGS+=(--relax-key-perms)
            shift
            ;;
        --no-certs)
            SKIP_CERTS=1
            shift
            ;;
        -f | --force)
            FORCE=1
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
        if command -v "$candidate" >/dev/null 2>&1; then
            RUNTIME="$candidate"
            break
        fi
    done
fi
[ -n "$RUNTIME" ] || die "no container runtime found; install docker or podman, or pass --runtime"
command -v "$RUNTIME" >/dev/null 2>&1 || die "$RUNTIME not found on PATH"
"$RUNTIME" info >/dev/null 2>&1 || die "$RUNTIME is installed but not running"

# shellcheck source=compose.sh
. "$HERE/compose.sh"
resolve_compose "$RUNTIME"
[ -f "$COMPOSE_FILE" ] || die "compose file not found: $COMPOSE_FILE"

if [ "$SKIP_CERTS" -eq 0 ]; then
    [ "$FORCE" -eq 1 ] && CERT_ARGS+=(--force)
    "$HERE/otel-certs.sh" --cert-dir "$CERT_DIR" ${CERT_ARGS[@]+"${CERT_ARGS[@]}"} >/dev/null
fi

[ -d "$CERT_DIR" ] || die "certificate directory not found: $CERT_DIR"
CERT_DIR="$(cd "$CERT_DIR" && pwd)"
for f in otlp-fullchain.crt otlp.key ca.crt; do
    [ -s "$CERT_DIR/$f" ] || die "missing $CERT_DIR/$f — run otel-certs.sh"
done

if "$RUNTIME" ps --filter "name=^${NAME}$" --format '{{.Names}}' | grep -qx "$NAME"; then
    if [ "$FORCE" -eq 0 ]; then
        echo "Dashboard '$NAME' is already running (use --force to replace it)."
        "$HERE/aspire-login-url.sh" --name "$NAME" --runtime "$RUNTIME" --ui-port "$UI_PORT" || true
        exit 0
    fi
fi

# Compose reads all of these from the environment; see compose-aspire.yaml.
export OTEL_CERT_DIR="$CERT_DIR"
export ASPIRE_NAME="$NAME"
export ASPIRE_UI_PORT="$UI_PORT"
export ASPIRE_OTLP_PORT="$OTLP_PORT"
export ASPIRE_IMAGE="$IMAGE"

up_args=(up --detach)
# Without this, compose leaves a container whose config has not changed alone,
# so --force would silently do nothing.
[ "$FORCE" -eq 1 ] && up_args+=(--force-recreate)

compose "$COMPOSE_FILE" "$NAME" "${up_args[@]}" >/dev/null

# Wait for the TLS listener to come up rather than guessing with sleep.
ready=0
for _ in $(seq 1 60); do
    if "$RUNTIME" logs "$NAME" 2>&1 | grep -q "OTLP/HTTP listening on: https://"; then
        ready=1
        break
    fi
    if ! "$RUNTIME" ps --filter "name=^${NAME}$" --format '{{.Names}}' | grep -qx "$NAME"; then
        break
    fi
    sleep 1
done

if [ "$ready" -eq 0 ]; then
    echo "error: the dashboard did not start a TLS OTLP listener." >&2
    echo "--- container log ---" >&2
    "$RUNTIME" logs "$NAME" 2>&1 | tail -20 >&2 || true
    if [ ! -r "$CERT_DIR/otlp.key" ] || [ "$(uname -s)" = "Linux" ]; then
        cat >&2 <<EOF

If the log mentions the certificate or key, the container user may not be able
to read $CERT_DIR/otlp.key (mode $(ls -l "$CERT_DIR/otlp.key" | awk '{print $1}')).
Native Linux runtimes enforce host file ownership; Docker Desktop does not.
Re-run with: aspire-up.sh --force --relax-key-perms
EOF
    fi
    exit 1
fi

cat <<EOF

Aspire dashboard is running.
  container   $NAME ($COMPOSE_DESC)
  UI          http://localhost:${UI_PORT}
  OTLP/HTTP   https://localhost:${OTLP_PORT}   (TLS, protobuf)

Copilot CLI settings:
  OTEL_EXPORTER_OTLP_ENDPOINT=https://localhost:${OTLP_PORT}
  OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
  OTEL_EXPORTER_OTLP_CERTIFICATE=${CERT_DIR}/ca.crt
EOF

"$HERE/aspire-login-url.sh" --name "$NAME" --runtime "$RUNTIME" --ui-port "$UI_PORT" || true
