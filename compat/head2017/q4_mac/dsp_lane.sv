`timescale 1ns/1ps
// The wire protocol remains 64 bits. In the two-beat variant the banked
// activation RAM and the weight registers supply two consecutive slices.
module para_mac_lane #(parameter BEATS=2, parameter BLOCKS=19) (
    input wire aclk, aresetn,
    input wire [63:0] s_axis_tdata,
    input wire s_axis_tvalid, s_axis_tlast,
    output wire s_axis_tready,
    output wire [63:0] m_axis_tdata,
    output reg m_axis_tvalid, m_axis_tlast,
    input wire m_axis_tready,
    output wire irq
);
    localparam SLICES=BLOCKS*16;
    localparam HALF_DEPTH=SLICES/BEATS;
    localparam LOAD=0, SCALES=1, WEIGHTS=2, DRAIN=3;
    reg [1:0] state;
    reg bank;
    reg [$clog2(SLICES)-1:0] address;
    reg [3:0] beat;
    reg [63:0] scales;
    reg [5:0] decoded_scale;
    reg [5:0] scale_pipe [0:2];
    reg [4:0] valid, block_end, packet_end;
    wire advance=!m_axis_tvalid || m_axis_tready;
    assign s_axis_tready=advance && state!=DRAIN;
    wire accept=s_axis_tvalid && s_axis_tready;
    wire complete=accept && state==WEIGHTS && (BEATS==1 || beat[0]);
    assign irq=m_axis_tvalid && m_axis_tready && m_axis_tlast;

    always @(posedge aclk) begin
        if (!aresetn) begin
            state <= LOAD;
            bank <= 0;
            address <= 0;
            beat <= 0;
            valid <= 0;
            block_end <= 0;
            packet_end <= 0;
            m_axis_tvalid <= 0;
            m_axis_tlast <= 0;
        end else if (advance) begin
            valid <= {valid[3:0], complete};
            block_end <= {block_end[3:0], beat==15};
            packet_end <= {packet_end[3:0], s_axis_tlast};
            scale_pipe[0] <= decoded_scale;
            scale_pipe[1] <= scale_pipe[0];
            scale_pipe[2] <= scale_pipe[1];
            m_axis_tvalid <= valid[4] && block_end[4];
            m_axis_tlast <= packet_end[4];
            if (irq) state <= LOAD;
            if (accept) case (state)
                LOAD: begin
                    bank <= !bank;
                    if (bank) begin
                        if (address==SLICES-1) begin
                            address <= 0;
                            state <= SCALES;
                        end else address <= address+1'b1;
                    end
                end
                SCALES: begin
                    scales <= s_axis_tdata;
                    state <= WEIGHTS;
                end
                WEIGHTS: begin
                    if (complete) decoded_scale <= scales[(beat[3:1]*8)+:6];
                    beat <= beat+1'b1;
                    address <= address==SLICES-1 ? 0 : address+1'b1;
                    if (beat==15) state <= s_axis_tlast ? DRAIN : SCALES;
                end
                default: ;
            endcase
        end
    end

    wire signed [22:0] contributions[0:BEATS-1];
    genvar h,i;
    generate for (h=0; h<BEATS; h=h+1) begin : slice
        reg [63:0] low[0:HALF_DEPTH-1];
        reg [63:0] high[0:HALF_DEPTH-1];
        reg [127:0] activation;
        reg [63:0] weight;
        wire selected=BEATS==1 || address[0]==h;
        wire [$clog2(HALF_DEPTH)-1:0] index=address/BEATS;
        always @(posedge aclk) begin
            if (accept && selected) begin
                if (state==LOAD) begin
                    if (bank) high[index] <= s_axis_tdata;
                    else low[index] <= s_axis_tdata;
                end
                if (state==WEIGHTS) begin
                    activation <= {high[index],low[index]};
                    weight <= s_axis_tdata;
                end
            end
        end
        (* use_dsp48 = "yes" *) reg signed [11:0] products[0:15];
        reg signed [13:0] quarters[0:3];
        reg signed [15:0] total;
        (* use_dsp48 = "yes" *) reg signed [22:0] scaled;
        for (i=0;i<16;i=i+1) begin : mul
            always @(posedge aclk)
                if (advance) products[i] <= $signed({1'b0,weight[4*i+:4]}) *
                                           $signed(activation[8*i+:8]);
        end
        for (i=0;i<4;i=i+1) begin : sum_four
            always @(posedge aclk)
                if (advance) quarters[i] <= (products[4*i]+products[4*i+1]) +
                                            (products[4*i+2]+products[4*i+3]);
        end
        always @(posedge aclk) if (advance) begin
            total <= (quarters[0]+quarters[1])+(quarters[2]+quarters[3]);
            scaled <= total*$signed({1'b0,scale_pipe[2]});
        end
        assign contributions[h]=scaled;
    end endgenerate

    wire signed [23:0] pair_sum;
    generate if (BEATS==2) assign pair_sum=contributions[0]+contributions[1];
    else assign pair_sum=contributions[0];
    endgenerate
    reg signed [31:0] acc, result;
    always @(posedge aclk) begin
        if (!aresetn) acc <= 0;
        else if (advance && valid[4]) begin
            if (block_end[4]) begin
                result <= acc+pair_sum;
                acc <= 0;
            end else acc <= acc+pair_sum;
        end
    end
    assign m_axis_tdata={32'd0,result};
endmodule
