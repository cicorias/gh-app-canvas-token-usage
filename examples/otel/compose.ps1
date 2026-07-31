#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Shared Compose plumbing, dot-sourced by aspire-up.ps1 and aspire-down.ps1.

.DESCRIPTION
    Compose ships two ways: as a runtime subcommand (`docker compose`, the v2
    plugin) and as a standalone binary (`docker-compose`, `podman-compose`).
    Detect whichever is present instead of assuming.
#>

$script:ComposeCmd = $null
$script:ComposeDesc = $null

function Resolve-Compose {
    param([Parameter(Mandatory)][string]$Runtime)

    & $Runtime compose version 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $script:ComposeCmd = @($Runtime, 'compose')
        $script:ComposeDesc = "$Runtime compose"
        return
    }

    $standalone = "$Runtime-compose"
    if (Get-Command $standalone -ErrorAction SilentlyContinue) {
        $script:ComposeCmd = @($standalone)
        $script:ComposeDesc = $standalone
        return
    }

    throw "No Compose support found for '$Runtime'. Install the Compose plugin (``$Runtime compose``) or $standalone."
}

function Get-ComposeProjectName {
    param([Parameter(Mandatory)][string]$Name)
    # Compose project names allow only lowercase letters, digits, dashes and
    # underscores, and must start with a letter or digit.
    $clean = ($Name.ToLowerInvariant() -replace '[^a-z0-9_-]', '-')
    if ($clean -match '^[a-z0-9]') { return $clean }
    return "x$clean"
}

function Invoke-Compose {
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string[]]$ComposeArgs
    )
    if (-not $script:ComposeCmd) { throw 'Resolve-Compose has not been called.' }
    # The project name is pinned rather than derived from the directory, so the
    # same stack is addressable from anywhere and two differently named
    # dashboards do not collide.
    $exe = $script:ComposeCmd[0]
    $prefix = @($script:ComposeCmd | Select-Object -Skip 1) +
              @('--file', $File, '--project-name', (Get-ComposeProjectName $Project))
    & $exe @prefix @ComposeArgs
}
