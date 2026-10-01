<#
.SYNOPSIS
    Renders installer\icon.svg to elytraguard.ico (16-256 px) and the setup
    wizard's small image, using headless Chrome or Edge and Python's Pillow.
    Only needed when the icon changes; the outputs are committed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$browser = @(
    (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw 'Chrome or Edge is needed to render the SVG.' }

$work = Join-Path ([IO.Path]::GetTempPath()) "elytraguard-icon-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$svg = (Resolve-Path (Join-Path $PSScriptRoot 'icon.svg')).Path -replace '\\', '/'
try {
    # Render each size on its own, so the browser rasterises it at that size.
    foreach ($size in 16, 20, 24, 32, 40, 48, 64, 128, 256) {
        $page = Join-Path $work "$size.html"
        Set-Content $page "<html><body style='margin:0;background:transparent'><img src='file:///$svg' width='$size' height='$size'></body></html>"
        & $browser --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 `
            "--window-size=$size,$size" "--screenshot=$work\$size.png" "file:///$($page -replace '\\', '/')" 2>$null | Out-Null
    }
    $py = @"
from PIL import Image
import os
w = r'$work'
out = r'$PSScriptRoot'
sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
imgs = [Image.open(os.path.join(w, f'{s}.png')).convert('RGBA').crop((0, 0, s, s)) for s in sizes]
imgs[-1].save(os.path.join(out, 'elytraguard.ico'), sizes=[(s, s) for s in sizes], append_images=imgs[:-1])
# Wizard corner image: 58 px icon on white, as Inno shows it on a white header.
small = Image.new('RGB', (58, 58), 'white')
icon = imgs[-1].resize((52, 52), Image.LANCZOS)
small.paste(icon, (3, 3), icon)
small.save(os.path.join(out, 'wizard-small.bmp'))
"@
    $py | python -
    if ($LASTEXITCODE -ne 0) { throw 'Pillow failed' }
    Write-Host "Wrote $PSScriptRoot\elytraguard.ico and wizard-small.bmp"
}
finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
