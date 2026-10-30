// q58_dot32: 32-element int8 dot product MAC (line-rate handshake revision).
// Same arithmetic as the delivery snapshot: per-beat 8 int8 products,
// product register stage, sequential accumulation, one result per 4 beats.
// Changed only the handshake: the product slot may be refilled on the same
// edge its contents are consumed, so one beat is accepted every cycle and
// a block result never stalls the next block's first beats. Accumulation
// order and values are bit-identical to the original module.
module q58_dot32 (
    input  wire               clk,
    input  wire               rst_n,
    input  wire [63:0]        w_data,
    input  wire [63:0]        x_data,
    input  wire               in_valid,
    output wire               in_ready,
    output reg  signed [31:0] result,
    output reg                out_valid,
    input  wire               out_ready
);

    wire signed [7:0] w0 = w_data[7:0];
    wire signed [7:0] w1 = w_data[15:8];
    wire signed [7:0] w2 = w_data[23:16];
    wire signed [7:0] w3 = w_data[31:24];
    wire signed [7:0] w4 = w_data[39:32];
    wire signed [7:0] w5 = w_data[47:40];
    wire signed [7:0] w6 = w_data[55:48];
    wire signed [7:0] w7 = w_data[63:56];

    wire signed [7:0] x0 = x_data[7:0];
    wire signed [7:0] x1 = x_data[15:8];
    wire signed [7:0] x2 = x_data[23:16];
    wire signed [7:0] x3 = x_data[31:24];
    wire signed [7:0] x4 = x_data[39:32];
    wire signed [7:0] x5 = x_data[47:40];
    wire signed [7:0] x6 = x_data[55:48];
    wire signed [7:0] x7 = x_data[63:56];

    wire signed [15:0] p0 = w0 * x0;
    wire signed [15:0] p1 = w1 * x1;
    wire signed [15:0] p2 = w2 * x2;
    wire signed [15:0] p3 = w3 * x3;
    wire signed [15:0] p4 = w4 * x4;
    wire signed [15:0] p5 = w5 * x5;
    wire signed [15:0] p6 = w6 * x6;
    wire signed [15:0] p7 = w7 * x7;

    reg signed [15:0] q0, q1, q2, q3, q4, q5, q6, q7;
    reg               q_valid;
    reg               q_last;

    reg  signed [21:0] acc;
    reg  [1:0]         beat_cnt;

    wire signed [18:0] q_sum   = q0 + q1 + q2 + q3 + q4 + q5 + q6 + q7;
    wire signed [22:0] dot_sum = acc + q_sum;

    // The slot frees this edge when it is empty, holds a non-final beat that
    // the accumulate stage consumes now, or holds a final beat while no
    // result is pending (result is produced and the slot refilled at once).
    // Only a final beat with an unconsumed result blocks new beats.
    wire consume = q_valid && (!q_last || !out_valid);
    assign in_ready = consume || !q_valid;

    always @(posedge clk) begin
        if (!rst_n) begin
            q_valid   <= 1'b0;
            q_last    <= 1'b0;
            beat_cnt  <= 2'd0;
            acc       <= '0;
            out_valid <= 1'b0;
            result    <= '0;
            q0 <= '0; q1 <= '0; q2 <= '0; q3 <= '0;
            q4 <= '0; q5 <= '0; q6 <= '0; q7 <= '0;
        end else begin
            // Accumulate stage: consume registered products (reads old q*)
            if (consume) begin
                q_valid <= 1'b0;
                if (q_last) begin
                    if (!out_valid) begin
                        result    <= {{9{dot_sum[22]}}, dot_sum};
                        out_valid <= 1'b1;
                    end
                    acc       <= '0;
                end else begin
                    acc <= acc + q_sum;
                end
            end

            // Input stage: accept one beat (written after accumulate on purpose)
            if (in_valid && in_ready) begin
                q_valid  <= 1'b1;
                q_last   <= (beat_cnt == 2'd3);
                q0 <= p0; q1 <= p1; q2 <= p2; q3 <= p3;
                q4 <= p4; q5 <= p5; q6 <= p6; q7 <= p7;
                beat_cnt <= beat_cnt + 2'd1;
            end

            // Output handshake
            if (out_valid && out_ready) begin
                out_valid <= 1'b0;
            end
        end
    end

endmodule
