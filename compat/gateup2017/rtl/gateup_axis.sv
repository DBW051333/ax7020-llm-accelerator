`timescale 1ns/1ps
`default_nettype none
// Line-rate Q5_0/Q8_0 AXIS engine (fusion-speedup2017).
// Packet and arithmetic contracts are unchanged from blite_q58_axis:
// header 0x58, format 5/8/21, bits31:16 rows, bits47:32 blocks (K/32);
// activation blocks padded to 40B, weight blocks padded to 24B (Q5) or
// 40B (Q8); per output row all Gate blocks precede all Up blocks; exact
// integer dot per 32-block, FP16 scale products, 112-bit block-order
// accumulation, one final FP32 RNE. See CONTRACT.md.
// Microarchitecture changes for throughput only:
//  - weight ping-pong buffers let the input stream run ahead of compute;
//  - the dot32 MAC accepts one beat per cycle;
//  - activation reads lead the feed pointer by one beat;
//  - scaler, SiLU and output stages are unchanged and backpressure flows
//    through the same handshake chain as before (stream -> MAC -> scaler
//    -> SiLU -> m_axis).
module gateup_axis (
    input wire aclk, aresetn,
    input wire [63:0] s_axis_tdata,
    input wire s_axis_tvalid, s_axis_tlast,
    output wire s_axis_tready,
    output wire [63:0] m_axis_tdata,
    output wire m_axis_tvalid,
    input wire m_axis_tready,
    output wire m_axis_tlast,
    output reg irq
);
    localparam HDR=0, XLOAD=1, FLOW=2, BAD=3;
    reg [1:0] state;
    reg [7:0] format;
    reg [15:0] rows;
    reg [8:0] blocks;
    reg [8:0] xload_blk;
    reg [2:0] xload_idx;
    reg [63:0] previous_word;
    reg [63:0] x_memory [0:1023];
    reg [15:0] d_memory [0:255];

    // weight ping-pong: stream fills one buffer while the MAC drains the other
    reg [1151:0] wbuf [0:1];
    reg wbuf_v [0:1];
    reg fill_sel;
    reg [4:0] fill_idx;
    wire [4:0] fill_last = (format==8'd12) ? 5'd17 : (format==8'd8) ? 5'd4 : 5'd2;
    // weight-word budget: stops accepting after the packet's last weight word
    // so the next packet's header is never eaten while results drain
    reg [27:0] wbudget;
    wire [7:0] hdr_format = s_axis_tdata[15:8];
    wire [31:0] hdr_units = (hdr_format==8'd12) ? ((s_axis_tdata[47:32]+16'd7)>>3)
                                               : {16'd0,s_axis_tdata[47:32]};
    wire [31:0] hdr_words = (hdr_format==8'd12) ? 32'd18 :
                            (hdr_format==8'd8) ? 32'd5 :
                            (hdr_format==8'd21) ? 32'd6 : 32'd3;
    wire [27:0] wbudget_next = s_axis_tdata[31:16] * (hdr_units * hdr_words);

    // feed pointers (one beat = 8 elements of one group)
    reg feed_sel;
    reg [1:0] feed_grp;
    reg [8:0] feed_blk;
    reg xvalid;
    reg [63:0] x_word_r;
    reg [15:0] x_scale_r;

    // result attribution: latched when a block's last beat fires
    reg [15:0] res_dw;
    reg [15:0] res_scale;
    reg [15:0] res_dw2;
    reg [15:0] res_dx2;
    reg [8:0] res_blk;
    reg res_pending;      // one dot result in flight; attribution is stable
                          // from its block's last beat until the scaler pops it

    reg [31:0] gate_result;
    reg out_is_gate;      // fused: next scale_valid carries the gate result

    // registered output beat
    reg out_v;
    reg [63:0] out_d;
    reg out_last_r;
    reg [15:0] out_row;

    // handshakes (declared before use by the MAC/scaler/SiLU instances)
    wire take = s_axis_tvalid && s_axis_tready;
    assign s_axis_tready = state==HDR || state==XLOAD ||
                           (state==FLOW && !wbuf_v[fill_sel] && wbudget!=0);
    wire fused = format==8'd21;
    wire emit_slot = !out_v || m_axis_tready;
    wire dot_input_ready, dot_valid;
    wire signed [31:0] dot;
    wire signed [31:0] dot_sx;
    wire scale_ready, scale_valid;
    wire [31:0] scaled_result;
    wire act_ready, act_valid;
    wire [31:0] act_result;
    wire scale_fire = dot_valid && scale_ready && state==FLOW;
    wire scale_output_ready = fused ? (out_is_gate ? 1'b1 : act_ready)
                                    : emit_slot;
    wire scale_consume = scale_valid && scale_output_ready;
    wire feed_fire = state==FLOW && xvalid && wbuf_v[feed_sel] && dot_input_ready
                     && (feed_grp!=2'd0 || !res_pending || scale_fire);
    wire [1151:0] feed_w = wbuf[feed_sel];
    // Q4_K 6-bit scale/min unpack (delivery blite_core get_sm mapping) and
    // exact FP16 encoding of a 6-bit integer
    function [5:0] get_sm6(input [2:0] jj, input [95:0] qq, input is_min);
        reg [5:0] sc, m;
        begin
            if (jj<3'd4) begin
                sc = qq[8*jj +: 8] & 8'h3F;
                m  = qq[8*(jj+4) +: 8] & 8'h3F;
            end else begin
                sc = (qq[8*(jj+4) +: 8] & 8'h0F) | (qq[8*(jj-4) +: 8] >> 6 << 4);
                m  = (qq[8*(jj+4) +: 8] >> 4)     | (qq[8*jj +: 8] >> 6 << 4);
            end
            get_sm6 = is_min ? m : sc;
        end
    endfunction
    function [15:0] fp16_of_6b(input [5:0] n);
        reg [2:0] e;
        begin
            if (n==6'd0) fp16_of_6b=16'h0000;
            else begin
                e = n[5] ? 3'd5 : n[4] ? 3'd4 : n[3] ? 3'd3 :
                    n[2] ? 3'd2 : n[1] ? 3'd1 : 3'd0;
                fp16_of_6b={1'b0,5'd15+{2'd0,e},(n<<(10-{1'b0,e}))};
            end
        end
    endfunction
    wire [5:0] sm_sc = get_sm6(feed_blk[2:0], feed_w[127:32], 1'b0);
    wire [5:0] sm_min = get_sm6(feed_blk[2:0], feed_w[127:32], 1'b1);

    // next-beat activation address (leads the beat consumed this cycle)
    wire [1:0] nxt_grp = (feed_grp==2'd3) ? 2'd0 : feed_grp+2'd1;
    wire [8:0] nxt_blk = (feed_grp==2'd3) ? ((feed_blk+9'd1==blocks) ? 9'd0 : feed_blk+9'd1)
                                          : feed_blk;

    wire [9:0] xrd_addr = feed_fire ? {nxt_blk[7:0],nxt_grp}
                                    : {feed_blk[7:0],feed_grp};
    wire xrd_grp0 = feed_fire ? (nxt_grp==2'd0) : (feed_grp==2'd0);
    wire [7:0] xrd_blk = feed_fire ? nxt_blk[7:0] : feed_blk[7:0];

    // weight decode (unchanged bit layout, source switched to the fed buffer)
    reg [63:0] decoded_weight;
    integer j, element, byteidx;
    reg [4:0] unsigned_q5;
    reg [3:0] q4_nib;
    always @* begin
        decoded_weight=0;
        unsigned_q5=0;
        element=0;
        byteidx=0;
        q4_nib=0;
        for (j=0; j<8; j=j+1) begin
            element=feed_grp*8+j;
            if (format==8'd12) begin
                byteidx=((feed_blk[2:1])*4 + feed_grp)*8 + (j&15);
                q4_nib=(feed_blk[0]) ? feed_w[128+byteidx*8+4 +: 4]
                                     : feed_w[128+byteidx*8 +: 4];
                decoded_weight[j*8 +: 8]={4'd0,q4_nib};
            end else if ((format==8'd5 || format==8'd21)) begin
                unsigned_q5={feed_w[16+element],
                    feed_w[48+(element%16)*8+(element>=16 ? 4 : 0) +: 4]};
                decoded_weight[j*8 +: 8]={3'd0,unsigned_q5}-8'd16;
            end else decoded_weight[j*8 +: 8]=feed_w[16+element*8 +: 8];
        end
    end

    q58_dot32 mac (
        .clk(aclk), .rst_n(aresetn), .w_data(decoded_weight), .x_data(x_word_r),
        .in_valid(feed_fire), .in_ready(dot_input_ready),
        .result(dot), .sx(dot_sx), .out_valid(dot_valid), .out_ready(scale_fire)
    );
    q58_scaled_accum scaler (
        .clk(aclk), .rst_n(aresetn), .dot(dot), .sx(dot_sx),
        .dw(res_dw), .dx(res_scale), .dw2(res_dw2), .dx2(res_dx2),
        .in_first(res_blk==9'd0), .in_last(res_blk+9'd1==blocks),
        .in_valid(scale_fire), .in_ready(scale_ready),
        .result(scaled_result), .out_valid(scale_valid), .out_ready(scale_output_ready)
    );
    gateup_silu_mul activation(.clk(aclk),.rst_n(aresetn),
        .gate_value(gate_result),.up_value(scaled_result),
        .in_valid(scale_consume && fused && !out_is_gate),.in_ready(act_ready),
        .result(act_result),.out_valid(act_valid),.out_ready(emit_slot));

    assign m_axis_tdata = out_d;
    assign m_axis_tvalid = out_v;
    assign m_axis_tlast = out_last_r;

    always @(posedge aclk) begin
        if (!aresetn) begin
            state<=HDR; format<=0; rows<=0; blocks<=0;
            xload_blk<=0; xload_idx<=0; previous_word<=0;
            fill_sel<=0; fill_idx<=0; wbuf_v[0]<=0; wbuf_v[1]<=0; wbudget<=0;
            feed_sel<=0; feed_grp<=0; feed_blk<=0; xvalid<=0;
            x_word_r<=0; x_scale_r<=0;
            res_dw<=0; res_scale<=0; res_dw2<=0; res_dx2<=0; res_blk<=0; res_pending<=1'b0;
            gate_result<=0; out_is_gate<=1;
            out_v<=0; out_d<=0; out_last_r<=0; out_row<=0; irq<=0;
        end else begin
            irq<=0;
            // output beat consume (refills below may re-set out_v same edge)
            if (out_v && m_axis_tready) begin
                out_v<=1'b0;
                if (out_last_r) begin
                    irq<=1'b1; state<=HDR; out_row<=16'd0;
                end else out_row<=out_row+16'd1;
            end
            case (state)
                HDR: if (take) begin
                    if (s_axis_tdata[7:0]!=8'h58 ||
                        (s_axis_tdata[15:8]!=5 && s_axis_tdata[15:8]!=8 && s_axis_tdata[15:8]!=12 && s_axis_tdata[15:8]!=21) ||
                        s_axis_tdata[31:16]==0 || s_axis_tdata[47:32]==0 ||
                        s_axis_tdata[47:32]>256) state<=BAD;
                    else begin
                        format<=s_axis_tdata[15:8]; rows<=s_axis_tdata[31:16];
                        blocks<=s_axis_tdata[47:32];
                        wbudget<=wbudget_next;
                        xload_blk<=0; xload_idx<=0;
                        state<=XLOAD;
                    end
                end
                XLOAD: if (take) begin
                    previous_word<=s_axis_tdata;
                    if (xload_idx==0) d_memory[xload_blk[7:0]]<=s_axis_tdata[15:0];
                    else x_memory[{xload_blk[7:0],2'b00}+xload_idx-1]
                        <={s_axis_tdata[15:0],previous_word[63:16]};
                    if (xload_idx==4) begin
                        xload_idx<=0;
                        if (xload_blk+9'd1==blocks) begin
                            xload_blk<=0;
                            fill_sel<=1'b0; fill_idx<=3'd0;
                            wbuf_v[0]<=1'b0; wbuf_v[1]<=1'b0;
                            feed_sel<=1'b0; feed_grp<=2'd0; feed_blk<=9'd0;
                            xvalid<=1'b0;
                            out_is_gate<=1'b1;
                            res_pending<=1'b0;
                            state<=FLOW;
                        end else xload_blk<=xload_blk+9'd1;
                    end else xload_idx<=xload_idx+3'd1;
                end
                FLOW: begin
                    // stream: fill the free weight buffer
                    if (take) begin
                        wbuf[fill_sel][fill_idx*64 +: 64]<=s_axis_tdata;
                        wbudget<=wbudget-28'd1;
                        if (fill_idx==fill_last) begin
                            fill_idx<=3'd0;
                            wbuf_v[fill_sel]<=1'b1;
                            fill_sel<=~fill_sel;
                        end else fill_idx<=fill_idx+3'd1;
                    end
                    // activation read pipeline: one BRAM read port shared by
                    // the fire path (next beat) and the prime path (first beat)
                    if (state==FLOW && (feed_fire || (!xvalid && wbuf_v[feed_sel]))) begin
                        x_word_r<=x_memory[xrd_addr];
                        if (xrd_grp0) x_scale_r<=d_memory[xrd_blk];
                        if (!feed_fire) xvalid<=1'b1;
                    end
                    // feed: one beat per cycle into the MAC
                    if (scale_fire) res_pending<=1'b0;
                    if (feed_fire) begin
                        if (feed_grp==2'd3) begin
                            if (format==8'd12) begin
                                if (feed_blk[2:0]==3'd7) begin
                                    wbuf_v[feed_sel]<=1'b0;
                                    feed_sel<=~feed_sel;
                                end
                            end else begin
                                wbuf_v[feed_sel]<=1'b0;
                                feed_sel<=~feed_sel;
                            end
                            res_dw<=feed_w[15:0];
                            res_scale<=(format==8'd12) ? fp16_of_6b(sm_sc) : x_scale_r;
                            res_dw2<=(format==8'd12) ? feed_w[31:16] : 16'd0;
                            res_dx2<=(format==8'd12) ? fp16_of_6b(sm_min) : 16'd0;
                            res_blk<=feed_blk;
                            res_pending<=1'b1;
                            feed_grp<=2'd0;
                            if (feed_blk+9'd1==blocks) feed_blk<=9'd0;
                            else feed_blk<=feed_blk+9'd1;
                        end else feed_grp<=feed_grp+2'd1;
                    end
                    // result side: gate capture / row emission
                    if (scale_consume) begin
                        if (fused) begin
                            if (out_is_gate) begin
                                gate_result<=scaled_result;
                                out_is_gate<=1'b0;
                            end else out_is_gate<=1'b1;
                        end else begin
                            out_d<={32'd0,scaled_result};
                            out_last_r<=(out_row+16'd1==rows);
                            out_v<=1'b1;
                        end
                    end
                    if (act_valid && emit_slot) begin
                        out_d<={32'd0,act_result};
                        out_last_r<=(out_row+16'd1==rows);
                        out_v<=1'b1;
                    end
                end
                BAD: irq<=1'b1;
                default: state<=BAD;
            endcase
        end
    end
    // The finite packet length is determined by the validated header. TLAST is
    // accepted at DMA packet boundaries; only output TLAST frames result rows.
endmodule
`default_nettype wire
