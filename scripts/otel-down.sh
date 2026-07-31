#!/usr/bin/env bash
#
# mise task entry point. The real implementation lives in examples/otel/ so it
# stays copy-pasteable for people who never install mise.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$repo_root/examples/otel/aspire-down.sh" "$@"
