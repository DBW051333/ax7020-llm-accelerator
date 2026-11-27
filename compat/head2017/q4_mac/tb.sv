`timescale 1ns/1ps
module tb #(parameter COLUMNS=2);
    localparam INPUTS=19*32*COLUMNS+2*19*17, OUTPUTS=38;
    reg clk=0, reset_n=0;
    always #5 clk=~clk;
    reg [63:0] stimulus [0:INPUTS-1], expected [0:OUTPUTS-1];
    reg [31:0] rng=32'hb671acf3;
    integer sent=0, received=0, cycles=0, total_sent=0, total_received=0;
    reg input_valid=0, output_ready=0, accepted=0;
    wire input_ready, output_valid, output_last, irq;
    wire [63:0] result;
    wire [63:0] data = stimulus[sent];
    decode_lane #(.COLUMNS(COLUMNS)) dut(clk, reset_n, data, input_valid,
        sent==INPUTS-1, input_ready, result, output_valid, output_last, output_ready, irq);
    initial begin
        $readmemh("stream.hex",stimulus);
        $readmemh("expected.hex",expected);
        repeat (5) @(negedge clk);
        reset_n=1;
    end
    always @(negedge clk) if (reset_n) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        if (!input_valid || accepted)
            input_valid=rng[4:0]!=0 && total_sent < 2*INPUTS;
        output_ready=rng[2:0]==0;
    end

    always @(posedge clk) if (reset_n) begin
        cycles <= cycles+1;
        accepted <= input_valid && input_ready;
        if (input_valid && input_ready) begin
            sent <= sent==INPUTS-1 ? 0 : sent+1;
            total_sent <= total_sent+1;
        end
        if (output_valid && output_ready) begin
            if (result !== expected[received] || output_last !== (received==OUTPUTS-1))
                $fatal(1,"Mismatch index=%d expected=%h actual=%h last=%b",received,expected[received],result,output_last);
            if (total_received==2*OUTPUTS-1) begin
                $display("Q4-MAC-PASS columns=%0d words=%0d results=%0d cycles=%0d",COLUMNS,total_sent,2*OUTPUTS,cycles);
                $finish;
            end
            total_received <= total_received+1;
            received <= received==OUTPUTS-1 ? 0 : received+1;
        end
        if (cycles > 15000) $fatal(1,"Timeout");
    end
endmodule

module tb_one; tb #(.COLUMNS(1)) check(); endmodule
module tb_two; tb #(.COLUMNS(2)) check(); endmodule
