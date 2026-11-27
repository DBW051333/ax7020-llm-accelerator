param([string]$Model,[string]$VivadoBin='D:/Xilinx/Vivado/2017.4/bin')
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$build=Join-Path $root 'build/head2017/para-mac'
$sim=Join-Path $build 'sim-para'
New-Item -ItemType Directory -Force $sim | Out-Null
Push-Location $sim
try {
    $modelArgs=@()
    if($Model) {$modelArgs=@('--model',$Model)}
    python (Join-Path $PSScriptRoot 'fixture.py') 1 @modelArgs
    if($LASTEXITCODE) {throw 'Fixture generation failed'}
    $stream=Get-Content stream.hex
    Set-Content -Encoding ascii stream.hex (@('00003143414d3451') + $stream)
    Copy-Item (Join-Path $build 'rtl/sigmoid.hex') .
    $text=Get-Content -Raw (Join-Path $PSScriptRoot 'tb.sv')
    $text=$text.Replace('INPUTS=19*32*COLUMNS+2*19*17','INPUTS=1+19*32*COLUMNS+2*19*17')
    $text=$text.Replace('decode_lane #(.COLUMNS(COLUMNS)) dut','decode_lane dut')
    $text=$text.Replace('sent==INPUTS-1, input_ready','(sent==INPUTS-1 || sent==19*32), input_ready')
    Set-Content -Encoding ascii tb.sv $text
    $rtl=Get-ChildItem (Join-Path $build 'rtl') -File | Where-Object Extension -in '.v','.sv'
    & "$VivadoBin/xvlog.bat" -sv @($rtl.FullName) tb.sv
    if($LASTEXITCODE) {throw 'Combined xvlog failed'}
    & "$VivadoBin/xelab.bat" work.tb_one -s para_mux
    if($LASTEXITCODE) {throw 'Combined xelab failed'}
    & "$VivadoBin/xsim.bat" para_mux -runall
    if($LASTEXITCODE -or !(Select-String -Quiet 'Q4-MAC-PASS' xsim.log)) {throw 'Para-MAC mux simulation failed'}
} finally {Pop-Location}
