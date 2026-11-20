param([string]$VivadoBin='D:/Xilinx/Vivado/2017.4/bin', [switch]$Combined)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$prepare=if ($Combined) { 'prepare_decode.py' } else { 'prepare.py' }
python (Join-Path $PSScriptRoot $prepare)
if ($LASTEXITCODE) { throw 'prepare failed' }
$out=Join-Path $repo 'build/head2017'
if ($Combined) { $out=Join-Path $out 'decode' }
$sim=Join-Path $out 'sim'
New-Item -ItemType Directory -Force $sim | Out-Null
$vectors=if ($Combined) { 'sim_decode.py' } else { 'sim_vectors.py' }
python (Join-Path $PSScriptRoot $vectors) $sim
if ($LASTEXITCODE) { throw 'vector generation failed' }
$tb=Join-Path $PSScriptRoot 'tb.sv'
if ($Combined) {
    $tb=Join-Path $sim 'tb.sv'
    Copy-Item (Join-Path $out 'rtl/sigmoid.hex') $sim
}
Push-Location $sim
try {
    $sources=Get-ChildItem (Join-Path $out 'rtl') -File | Where-Object Extension -In '.v','.sv' | ForEach-Object FullName
    & (Join-Path $VivadoBin 'xvlog.bat') -sv @sources $tb
    if ($LASTEXITCODE) { throw 'xvlog failed' }
    & (Join-Path $VivadoBin 'xelab.bat') tb_head -s head_sim -debug off -timescale 1ns/1ps
    if ($LASTEXITCODE) { throw 'xelab failed' }
    & (Join-Path $VivadoBin 'xsim.bat') head_sim -runall 2>&1 | Tee-Object simulation.txt
    if ($LASTEXITCODE -or !(Select-String -Quiet 'HEAD-SIM-PASS' simulation.txt)) { throw 'Head simulation failed' }
} finally { Pop-Location }
