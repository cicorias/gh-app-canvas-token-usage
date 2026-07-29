#!/usr/bin/env sh
# Install the token-usage canvas extension.
#
#   ./install.sh                      -> user scope ($COPILOT_HOME/extensions)
#   ./install.sh --project /path/repo -> project scope (<repo>/.github/extensions)
#   ./install.sh --session <id>       -> session scope
#
set -eu

NAME="token-usage"
SRC="$(CDPATH='' cd -- "$(dirname -- "$0")/$NAME" && pwd)"
COPILOT_HOME="${COPILOT_HOME:-$HOME/.copilot}"

scope="user"
target_repo=""
session_id=""

while [ $# -gt 0 ]; do
    case "$1" in
        --user)
            scope="user"
            shift
            ;;
        --project)
            scope="project"
            target_repo="${2:-.}"
            shift 2 || shift
            ;;
        --session)
            scope="session"
            session_id="${2:-}"
            shift 2 || shift
            ;;
        -h | --help)
            sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

case "$scope" in
    user) DEST="$COPILOT_HOME/extensions/$NAME" ;;
    project) DEST="$target_repo/.github/extensions/$NAME" ;;
    session)
        if [ -z "$session_id" ]; then
            echo "--session requires a session id" >&2
            exit 2
        fi
        DEST="$COPILOT_HOME/session-state/$session_id/extensions/$NAME"
        ;;
esac

if [ ! -f "$SRC/extension.mjs" ]; then
    echo "source not found: $SRC/extension.mjs" >&2
    exit 1
fi

# Node 22+ is required for the built-in node:sqlite module.
if command -v node >/dev/null 2>&1; then
    major="$(node -p 'process.versions.node.split(".")[0]')"
    if [ "$major" -lt 22 ]; then
        echo "warning: node $major detected; node:sqlite requires Node 22+ (history from session-store.db will be unavailable)" >&2
    fi
fi

mkdir -p "$DEST"
cp "$SRC"/*.mjs "$SRC"/ui.html "$SRC"/copilot-extension.json "$SRC"/README.md "$DEST"/

echo "installed $NAME -> $DEST"
echo "reload extensions or restart the CLI, then open the \"Token usage & spend\" canvas."
