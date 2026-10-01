<#
.SYNOPSIS
    Installs ElytraGuard: copies the guard to Program Files and registers a
    SYSTEM scheduled task that runs it at startup and every 5 minutes.

.PARAMETER IntervalMinutes
    How often the guard runs.

.PARAMETER GraceMinutes
    Passed to the guard: minimum Elytra uptime before it may be stopped.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 60)][int]$IntervalMinutes = 5,
    [ValidateRange(1, 120)][int]$GraceMinutes = 10
)

$ErrorActionPreference = 'Stop'

# Without admin rights, ask for them (the Windows UAC prompt) and run again
# in a new window that stays open until the result has been read.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = foreach ($p in $PSBoundParameters.GetEnumerator()) {
        if ($p.Value -is [switch]) { if ($p.Value) { "-$($p.Key)" } } else { "-$($p.Key) $($p.Value)" }
    }
    $self = $PSCommandPath -replace "'", "''"
    $command = "`$failed = `$false; try { & '$self' $($argList -join ' ') } catch { Write-Host `$_ -ForegroundColor Red; `$failed = `$true }; " +
        "Read-Host 'Press Enter to close'; if (`$failed) { exit 1 }"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Write-Host 'This needs administrator rights. Accept the Windows prompt to continue in a new window.'
    try {
        $proc = Start-Process powershell.exe -Verb RunAs -Wait -PassThru `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
    } catch {
        Write-Host 'Cancelled: no administrator rights were given, so nothing was changed.' -ForegroundColor Yellow
        exit 1
    }
    exit $proc.ExitCode
}

$TaskName = 'ElytraGuard'
$BinDir = Join-Path $env:ProgramFiles 'ElytraGuard'
$LogDir = Join-Path $env:ProgramData 'ElytraGuard'

# The task runs as SYSTEM, so the script must not be writable by normal users.
# Program Files already grants Users read/execute only.
New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
foreach ($f in 'elytraguard.ps1', 'status.ps1') { Copy-Item (Join-Path $PSScriptRoot $f) $BinDir -Force }

# Log folder: SYSTEM and Administrators write, Users read (so a log shipper
# running as the user can read it).
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$inherit = 'ContainerInherit, ObjectInherit'
foreach ($rule in @(
        @('*S-1-5-18', 'FullControl'),       # SYSTEM
        @('*S-1-5-32-544', 'FullControl'),   # Administrators
        @('*S-1-5-32-545', 'ReadAndExecute') # Users
    )) {
    $sid = New-Object System.Security.Principal.SecurityIdentifier($rule[0].TrimStart('*'))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $rule[1], $inherit, 'None', 'Allow')))
}
Set-Acl -Path $LogDir -AclObject $acl

$script = Join-Path $BinDir 'elytraguard.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -GraceMinutes $GraceMinutes"
$triggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes))
)
# A run that finds the game open lasts until the game closes. The one-day
# limit only ends a run that has hung; the next trigger starts a fresh one.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Days 1) -MultipleInstances IgnoreNew -Priority 7
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal `
    -Description 'Stops the Elytra anti-cheat service (WARDOGS) when the game is not running. https://github.com/superhelten/elytraguard' -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 5
$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host "ElytraGuard installed. First run result: $($info.LastTaskResult) (0 = OK)"
Write-Host "Log: $(Join-Path $LogDir 'elytraguard.log')"
Write-Host "Check health any time: & `"$BinDir\status.ps1`""
if (Test-Path (Join-Path $LogDir 'elytraguard.log')) { Get-Content (Join-Path $LogDir 'elytraguard.log') -Tail 1 }
