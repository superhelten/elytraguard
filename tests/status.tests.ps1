<#
.SYNOPSIS
    Runs status.ps1 against generated logs and checks its output and exit
    code, under both Windows PowerShell 5.1 and PowerShell 7 when present.
    No admin rights needed; nothing outside a temp folder is touched.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$status = Join-Path $PSScriptRoot '..\status.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) "elytraguard-tests-$PID"
New-Item -ItemType Directory -Force $work | Out-Null

# Any name that can't exist, so status.ps1 falls back to the log for Elytra's state.
$noService = 'ElytraGuardTestNoSuchService'

function Line([double]$minutesAgo, [string]$result, [hashtable]$extra = @{}) {
    $entry = @{
        time    = (Get-Date).ToUniversalTime().AddMinutes(-$minutesAgo).ToString('o')
        version = 'test'
        level   = 'info'
        service = 'Elytra.Service'
        result  = $result
    }
    foreach ($k in $extra.Keys) { $entry[$k] = $extra[$k] }
    $entry | ConvertTo-Json -Compress
}
$playing = @{ service_state = 'Running'; game_running = $true; game_dir_found = $true }
$waiting = @{ service_state = 'Running'; game_running = $false; game_dir_found = $true; uptime_min = 3 }
$stopped = @{ service_state = 'Stopped'; game_running = $false; game_dir_found = $true; uptime_min = 59.5 }
$idle = @{ service_state = 'Stopped' }

$cases = @(
    @{
        name = 'normal session'
        log  = @((Line 20 game_running $playing), (Line 15 game_running $playing), (Line 10 game_running $playing),
                 (Line 5 stopped $stopped), (Line 0.5 idle $idle))
        exit = 0
        want = @('ElytraGuard: OK', 'Elytra anti-cheat is stopped right now', 'Last check just now',
                 'WARDOGS open, Elytra left running (3 checks)', 'WARDOGS closed, Elytra stopped by ElytraGuard',
                 'Nothing to do, Elytra already stopped', 'Scheduled task',
                 'Version test. New versions: https://github.com/superhelten/elytraguard/releases')
        not  = @('service=', 'game_running', 'NOT OK', "'Stopped'")
    }
    @{
        # The guard logs how long after the game closed it stopped Elytra.
        name = 'stopped after the game closed'
        log  = @((Line 10 game_running $playing), (Line 5 stopped ($stopped + @{ after_game_s = 47 })), (Line 0.5 idle $idle))
        exit = 0
        want = @('WARDOGS closed, Elytra stopped by ElytraGuard 47 s later')
    }
    @{
        name = 'Elytra lingers'
        log  = @((Line 16 grace $waiting), (Line 11 grace $waiting), (Line 6 grace $waiting), (Line 1 grace $waiting))
        exit = 1
        want = @('ElytraGuard: NOT OK', 'Elytra has kept running without WARDOGS for the last 4 checks',
                 'Elytra anti-cheat is running right now', 'Elytra started recently, waiting (4 checks)')
        not  = @("'Running'")
    }
    @{
        name = 'guard stopped running'
        log  = @((Line 35 idle $idle), (Line 30 idle $idle))
        exit = 1
        want = @('ElytraGuard: NOT OK', 'The guard has not run for 30 minutes', 'Last check 30 min ago',
                 'Nothing to do, Elytra already stopped (2 checks)')
    }
    @{
        name = 'warning line'
        log  = @((Line 1 game_running ($playing + @{ level = 'warn'; message = 'WARDOGS install folder not found' })))
        exit = 1
        want = @('ElytraGuard: NOT OK', '1 warning in the last hour', 'WARDOGS install folder not found',
                 'WARDOGS open, Elytra left running')
    }
    @{
        name = 'error line'
        log  = @((Line 1 error @{ level = 'error'; message = 'Access is denied'; service_state = 'Running' }))
        exit = 1
        want = @('ElytraGuard: NOT OK', '1 error in the last hour', 'Error: Access is denied')
    }
    @{
        name = 'Elytra not installed'
        log  = @((Line 1 no_service @{ service = $null }))
        exit = 0
        want = @('ElytraGuard: OK', 'Elytra anti-cheat is not installed', 'Elytra is not installed')
        not  = @("'NotInstalled'")
    }
    @{
        name = 'older runs show their date'
        log  = @((Line 1500 idle $idle), (Line 1495 idle $idle), (Line 2 game_running $playing))
        exit = 0
        want = @((Get-Date).AddMinutes(-1500).ToString('MM-dd'), 'Nothing to do, Elytra already stopped (2 checks)')
    }
    @{
        name = 'a stretch across midnight dates both ends'
        log  = @((Line 1500 idle $idle), (Line 1 idle $idle))
        exit = 0
        want = @(" - $((Get-Date).ToString('MM-dd')) ", 'Nothing to do, Elytra already stopped (2 checks)')
    }
    @{
        name = 'Elytra updated'
        log  = @((Line 11 idle ($idle + @{ footprint = 'recorded' })), (Line 6 idle ($idle + @{ footprint = 'same' })),
                 (Line 1 idle ($idle + @{ footprint = 'updated'; message = 'Elytra updated: service.exe changed (ABCD1234)' })))
        exit = 0
        want = @('ElytraGuard: OK', "Nothing to do, Elytra already stopped (recorded Elytra's setup)",
                 'Nothing to do, Elytra already stopped' + [Environment]::NewLine,
                 'Nothing to do, Elytra already stopped (Elytra updated: service.exe changed (ABCD1234))')
    }
    @{
        name = 'Elytra changed'
        log  = @((Line 1 idle ($idle + @{ footprint = 'changed'; level = 'warn'; message = "Elytra changed: start type 'Manual' -> 'Auto'" })))
        exit = 1
        want = @('ElytraGuard: NOT OK', "1 warning in the last hour. Latest: Elytra changed: start type 'Manual' -> 'Auto'")
    }
    @{
        name = 'changes accepted'
        log  = @((Line 1 accepted ($idle + @{ footprint = 'accepted' })))
        exit = 0
        want = @('ElytraGuard: OK', "An admin accepted Elytra's current setup")
    }
    @{
        name = 'empty log'
        log  = @()
        exit = 1
        want = @('ElytraGuard: NOT OK', 'The log is empty')
        not  = @('Exception', 'null')
    }
    @{
        name = 'missing log'
        log  = $null
        exit = 1
        want = @('ElytraGuard: NOT OK', 'No log at')
    }
    @{
        name = 'live service state wins over the log'
        log  = @((Line 1 idle $idle))
        service = 'EventLog'
        exit = 0
        want = @('Elytra anti-cheat is running right now')
    }
)

$hosts = @('powershell.exe', 'pwsh.exe') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue }
$failed = 0
foreach ($exe in $hosts) {
    foreach ($case in $cases) {
        $log = Join-Path $work 'elytraguard.log'
        Remove-Item $log -ErrorAction SilentlyContinue
        if ($null -ne $case.log) { Set-Content -Path $log -Value $case.log -Encoding UTF8 }
        $svc = if ($case.service) { $case.service } else { $noService }

        $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $status -LogPath $log -ServiceName $svc 2>&1 | Out-String
        $code = $LASTEXITCODE

        $why = @()
        if ($code -ne $case.exit) { $why += "exit $code, expected $($case.exit)" }
        foreach ($w in $case.want) { if (-not $out.Contains($w)) { $why += "missing '$w'" } }
        foreach ($n in @($case.not)) { if ($n -and $out.Contains($n)) { $why += "unexpected '$n'" } }

        if ($why) {
            $failed++
            Write-Host "FAIL [$exe] $($case.name)" -ForegroundColor Red
            $why | ForEach-Object { Write-Host "     $_" }
            Write-Host ($out -replace '(?m)^', '     | ')
        }
        else {
            Write-Host "pass [$exe] $($case.name)" -ForegroundColor Green
        }
    }
}

Remove-Item $work -Recurse -Force
if ($failed) { Write-Host "$failed failed"; exit 1 }
Write-Host 'all passed'
