<#
.SYNOPSIS
    Removes ElytraGuard: the scheduled task and the Program Files folder.
    Elytra itself is not touched. Logs and the record of Elytra's setup are
    kept unless -RemoveLogs is given.
#>
[CmdletBinding()]
param([switch]$RemoveLogs)

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

Unregister-ScheduledTask -TaskName 'ElytraGuard' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:ProgramFiles 'ElytraGuard') -Recurse -Force -ErrorAction SilentlyContinue
if ($RemoveLogs) {
    Remove-Item (Join-Path $env:ProgramData 'ElytraGuard') -Recurse -Force -ErrorAction SilentlyContinue
    # The baseline's seal; without the baseline it would read as deleted.
    Remove-Item 'HKLM:\SOFTWARE\ElytraGuard' -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'ElytraGuard removed.'
