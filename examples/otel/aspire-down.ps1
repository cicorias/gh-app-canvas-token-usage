#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Stop the local Aspire dashboard. Safe to run when it is not running.
#>
[CmdletBinding()]
param(
    [Alias('n')][string]$Name = 'aspire-dashboard',
    [Alias('r')][string]$Runtime,
    [Alias('d')][string]$CertDir = $(if ($env:OTEL_CERT_DIR) { $env:OTEL_CERT_DIR } else { './.otel-certs' }),
    [switch]$PurgeCerts
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if (-not $Runtime) {
    foreach ($candidate in @('docker', 'podman')) {
        if (Get-Command $candidate -ErrorAction SilentlyContinue) { $Runtime = $candidate; break }
    }
}

if ($Runtime) {
    & $Runtime info 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        # `rm -f` exits 0 for a container that does not exist, so ask first
        # rather than claiming to have stopped something that was never there.
        $existing = (& $Runtime ps -a --filter "name=^$Name$" --format '{{.Names}}' 2>&1) -split "`n" |
            Where-Object { $_ -eq $Name }
        if ($existing) {
            & $Runtime rm -f $Name 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Failed to remove '$Name'." }
            Write-Host "Stopped '$Name'."
        }
        else {
            Write-Host "'$Name' is not running."
        }
    }
    else {
        Write-Host 'No running container runtime; nothing to stop.'
    }
}
else {
    Write-Host 'No container runtime found; nothing to stop.'
}

if ($PurgeCerts) {
    if (Test-Path -LiteralPath $CertDir) {
        # Only remove a directory that actually looks like ours.
        $looksRight = (Test-Path -LiteralPath (Join-Path $CertDir 'ca.crt')) -and
                      (Test-Path -LiteralPath (Join-Path $CertDir 'otlp.crt'))
        if (-not $looksRight) {
            throw "$CertDir does not look like a generated certificate directory; refusing to delete it."
        }
        Remove-Item -LiteralPath $CertDir -Recurse -Force
        Write-Host "Removed certificates in $CertDir."
    }
    else {
        Write-Host "No certificate directory at $CertDir."
    }
}
