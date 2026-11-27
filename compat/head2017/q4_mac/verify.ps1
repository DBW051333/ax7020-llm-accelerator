param([string]$VivadoBin='D:/Xilinx/Vivado/2017.4/bin',[string]$Model)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
foreach ($columns in 1,2) {
    $out=Join-Path $root "build/q4-mac-sim-$columns"
    New-Item -ItemType Directory -Force $out | Out-Null
    Push-Location $out
    try {
        $modelArgs=@()
        if ($Model) { $modelArgs=@('--model',$Model) }
        python (Join-Path $PSScriptRoot 'fixture.py') $columns @modelArgs
        if ($LASTEXITCODE) { throw 'Fixture generation failed' }
        & "$VivadoBin/xvlog.bat" -sv (Join-Path $PSScriptRoot 'decode_lane.sv') (Join-Path $PSScriptRoot 'tb.sv')
        if ($LASTEXITCODE) { throw 'xvlog failed' }
        $top = if ($columns -eq 1) { 'tb_one' } else { 'tb_two' }
        & "$VivadoBin/xelab.bat" "work.$top" -s q4test
        if ($LASTEXITCODE) { throw 'xelab failed' }
        & "$VivadoBin/xsim.bat" q4test -runall
        if ($LASTEXITCODE -or !(Select-String -Quiet -Path xsim.log -Pattern 'Q4-MAC-PASS')) { throw 'Simulation failed' }
    } finally { Pop-Location }
}
