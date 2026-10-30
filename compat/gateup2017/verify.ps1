param([string]$VivadoBin='D:\Xilinx\Vivado\2017.4\bin')
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
python (Join-Path $PSScriptRoot 'prepare.py')
if($LASTEXITCODE -ne 0){throw 'prepare failed'}
python (Join-Path $PSScriptRoot 'vectors.py')
if($LASTEXITCODE -ne 0){throw 'vectors failed'}
$rtl=Join-Path $repo 'build/gateup2017/rtl'
$sim=Join-Path $repo 'build/gateup2017/sim'
Copy-Item (Join-Path $rtl 'sigmoid.hex') $sim
"run 40 ms`nquit" | Set-Content -Encoding ascii (Join-Path $sim 'run.tcl')
Push-Location $sim
try {
 $sources=Get-ChildItem (Join-Path $rtl '*.sv') | ForEach-Object {$_.FullName}
 & (Join-Path $VivadoBin 'xvlog.bat') -sv @sources (Join-Path $PSScriptRoot 'tb.sv') 2>&1 | Tee-Object compile.txt
 if($LASTEXITCODE -ne 0){throw 'xvlog failed'}
 & (Join-Path $VivadoBin 'xelab.bat') tb_gateup -s gateup_sim -debug off 2>&1 | Tee-Object elaborate.txt
 if($LASTEXITCODE -ne 0){throw 'xelab failed'}
 & (Join-Path $VivadoBin 'xsim.bat') gateup_sim -tclbatch run.tcl 2>&1 | Tee-Object simulation.txt
 if($LASTEXITCODE -ne 0){throw 'xsim failed'}
 $log=Get-Content simulation.txt -Raw
 foreach($marker in @('FP-MUL-PASS','SILU-MUL-PASS','GATEUP-AXIS-PASS')){
  if(!$log.Contains($marker)){throw "missing $marker"}
 }
 if($log -match 'Fatal:|WATCHDOG|mismatch'){throw 'simulation failure'}
 Write-Output 'GATEUP-VERIFIED'
}finally{Pop-Location}
