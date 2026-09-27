<#
.SYNOPSIS
    Shows whether ElytraGuard is healthy: scheduled task state, last run,
    recent log lines, and a verdict. Works without admin rights, but the task
    details need an elevated prompt.
#>
[CmdletBinding()]
param([string]$LogPath = (Join-Path $env:ProgramData 'ElytraGuard\elytraguard.log'))

$problems = @()

try {
    $task = Get-ScheduledTask -TaskName 'ElytraGuard' -ErrorAction Stop
    $info = $task | Get-ScheduledTaskInfo
    Write-Host "Task:       $($task.State), last run $($info.LastRunTime), result $($info.LastTaskResult), next $($info.NextRunTime)"
    if ($task.State -eq 'Disabled') { $problems += 'the scheduled task is disabled' }
}
catch {
    Write-Host 'Task:       not visible (run from an elevated prompt to see it)'
}

if (-not (Test-Path $LogPath)) {
    $problems += "no log at $LogPath"
}
else {
    $lines = @(Get-Content $LogPath -Tail 200 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
    $last = $lines | Select-Object -Last 1
    $age = ((Get-Date).ToUniversalTime() - ([datetime]$last.time).ToUniversalTime()).TotalMinutes
    Write-Host ("Last run:   {0:N0} min ago, result '{1}'" -f $age, $last.result)
    if ($age -gt 15) { $problems += "no run for $([math]::Round($age)) minutes" }

    $since = (Get-Date).ToUniversalTime().AddMinutes(-60)
    $recent = $lines | Where-Object { ([datetime]$_.time).ToUniversalTime() -gt $since }
    $bad = @($recent | Where-Object { $_.level -in 'warn', 'error' })
    if ($bad) { $problems += "$($bad.Count) warning/error line(s) in the last hour: $($bad[-1].message)" }
    $lingering = @($lines | Select-Object -Last 4 | Where-Object { $_.service_state -eq 'Running' -and $_.game_running -eq $false })
    if ($lingering.Count -ge 4) { $problems += 'Elytra has been running without the game for the last 4 runs' }

    Write-Host ''
    Write-Host 'Recent runs:'
    $lines | Select-Object -Last 5 | ForEach-Object {
        Write-Host ("  {0}  {1,-13} service={2} game_running={3}" -f ([datetime]$_.time).ToLocalTime().ToString('yyyy-MM-dd HH:mm'), $_.result, $_.service_state, $_.game_running)
    }
}

Write-Host ''
if ($problems) {
    Write-Host 'NOT OK:' -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'OK' -ForegroundColor Green
