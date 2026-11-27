param(
    [int]$Axi = 125,
    [int]$Compute = 200,
    [switch]$ScalePipeline,
    [string]$BuildOutput,
    [string]$VivadoBin = 'D:/Xilinx/Vivado/2017.4/bin'
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$suffix = if ($ScalePipeline) { '-pipe' } else { '' }
$out = Join-Path $repo "build/head2017/dual-clock-$Axi-$Compute$suffix"
if ($BuildOutput) { $out = (Resolve-Path $BuildOutput).Path }
$bd = Join-Path $out 'quad/project/head_quad_2017.srcs/sources_1/bd/head_quad'
if (!(Test-Path $bd)) { throw 'Generate the block design with the bd stage first' }
$sim = Join-Path $out 'sim-cdc'
$vectorTool = Join-Path $PSScriptRoot '../sim_decode.py'
python $vectorTool $sim
if ($LASTEXITCODE) { throw 'Vector generation failed' }
Copy-Item (Join-Path $out 'rtl/sigmoid.hex') $sim
$testbench = Join-Path $sim 'tb.sv'
$text = Get-Content $testbench -Raw
$original = 'decode_lane dut(clk,rst_n,data,valid,last,ready,result,out_valid,out_last,out_ready,);'
if (!$text.Contains($original)) { throw 'Unexpected combined testbench' }
$text = $text.Replace('always #6 clk=!clk;', "always #(500.0/$Axi) clk=!clk;")
$text = $text.Replace('repeat(5) @(negedge clk);', 'repeat(40) @(negedge clk);')
$corePeriod = 500.0/$Compute
$crossing = @"
    reg core_clk=0;
    always #$corePeriod core_clk=!core_clk;
    wire [63:0] core_input, core_output;
    integer core_sent=0;
    always @(posedge core_clk) if (rst_n && ci_valid && ci_ready) begin
        if (core_sent >= INPUT_WORDS)
            `$fatal(1,"Unexpected FIFO beat %0d",core_sent);
        if ({ci_last,core_input} !== {(core_sent%233==0),input_words[core_sent]})
            `$fatal(1,"FIFO input payload or TLAST changed at beat %0d",core_sent);
        core_sent <= core_sent+1;
    end
    wire ci_valid, ci_ready, ci_last, co_valid, co_ready, co_last;
    head_quad_ingress0_0 ingress(
        .s_axis_aclk(clk), .m_axis_aclk(core_clk),
        .s_axis_aresetn(rst_n), .m_axis_aresetn(rst_n),
        .s_axis_tdata(data), .s_axis_tvalid(valid), .s_axis_tready(ready), .s_axis_tlast(last),
        .m_axis_tdata(core_input), .m_axis_tvalid(ci_valid), .m_axis_tready(ci_ready), .m_axis_tlast(ci_last));
    decode_lane dut(core_clk,rst_n,core_input,ci_valid,ci_last,ci_ready,
                    core_output,co_valid,co_last,co_ready,);
    head_quad_egress0_0 egress(
        .s_axis_aclk(core_clk), .m_axis_aclk(clk),
        .s_axis_aresetn(rst_n), .m_axis_aresetn(rst_n),
        .s_axis_tdata(core_output), .s_axis_tvalid(co_valid), .s_axis_tready(co_ready), .s_axis_tlast(co_last),
        .m_axis_tdata(result), .m_axis_tvalid(out_valid), .m_axis_tready(out_ready), .m_axis_tlast(out_last));
"@
$text = $text.Replace($original, $crossing)
$text = $text.Replace('if(sent!=INPUT_WORDS)', 'if(sent!=INPUT_WORDS || core_sent!=INPUT_WORDS)')
[IO.File]::WriteAllText($testbench, $text, [Text.UTF8Encoding]::new($false))
$shared = Join-Path $bd 'ipshared'
function Get-UniqueSource($filter) {
    $files = @(Get-ChildItem $shared -Recurse -File -Filter $filter)
    if ($files.Count -ne 1) { throw "Expected exactly one $filter file" }
    $files[0]
}
$source = @(
    (Get-Item (Join-Path $VivadoBin '../data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv'))
    (Get-Item (Join-Path $VivadoBin '../data/verilog/src/glbl.v'))
    (Get-UniqueSource 'fifo_generator_vlog_beh.v')
    (Get-UniqueSource 'fifo_generator_v13_2_rfs.v')
    (Get-UniqueSource 'axis_infrastructure_v1_1_vl_rfs.v')
    (Get-UniqueSource 'axis_data_fifo_v1_1_vl_rfs.v')
)
$include = (Get-UniqueSource 'axis_infrastructure_v1_1_0.vh').DirectoryName
$wrapper = @('ingress','egress') | ForEach-Object { Join-Path $bd "ip/head_quad_${_}0_0/sim/head_quad_${_}0_0.v" }
$rtl = Get-ChildItem (Join-Path $out 'rtl') -File | Where-Object Extension -in '.v','.sv'
Push-Location $sim
try {
    & (Join-Path $VivadoBin 'xvlog.bat') -sv -i $include @($source.FullName) @($rtl.FullName) @wrapper $testbench
    if ($LASTEXITCODE) { throw 'xvlog failed' }
    & (Join-Path $VivadoBin 'xelab.bat') tb_head glbl -s cdc_sim -debug off -timescale 1ns/1ps
    if ($LASTEXITCODE) { throw 'xelab failed' }
    & (Join-Path $VivadoBin 'xsim.bat') cdc_sim -runall 2>&1 | Tee-Object simulation.txt
    if ($LASTEXITCODE -or !(Select-String -Quiet 'HEAD-SIM-PASS' simulation.txt)) { throw 'CDC simulation failed' }
    if ($ScalePipeline) {
        python (Join-Path $PSScriptRoot 'scale_vectors.py') $sim
        if ($LASTEXITCODE) { throw 'Scale vectors failed' }
        & (Join-Path $VivadoBin 'xvlog.bat') -sv tb_range.sv
        if ($LASTEXITCODE) { throw 'Scale oracle compilation failed' }
        & (Join-Path $VivadoBin 'xelab.bat') tb_range -s scale_range_sim -debug off -timescale 1ns/1ps
        if ($LASTEXITCODE) { throw 'Scale oracle elaboration failed' }
        & (Join-Path $VivadoBin 'xsim.bat') scale_range_sim -runall 2>&1 | Tee-Object scale-range.txt
        if ($LASTEXITCODE -or !(Select-String -Quiet 'SCALE-RANGE-PASS' scale-range.txt)) {
            throw 'Scale oracle simulation failed'
        }
    }
} finally {
    Pop-Location
}
