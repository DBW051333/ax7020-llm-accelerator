"""Derive the fused Q5 gate/up engine without changing the delivery snapshot."""
import hashlib
import json
import math
from pathlib import Path

root=Path(__file__).resolve().parents[2]
out=root/'build/gateup2017/rtl'
out.mkdir(parents=True,exist_ok=True)
source=root/'accel/experimental'
for relative in ['q58_mac/q58_dot32.sv','q58_scale/q58_scaled_accum.sv']:
    (out/Path(relative).name).write_bytes((source/relative).read_bytes())
for p in (root/'compat/gateup2017/rtl').glob('*.sv'):
    (out/p.name).write_bytes(p.read_bytes())
rom=''.join(f'{round((1/(1+math.exp(-i/256)))*(1<<30)):08x}\n' for i in range(8193))
(out/'sigmoid.hex').write_text(rom,encoding='ascii')
s=(source/'q58_exact/blite_q58_axis.sv').read_text()
s=s.replace('module blite_q58_axis','module gateup_axis')
s=s.replace('DOTWAIT=5, ROWWAIT=6, BAD=7;','DOTWAIT=5, ROWWAIT=6, BAD=7, ACTWAIT=8;')
s=s.replace('reg [2:0] state;','reg [3:0] state;\n    reg phase;\n    reg [31:0] gate_result;')
s=s.replace("format==8'd5","(format==8'd5 || format==8'd21)")
s=s.replace('(format==5 ? 2 : 4)','((format==5 || format==21) ? 2 : 4)')
s=s.replace('(s_axis_tdata[15:8]!=5 && s_axis_tdata[15:8]!=8)',
            '(s_axis_tdata[15:8]!=5 && s_axis_tdata[15:8]!=8 && s_axis_tdata[15:8]!=21)')
start=s.index('    assign scale_output_ready=')
end=s.index('\n    always @(posedge aclk)',start)
s=s[:start]+'''    wire fused=format==21;
    wire act_ready,act_valid;
    wire [31:0] act_result;
    gateup_silu_mul activation(.clk(aclk),.rst_n(aresetn),
        .gate_value(gate_result),.up_value(scaled_result),
        .in_valid(state==ROWWAIT && fused && phase && scale_valid),.in_ready(act_ready),
        .result(act_result),.out_valid(act_valid),.out_ready(state==ACTWAIT && m_axis_tready));
    assign scale_output_ready=state==ROWWAIT && (fused ? (!phase || act_ready) : m_axis_tready);
    assign m_axis_tvalid=fused ? (state==ACTWAIT && act_valid) : (state==ROWWAIT && scale_valid);
    assign m_axis_tdata={32'd0,fused?act_result:scaled_result};
    assign m_axis_tlast=row_index+16'd1==rows;
'''+s[end:]
s=s.replace('state<=HDR; format<=0;', 'state<=HDR; phase<=0; gate_result<=0; format<=0;')
s=s.replace('blocks<=s_axis_tdata[40:32]; row_index<=0;',
            'blocks<=s_axis_tdata[40:32]; row_index<=0; phase<=0;')
start=s.index('                ROWWAIT:')
end=s.index('                BAD:',start)
s=s[:start]+'''                ROWWAIT: if (scale_valid && scale_output_ready) begin
                    block_index<=0; group_index<=0; word_index<=0;
                    if(fused && !phase)begin
                        gate_result<=scaled_result;phase<=1;state<=WLOAD;
                    end else if(fused)state<=ACTWAIT;
                    else if (row_index+16'd1==rows) begin state<=HDR; irq<=1; end
                    else begin row_index<=row_index+1; state<=WLOAD; end
                end
                ACTWAIT:if(act_valid && m_axis_tready)begin
                    phase<=0;block_index<=0;group_index<=0;word_index<=0;
                    if(row_index+16'd1==rows)begin state<=HDR;irq<=1;end
                    else begin row_index<=row_index+1;state<=WLOAD;end
                end
'''+s[end:]
(out/'gateup_axis.sv').write_text(s)
wrapper=(source/'q58_exact/blite_q58_bd.v').read_text().replace('blite_q58_bd','gateup_bd').replace('blite_q58_axis','gateup_axis')
(out/'gateup_bd.v').write_text(wrapper)
manifest={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(out.iterdir()) if p.is_file()}
(out.parent/'rtl-manifest.json').write_text(json.dumps(manifest,indent=2))
print(out)
