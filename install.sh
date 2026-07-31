#!/usr/bin/env sh
# Install the token-usage canvas extension.
#
#   ./install.sh                      -> user scope ($COPILOT_HOME/extensions)
#   ./install.sh --project /path/repo -> project scope (<repo>/.github/extensions)
#   ./install.sh --session <id>       -> session scope
#   ./install.sh --ref <branch|tag>   -> source ref when downloading (default: main)
#
# One command, no clone:
#   curl -fsSL https://raw.githubusercontent.com/cicorias/gh-app-canvas-token-usage/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/cicorias/gh-app-canvas-token-usage/main/install.sh | sh -s -- --project /path/repo
#
set -eu

NAME="token-usage"
REPO="cicorias/gh-app-canvas-token-usage"
COPILOT_HOME="${COPILOT_HOME:-$HOME/.copilot}"

scope="user"
target_repo=""
session_id=""
ref="main"

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
        --ref)
            ref="${2:-main}"
            shift 2 || shift
            ;;
        -h | --help)
            if [ -f "${0:-}" ]; then
                sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            else
                echo "usage: install.sh [--user | --project <repo> | --session <id>] [--ref <branch|tag>]"
            fi
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

# Prefer a sibling source folder (running from a clone); otherwise download the repo.
SRC=""
script_dir="$(CDPATH='' cd -- "$(dirname -- "${0:-.}")" 2>/dev/null && pwd || true)"
if [ -n "$script_dir" ] && [ -f "$script_dir/$NAME/extension.mjs" ]; then
    SRC="$script_dir/$NAME"
fi

TMP=""
cleanup() {
    if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
}
trap cleanup EXIT INT TERM

if [ -z "$SRC" ]; then
    command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
    command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }
    echo "downloading $REPO@$ref ..."
    TMP="$(mktemp -d)"
    curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$ref" | tar -xzf - -C "$TMP"
    SRC="$(find "$TMP" -maxdepth 2 -type d -name "$NAME" | head -n 1)"
    if [ -z "$SRC" ] || [ ! -f "$SRC/extension.mjs" ]; then
        echo "could not find $NAME/extension.mjs in the downloaded archive" >&2
        exit 1
    fi
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
