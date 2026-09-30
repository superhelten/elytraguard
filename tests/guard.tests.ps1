<#
.SYNOPSIS
    Runs elytraguard.ps1 in dry-run mode against real services and checks
    what it logs, under both Windows PowerShell 5.1 and PowerShell 7 when
    present. No admin rights needed. Every run uses -DryRun, so no service is
    ever stopped; nothing outside a temp folder is written.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$guard = Join-Path $PSScriptRoot '..\elytraguard.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) "elytraguard-guard-tests-$PID"
New-Item -ItemType Directory -Force $work | Out-Null

# A stand-in for the game: ping.exe under a known WARDOGS process name. It
# runs for about one second per ping.
$fakeGame = Join-Path $work 'WardogsLauncher-Shipping.exe'
Copy-Item (Join-Path $env:SystemRoot 'System32\PING.EXE') $fakeGame
$marker = Join-Path $work 'second-game-exited.txt'

# EventLog always runs and has been up for longer than a minute.
$running = 'EventLog'
$stopped = (Get-Service | Where-Object { $_.Status -eq 'Stopped' } | Select-Object -First 1).Name
$closed = @('-ServiceName', $running, '-GraceMinutes', 1)
$quick = $closed + @('-SettleSeconds', 1)

$cases = @(
    @{ name = 'service stopped';  args = @('-ServiceName', $stopped); want = 'idle' }
    @{ name = 'started recently'; args = @('-ServiceName', $running, '-GraceMinutes', 100000); want = 'grace' }
    @{ name = 'game closed';      args = $closed; want = 'would_stop' }
    @{
        name = 'waits for the game to close'
        args = $quick; game = 5
        first = 'game_running'; want = 'would_stop'
    }
    @{
        name = 'logs while the game stays open'
        args = $quick + @('-HeartbeatMinutes', 0.05); game = 12
        first = 'game_running'; want = 'would_stop'; beats = 3
    }
    @{
        # The launcher closes and the client starts a few seconds later.
        name = 'follows the game into a new process'
        args = $closed + @('-SettleSeconds', 5); game = 6; next = @{ after = 7; pings = 5 }
        first = 'game_running'; want = 'would_stop'
    }
)
# With no service of that name the guard looks for one in an Elytra folder,
# so this case only holds on a machine without Elytra.
if (-not (Get-CimInstance Win32_Service | Where-Object { $_.PathName -match '\\Elytra\\' })) {
    $cases += @{ name = 'no service'; args = @('-ServiceName', 'ElytraGuardTestNoSuchService'); want = 'no_service' }
}

$hosts = @('powershell.exe', 'pwsh.exe') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue }
$failed = 0
foreach ($exe in $hosts) {
    foreach ($case in $cases) {
        $log = Join-Path $work 'elytraguard.log'
        Remove-Item $log, $marker -ErrorAction SilentlyContinue
        $started = @()
        if ($case.game) {
            $started += Start-Process $fakeGame -ArgumentList '-n', $case.game, '127.0.0.1' -WindowStyle Hidden -PassThru
        }
        if ($case.next) {
            $cmd = "Start-Sleep -Seconds $($case.next.after); & '$fakeGame' -n $($case.next.pings) 127.0.0.1 | Out-Null; " +
                "(Get-Date).ToUniversalTime().ToString('o') | Set-Content '$marker'"
            $started += Start-Process powershell.exe -ArgumentList '-NoProfile', '-Command', $cmd -WindowStyle Hidden -PassThru
        }
        try {
            $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $guard -DryRun -LogPath $log @($case.args) 2>&1 | Out-String
            $code = $LASTEXITCODE
        }
        finally {
            foreach ($p in $started) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
            Get-Process -Name 'WardogsLauncher-Shipping' -ErrorAction SilentlyContinue | Stop-Process -Force
        }

        $lines = @()
        if (Test-Path $log) { $lines = @(Get-Content $log | ConvertFrom-Json) }

        $why = @()
        if ($code -ne 0) { $why += "exit $code" }
        if (-not $lines) { $why += 'no log line' }
        else {
            $last = $lines[-1]
            if ($last.result -ne $case.want) { $why += "last result '$($last.result)', expected '$($case.want)'" }
            if ($last.result -in 'grace', 'would_stop' -and $null -eq $last.uptime_min) { $why += 'no uptime_min' }
            if ($case.first -and $lines[0].result -ne $case.first) { $why += "first result '$($lines[0].result)', expected '$($case.first)'" }
            if ($case.first -and $last.game_running -ne $false) { $why += 'last line does not say the game is closed' }
            $beats = @($lines | Where-Object { $_.result -eq 'game_running' }).Count
            if ($case.beats -and $beats -lt $case.beats) { $why += "$beats game_running lines, expected at least $($case.beats)" }
            if ($case.next) {
                if (-not (Test-Path $marker)) { $why += 'second game process did not finish' }
                # PowerShell 7 parses the time as UTC, a cast from a string gives local time.
                elseif (([datetime]$last.time).ToUniversalTime() -le ([datetime](Get-Content $marker)).ToUniversalTime()) {
                    $why += 'acted before the second game process exited'
                }
            }
        }

        if ($why) {
            $failed++
            Write-Host "FAIL [$exe] $($case.name)" -ForegroundColor Red
            $why | ForEach-Object { Write-Host "     $_" }
            if (Test-Path $log) { Get-Content $log | ForEach-Object { Write-Host "     | $_" } }
            if ($out.Trim()) { Write-Host ($out -replace '(?m)^', '     | ') }
        }
        else {
            Write-Host "pass [$exe] $($case.name)" -ForegroundColor Green
        }
    }
}

Remove-Item $work -Recurse -Force
if ($failed) { Write-Host "$failed failed"; exit 1 }
Write-Host 'all passed'
