`timescale 1ns/1ps
`default_nettype none
// Exact FP16 products with a signed 112-bit, 2^-48 accumulator.
// Split scaling from the row accumulator so extra pipeline depth can overlap.
module q58_scaled_accum (
    input wire clk, rst_n,
    input wire signed [31:0] dot,
    input wire [15:0] dw, dx,
    input wire in_first, in_last, in_valid,
    output wire in_ready,
    output reg [31:0] result,
    output reg out_valid,
    input wire out_ready
);
    localparam ACC_IDLE=0, ACC_COMMIT=1, ABS=2, FIND_LOCAL=3,
               FIND_GLOBAL=4, SHIFT_COARSE=5, SHIFT_FINE=6, STICKY=7, ROUND=8, HOLD=9;
    reg [3:0] state;

    wire [10:0] mw = {dw[14:10]!=0,dw[9:0]};
    wire [10:0] mx = {dx[14:10]!=0,dx[9:0]};
    wire [5:0] ew = dw[14:10]==0 ? 6'd1 : {1'b0,dw[14:10]};
    wire [5:0] ex = dx[14:10]==0 ? 6'd1 : {1'b0,dx[14:10]};
    reg [4:0] valid, first, last;
    reg [5:0] shift [0:3];
    reg [21:0] coefficient;
    reg signed [20:0] signed_dot;
    reg signed [39:0] product_lo;
    reg signed [25:0] product_hi;
    reg signed [43:0] product;
    reg signed [111:0] fine_term, term;
    wire term_ready = state == ACC_IDLE;
    wire advance = !valid[4] || term_ready;
    assign in_ready = advance;

    integer stage;
    always @(posedge clk) begin
        if (!rst_n) valid <= 0;
        else if (advance) begin
            valid <= {valid[3:0],in_valid};
            first <= {first[3:0],in_first};
            last <= {last[3:0],in_last};
            shift[0] <= ew + ex - 6'd2;
            for (stage=1; stage<4; stage=stage+1) shift[stage] <= shift[stage-1];
            coefficient <= mw * mx;
            signed_dot <= (dw[15]^dx[15]) ? -$signed(dot[20:0]) : $signed(dot[20:0]);
            product_lo <= $signed({1'b0,signed_dot[16:0]}) * $signed({1'b0,coefficient});
            product_hi <= $signed(signed_dot[20:17]) * $signed({1'b0,coefficient});
            product <= product_lo + ($signed({{18{product_hi[25]}},product_hi}) <<< 17);
            fine_term <= $signed({{68{product[43]}},product}) <<< shift[2][2:0];
            term <= fine_term <<< {shift[3][5:3],3'd0};
        end
    end

    reg [111:0] accumulator, magnitude, normalized;
    reg [28:0] chunk_sum [0:3];
    reg last_block, negative, zero;
    wire [4:0] carry;
    assign carry[0] = 0;
    genvar chunk;
    generate for (chunk=0; chunk<4; chunk=chunk+1) begin : accum
        localparam OFFSET = chunk*28;
        wire [27:0] prior = first[4] ? 28'd0 : accumulator[OFFSET+:28];
        assign carry[chunk+1] = chunk_sum[chunk][28] |
                                ((&chunk_sum[chunk][27:0]) & carry[chunk]);
        wire lower_zero;
        if (chunk==0) assign lower_zero = 1'b1;
        else assign lower_zero = ~|accumulator[OFFSET-1:0];
        always @(posedge clk) begin
            if (state==ACC_IDLE && valid[4])
                chunk_sum[chunk] <= {1'b0,prior} + {1'b0,term[OFFSET+:28]};
            if (state==ACC_COMMIT)
                accumulator[OFFSET+:28] <= chunk_sum[chunk][27:0] + carry[chunk];
            if (state==ABS)
                magnitude[OFFSET+:28] <= accumulator[111] ?
                          (~accumulator[OFFSET+:28] + lower_zero) : accumulator[OFFSET+:28];
        end
    end endgenerate

    function automatic [3:0] high_bit(input [15:0] value);
        reg [7:0] half;
        reg [3:0] quarter;
        reg [1:0] pair;
        begin
            high_bit[3] = |value[15:8];
            half = high_bit[3] ? value[15:8] : value[7:0];
            high_bit[2] = |half[7:4];
            quarter = high_bit[2] ? half[7:4] : half[3:0];
            high_bit[1] = |quarter[3:2];
            pair = high_bit[1] ? quarter[3:2] : quarter[1:0];
            high_bit[0] = pair[1];
        end
    endfunction

    reg [6:0] occupied;
    reg [3:0] local_high [0:6];
    reg [2:0] group;
    reg [6:0] norm_shift;
    reg [7:0] exponent;
    reg sticky;
    wire [6:0] highest = {group,local_high[group]};
    wire [24:0] rounded = {1'b0,normalized[111:88]} +
                          (normalized[87] && (sticky || normalized[88]));
    integer bank;
    always @* begin
        casez (occupied)
            7'b1??????: group=6;
            7'b01?????: group=5;
            7'b001????: group=4;
            7'b0001???: group=3;
            7'b00001??: group=2;
            7'b000001?: group=1;
            default: group=0;
        endcase
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ACC_IDLE;
            out_valid <= 0;
        end else case (state)
            ACC_IDLE: if (valid[4]) begin
                last_block <= last[4];
                state <= ACC_COMMIT;
            end
            ACC_COMMIT: state <= last_block ? ABS : ACC_IDLE;
            ABS: begin
                negative <= accumulator[111];
                state <= FIND_LOCAL;
            end
            FIND_LOCAL: begin
                for (bank=0; bank<7; bank=bank+1) begin
                    occupied[bank] <= |magnitude[bank*16+:16];
                    local_high[bank] <= high_bit(magnitude[bank*16+:16]);
                end
                state <= FIND_GLOBAL;
            end
            FIND_GLOBAL: begin
                zero <= !occupied;
                exponent <= 8'd79 + {1'b0,highest};
                norm_shift <= 7'd111 - highest;
                state <= SHIFT_COARSE;
            end
            SHIFT_COARSE: begin
                normalized <= magnitude << {norm_shift[6:4],4'd0};
                state <= SHIFT_FINE;
            end
            SHIFT_FINE: begin
                normalized <= normalized << norm_shift[3:0];
                state <= STICKY;
            end
            STICKY: begin
                sticky <= |normalized[86:0];
                state <= ROUND;
            end
            ROUND: begin
                if (zero) result <= 0;
                else if (rounded[24]) result <= {negative,exponent+8'd1,23'd0};
                else result <= {negative,exponent,rounded[22:0]};
                out_valid <= 1;
                state <= HOLD;
            end
            HOLD: if (out_ready) begin
                out_valid <= 0;
                state <= ACC_IDLE;
            end
            default: state <= ACC_IDLE;
        endcase
    end
endmodule
`default_nettype wire
