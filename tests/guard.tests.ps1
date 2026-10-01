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
if (Get-Process -Name 'WardogsLauncher-Shipping', 'WardogsClient-Win64-Shipping' -ErrorAction SilentlyContinue) {
    throw 'Close WARDOGS first: the guard would wait for it to close.'
}
New-Item -ItemType Directory -Force $work | Out-Null

# A stand-in for the game: ping.exe under a known WARDOGS process name. It
# runs for about one second per ping.
$fakeGame = Join-Path $work 'WardogsLauncher-Shipping.exe'
Copy-Item (Join-Path $env:SystemRoot 'System32\PING.EXE') $fakeGame
$marker = Join-Path $work 'second-game-exited.txt'
$baseline = Join-Path $work 'elytra-baseline.json'
# The baseline's seal goes to HKCU here, since HKLM needs admin rights.
$stateKey = "HKCU:\Software\ElytraGuardTests\$PID"
function Set-TestSeal { Set-ItemProperty $stateKey -Name BaselineSha256 -Value (Get-FileHash $baseline -Algorithm SHA256).Hash }

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
        # A short session: the game has come and gone, so no grace is needed.
        name = 'no grace after the game closed'
        args = @('-ServiceName', $running, '-GraceMinutes', 100000, '-SettleSeconds', 1); game = 4
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
    @{
        # Accepting must not wait for an open game; it records and exits.
        name = 'accepting changes records and exits'
        args = $closed + @('-AcceptElytraChanges'); game = 60; maxSeconds = 20
        want = 'accepted'; footprint = 'recorded'
    }
    @{
        # A baseline that can't be saved (here: a folder in its place, as
        # good as a missing admin right) must not be reported as recorded.
        name = 'accepting fails loudly'
        args = $closed + @('-AcceptElytraChanges'); baselineIsDir = $true
        want = 'error'; exit = 1; notInOutput = 'Recorded'; inOutput = 'not recorded'
    }
    @{ name = 'Elytra unchanged';  args = $closed; seed = @{}; want = 'would_stop'; footprint = 'same'; level = 'info' }
    @{
        # A change is a warning, but the guard still does its job.
        name = 'Elytra changed'
        args = $closed; seed = @{ start_mode = 'Disabled' }
        want = 'would_stop'; footprint = 'changed'; level = 'warn'; message = "start type 'Disabled' -> "
    }
    @{
        # Deleting the baseline must not lead to a quiet new one.
        name = 'a deleted baseline is a warning'
        args = $closed; seed = @{}; delete = $true
        want = 'would_stop'; footprint = 'unverified'; level = 'warn'; message = 'has been deleted'; noBaselineAfter = $true
    }
    @{
        name = 'a baseline edited outside the guard is a warning'
        args = $closed; seed = @{ start_mode = 'Disabled' }; reseal = $false
        want = 'would_stop'; footprint = 'unverified'; level = 'warn'; message = 'was changed outside ElytraGuard'
    }
    @{
        name = 'a broken baseline does not stop the guard'
        args = $closed; corrupt = $true
        want = 'would_stop'; footprint = 'error'; level = 'warn'; message = 'Checking Elytra for changes failed'
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
        Remove-Item $log, $marker, $baseline -Recurse -ErrorAction SilentlyContinue
        Remove-Item $stateKey -Recurse -ErrorAction SilentlyContinue
        New-Item $stateKey -Force | Out-Null
        if ($case.seed) {
            # Record a baseline, then edit it to stand for Elytra's earlier setup.
            & $exe -NoProfile -ExecutionPolicy Bypass -File $guard -DryRun -LogPath $log -BaselinePath $baseline -StateKey $stateKey @($case.args) -AcceptElytraChanges | Out-Null
            $b = Get-Content $baseline -Raw | ConvertFrom-Json
            foreach ($k in $case.seed.Keys) { $b.service.$k = $case.seed[$k] }
            $b | ConvertTo-Json -Depth 5 | Set-Content $baseline -Encoding UTF8
            # As if the guard had saved it, unless the case is about an outside edit.
            if ($case.reseal -ne $false) { Set-TestSeal }
            if ($case.delete) { Remove-Item $baseline }
            Remove-Item $log
        }
        if ($case.baselineIsDir) { New-Item -ItemType Directory $baseline | Out-Null }
        if ($case.corrupt) { Set-Content $baseline '{ not json'; Set-TestSeal }
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
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $guard -DryRun -LogPath $log -BaselinePath $baseline -StateKey $stateKey @($case.args) 2>&1 | Out-String
            $code = $LASTEXITCODE
            $took = $clock.Elapsed.TotalSeconds
        }
        finally {
            foreach ($p in $started) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
            # The second stand-in, started by the wrapper; never the real game.
            Get-Process -Name 'WardogsLauncher-Shipping' -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -eq $fakeGame } | Stop-Process -Force
        }

        $lines = @()
        if (Test-Path $log) { $lines = @(Get-Content $log | ConvertFrom-Json) }

        $why = @()
        $wantExit = if ($case.ContainsKey('exit')) { $case.exit } else { 0 }
        if ($code -ne $wantExit) { $why += "exit $code, expected $wantExit" }
        if ($case.notInOutput -and $out.Contains($case.notInOutput)) { $why += "output says '$($case.notInOutput)'" }
        if ($case.inOutput -and -not $out.Contains($case.inOutput)) { $why += "output lacks '$($case.inOutput)'" }
        if (-not $lines) { $why += 'no log line' }
        else {
            $last = $lines[-1]
            if ($last.result -ne $case.want) { $why += "last result '$($last.result)', expected '$($case.want)'" }
            if ($last.result -in 'grace', 'would_stop' -and $null -eq $last.uptime_min) { $why += 'no uptime_min' }
            if ($case.first -and $lines[0].result -ne $case.first) { $why += "first result '$($lines[0].result)', expected '$($case.first)'" }
            if ($case.first -and $last.game_running -ne $false) { $why += 'last line does not say the game is closed' }
            foreach ($field in 'footprint', 'level') {
                if ($case.$field -and $last.$field -ne $case.$field) { $why += "$field '$($last.$field)', expected '$($case.$field)'" }
            }
            if ($case.message -and -not "$($last.message)".Contains($case.message)) { $why += "message '$($last.message)'" }
            if ($case.noBaselineAfter -and (Test-Path $baseline)) { $why += 'a new baseline was recorded' }
            if ($case.maxSeconds -and $took -gt $case.maxSeconds) { $why += "took $([int]$took) s" }
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
Remove-Item 'HKCU:\Software\ElytraGuardTests' -Recurse -ErrorAction SilentlyContinue
if ($failed) { Write-Host "$failed failed"; exit 1 }
Write-Host 'all passed'
