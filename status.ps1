<#
.SYNOPSIS
    Shows whether ElytraGuard is healthy, in plain words: a verdict, whether
    Elytra is running right now, what the guard did recently, and the
    scheduled task. Exits 1 when something is wrong. Works without admin
    rights, but the task details need an elevated prompt.
#>
[CmdletBinding()]
param(
    [string]$LogPath = (Join-Path $env:ProgramData 'ElytraGuard\elytraguard.log'),
    [string]$ServiceName = 'Elytra.Service'
)

# What a logged result means, for one run or a stretch of identical runs.
function Get-Description($entry) {
    $text = switch ($entry.result) {
        'game_running' { 'WARDOGS open, Elytra left running' }
        'stopped'      { 'WARDOGS closed, Elytra stopped by ElytraGuard' }
        'idle'         { 'Nothing to do, Elytra already stopped' }
        'grace'        { 'Elytra started recently, waiting' }
        'would_stop'   { 'Dry run: would have stopped Elytra' }
        'no_service'   { 'Elytra is not installed' }
        'error'        { "Error: $($entry.message)" }
        default        { "Result '$($entry.result)'" }
    }
    if ($entry.level -eq 'warn' -and $entry.message) { $text += " (warning: $($entry.message))" }
    $text
}

function Format-When([datetime]$t) {
    if ($t.Date -eq (Get-Date).Date) { $t.ToString('HH:mm') } else { $t.ToString('MM-dd HH:mm') }
}

function Format-Count([int]$n, [string]$word) {
    if ($n -eq 1) { "1 $word" } else { "$n ${word}s" }
}

$problems = @()
$lines = @()

try {
    $task = Get-ScheduledTask -TaskName 'ElytraGuard' -ErrorAction Stop
    $info = $task | Get-ScheduledTaskInfo
    $taskNote = "Scheduled task: $($task.State)"
    if ($info.NextRunTime) { $taskNote += ", next run $(Format-When $info.NextRunTime)" }
    # 267009 = running now, 267011 = has not run yet; neither is a failure.
    if ($info.LastTaskResult -notin 0, 267009, 267011) { $taskNote += ", last run exited with code $($info.LastTaskResult)" }
    if ($task.State -eq 'Disabled') { $problems += 'The ElytraGuard task is disabled.' }
}
catch {
    $taskNote = 'Scheduled task details need an admin prompt; that is normal.'
}

if (-not (Test-Path $LogPath)) {
    $problems += "No log at $LogPath. Is ElytraGuard installed?"
}
else {
    $lines = @(Get-Content $LogPath -Tail 200 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } |
        Where-Object { $_ -and $_.time } |
        ForEach-Object { $_ | Add-Member -NotePropertyName when -NotePropertyValue ([datetime]$_.time).ToLocalTime() -PassThru })
    if (-not $lines) { $problems += 'The log is empty; the guard has not run yet.' }
}

$last = if ($lines) { $lines[-1] } else { $null }
$age = if ($last) { ((Get-Date) - $last.when).TotalMinutes } else { $null }

if ($last) {
    if ($age -gt 15) {
        $problems += "The guard has not run for $([math]::Round($age)) minutes. Is the ElytraGuard task disabled or missing?"
    }

    $since = (Get-Date).AddMinutes(-60)
    $recent = @($lines | Where-Object { $_.when -gt $since })
    $warns = @($recent | Where-Object { $_.level -eq 'warn' })
    $errors = @($recent | Where-Object { $_.level -eq 'error' })
    if ($warns -or $errors) {
        $counts = @()
        if ($errors) { $counts += Format-Count $errors.Count 'error' }
        if ($warns) { $counts += Format-Count $warns.Count 'warning' }
        $latest = @($recent | Where-Object { $_.level -in 'warn', 'error' })[-1]
        $problems += "$($counts -join ' and ') in the last hour. Latest: $($latest.message)"
    }

    $lingering = @($lines | Select-Object -Last 4 | Where-Object { $_.service_state -eq 'Running' -and $_.game_running -eq $false })
    if ($lingering.Count -ge 4) { $problems += 'Elytra has kept running without WARDOGS for the last 4 checks.' }
}

# Elytra's state right now; fall back to the last run if the service can't be queried.
$state = $null
try { $state = [string](Get-Service -Name $ServiceName -ErrorAction Stop).Status } catch { }
if (-not $state -and $last) {
    $state = if ($last.result -eq 'no_service') { 'NotInstalled' } else { $last.service_state }
}

if ($problems) {
    Write-Host 'ElytraGuard: NOT OK' -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}
else {
    Write-Host 'ElytraGuard: OK' -ForegroundColor Green
}

switch ($state) {
    'Running' {
        Write-Host '  Elytra anti-cheat is running right now.'
        if ($last.result -eq 'game_running') { Write-Host '  WARDOGS was open at the last check, so it is left alone.' }
        elseif ($last.result -eq 'grace') { Write-Host '  It started recently; the guard stops it if WARDOGS stays closed.' }
        break
    }
    'Stopped' { Write-Host '  Elytra anti-cheat is stopped right now.'; break }
    'NotInstalled' { Write-Host '  Elytra anti-cheat is not installed.'; break }
    { $_ } { Write-Host "  Elytra anti-cheat is '$state' right now." }
}

if ($last) {
    $ago = if ($age -lt 1) { 'just now' }
    elseif ($age -lt 120) { "$([math]::Round($age)) min ago" }
    else { "$([math]::Round($age / 60)) h ago" }
    Write-Host "  Last check $ago (checks run every 5 min)."

    # Collapse runs that logged the same thing into one line.
    $groups = @()
    foreach ($l in $lines) {
        $key = "$($l.result)|$($l.level)|$($l.message)"
        if ($groups -and $groups[-1].key -eq $key) {
            $groups[-1].end = $l.when
            $groups[-1].count++
        }
        else {
            $groups += [pscustomobject]@{ key = $key; start = $l.when; end = $l.when; count = 1; entry = $l }
        }
    }
    $shown = @($groups | Select-Object -Last 5 | ForEach-Object {
        $label = Format-When $_.start
        if ($_.count -gt 1 -and $_.end -ne $_.start) {
            $label = if ($_.end.Date -eq $_.start.Date) { "$label-$($_.end.ToString('HH:mm'))" } else { "$label - $($_.end.ToString('MM-dd HH:mm'))" }
        }
        $text = Get-Description $_.entry
        if ($_.count -gt 1) { $text += " ($($_.count) checks)" }
        $color = switch ($_.entry.level) { 'warn' { 'Yellow' } 'error' { 'Red' } default { $null } }
        [pscustomobject]@{ label = $label; text = $text; color = $color }
    })
    $width = ($shown | ForEach-Object { $_.label.Length } | Measure-Object -Maximum).Maximum

    Write-Host ''
    Write-Host 'What happened:'
    foreach ($s in $shown) {
        $row = "  $($s.label.PadRight($width))  $($s.text)"
        if ($s.color) { Write-Host $row -ForegroundColor $s.color } else { Write-Host $row }
    }
}

Write-Host ''
Write-Host $taskNote -ForegroundColor DarkGray
if ($problems) { exit 1 }
