#!/usr/bin/env pwsh
#
# mise task entry point. verify-otlp.py is a PEP-723 script: uv resolves its
# dependencies into a throwaway environment, so nothing is installed globally.

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    throw 'uv is not on PATH. Install it from https://docs.astral.sh/uv/, or run this through mise (`mise run otel:verify`), which provides it.'
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
& uv run (Join-Path $repoRoot 'examples/otel/verify-otlp.py') @args
