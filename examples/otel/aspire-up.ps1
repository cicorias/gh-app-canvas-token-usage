#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Run the .NET Aspire dashboard as a local OTLP target for GitHub Copilot CLI,
    with TLS on the OTLP/HTTP endpoint.

.DESCRIPTION
    TLS is not optional here. Copilot disables OTLP export rather than send it
    over cleartext http://, and says so only in its process log - so the Aspire
    quickstart's http://localhost:4318 appears to work and silently drops
    everything.

    Rerunnable: an already-running dashboard is left alone unless -Force.

.PARAMETER CertDir
    Certificate directory on the host. Any location works; it is bind-mounted
    into the container. Default: $env:OTEL_CERT_DIR, else ./.otel-certs

.EXAMPLE
    ./aspire-up.ps1

.EXAMPLE
    ./aspire-up.ps1 -CertDir ~/.otel/certs -OtlpPort 4319 -Force
#>
[CmdletBinding()]
param(
    [Alias('d')][string]$CertDir = $(if ($env:OTEL_CERT_DIR) { $env:OTEL_CERT_DIR } else { './.otel-certs' }),
    [Alias('n')][string]$Name = 'aspire-dashboard',
    [Alias('u')][int]$UiPort = 18888,
    [Alias('o')][int]$OtlpPort = 4318,
    [Alias('i')][string]$Image = 'mcr.microsoft.com/dotnet/aspire-dashboard:latest',
    [Alias('r')][string]$Runtime,
    [Alias('H')][string[]]$CertHost = @(),
    [switch]$RelaxKeyPerms,
    [switch]$NoCerts,
    [Alias('f')][switch]$Force
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$here = Split-Path -Parent $PSCommandPath

# Where the certificates are mounted inside the container. Nothing depends on
# this value; it just has to match the two Kestrel paths below.
$containerCertDir = '/certs'
# The dashboard's own OTLP/HTTP port inside the container.
$containerOtlpPort = 18890

if (-not $Runtime) {
    foreach ($candidate in @('docker', 'podman')) {
        if (Get-Command $candidate -ErrorAction SilentlyContinue) { $Runtime = $candidate; break }
    }
}
if (-not $Runtime) { throw 'No container runtime found; install docker or podman, or pass -Runtime.' }
if (-not (Get-Command $Runtime -ErrorAction SilentlyContinue)) { throw "$Runtime not found on PATH." }
& $Runtime info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "$Runtime is installed but not running." }

if (-not $NoCerts) {
    $certArgs = @{ CertDir = $CertDir }
    if ($CertHost) { $certArgs.CertHost = $CertHost }
    if ($RelaxKeyPerms) { $certArgs.RelaxKeyPerms = $true }
    if ($Force) { $certArgs.Force = $true }
    & (Join-Path $here 'otel-certs.ps1') @certArgs | Out-Null
}

if (-not (Test-Path -LiteralPath $CertDir)) { throw "Certificate directory not found: $CertDir" }
$CertDir = (Resolve-Path -LiteralPath $CertDir).Path
foreach ($f in @('otlp-fullchain.crt', 'otlp.key', 'ca.crt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $CertDir $f))) {
        throw "Missing $(Join-Path $CertDir $f) - run otel-certs.ps1"
    }
}

$running = (& $Runtime ps --filter "name=^$Name$" --format '{{.Names}}' 2>&1) -split "`n" | Where-Object { $_ -eq $Name }
if ($running) {
    if (-not $Force) {
        Write-Host "Dashboard '$Name' is already running (use -Force to replace it)."
        & (Join-Path $here 'aspire-login-url.ps1') -Name $Name -Runtime $Runtime -UiPort $UiPort
        exit 0
    }
}
# A stopped container of the same name would block the run below.
& $Runtime rm -f $Name 2>&1 | Out-Null

$runArgs = @(
    'run', '--rm', '-d', '--name', $Name
    '-p', "${UiPort}:18888"
    '-p', "${OtlpPort}:${containerOtlpPort}"
    '-v', "${CertDir}:${containerCertDir}:ro"
    '-e', "ASPIRE_DASHBOARD_OTLP_HTTP_ENDPOINT_URL=https://+:${containerOtlpPort}"
    '-e', "ASPNETCORE_Kestrel__Certificates__Default__Path=${containerCertDir}/otlp-fullchain.crt"
    '-e', "ASPNETCORE_Kestrel__Certificates__Default__KeyPath=${containerCertDir}/otlp.key"
    $Image
)
& $Runtime @runArgs 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "$Runtime run failed for '$Name'." }

# Wait for the TLS listener rather than guessing with a sleep.
$ready = $false
foreach ($attempt in 1..60) {
    $log = (& $Runtime logs $Name 2>&1) -join "`n"
    if ($log -match 'OTLP/HTTP listening on: https://') { $ready = $true; break }
    $alive = (& $Runtime ps --filter "name=^$Name$" --format '{{.Names}}' 2>&1) -split "`n" | Where-Object { $_ -eq $Name }
    if (-not $alive) { break }
    Start-Sleep -Seconds 1
}

if (-not $ready) {
    Write-Error "The dashboard did not start a TLS OTLP listener." -ErrorAction Continue
    Write-Host '--- container log ---'
    (& $Runtime logs $Name 2>&1) | Select-Object -Last 20 | ForEach-Object { Write-Host $_ }
    if (-not $IsWindows) {
        Write-Host ''
        Write-Host "If the log mentions the certificate or key, the container user may not be"
        Write-Host "able to read $(Join-Path $CertDir 'otlp.key'). Native Linux runtimes enforce"
        Write-Host 'host file ownership; Docker Desktop does not. Re-run with:'
        Write-Host '  ./aspire-up.ps1 -Force -RelaxKeyPerms'
    }
    exit 1
}

Write-Host ''
Write-Host 'Aspire dashboard is running.'
Write-Host "  container   $Name ($Runtime)"
Write-Host "  UI          http://localhost:$UiPort"
Write-Host "  OTLP/HTTP   https://localhost:$OtlpPort   (TLS, protobuf)"
Write-Host ''
Write-Host 'Copilot CLI settings:'
Write-Host "  OTEL_EXPORTER_OTLP_ENDPOINT=https://localhost:$OtlpPort"
Write-Host '  OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf'
Write-Host "  OTEL_EXPORTER_OTLP_CERTIFICATE=$(Join-Path $CertDir 'ca.crt')"

& (Join-Path $here 'aspire-login-url.ps1') -Name $Name -Runtime $Runtime -UiPort $UiPort
