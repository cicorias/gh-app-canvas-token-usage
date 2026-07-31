#!/usr/bin/env bash
#
# mise task entry point. verify-otlp.py is a PEP-723 script: uv resolves its
# dependencies into a throwaway environment, so nothing is installed globally.

set -euo pipefail

if ! command -v uv >/dev/null 2>&1; then
    echo "error: uv is not on PATH. Install it from https://docs.astral.sh/uv/," >&2
    echo "       or run this through mise (\`mise run otel:verify\`), which provides it." >&2
    exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec uv run "$repo_root/examples/otel/verify-otlp.py" "$@"
