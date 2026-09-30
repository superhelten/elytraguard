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
        is still starting up is not cut off, unless this run has just seen
        the game open and close;
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

.PARAMETER BaselinePath
    The record of how Elytra is set up: its service settings, its program
    files and anything else it installed. Each run compares against it; see
    README, "Watching Elytra for changes".

.PARAMETER AcceptElytraChanges
    Record Elytra's current setup as the new baseline, then exit. Run this as
    admin after checking a change the guard warned about.
#>
[CmdletBinding()]
param(
    [int]$GraceMinutes = 10,
    [string]$LogPath = (Join-Path $env:ProgramData 'ElytraGuard\elytraguard.log'),
    [switch]$DryRun,
    [string]$ServiceName = 'Elytra.Service',
    [int]$SettleSeconds = 45,
    [double]$HeartbeatMinutes = 5,
    [string]$BaselinePath = (Join-Path $env:ProgramData 'ElytraGuard\elytra-baseline.json'),
    [switch]$AcceptElytraChanges
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
    $Entry['version'] = '1.2.0'
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

function Add-Message {
    param([hashtable]$Entry, [string]$Text)
    # StrictMode throws on $Entry.message while the key is missing.
    if ($Entry.ContainsKey('message')) { $Entry['message'] += "; $Text" } else { $Entry['message'] = $Text }
}

# A property of a baseline read from JSON, or $null. StrictMode throws on a
# missing property, and an older baseline may lack a newer field.
function Get-Field {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

function Get-List {
    param($Object, [string]$Name)
    @(Get-Field $Object $Name | Where-Object { $null -ne $_ })
}

# Who signed a file, or '' unless the signature is valid: a tampered file
# still carries its certificate but fails the check.
function Get-Signer {
    param([string]$Path)
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') { return '' }
    $sig.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
}

function Get-BinaryPath {
    param([string]$PathName)
    if ($PathName -match '^"([^"]+)"') { return $Matches[1] }
    if ($PathName -match '^(.+?\.(exe|sys))(\s|$)') { return $Matches[1] }
    $PathName
}

# Elytra's setup as it is now. Files whose hash is in $Previous keep their
# recorded signer, so only new or changed files are checked for signatures.
function Get-ElytraFootprint {
    param($Service, $Previous)
    $bin = Get-BinaryPath $Service.PathName
    $dir = Split-Path $bin
    $prefix = $dir.TrimEnd('\') + '\'
    $inWindows = $prefix.StartsWith($env:SystemRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $prefix.Length -le 3

    $sd = & sc.exe sdshow $Service.Name
    $dacl = if ($LASTEXITCODE -eq 0) { (@($sd) | Where-Object { "$_".Trim() }) -join '' } else { '' }
    $recovery = ''
    $depends = ''
    $reg = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($Service.Name)" -ErrorAction SilentlyContinue
    if (Get-Field $reg 'FailureActions') { $recovery = [Convert]::ToBase64String($reg.FailureActions) }
    if (Get-Field $reg 'DependOnService') { $depends = @($reg.DependOnService) -join ',' }

    # Program files only. Content\ holds data packages that change all the time.
    $known = @{}
    foreach ($f in Get-List $Previous 'files') { $known[$f.sha256] = $f.signer }
    $files = @()
    if (-not $inWindows -and (Test-Path $dir)) {
        $files = @(Get-ChildItem $dir -Recurse -File -Include *.exe, *.dll, *.sys -ErrorAction SilentlyContinue |
            Where-Object { -not $_.FullName.StartsWith("$($prefix)Content\", [StringComparison]::OrdinalIgnoreCase) } |
            Sort-Object FullName | ForEach-Object {
                $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
                $signer = if ($known.ContainsKey($hash)) { $known[$hash] } else { Get-Signer $_.FullName }
                [pscustomobject]@{ path = $_.FullName.Substring($prefix.Length); sha256 = $hash; signer = $signer }
            })
    }

    # Other services, drivers and scheduled tasks that belong to Elytra, going
    # by name or by where their program lives.
    $isElytra = {
        param([string]$Name, [string]$Path)
        ("$Name $Path" -match 'elytra|vaiiya' -and $Name -ne 'ElytraGuard') -or
        (-not $inWindows -and $Path -and $Path.IndexOf($prefix, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    $related = @()
    foreach ($s in Get-CimInstance Win32_Service) {
        if ($s.Name -ne $Service.Name -and (& $isElytra "$($s.Name) $($s.DisplayName)" $s.PathName)) { $related += "service:$($s.Name)" }
    }
    foreach ($d in Get-CimInstance Win32_SystemDriver) {
        if (& $isElytra "$($d.Name) $($d.DisplayName)" $d.PathName) { $related += "driver:$($d.Name)" }
    }
    foreach ($t in Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $exec = @($t.Actions | ForEach-Object { Get-Field $_ 'Execute' }) -join ' '
        if (& $isElytra $t.TaskName $exec) { $related += "task:$($t.TaskPath)$($t.TaskName)" }
    }

    [pscustomobject]@{
        service        = [pscustomobject]@{
            name = $Service.Name; path = $bin; start_mode = $Service.StartMode; account = $Service.StartName
            type = $Service.ServiceType; dacl = $dacl; recovery = $recovery; depends = $depends
        }
        dir            = $dir
        dir_in_windows = $inWindows
        files          = $files
        related        = @($related | Sort-Object)
    }
}

# What differs between two footprints. 'warn' for anything that changes what
# Elytra can do or who signed it; 'info' for an ordinary update.
function Compare-ElytraFootprint {
    param($Old, $New)
    $changes = @()
    $labels = [ordered]@{
        name = 'service name'; path = 'service program'; start_mode = 'start type'; account = 'service account'
        type = 'service type'; depends = 'service dependencies'; dacl = 'service permissions'; recovery = 'service recovery actions'
    }
    $oldSvc = Get-Field $Old 'service'
    $newSvc = Get-Field $New 'service'
    foreach ($field in $labels.Keys) {
        $a = "$(Get-Field $oldSvc $field)"
        $b = "$(Get-Field $newSvc $field)"
        if ($a -eq $b) { continue }
        # Permissions and recovery actions are long encoded strings; say that they changed, not how.
        $text = if ($field -in 'dacl', 'recovery') { "$($labels[$field]) changed" } else { "$($labels[$field]) '$a' -> '$b'" }
        $changes += @{ severity = 'warn'; text = $text }
    }
    if ((Get-Field $New 'dir_in_windows') -and -not (Get-Field $Old 'dir_in_windows')) {
        $changes += @{ severity = 'warn'; text = "service program moved into the Windows folder" }
    }

    $signers = @{}
    $oldFiles = @{}
    foreach ($f in Get-List $Old 'files') {
        $oldFiles[$f.path] = $f
        if ($f.signer) { $signers[$f.signer] = $true }
    }
    $newPaths = @{}
    foreach ($f in Get-List $New 'files') {
        $newPaths[$f.path] = $true
        $o = $oldFiles[$f.path]
        if ($o -and $o.sha256 -eq $f.sha256) { continue }
        $what = if ($o) { 'changed' } else { 'added' }
        $changes += if ($f.path -like '*.sys') { @{ severity = 'warn'; text = "driver file $($f.path) $what" } }
        elseif (-not $f.signer) { @{ severity = 'warn'; text = "$($f.path) $what, not signed" } }
        elseif (-not $signers.ContainsKey($f.signer)) { @{ severity = 'warn'; text = "$($f.path) $what, signed by '$($f.signer)'" } }
        else { @{ severity = 'info'; text = "$($f.path) $what ($("$($f.sha256)" -replace '^(.{8}).+', '$1'))" } }
    }
    foreach ($p in $oldFiles.Keys) {
        if (-not $newPaths.ContainsKey($p)) { $changes += @{ severity = 'info'; text = "$p removed" } }
    }

    $oldRelated = Get-List $Old 'related'
    $newRelated = Get-List $New 'related'
    foreach ($r in $newRelated) { if ($r -notin $oldRelated) { $changes += @{ severity = 'warn'; text = "new $r" } } }
    foreach ($r in $oldRelated) { if ($r -notin $newRelated) { $changes += @{ severity = 'info'; text = "$r removed" } } }
    $changes
}

function Save-Baseline {
    param($Footprint)
    New-Item -ItemType Directory -Path (Split-Path $BaselinePath) -Force | Out-Null
    $tmp = "$BaselinePath.tmp"
    $Footprint | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item $tmp $BaselinePath -Force
}

# Compares Elytra's setup with the baseline and notes the outcome in $Entry.
# Ordinary updates move the baseline along; anything else is logged as a
# warning on every run until an admin accepts it with -AcceptElytraChanges.
function Update-Footprint {
    param([hashtable]$Entry, $Service)
    $old = $null
    if (Test-Path $BaselinePath) {
        # Accepting replaces the baseline, so a damaged one mustn't block it.
        try { $old = Get-Content $BaselinePath -Raw | ConvertFrom-Json }
        catch { if (-not $AcceptElytraChanges) { throw } }
    }
    if (-not $Service) {
        $dir = Get-Field $old 'dir'
        if ($AcceptElytraChanges -and (Test-Path $BaselinePath)) {
            # Elytra is gone; accepting that means forgetting its old setup.
            Remove-Item $BaselinePath -Force
            $Entry.footprint = 'accepted'
        }
        elseif ($dir -and (Test-Path $dir)) {
            $Entry.footprint = 'changed'
            $Entry.level = 'warn'
            Add-Message $Entry 'Elytra changed: its service is gone but its folder is still there'
        }
        return
    }

    $new = Get-ElytraFootprint $Service $old
    if (-not $old -or $AcceptElytraChanges) {
        Save-Baseline $new
        $Entry.footprint = if ($old) { 'accepted' } else { 'recorded' }
        return
    }
    $changes = @(Compare-ElytraFootprint $old $new)
    $warn = @($changes | Where-Object { $_.severity -eq 'warn' } | ForEach-Object { $_.text })
    if ($warn) {
        $Entry.footprint = 'changed'
        $Entry.level = 'warn'
        Add-Message $Entry ('Elytra changed: ' + ($warn -join '; '))
    }
    elseif ($changes) {
        Save-Baseline $new
        $Entry.footprint = 'updated'
        Add-Message $Entry ('Elytra updated: ' + (@($changes | ForEach-Object { $_.text }) -join '; '))
    }
    else {
        $Entry.footprint = 'same'
    }
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
    param([hashtable]$Entry, [bool]$GameWasOpen = $false)
    $svc = Get-ElytraService
    # Watching for changes comes second to stopping Elytra, so its failure
    # is a warning and the run carries on.
    try { Update-Footprint $Entry $svc }
    catch {
        $Entry.footprint = 'error'
        $Entry.level = 'warn'
        Add-Message $Entry "Checking Elytra for changes failed: $($_.Exception.Message)"
    }
    if (-not $svc) {
        if ($AcceptElytraChanges) { return 'accepted' }
        return 'no_service'
    }
    $Entry.service = $svc.Name
    $Entry.service_state = $svc.State
    if ($AcceptElytraChanges) {
        Write-Host "Recorded Elytra's current setup as the baseline: $BaselinePath"
        return 'accepted'
    }
    if ($svc.State -ne 'Running') { return 'idle' }

    $gameDir = Get-WardogsDir
    $Entry.game_dir_found = [bool]$gameDir
    if (-not $gameDir) {
        # Still safe thanks to the known process names, but detection is weaker.
        $Entry.level = 'warn'
        Add-Message $Entry 'WARDOGS install folder not found; using known process names only'
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
        return Invoke-Guard $Entry $true
    }

    # CreationDate is readable without admin rights, unlike Process.StartTime.
    $svcProc = $procs | Where-Object { $_.ProcessId -eq $svc.ProcessId } | Select-Object -First 1
    if (-not ($svcProc -and $svcProc.CreationDate)) { return 'grace' }
    $uptime = ((Get-Date) - $svcProc.CreationDate).TotalMinutes
    $Entry.uptime_min = [math]::Round($uptime, 1)
    # Grace covers a game that hasn't shown up yet; not needed once it has.
    if ($uptime -lt $GraceMinutes -and -not $GameWasOpen) { return 'grace' }
    if ($DryRun) { return 'would_stop' }

    # Stop-Service waits forever; a hung stop would hit the task's time limit
    # and leave no log line. Time out here instead, so it is logged as an error.
    Stop-Service -Name $svc.Name -Force -NoWait
    (Get-Service -Name $svc.Name).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    $Entry.service_state = 'Stopped'
    'stopped'
}

# Dot-sourced (by the tests): define the functions, run nothing.
if ($MyInvocation.InvocationName -eq '.') { return }

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
