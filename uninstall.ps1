<#
.SYNOPSIS
    Removes ElytraGuard: the scheduled task and the Program Files folder.
    Elytra itself is not touched. Logs are kept unless -RemoveLogs is given.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$RemoveLogs)

$ErrorActionPreference = 'Stop'
Unregister-ScheduledTask -TaskName 'ElytraGuard' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:ProgramFiles 'ElytraGuard') -Recurse -Force -ErrorAction SilentlyContinue
if ($RemoveLogs) {
    Remove-Item (Join-Path $env:ProgramData 'ElytraGuard') -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'ElytraGuard removed.'
