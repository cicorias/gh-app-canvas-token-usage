#!/usr/bin/env bash
#
# mise task entry point. verify-otlp.py is a PEP-723 script: uv resolves its
# dependencies into a throwaway environment, so nothing is installed globally.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec uv run "$repo_root/examples/otel/verify-otlp.py" "$@"
