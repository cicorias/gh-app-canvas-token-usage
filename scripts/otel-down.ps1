#!/usr/bin/env pwsh
#
# mise task entry point. The real implementation lives in examples/otel/ so it
# stays usable for people who never install mise.

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
& (Join-Path $repoRoot 'examples/otel/aspire-down.ps1') @args
