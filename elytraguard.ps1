<#
.SYNOPSIS
    Stops the Elytra anti-cheat service when WARDOGS is not running.

.DESCRIPTION
    WARDOGS installs the Elytra anti-cheat as a demand-start Windows service
    (Elytra.Service) running as LocalSystem. The game starts it on launch, but
    it can keep running after the game has closed. ElytraGuard stops it again
    once no process from the WARDOGS install folder is running.

    Meant to run as SYSTEM from the scheduled task that install.ps1 creates.
    Every run appends one JSON line to the log, so a missing or failing guard
    can be noticed (see README).

    Safety rules, in order:
      - never stop the service while any process from the game folder, or a
        known game process name, is running;
      - leave a freshly started service alone for GraceMinutes, so a game that
        is still starting up is not cut off;
      - if the service start time can't be read, treat it as fresh.

.PARAMETER GraceMinutes
    Minimum service uptime before it may be stopped.

.PARAMETER LogPath
    JSON-lines log. Rotated to <name>.1 at 1 MB.

.PARAMETER DryRun
    Log what would happen without stopping anything.
#>
[CmdletBinding()]
param(
    [int]$GraceMinutes = 10,
    [string]$LogPath = (Join-Path $env:ProgramData 'ElytraGuard\elytraguard.log'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$WardogsAppId = '1867240'
$KnownGameProcesses = @('WardogsLauncher-Shipping', 'WardogsClient-Win64-Shipping')
$ServiceName = 'Elytra.Service'

function Write-GuardLog {
    param([hashtable]$Entry)
    $dir = Split-Path $LogPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) {
        # A log shipper may hold the file open; rotate next time instead.
        try { Move-Item $LogPath "$LogPath.1" -Force } catch { }
    }
    $Entry['time'] = (Get-Date).ToUniversalTime().ToString('o')
    $Entry['version'] = '1.0.2'
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Entry | ConvertTo-Json -Compress) + "`r`n")
    # Share read/write/delete: Add-Content fails while a log shipper (e.g. a
    # Docker bind mount) has the file open.
    $fs = [IO.File]::Open($LogPath, [IO.FileMode]::Append, [IO.FileAccess]::Write,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
}

function Get-SteamLibraries {
    $steam = $null
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        $p = Get-ItemProperty $key -Name InstallPath -ErrorAction SilentlyContinue
        if ($p) { $steam = $p.InstallPath; break }
    }
    if (-not $steam) { $steam = Join-Path ${env:ProgramFiles(x86)} 'Steam' }

    $libs = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $libs += $m.Groups[1].Value -replace '\\\\', '\'
        }
    }
    $libs | Select-Object -Unique
}

function Get-WardogsDir {
    foreach ($lib in Get-SteamLibraries) {
        $acf = Join-Path $lib "steamapps\appmanifest_$WardogsAppId.acf"
        if (Test-Path $acf) {
            $m = [regex]::Match((Get-Content $acf -Raw), '"installdir"\s+"([^"]+)"')
            if ($m.Success) {
                $dir = Join-Path $lib ("steamapps\common\" + $m.Groups[1].Value)
                if (Test-Path $dir) { return $dir }
            }
        }
    }
    $null
}

function Get-ElytraService {
    # By name first; by binary path in case a future version renames the service.
    $all = Get-CimInstance Win32_Service
    $svc = $all | Where-Object { $_.Name -eq $ServiceName } | Select-Object -First 1
    if (-not $svc) {
        $svc = $all | Where-Object { $_.PathName -match '\\Elytra\\[^\\]*\.exe' } | Select-Object -First 1
    }
    $svc
}

function Test-GameRunning {
    param([string]$GameDir)
    if (Get-Process -Name $KnownGameProcesses -ErrorAction SilentlyContinue) { return $true }
    if ($GameDir) {
        $prefix = $GameDir.TrimEnd('\') + '\'
        $hit = Get-CimInstance Win32_Process |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -First 1
        if ($hit) { return $true }
    }
    $false
}

$entry = @{ level = 'info' }
try {
    $svc = Get-ElytraService
    if (-not $svc) {
        $entry.result = 'no_service'
        Write-GuardLog $entry
        return
    }
    $entry.service = $svc.Name
    $entry.service_state = $svc.State

    if ($svc.State -ne 'Running') {
        $entry.result = 'idle'
        Write-GuardLog $entry
        return
    }

    $gameDir = Get-WardogsDir
    $entry.game_dir_found = [bool]$gameDir
    $entry.game_running = Test-GameRunning $gameDir
    if (-not $gameDir) {
        # Still safe thanks to the known process names, but detection is weaker.
        $entry.level = 'warn'
        $entry.message = 'WARDOGS install folder not found; using known process names only'
    }

    if ($entry.game_running) {
        $entry.result = 'game_running'
        Write-GuardLog $entry
        return
    }

    $uptime = $null
    try { $uptime = ((Get-Date) - (Get-Process -Id $svc.ProcessId).StartTime).TotalMinutes } catch { }
    if ($null -ne $uptime) { $entry.uptime_min = [math]::Round($uptime, 1) }
    if ($null -eq $uptime -or $uptime -lt $GraceMinutes) {
        $entry.result = 'grace'
        Write-GuardLog $entry
        return
    }

    if ($DryRun) {
        $entry.result = 'would_stop'
        Write-GuardLog $entry
        return
    }

    Stop-Service -Name $svc.Name -Force
    (Get-Service -Name $svc.Name).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
    $entry.service_state = [string](Get-Service -Name $svc.Name).Status
    $entry.result = 'stopped'
    Write-GuardLog $entry
}
catch {
    $entry.level = 'error'
    $entry.result = 'error'
    $entry.message = $_.Exception.Message
    try { $entry.service_state = [string](Get-Service -Name $ServiceName -ErrorAction Stop).Status } catch { }
    try { Write-GuardLog $entry } catch { }
    exit 1
}
