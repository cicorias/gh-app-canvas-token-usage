#!/usr/bin/env bash
#
# Print the Aspire dashboard's browser login URL, which the container writes to
# its log once at startup.

set -euo pipefail

NAME="aspire-dashboard"
RUNTIME=""
UI_PORT=18888

usage() {
    cat <<'EOF'
Usage: aspire-login-url.sh [options]

Options:
  -n, --name NAME       Container name. Default: aspire-dashboard
  -r, --runtime NAME    docker or podman. Default: whichever is found.
  -u, --ui-port PORT    Host port the UI is published on. Default: 18888
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
        -u | --ui-port)
            UI_PORT="$2"
            shift 2
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
[ -n "$RUNTIME" ] || die "no container runtime found"

token="$("$RUNTIME" logs "$NAME" 2>&1 | sed -n 's|.*/login?t=\([A-Za-z0-9]*\).*|\1|p' | head -1)"
[ -n "$token" ] || die "no login token in the log for '$NAME'; is it running?"

# The port inside the log is the container's, so rebuild the URL with the
# published host port.
echo "  Login URL   http://localhost:${UI_PORT}/login?t=${token}"
