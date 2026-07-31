#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Print the Aspire dashboard's browser login URL, which the container writes
    to its log once at startup.
#>
[CmdletBinding()]
param(
    [Alias('n')][string]$Name = 'aspire-dashboard',
    [Alias('r')][string]$Runtime,
    [Alias('u')][int]$UiPort = 18888
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if (-not $Runtime) {
    foreach ($candidate in @('docker', 'podman')) {
        if (Get-Command $candidate -ErrorAction SilentlyContinue) { $Runtime = $candidate; break }
    }
}
if (-not $Runtime) { throw 'No container runtime found.' }

$log = (& $Runtime logs $Name 2>&1) -join "`n"
$match = [regex]::Match($log, '/login\?t=([A-Za-z0-9]+)')
if (-not $match.Success) {
    Write-Warning "No login token in the log for '$Name'; is it running?"
    exit 1
}

# The port in the log is the container's, so rebuild the URL with the published
# host port.
Write-Host "  Login URL   http://localhost:$UiPort/login?t=$($match.Groups[1].Value)"
