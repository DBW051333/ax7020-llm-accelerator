`timescale 1ns/1ps
module tb_normalization;
    reg signed [55:0] q18;
    reg [5:0] scale;
    reg signed [23:0] integer_value;
    wire [31:0] q18_float, scale_float, integer_float;
    reg [191:0] vectors [0:2047];
    integer index, count;
    int56_to_fp32 fixed_converter(.v(q18), .f(q18_float));
    int_to_fp32 #(.W(6), .SIGNED_IN(0)) scale_converter(.v(scale), .f(scale_float));
    int_to_fp32 #(.W(24), .SIGNED_IN(1)) integer_converter(.v(integer_value), .f(integer_float));
    initial begin
        $readmemh("normalization.hex", vectors);
        count = vectors[0][31:0];
        for (index=1; index<=count; index=index+1) begin
            {q18, integer_value, scale} = vectors[index][181:96];
            #1;
            if (q18_float !== vectors[index][95:64] ||
                integer_float !== vectors[index][63:32] ||
                scale_float !== vectors[index][31:0]) begin
                $fatal(1,"NORMALIZATION-FAIL index=%0d q18=%h integer=%h scale=%h",index,q18_float,integer_float,scale_float);
            end
        end
        $display("NORMALIZATION-PASS %0d vectors",count);
        $finish;
    end
endmodule
