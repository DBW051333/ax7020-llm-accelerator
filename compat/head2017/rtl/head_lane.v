`timescale 1ns/1ps
// One Q8_0 Head lane, width 896. Payload is the raw GGUF byte layout.
// Transport segments may end anywhere on a 64-bit boundary. Input TLAST is
// a DMA descriptor boundary; the header gives the logical request length.
module head_lane (
    input wire aclk, aresetn,
    input wire [63:0] s_axis_tdata,
    input wire s_axis_tvalid, s_axis_tlast,
    output wire s_axis_tready,
    output wire [63:0] m_axis_tdata,
    output wire m_axis_tvalid, m_axis_tlast,
    input wire m_axis_tready,
    output wire irq
);
    localparam HEADER=0, ACTIVATION=1, WEIGHTS=2;
    reg [1:0] state;
    reg [31:0] rows_left, groups_left;
    reg [4:0] word_index;
    reg [2:0] activation_group, weight_group;
    reg [1:0] block_index, beat_index;
    reg write_bank, read_bank, waiting_row;
    reg [1:0] occupied;
    reg [1087:0] staging;
    reg [1087:0] weights [0:1];
    reg [1087:0] activations [0:6];
    wire [1087:0] next_group = {s_axis_tdata, staging[1087:64]};
    wire input_fire = s_axis_tvalid && s_axis_tready;
    wire write_group = input_fire && state==WEIGHTS && word_index==16;

    wire dot_ready, dot_valid, scale_ready, scale_valid;
    wire signed [31:0] dot;
    wire [31:0] scaled;
    reg pending, first_block, last_block;
    reg [15:0] dw, dx;

    wire [271:0] w = weights[read_bank][272*block_index +: 272];
    wire [271:0] x = activations[weight_group][272*block_index +: 272];
    wire issue = state==WEIGHTS && occupied[read_bank] && !waiting_row &&
                 (beat_index!=3 || !pending || (dot_valid && scale_ready));
    wire dot_fire = issue && dot_ready;
    wire read_group = dot_fire && block_index==3 && beat_index==3;
    wire scale_fire = dot_valid && scale_ready;
    wire row_fire = m_axis_tvalid && m_axis_tready;

    assign s_axis_tready = aresetn && (state!=WEIGHTS ||
                           (groups_left!=0 && !occupied[write_bank]));
    assign m_axis_tvalid = scale_valid;
    assign m_axis_tdata = {32'd0, scaled};
    assign m_axis_tlast = scale_valid && rows_left==1;
    assign irq = row_fire && m_axis_tlast;

    q58_dot32 dots(.clk(aclk), .rst_n(aresetn),
        .w_data(w[16+64*beat_index +: 64]), .x_data(x[16+64*beat_index +: 64]),
        .in_valid(issue), .in_ready(dot_ready), .result(dot), .sx(),
        .out_valid(dot_valid), .out_ready(scale_ready));
    q58_scaled_accum scaler(.clk(aclk), .rst_n(aresetn), .dot(dot), .dw(dw), .dx(dx),
        .in_first(first_block), .in_last(last_block), .in_valid(dot_valid),
        .in_ready(scale_ready), .result(scaled), .out_valid(scale_valid),
        .out_ready(m_axis_tready));

    always @(posedge aclk) begin
        if (!aresetn) begin
            state<=HEADER; rows_left<=0; groups_left<=0; word_index<=0;
            activation_group<=0; weight_group<=0; block_index<=0; beat_index<=0;
            write_bank<=0; read_bank<=0; occupied<=0; waiting_row<=0;
            pending<=0; first_block<=0; last_block<=0; dw<=0; dx<=0;
        end else begin
            if (scale_fire) pending<=0;
            if (input_fire) begin
                if (state==HEADER) begin
                    if (s_axis_tdata[31:0]==32'h38444851 && s_axis_tdata[63:32]!=0 &&
                        s_axis_tdata[63:32]<=32'd151936) begin
                        rows_left<=s_axis_tdata[63:32];
                        groups_left<=(s_axis_tdata[63:32]<<3)-s_axis_tdata[63:32];
                        state<=ACTIVATION;
                    end
                end else begin
                    staging<=next_group;
                    if (word_index==16) begin
                        word_index<=0;
                        if (state==ACTIVATION) begin
                            activations[activation_group]<=next_group;
                            if (activation_group==6) begin
                                state<=WEIGHTS;
                                activation_group<=0;
                            end else activation_group<=activation_group+1'b1;
                        end
                    end else word_index<=word_index+1'b1;
                end
            end
            if (write_group) begin
                weights[write_bank]<=next_group;
                occupied[write_bank]<=1;
                write_bank<=!write_bank;
                groups_left<=groups_left-1'b1;
            end
            if (dot_fire) begin
                beat_index<=beat_index+1'b1;
                if (beat_index==3) begin
                    pending<=1;
                    dw<=w[15:0]; dx<=x[15:0];
                    first_block<=weight_group==0 && block_index==0;
                    last_block<=weight_group==6 && block_index==3;
                    block_index<=block_index+1'b1;
                end
            end
            if (read_group) begin
                occupied[read_bank]<=0;
                read_bank<=!read_bank;
                if (weight_group==6) begin
                    weight_group<=0;
                    waiting_row<=1;
                end else weight_group<=weight_group+1'b1;
            end
            if (row_fire) begin
                waiting_row<=0;
                rows_left<=rows_left-1'b1;
                if (rows_left==1) state<=HEADER;
            end
        end
    end
endmodule
