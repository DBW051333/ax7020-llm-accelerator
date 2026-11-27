`timescale 1ns/1ps
// Each weight beat carries 16 unsigned Q4 values. The same beat feeds
// every active column. A scale byte applies to each consecutive 32 values.
module decode_lane #(parameter COLUMNS = 2, parameter BLOCKS = 19) (
    input wire aclk, aresetn,
    input wire [63:0] s_axis_tdata,
    input wire s_axis_tvalid, s_axis_tlast,
    output wire s_axis_tready,
    output wire [63:0] m_axis_tdata,
    output reg m_axis_tvalid, m_axis_tlast,
    input wire m_axis_tready,
    output wire irq
);
    localparam ACT_WORDS = BLOCKS * 16;
    localparam LOAD = 0, SCALES = 1, WEIGHTS = 2, DRAIN = 3;
    reg [1:0] state;
    reg [1:0] bank;
    reg [$clog2(ACT_WORDS)-1:0] address;
    reg [3:0] beat;
    reg [63:0] scales;
    reg [63:0] weights;
    reg [5:0] decode_scale;
    reg [4:0] valid, block_end, packet_end;
    reg [5:0] scale_pipe [0:2];
    wire advance = !m_axis_tvalid || m_axis_tready;
    wire accept = s_axis_tvalid && s_axis_tready;
    assign s_axis_tready = advance && state != DRAIN;
    assign irq = m_axis_tvalid && m_axis_tready && m_axis_tlast;

    always @(posedge aclk) begin
        if (!aresetn) begin
            state <= LOAD;
            address <= 0;
            bank <= 0;
            beat <= 0;
            valid <= 0;
            block_end <= 0;
            packet_end <= 0;
            m_axis_tvalid <= 0;
            m_axis_tlast <= 0;
        end else if (advance) begin
            valid <= {valid[3:0], accept && state == WEIGHTS};
            block_end <= {block_end[3:0], beat == 15};
            packet_end <= {packet_end[3:0], s_axis_tlast};
            scale_pipe[0] <= decode_scale;
            scale_pipe[1] <= scale_pipe[0];
            scale_pipe[2] <= scale_pipe[1];
            m_axis_tvalid <= valid[4] && block_end[4];
            m_axis_tlast <= packet_end[4];
            if (irq) state <= LOAD;
            if (accept) case (state)
                LOAD: begin
                    if (bank == 2*COLUMNS-1) begin
                        bank <= 0;
                        if (address == ACT_WORDS-1) begin
                            address <= 0;
                            state <= SCALES;
                        end else address <= address + 1'b1;
                    end else bank <= bank + 1'b1;
                end
                SCALES: begin
                    scales <= s_axis_tdata;
                    state <= WEIGHTS;
                end
                WEIGHTS: begin
                    weights <= s_axis_tdata;
                    decode_scale <= scales[(beat[3:1]*8) +: 6];
                    beat <= beat + 1'b1;
                    address <= address == ACT_WORDS-1 ? 0 : address + 1'b1;
                    if (beat == 15) state <= s_axis_tlast ? DRAIN : SCALES;
                end
                default: ;
            endcase
        end
    end

    genvar c, i;
    generate for (c=0; c<COLUMNS; c=c+1) begin : column
        reg [63:0] low [0:ACT_WORDS-1];
        reg [63:0] high [0:ACT_WORDS-1];
        reg [127:0] activation;
        reg signed [11:0] products [0:15];
        reg signed [13:0] quarters [0:3];
        reg signed [15:0] total;
        reg signed [22:0] scaled;
        reg signed [31:0] acc, result;

        always @(posedge aclk) begin
            if (accept && state == LOAD && bank == 2*c)
                low[address] <= s_axis_tdata;
            if (accept && state == LOAD && bank == 2*c+1)
                high[address] <= s_axis_tdata;
            if (accept && state == WEIGHTS) begin
                activation[63:0] <= low[address];
                activation[127:64] <= high[address];
            end
        end
        for (i=0; i<16; i=i+1) begin : multiply
            always @(posedge aclk)
                if (advance)
                    products[i] <= $signed({1'b0, weights[4*i+:4]}) *
                                   $signed(activation[8*i+:8]);
        end
        for (i=0; i<4; i=i+1) begin : reduce_four
            always @(posedge aclk)
                if (advance)
                    quarters[i] <= (products[4*i] + products[4*i+1]) +
                                   (products[4*i+2] + products[4*i+3]);
        end
        always @(posedge aclk) begin
            if (!aresetn) acc <= 0;
            else if (advance) begin
                total <= (quarters[0] + quarters[1]) + (quarters[2] + quarters[3]);
                scaled <= total * $signed({1'b0, scale_pipe[2]});
                if (valid[4]) begin
                    if (block_end[4]) begin
                        result <= acc + scaled;
                        acc <= 0;
                    end else acc <= acc + scaled;
                end
            end
        end
        assign m_axis_tdata[32*c+:32] = result;
    end
    if (COLUMNS == 1) begin : single_column
        assign m_axis_tdata[63:32] = 0;
    end endgenerate
endmodule
