`timescale 1ns/1ps
module tb_fp8_math;
    `include "defs/fp8_math.vh"
    reg [15:0] binary_vectors [0:65535];
    reg [7:0] pack_vectors [0:7423];
    string binary_path, pack_path;
    reg [7:0] got_add, got_mul, got_pack, expected_pack;
    initial begin
        if (!$value$plusargs("binary=%s",binary_path) || !$value$plusargs("pack=%s",pack_path))
            $fatal(1,"Missing reference vectors");
        $readmemh(binary_path,binary_vectors);
        $readmemh(pack_path,pack_vectors);
        for (integer a=0; a<256; a++) begin
            for (integer b=0; b<256; b++) begin
                got_add=fp8_add(8'(a),8'(b));
                got_mul=fp8_mul(8'(a),8'(b));
                if ({got_add,got_mul} !== binary_vectors[a*256+b])
                    $fatal(1,"a=%h b=%h got=%h expected=%h",8'(a),8'(b),{got_add,got_mul},binary_vectors[a*256+b]);
            end
        end
        // Every 8-bit magnitude and the complete scale range produced by MUL.
        for (integer scale=-18; scale<=10; scale++) begin
            for (integer magnitude=0; magnitude<256; magnitude++) begin
                for (integer sign=0; sign<2; sign++) begin
                    got_pack=fp8_pack8(1'(sign),8'(magnitude),7'(scale));
                    expected_pack=pack_vectors[(scale+18)*256+magnitude] | (sign ? 8'h80 : 8'h00);
                    if (got_pack !== expected_pack)
                        $fatal(1,"pack sign=%0d magnitude=%0d scale=%0d got=%h expected=%h",sign,magnitude,scale,got_pack,expected_pack);
                end
            end
        end
        $display("PASS FP8 math: 65,536 ADD + 65,536 MUL + 14,848 pack cases, exact rational RNE reference");
        $finish;
    end
endmodule
