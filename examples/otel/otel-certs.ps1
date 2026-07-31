#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Create a local certificate authority and a TLS server certificate for an
    OTLP endpoint on localhost.

.DESCRIPTION
    GitHub Copilot CLI refuses to send OTLP over cleartext http://, and its
    exporter uses a Rust TLS stack that rejects a self-signed CA certificate
    presented as the server's own leaf. So "just make a self-signed cert" does
    not work - a real two-certificate chain is required, which is what this
    script produces.

    Rerunnable: existing certificates are kept unless they are invalid,
    expiring, or missing a requested hostname. Use -Force to regenerate
    regardless.

.PARAMETER CertDir
    Where to write the certificates. Default: $env:OTEL_CERT_DIR, else
    ./.otel-certs. Relative paths resolve against the current directory.

.PARAMETER CertHost
    Extra hostnames to include as SANs. "localhost" is always included.

.PARAMETER Force
    Regenerate even if usable certificates already exist.

.PARAMETER RelaxKeyPerms
    Leave the server key world-readable instead of restricting it. Needed only
    when a native Linux container runtime runs the server as a different uid.

.EXAMPLE
    ./otel-certs.ps1

.EXAMPLE
    ./otel-certs.ps1 -CertDir ./certs -CertHost host.docker.internal -Force
#>
[CmdletBinding()]
param(
    [Alias('d')][string]$CertDir = $(if ($env:OTEL_CERT_DIR) { $env:OTEL_CERT_DIR } else { './.otel-certs' }),
    [Alias('H')][string[]]$CertHost = @(),
    [string]$CommonName = 'localhost',
    [int]$Days = 825,
    [Alias('f')][switch]$Force,
    [switch]$RelaxKeyPerms
)

$ErrorActionPreference = 'Stop'
# openssl writes progress to stderr; without this PowerShell 7.4+ turns that
# into a terminating error. Exit codes are checked explicitly instead.
$PSNativeCommandUseErrorActionPreference = $false

$RenewWindowDays = 30

function Invoke-OpenSsl {
    # The arguments are passed as one array rather than as remaining arguments,
    # because PowerShell would otherwise try to bind things like -out to its own
    # common parameters (-OutVariable, -OutBuffer) and fail as ambiguous.
    param([Parameter(Mandatory = $true, Position = 0)][string[]]$OpenSslArgs)
    $output = & openssl @OpenSslArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "openssl $($OpenSslArgs -join ' ') failed:`n$output"
    }
    return $output
}

function Test-OpenSslQuiet {
    param([Parameter(Mandatory = $true, Position = 0)][string[]]$OpenSslArgs)
    & openssl @OpenSslArgs 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Set-PrivateKeyPermission {
    param([string]$Path, [bool]$Relax)
    if ($IsWindows) {
        if (-not $Relax) {
            # Owner-only, matching the intent of chmod 600 elsewhere.
            & icacls $Path /inheritance:r /grant:r "$($env:USERNAME):(R,W)" 2>&1 | Out-Null
        }
    }
    else {
        & chmod $(if ($Relax) { '644' } else { '600' }) $Path 2>&1 | Out-Null
    }
}

if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    throw 'openssl not found on PATH. On Windows it ships with Git for Windows, or install it with: winget install ShiningLight.OpenSSL.Light'
}

# Always cover localhost, preserving caller order and dropping duplicates.
$allHosts = @('localhost')
foreach ($h in $CertHost) {
    if ($h -and ($allHosts -notcontains $h)) { $allHosts += $h }
}

if (-not (Test-Path -LiteralPath $CertDir)) {
    New-Item -ItemType Directory -Path $CertDir -Force | Out-Null
}
$CertDir = (Resolve-Path -LiteralPath $CertDir).Path

$caCrt = Join-Path $CertDir 'ca.crt'
$caKey = Join-Path $CertDir 'ca.key'
$leafCrt = Join-Path $CertDir 'otlp.crt'
$leafKey = Join-Path $CertDir 'otlp.key'
$fullChain = Join-Path $CertDir 'otlp-fullchain.crt'

function Get-SanEntries {
    # @(...) is load-bearing: with a single hostname ForEach-Object returns a
    # bare string, and + would then concatenate instead of appending, producing
    # a malformed subjectAltName that openssl rejects.
    $dns = @($allHosts | ForEach-Object { "DNS:$_" })
    return (($dns + @('IP:127.0.0.1', 'IP:::1')) -join ',')
}

function Test-CertsUsable {
    foreach ($f in @($caCrt, $caKey, $leafCrt, $leafKey, $fullChain)) {
        if (-not (Test-Path -LiteralPath $f)) { return $false }
        if ((Get-Item -LiteralPath $f).Length -eq 0) { return $false }
    }
    if (-not (Test-OpenSslQuiet @('verify', '-CAfile', $caCrt, $leafCrt))) { return $false }

    $seconds = $RenewWindowDays * 86400
    if (-not (Test-OpenSslQuiet @('x509', '-checkend', "$seconds", '-noout', '-in', $leafCrt))) { return $false }
    if (-not (Test-OpenSslQuiet @('x509', '-checkend', "$seconds", '-noout', '-in', $caCrt))) { return $false }

    # `openssl x509 -ext` is missing from the LibreSSL that ships with macOS, so
    # read the extensions out of the text dump instead.
    $text = (& openssl x509 -in $leafCrt -noout -text 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { return $false }

    # OpenSSL 3 clients refuse to build a chain without these, so certificates
    # generated before they were added must be replaced.
    if ($text -notmatch 'Authority Key Identifier') { return $false }

    foreach ($h in $allHosts) {
        if ($text -notmatch [regex]::Escape("DNS:$h") + '(,|\s|$)') { return $false }
    }
    return $true
}

function Write-Result {
    param([string]$Action)
    # Write-Output, not Write-Host: callers such as aspire-up.ps1 pipe this to
    # Out-Null, and Write-Host bypasses the pipeline entirely.
    $notAfter = ((& openssl x509 -in $leafCrt -noout -enddate) -split '=', 2)[1]
    Write-Output ''
    Write-Output $Action
    Write-Output "  directory   $CertDir"
    Write-Output "  hostnames   $($allHosts -join ' ')"
    Write-Output "  expires     $notAfter"
    Write-Output ''
    Write-Output 'Server (for example the Aspire dashboard) should present:'
    Write-Output "  certificate $fullChain"
    Write-Output "  private key $leafKey"
    Write-Output ''
    Write-Output 'Copilot CLI should trust:'
    Write-Output "  OTEL_EXPORTER_OTLP_CERTIFICATE=$caCrt"
}

if (-not $Force -and (Test-CertsUsable)) {
    Write-Result 'Existing certificates are still usable; nothing to do (use -Force to regenerate).'
    exit 0
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    $wCaCrt = Join-Path $work 'ca.crt'
    $wCaKey = Join-Path $work 'ca.key'
    $wLeafCrt = Join-Path $work 'otlp.crt'
    $wLeafKey = Join-Path $work 'otlp.key'
    $wCsr = Join-Path $work 'otlp.csr'
    $wExt = Join-Path $work 'leaf.ext'
    $wChain = Join-Path $work 'otlp-fullchain.crt'

    # 1. The certificate authority. Copilot is pointed at this, and only this.
    Invoke-OpenSsl @(
        'req', '-x509', '-newkey', 'rsa:2048', '-sha256', '-days', "$Days", '-nodes'
        '-keyout', $wCaKey, '-out', $wCaCrt
        '-subj', '/CN=Local OTLP development CA'
        '-addext', 'basicConstraints=critical,CA:TRUE,pathlen:0'
        '-addext', 'keyUsage=critical,keyCertSign,cRLSign'
        '-addext', 'subjectKeyIdentifier=hash'
    ) | Out-Null

    # 2. The server certificate, signed by that CA. It must be a leaf - CA:FALSE
    #    with serverAuth - or the Rust TLS stack in the exporter rejects it.
    Invoke-OpenSsl @(
        'req', '-newkey', 'rsa:2048', '-sha256', '-nodes'
        '-keyout', $wLeafKey, '-out', $wCsr, '-subj', "/CN=$CommonName"
    ) | Out-Null

    @(
        'basicConstraints=critical,CA:FALSE'
        'keyUsage=critical,digitalSignature,keyEncipherment'
        'extendedKeyUsage=serverAuth'
        "subjectAltName=$(Get-SanEntries)"
        'subjectKeyIdentifier=hash'
        'authorityKeyIdentifier=keyid:always'
    ) | Set-Content -LiteralPath $wExt -Encoding ascii

    Invoke-OpenSsl @(
        'x509', '-req', '-in', $wCsr, '-CA', $wCaCrt, '-CAkey', $wCaKey
        '-CAcreateserial', '-out', $wLeafCrt, '-days', "$Days", '-sha256', '-extfile', $wExt
    ) | Out-Null

    Get-Content -LiteralPath $wLeafCrt, $wCaCrt | Set-Content -LiteralPath $wChain -Encoding ascii

    $verify = & openssl @('verify', '-CAfile', $wCaCrt, $wLeafCrt) 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "generated certificate failed verification:`n$verify"
    }

    # Only replace the real files once everything above succeeded.
    Copy-Item -LiteralPath $wCaCrt -Destination $caCrt -Force
    Copy-Item -LiteralPath $wCaKey -Destination $caKey -Force
    Copy-Item -LiteralPath $wLeafCrt -Destination $leafCrt -Force
    Copy-Item -LiteralPath $wLeafKey -Destination $leafKey -Force
    Copy-Item -LiteralPath $wChain -Destination $fullChain -Force

    Set-PrivateKeyPermission -Path $caKey -Relax $false
    Set-PrivateKeyPermission -Path $leafKey -Relax ([bool]$RelaxKeyPerms)
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Result 'Generated a new certificate authority and server certificate.'
