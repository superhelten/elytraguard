<#
.SYNOPSIS
    Builds dist\elytraguard-setup.exe with Inno Setup 6. The version is
    read from elytraguard.ps1, so it can't drift from the guard's log lines.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$match = Select-String -Path (Join-Path $root 'elytraguard.ps1') -Pattern "\`$Entry\['version'\] = '([0-9.]+)'"
if (-not $match) { throw "No version found in elytraguard.ps1" }
$version = $match.Matches[0].Groups[1].Value

$iscc = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 not found. Install it with: winget install JRSoftware.InnoSetup' }

& $iscc /Q "/DAppVersion=$version" (Join-Path $PSScriptRoot 'elytraguard.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }

$exe = Join-Path $root 'dist\elytraguard-setup.exe'
Write-Host "Built $exe ($version)"
Write-Host "SHA256 $((Get-FileHash $exe -Algorithm SHA256).Hash.ToLower())"
