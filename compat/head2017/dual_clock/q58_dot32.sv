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
    reg q_valid, q_last;
    reg [1:0] beat_count;
    reg signed [18:0] beat_sum;
    reg sum_valid, sum_last;
    reg signed [21:0] acc;

    wire signed [16:0] pair0 = q0 + q1;
    wire signed [16:0] pair1 = q2 + q3;
    wire signed [16:0] pair2 = q4 + q5;
    wire signed [16:0] pair3 = q6 + q7;
    wire signed [17:0] half0 = pair0 + pair1;
    wire signed [17:0] half1 = pair2 + pair3;
    wire signed [22:0] next_sum = acc + beat_sum;

    wire pop_sum = sum_valid && (!sum_last || !out_valid || out_ready);
    wire move_products = q_valid && (!sum_valid || pop_sum);
    assign in_ready = !q_valid || move_products;

    always @(posedge clk) begin
        if (!rst_n) begin
            q_valid <= 0;
            sum_valid <= 0;
            out_valid <= 0;
            beat_count <= 0;
            acc <= 0;
        end else begin
            if (out_ready) out_valid <= 0;
            if (pop_sum) begin
                sum_valid <= 0;
                if (sum_last) begin
                    result <= {{9{next_sum[22]}}, next_sum};
                    out_valid <= 1;
                    acc <= 0;
                end else acc <= next_sum[21:0];
            end
            if (move_products) begin
                q_valid <= 0;
                sum_valid <= 1;
                sum_last <= q_last;
                beat_sum <= half0 + half1;
            end
            if (in_valid && in_ready) begin
                q_valid <= 1;
                q_last <= beat_count == 3;
                beat_count <= beat_count + 1'b1;
                q0 <= p0; q1 <= p1; q2 <= p2; q3 <= p3;
                q4 <= p4; q5 <= p5; q6 <= p6; q7 <= p7;
            end
        end
    end

endmodule
