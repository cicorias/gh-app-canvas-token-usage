<#
.SYNOPSIS
Install the token-usage canvas extension (PowerShell 5.1+ / PowerShell 7+).

.DESCRIPTION
Works from a clone or straight off the network:

    ./install.ps1                                   # user scope
    ./install.ps1 -Project C:\path\to\repo          # project scope
    ./install.ps1 -Session <session-id>             # session scope

One command, no clone:

    irm https://raw.githubusercontent.com/cicorias/gh-app-canvas-token-usage/main/install.ps1 | iex

With arguments:

    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/cicorias/gh-app-canvas-token-usage/main/install.ps1))) -Project C:\path\to\repo
#>
[CmdletBinding()]
param(
    [switch]$User,
    [string]$Project,
    [string]$Session,
    [string]$Ref = 'main'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Name = 'token-usage'
$Repo = 'cicorias/gh-app-canvas-token-usage'
$Files = @('aggregate.mjs', 'extension.mjs', 'live.mjs', 'otel.mjs', 'paths.mjs',
    'ratecard.mjs', 'usagedb.mjs', 'ui.html', 'copilot-extension.json', 'README.md')

$copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }

if ($Project -and $Session) { throw 'use only one of -Project or -Session' }

$dest =
if ($Project) { Join-Path (Join-Path (Join-Path $Project '.github') 'extensions') $Name }
elseif ($Session) { Join-Path (Join-Path (Join-Path $copilotHome 'session-state') $Session) "extensions\$Name" }
else { Join-Path (Join-Path $copilotHome 'extensions') $Name }

# Prefer a sibling source folder (running from a clone); otherwise download the repo.
$src = $null
if ($PSCommandPath) {
    $local = Join-Path (Split-Path -Parent $PSCommandPath) $Name
    if (Test-Path (Join-Path $local 'extension.mjs')) { $src = $local }
}

$tmp = $null
if (-not $src) {
    Write-Host "downloading $Repo@$Ref ..."
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("$Name-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zip = Join-Path $tmp 'src.zip'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    Invoke-WebRequest -Uri "https://codeload.github.com/$Repo/zip/refs/heads/$Ref" -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem -Path $tmp -Directory |
    ForEach-Object { Join-Path $_.FullName $Name } |
    Where-Object { Test-Path (Join-Path $_ 'extension.mjs') } |
    Select-Object -First 1
    if (-not $src) { throw "could not find $Name/extension.mjs in the downloaded archive" }
}

try {
    # Node 22+ is required for the built-in node:sqlite module.
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        $major = [int]((& node -p 'process.versions.node.split(".")[0]') 2>$null)
        if ($major -lt 22) {
            Write-Warning "node $major detected; node:sqlite requires Node 22+ (history from session-store.db will be unavailable)"
        }
    }

    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    foreach ($f in $Files) {
        $path = Join-Path $src $f
        if (Test-Path $path) { Copy-Item -Path $path -Destination $dest -Force }
    }

    Write-Host "installed $Name -> $dest"
    Write-Host 'reload extensions or restart the CLI, then open the "Token usage & spend" canvas.'
}
finally {
    if ($tmp -and (Test-Path $tmp)) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
