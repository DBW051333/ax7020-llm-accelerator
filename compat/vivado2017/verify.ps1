param([string]$VivadoBin = 'D:\Xilinx\Vivado\2017.4\bin')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$rtl = Join-Path $repo 'build/vivado2017/rtl'
& python (Join-Path $PSScriptRoot 'prepare_rtl.py')
if ($LASTEXITCODE -ne 0) { throw 'Failed to prepare RTL' }
& python (Join-Path $PSScriptRoot 'normalization_vectors.py')
if ($LASTEXITCODE -ne 0) { throw 'Failed to prepare normalization vectors' }
if (!(Test-Path (Join-Path $rtl 'blite_core.v'))) { throw 'Run python tools/restore_source.py first.' }
$tests = @(
    @{Name='normalization'; Top='tb_normalization'; Marker='NORMALIZATION-PASS'; Tb=(Join-Path $PSScriptRoot 'tb_normalization.sv')},
    @{Name='core'; Top='tb_core'; Marker='TB-PASS: 8 rows, 0 errors'; Tb=(Join-Path $repo 'accel/rtl/tb_core.v')},
    @{Name='axis'; Top='tb_axis'; Marker='AXIS-TB-PASS'; Tb=(Join-Path $repo 'accel/rtl/tb_axis.v')},
    @{Name='real-stall'; Top='tb_real_stall'; Marker='REAL-STALL-PASS'; Tb=(Join-Path $repo 'accel/verify/real-stall/tb_real_stall.v')}
)
foreach ($test in $tests) {
    $out = Join-Path $repo ('build/vivado2017/sim/' + $test.Name)
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    Copy-Item (Join-Path $repo 'accel/rtl/*.hex') -Destination $out
    if ($test.Name -eq 'real-stall') {
        Copy-Item (Join-Path $repo 'accel/verify/real-stall/*.hex') -Destination $out
        Copy-Item (Join-Path $repo 'accel/verify/real-stall/params.vh') -Destination $out
    }
    "run 2 ms`nquit" | Set-Content -Encoding ascii (Join-Path $out 'run.tcl')
    Push-Location $out
    try {
        & (Join-Path $VivadoBin 'xvlog.bat') -sv (Join-Path $rtl 'fpu32.v') (Join-Path $rtl 'blite_core.v') (Join-Path $rtl 'blite_axis_top.v') $test.Tb 2>&1 | Tee-Object -FilePath compile.txt
        if ($LASTEXITCODE -ne 0) { throw "xvlog failed: $($test.Name)" }
        & (Join-Path $VivadoBin 'xelab.bat') $test.Top -s verified_snapshot -debug off 2>&1 | Tee-Object -FilePath elaborate.txt
        if ($LASTEXITCODE -ne 0) { throw "xelab failed: $($test.Name)" }
        & (Join-Path $VivadoBin 'xsim.bat') verified_snapshot -tclbatch run.tcl 2>&1 | Tee-Object -FilePath simulation.txt
        if ($LASTEXITCODE -ne 0) { throw "xsim failed: $($test.Name)" }
        $log = Get-Content simulation.txt -Raw
        if (!$log.Contains($test.Marker) -or $log -match 'TB-FAIL|TB-TIMEOUT|AXIS-TB-FAIL|REAL-STALL-FAIL|Fatal:|TIMEOUT') {
            throw "Simulation acceptance failed: $($test.Name)"
        }
        Write-Output "VERIFIED $($test.Name): $($test.Marker)"
    } finally { Pop-Location }
}
& python (Join-Path $PSScriptRoot 'verification_receipt.py')
if ($LASTEXITCODE -ne 0) { throw 'Failed to write verification receipt' }
