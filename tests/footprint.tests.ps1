<#
.SYNOPSIS
    Checks how elytraguard.ps1 compares Elytra's setup with its baseline,
    and that it inventories a folder, under both Windows PowerShell 5.1 and
    PowerShell 7 when present. No admin rights needed; nothing outside a
    temp folder is written.
#>
[CmdletBinding()]
param([switch]$Inner)

if (-not $Inner) {
    $failed = 0
    foreach ($exe in @('powershell.exe', 'pwsh.exe') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue }) {
        & $exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Inner
        if ($LASTEXITCODE) { $failed++ }
    }
    if ($failed) { exit 1 }
    Write-Host 'all passed'
    return
}

. (Join-Path $PSScriptRoot '..\elytraguard.ps1')
$exe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }

# A file record; $thumb '' means not signed.
function File($path, $hash, $thumb = 'T1', $signer = 'Vaiiya Corporate Limited') {
    if (-not $thumb) { $signer = '' }
    [pscustomobject]@{ path = $path; sha256 = $hash; signer = $signer; thumbprint = $thumb; chain = $(if ($thumb) { "$thumb>ROOT" } else { '' }) }
}
function Footprint([hashtable]$service = @{}, $files = $null, $related = @(), [bool]$inWindows = $false) {
    $svc = @{
        name = 'Elytra.Service'; path = 'C:\Program Files\Elytra\service.exe'; start_mode = 'Manual'
        account = 'LocalSystem'; type = 'Own Process'; dacl = 'D:(A;;RPWP;;;AU)'; recovery = ''; depends = ''
    }
    foreach ($k in $service.Keys) { $svc[$k] = $service[$k] }
    if ($null -eq $files) { $files = @((File 'control.exe' 'AAAA1111'), (File 'service.exe' 'BBBB2222')) }
    [pscustomobject]@{
        service = [pscustomobject]$svc; dir = 'C:\Program Files\Elytra'; dir_in_windows = $inWindows
        files = @($files); related = @($related)
    }
}

$base = Footprint
$cases = @(
    @{ name = 'nothing changed'; new = (Footprint); want = @() }
    @{
        name = 'an update signed by the same company'
        new  = (Footprint -files @((File 'control.exe' 'AAAA1111'), (File 'service.exe' 'CCCC3333')))
        want = @('info:service.exe changed (CCCC3333)')
    }
    @{
        name = 'a changed file that is not signed'
        new  = (Footprint -files @((File 'control.exe' 'AAAA1111'), (File 'service.exe' 'CCCC3333' '')))
        want = @('warn:service.exe changed, not signed')
    }
    @{
        name = 'a new file signed by someone else'
        new  = (Footprint -files @((File 'control.exe' 'AAAA1111'), (File 'service.exe' 'BBBB2222'), (File 'x.dll' 'DDDD4444' 'T9' 'Someone Else')))
        want = @("warn:x.dll added, signed with a new certificate: 'Someone Else' T9")
    }
    @{
        # Same company name on another certificate: not trusted on the name alone.
        name = 'the same company name on another certificate'
        new  = (Footprint -files @((File 'control.exe' 'AAAA1111'), (File 'service.exe' 'CCCC3333' 'T2')))
        want = @("warn:service.exe changed, signed with a new certificate: 'Vaiiya Corporate Limited' T2")
    }
    @{
        name = 'a driver file, even from the same company'
        new  = (Footprint -files @((File 'control.exe' 'AAAA1111'), (File 'service.exe' 'BBBB2222'), (File 'drv\elytra.sys' 'EEEE5555')))
        want = @('warn:driver file drv\elytra.sys added')
    }
    @{
        name = 'a file removed'
        new  = (Footprint -files @((File 'service.exe' 'BBBB2222')))
        want = @('info:control.exe removed')
    }
    @{
        name = 'starts with Windows'
        new  = (Footprint -service @{ start_mode = 'Auto' })
        want = @("warn:start type 'Manual' -> 'Auto'")
    }
    @{
        name = 'runs as another account'
        new  = (Footprint -service @{ account = '.\ElytraUser' })
        want = @("warn:service account 'LocalSystem' -> '.\ElytraUser'")
    }
    @{
        name = 'permissions and recovery actions'
        new  = (Footprint -service @{ dacl = 'D:(A;;RP;;;SY)'; recovery = 'AAAA' })
        want = @('warn:service permissions changed', 'warn:service recovery actions changed')
    }
    @{
        name = 'a new scheduled task and a removed driver'
        old  = (Footprint -related @('driver:elytrakm'))
        new  = (Footprint -related @('task:\Elytra\Update'))
        want = @('warn:new task:\Elytra\Update', 'info:driver:elytrakm removed')
    }
    @{
        name = 'moved into the Windows folder'
        new  = (Footprint -inWindows $true -files @())
        want = @('warn:service program moved into the Windows folder', 'info:control.exe removed', 'info:service.exe removed')
    }
    @{
        name = 'an older baseline without some fields'
        old  = [pscustomobject]@{ service = [pscustomobject]@{ name = 'Elytra.Service' }; dir = 'C:\Program Files\Elytra' }
        new  = (Footprint -files @())
        want = @("warn:service program '' -> 'C:\Program Files\Elytra\service.exe'", "warn:start type '' -> 'Manual'",
                 "warn:service account '' -> 'LocalSystem'", "warn:service type '' -> 'Own Process'",
                 'warn:service permissions changed')
    }
)

$failed = 0
foreach ($case in $cases) {
    $old = if ($case.ContainsKey('old')) { $case.old } else { $base }
    # Round-trip through JSON, as the guard reads its baseline from a file.
    $old = $old | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $got = @(Compare-ElytraFootprint $old $case.new | ForEach-Object { "$($_.severity):$($_.text)" })
    $missing = @($case.want | Where-Object { $_ -notin $got })
    $extra = @($got | Where-Object { $_ -notin $case.want })
    if ($missing -or $extra) {
        $failed++
        Write-Host "FAIL [$exe] $($case.name)" -ForegroundColor Red
        $missing | ForEach-Object { Write-Host "     missing $_" }
        $extra | ForEach-Object { Write-Host "     unexpected $_" }
    }
    else { Write-Host "pass [$exe] $($case.name)" -ForegroundColor Green }
}

# Inventory of a real folder: program files only, Content\ left out, an
# unsigned file recorded without a signer, and a known hash not re-checked.
$work = Join-Path ([IO.Path]::GetTempPath()) "elytraguard-footprint-tests-$PID"
New-Item -ItemType Directory -Force (Join-Path $work 'Content'), (Join-Path $work 'bin') | Out-Null
Set-Content (Join-Path $work 'service.exe') 'not really a program'
Set-Content (Join-Path $work 'bin\helper.dll') 'not really a library'
Set-Content (Join-Path $work 'Content\data.dll') 'data package'
Set-Content (Join-Path $work 'readme.txt') 'text'
$svc = [pscustomobject]@{
    Name = 'ElytraGuardTestNoSuchService'; PathName = "`"$(Join-Path $work 'service.exe')`" --flag"
    StartMode = 'Manual'; StartName = 'LocalSystem'; ServiceType = 'Own Process'
}
$serviceHash = (Get-FileHash (Join-Path $work 'service.exe') -Algorithm SHA256).Hash
$previous = [pscustomobject]@{ files = @((File 'service.exe' $serviceHash 'REMEMBERED' 'Remembered Signer')) }
$fp = Get-ElytraFootprint $svc $previous
$paths = @($fp.files | ForEach-Object { $_.path })
$why = @()
if (($paths -join ',') -ne 'bin\helper.dll,service.exe') { $why += "files '$($paths -join ',')'" }
$helper = @($fp.files | Where-Object { $_.path -eq 'bin\helper.dll' })[0]
if ($helper.signer -or $helper.thumbprint) { $why += 'unsigned file got a signer' }
if (@($fp.files | Where-Object { $_.path -eq 'service.exe' })[0].thumbprint -ne 'REMEMBERED') { $why += 'known hash was checked again' }
if ($fp.service.path -ne (Join-Path $work 'service.exe')) { $why += "service path '$($fp.service.path)'" }
if ($fp.dir_in_windows) { $why += 'temp folder taken for the Windows folder' }
if ($fp.service.dacl) { $why += 'permissions read for a service that does not exist' }
Remove-Item $work -Recurse -Force
if ($why) {
    $failed++
    Write-Host "FAIL [$exe] inventory of a folder" -ForegroundColor Red
    $why | ForEach-Object { Write-Host "     $_" }
}
else { Write-Host "pass [$exe] inventory of a folder" -ForegroundColor Green }

# A service in the Windows folder: no inventory of System32.
$fp = Get-ElytraFootprint ([pscustomobject]@{
        Name = 'EventLog'; PathName = "$env:SystemRoot\System32\svchost.exe -k LocalServiceNetworkRestricted -p"
        StartMode = 'Auto'; StartName = 'NT AUTHORITY\LocalService'; ServiceType = 'Share Process'
    }) $null
if (-not $fp.dir_in_windows -or @($fp.files).Count) {
    $failed++
    Write-Host "FAIL [$exe] no inventory of the Windows folder" -ForegroundColor Red
}
else { Write-Host "pass [$exe] no inventory of the Windows folder" -ForegroundColor Green }

# Elytra's service gone but its folder left behind: a warning, which
# accepting clears by forgetting the old setup.
$work = Join-Path ([IO.Path]::GetTempPath()) "elytraguard-footprint-gone-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$BaselinePath = Join-Path $work 'elytra-baseline.json'
$StateKey = "HKCU:\Software\ElytraGuardTests\footprint-$PID"
Save-Baseline ([pscustomobject]@{ dir = $work })
$why = @()
$e = @{ level = 'info' }
Update-Footprint $e $null
if ($e.level -ne 'warn' -or "$($e['message'])" -notlike '*service is gone*') { $why += "no warning: level '$($e.level)'" }
$AcceptElytraChanges = $true
$e = @{ level = 'info' }
Update-Footprint $e $null
$AcceptElytraChanges = $false
if ($e['footprint'] -ne 'accepted' -or $e.level -ne 'info') { $why += "accept gave footprint '$($e['footprint'])', level '$($e.level)'" }
if (Test-Path $BaselinePath) { $why += 'baseline still there after accepting' }
$e = @{ level = 'info' }
Update-Footprint $e $null
if ($e.level -ne 'info') { $why += 'still warns after accepting' }
Remove-Item $work -Recurse -Force
Remove-Item $StateKey -Recurse -ErrorAction SilentlyContinue
if ($why) {
    $failed++
    Write-Host "FAIL [$exe] Elytra gone, folder left behind" -ForegroundColor Red
    $why | ForEach-Object { Write-Host "     $_" }
}
else { Write-Host "pass [$exe] Elytra gone, folder left behind" -ForegroundColor Green }

# Only a valid signature counts: a certificate Windows doesn't trust, or a
# signed file changed afterwards, reads as not signed.
$work = Join-Path ([IO.Path]::GetTempPath()) "elytraguard-signer-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Vaiiya Corporate Limited' -CertStoreLocation Cert:\CurrentUser\My
$why = @()
try {
    $script = Join-Path $work 'signed.ps1'
    Set-Content $script "'hello'"
    Set-AuthenticodeSignature $script $cert | Out-Null
    $s = Get-Signer $script
    if ($s.signer -or $s.thumbprint) { $why += "untrusted certificate accepted as '$($s.signer)'" }
    Add-Content $script "'changed'"
    $s = Get-Signer $script
    if ($s.signer -or $s.thumbprint) { $why += 'tampered file accepted' }
}
finally {
    Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -ErrorAction SilentlyContinue
    Remove-Item $work -Recurse -Force
}
# A validly signed program, if this machine has one to hand.
$signed = @("$PSHOME\pwsh.exe", "$env:ProgramFiles\PowerShell\7\pwsh.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($signed) {
    $s = Get-Signer $signed
    if (-not $s.signer -or $s.thumbprint -notmatch '^[0-9A-F]{40}$' -or $s.chain -notlike "$($s.thumbprint)>*") {
        $why += "valid signature read as '$($s.signer)' / '$($s.thumbprint)' / '$($s.chain)'"
    }
}
if ($why) {
    $failed++
    Write-Host "FAIL [$exe] only valid signatures count" -ForegroundColor Red
    $why | ForEach-Object { Write-Host "     $_" }
}
else { Write-Host "pass [$exe] only valid signatures count" -ForegroundColor Green }

if ($failed) { exit 1 }
