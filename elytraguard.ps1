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

    A run that finds the game open stays until the game closes, then stops
    Elytra within about a minute instead of at the next scheduled run. While
    it waits it logs a line every HeartbeatMinutes, as the task would.

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

.PARAMETER ServiceName
    The Elytra service. If no service has this name, one running from an
    Elytra folder is used instead.

.PARAMETER SettleSeconds
    How long the game must stay closed before the guard acts, so the switch
    from launcher to game client isn't taken for the game closing.

.PARAMETER HeartbeatMinutes
    While waiting for the game to close, log a line this often.
#>
[CmdletBinding()]
param(
    [int]$GraceMinutes = 10,
    [string]$LogPath = (Join-Path $env:ProgramData 'ElytraGuard\elytraguard.log'),
    [switch]$DryRun,
    [string]$ServiceName = 'Elytra.Service',
    [int]$SettleSeconds = 45,
    [double]$HeartbeatMinutes = 5
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$WardogsAppId = '1867240'
$KnownGameProcesses = @('WardogsLauncher-Shipping', 'WardogsClient-Win64-Shipping')

function Write-GuardLog {
    param([hashtable]$Entry)
    New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force | Out-Null
    if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) {
        # A log shipper may hold the file open; rotate next time instead.
        try { Move-Item $LogPath "$LogPath.1" -Force } catch { }
    }
    $Entry['time'] = (Get-Date).ToUniversalTime().ToString('o')
    $Entry['version'] = '1.1.0'
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

function Get-GameProcess {
    param($Processes, [string]$GameDir)
    $prefix = if ($GameDir) { $GameDir.TrimEnd('\') + '\' } else { $null }
    $Processes | Where-Object {
        ($KnownGameProcesses -contains [IO.Path]::GetFileNameWithoutExtension($_.Name)) -or
        ($prefix -and $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))
    }
}

# True once the process is gone, false if it still runs after $Milliseconds.
function Wait-ProcessExit {
    param([int]$Id, [int]$Milliseconds)
    try { $p = [Diagnostics.Process]::GetProcessById($Id) } catch { return $true }
    try { return $p.WaitForExit($Milliseconds) }
    catch {
        # No handle to wait on (access denied): poll instead.
        $end = (Get-Date).AddMilliseconds($Milliseconds)
        while ((Get-Date) -lt $end) {
            if (-not (Get-Process -Id $Id -ErrorAction SilentlyContinue)) { return $true }
            Start-Sleep -Seconds 5
        }
        return -not (Get-Process -Id $Id -ErrorAction SilentlyContinue)
    }
}

# Blocks until no game process has run for SettleSeconds. The task skips its
# own runs while this one lasts, so log $Entry every HeartbeatMinutes instead.
function Wait-GameExit {
    param([hashtable]$Entry, [string]$GameDir)
    $beat = (Get-Date).AddMinutes($HeartbeatMinutes)
    do {
        foreach ($p in @(Get-GameProcess (Get-CimInstance Win32_Process) $GameDir)) {
            while (-not (Wait-ProcessExit $p.ProcessId ([math]::Max(1000, ($beat - (Get-Date)).TotalMilliseconds)))) {
                Write-GuardLog $Entry
                $beat = (Get-Date).AddMinutes($HeartbeatMinutes)
            }
        }
        Start-Sleep -Seconds $SettleSeconds
    } while (Get-GameProcess (Get-CimInstance Win32_Process) $GameDir)
}

# Decides what to do, stops the service if it should, and returns the result.
# Everything else worth logging goes into $Entry.
function Invoke-Guard {
    param([hashtable]$Entry)
    $svc = Get-ElytraService
    if (-not $svc) { return 'no_service' }
    $Entry.service = $svc.Name
    $Entry.service_state = $svc.State
    if ($svc.State -ne 'Running') { return 'idle' }

    $gameDir = Get-WardogsDir
    $Entry.game_dir_found = [bool]$gameDir
    if (-not $gameDir) {
        # Still safe thanks to the known process names, but detection is weaker.
        $Entry.level = 'warn'
        $Entry.message = 'WARDOGS install folder not found; using known process names only'
    }
    $procs = @(Get-CimInstance Win32_Process)
    $Entry.game_running = [bool](Get-GameProcess $procs $gameDir)
    if ($Entry.game_running) {
        # Stay until the game closes, then decide again from scratch.
        $Entry.result = 'game_running'
        Write-GuardLog $Entry
        Wait-GameExit $Entry $gameDir
        $Entry.Clear()
        $Entry.level = 'info'
        return Invoke-Guard $Entry
    }

    # CreationDate is readable without admin rights, unlike Process.StartTime.
    $svcProc = $procs | Where-Object { $_.ProcessId -eq $svc.ProcessId } | Select-Object -First 1
    if (-not ($svcProc -and $svcProc.CreationDate)) { return 'grace' }
    $uptime = ((Get-Date) - $svcProc.CreationDate).TotalMinutes
    $Entry.uptime_min = [math]::Round($uptime, 1)
    if ($uptime -lt $GraceMinutes) { return 'grace' }
    if ($DryRun) { return 'would_stop' }

    # Stop-Service waits forever; a hung stop would hit the task's time limit
    # and leave no log line. Time out here instead, so it is logged as an error.
    Stop-Service -Name $svc.Name -Force -NoWait
    (Get-Service -Name $svc.Name).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    $Entry.service_state = 'Stopped'
    'stopped'
}

$entry = @{ level = 'info' }
try {
    $entry.result = Invoke-Guard $entry
    Write-GuardLog $entry
}
catch {
    $entry.level = 'error'
    $entry.result = 'error'
    $entry.message = $_.Exception.Message
    $name = if ($entry.ContainsKey('service')) { $entry.service } else { $ServiceName }
    try { $entry.service_state = [string](Get-Service -Name $name -ErrorAction Stop).Status } catch { }
    try { Write-GuardLog $entry } catch { }
    exit 1
}
