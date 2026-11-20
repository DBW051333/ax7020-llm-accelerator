`timescale 1ns/1ps
// Select at the first accepted header. Hold the route until the final
// result handshake, regardless of how many MM2S transfers the request uses.
module decode_lane (
    input wire aclk, aresetn,
    input wire [63:0] s_axis_tdata,
    input wire s_axis_tvalid, s_axis_tlast,
    output wire s_axis_tready,
    output wire [63:0] m_axis_tdata,
    output wire m_axis_tvalid, m_axis_tlast,
    input wire m_axis_tready,
    output wire irq
);
    reg active, head;
    wire use_head = active ? head : (s_axis_tdata[31:0]==32'h38444851);
    wire head_in_ready, gate_in_ready, head_valid, gate_valid, head_last, gate_last;
    wire [63:0] head_data, gate_data;
    assign s_axis_tready = use_head ? head_in_ready : gate_in_ready;
    assign m_axis_tdata = head ? head_data : gate_data;
    assign m_axis_tvalid = active && (head ? head_valid : gate_valid);
    assign m_axis_tlast = head ? head_last : gate_last;
    assign irq = m_axis_tvalid && m_axis_tready && m_axis_tlast;

    always @(posedge aclk) begin
        if (!aresetn) begin active<=0; head<=0; end
        else if (irq) active<=0;
        else if (!active && s_axis_tvalid && s_axis_tready) begin
            active<=1; head<=use_head;
        end
    end

    head_lane head_engine(aclk,aresetn,s_axis_tdata,s_axis_tvalid && use_head,s_axis_tlast,
        head_in_ready,head_data,head_valid,head_last,m_axis_tready && active && head,);
    gateup_axis gate_engine(aclk,aresetn,s_axis_tdata,s_axis_tvalid && !use_head,s_axis_tlast,
        gate_in_ready,gate_data,gate_valid,active && !head && m_axis_tready,gate_last,);
endmodule
