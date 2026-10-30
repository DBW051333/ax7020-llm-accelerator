param(
    [string]$VivadoBin = 'D:\Xilinx\Vivado\2017.4\bin',
    [ValidateSet('all', 'bd', 'impl')][string]$Stage = 'all'
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Push-Location $repo
try {
    & python tools/restore_source.py
    if ($LASTEXITCODE -ne 0) { throw 'Source restoration/verification failed' }
    & (Join-Path $PSScriptRoot 'verify.ps1') -VivadoBin $VivadoBin
    $project = Join-Path $repo 'build/vivado2017/quad-2017/project/blite_quad_2017.xpr'
    if ($Stage -eq 'all' -and (Test-Path $project)) { $Stage = 'impl' }
    & (Join-Path $VivadoBin 'vivado.bat') -mode batch `
        -source compat/vivado2017/build_quad.tcl `
        -log "build/vivado2017/$Stage.log" `
        -journal "build/vivado2017/$Stage.jou" -tclargs $Stage
    if ($LASTEXITCODE -ne 0) { throw "Vivado stage $Stage failed; inspect build/vivado2017/$Stage.log" }
    if ($Stage -eq 'bd') {
        & python compat/vivado2017/audit_netlist.py
        if ($LASTEXITCODE -ne 0) { throw 'Generated netlist audit failed' }
        & python compat/vivado2017/audit_handoff.py
        if ($LASTEXITCODE -ne 0) { throw 'HWH audit failed' }
    } else {
        & python compat/vivado2017/collect_result.py
        if ($LASTEXITCODE -ne 0) { throw 'Final acceptance record failed' }
    }
} finally { Pop-Location }
