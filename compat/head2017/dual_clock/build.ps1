param(
    [int]$Axi = 125,
    [int]$Compute = 200,
    [switch]$LegacyScaler,
    [string]$VivadoBin = 'D:/Xilinx/Vivado/2017.4/bin'
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$bin = Join-Path $VivadoBin 'vivado.bat'
$profile = if ($LegacyScaler) { '' } else { '-pipe' }
$variant = if ($LegacyScaler) { @() } else { @('--scale-pipeline') }
$out = Join-Path $repo "build/head2017/dual-clock-$Axi-$Compute$profile"
if (Test-Path (Join-Path $out 'quad/project/head_quad_2017.xpr')) {
    throw "A Vivado project already exists under $out"
}
python (Join-Path $PSScriptRoot 'prepare.py') --axi $Axi --compute $Compute @variant
if ($LASTEXITCODE) { throw 'Source generation failed' }
Push-Location $out
try {
    & $bin -mode batch -source build_quad.tcl -tclargs bd 2>&1 | Tee-Object bd-console.log
    if ($LASTEXITCODE) { throw 'Block design failed' }
    & (Join-Path $PSScriptRoot 'verify.ps1') -Axi $Axi -Compute $Compute -VivadoBin $VivadoBin -ScalePipeline:(!$LegacyScaler)
    & $bin -mode batch -source build_quad.tcl -tclargs impl 2>&1 | Tee-Object impl-console.log
    if ($LASTEXITCODE) { throw 'Implementation failed. Check quad/timing.rpt and quad/cdc.rpt' }
    $receipt = python (Join-Path $PSScriptRoot 'seal.py') quad impl-console.log
    if ($LASTEXITCODE) { throw 'Receipt generation failed' }
    Set-Content -LiteralPath 'quad/accepted.json' -Encoding Ascii -Value $receipt
} finally {
    Pop-Location
}
