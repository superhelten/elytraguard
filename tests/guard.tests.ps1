<#
.SYNOPSIS
    Runs elytraguard.ps1 in dry-run mode against real services and checks
    the result it logs, under both Windows PowerShell 5.1 and PowerShell 7
    when present. No admin rights needed. Every run uses -DryRun, so no
    service is ever stopped; nothing outside a temp folder is written.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$guard = Join-Path $PSScriptRoot '..\elytraguard.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) "elytraguard-guard-tests-$PID"
New-Item -ItemType Directory -Force $work | Out-Null

# A stand-in for the game: ping.exe under a known WARDOGS process name.
$fakeGame = Join-Path $work 'WardogsLauncher-Shipping.exe'
Copy-Item (Join-Path $env:SystemRoot 'System32\PING.EXE') $fakeGame

# EventLog always runs and has been up for longer than a minute.
$running = 'EventLog'
$stopped = (Get-Service | Where-Object { $_.Status -eq 'Stopped' } | Select-Object -First 1).Name

$cases = @(
    @{ name = 'service stopped';        args = @('-ServiceName', $stopped);                         want = 'idle' }
    @{ name = 'started recently';       args = @('-ServiceName', $running, '-GraceMinutes', 100000); want = 'grace' }
    @{ name = 'game closed';            args = @('-ServiceName', $running, '-GraceMinutes', 1);      want = 'would_stop' }
    @{ name = 'game open';              args = @('-ServiceName', $running, '-GraceMinutes', 1);      want = 'game_running'; game = $true }
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
        Remove-Item $log -ErrorAction SilentlyContinue
        $game = $null
        if ($case.game) {
            $game = Start-Process $fakeGame -ArgumentList '-n', '60', '127.0.0.1' -WindowStyle Hidden -PassThru
        }
        try {
            $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $guard -DryRun -LogPath $log @($case.args) 2>&1 | Out-String
            $code = $LASTEXITCODE
        }
        finally {
            if ($game) { Stop-Process -Id $game.Id -Force -ErrorAction SilentlyContinue; $game.WaitForExit() }
        }

        $entry = $null
        if (Test-Path $log) { $entry = Get-Content $log -Tail 1 | ConvertFrom-Json }

        $why = @()
        if ($code -ne 0) { $why += "exit $code" }
        if (-not $entry) { $why += 'no log line' }
        elseif ($entry.result -ne $case.want) { $why += "result '$($entry.result)', expected '$($case.want)'" }
        elseif ($entry.result -in 'grace', 'would_stop' -and $null -eq $entry.uptime_min) { $why += 'no uptime_min' }

        if ($why) {
            $failed++
            Write-Host "FAIL [$exe] $($case.name)" -ForegroundColor Red
            $why | ForEach-Object { Write-Host "     $_" }
            if ($entry) { Write-Host "     | $(Get-Content $log -Tail 1)" }
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
