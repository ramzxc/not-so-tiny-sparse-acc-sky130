// Include inside each module that uses FP8 arithmetic.
    // FP8 E4M3FN arithmetic adapted from acc/lib/tpu_pkg.sv.
    // Round to nearest, ties to even; finite saturation and canonical NaN.
    typedef logic [7:0] fp8_type;
    localparam fp8_type FP8_ZERO = 8'h00, FP8_QNAN = 8'h7f;

    function automatic logic fp8_is_nan(input logic [6:0] magnitude);
        return magnitude == 7'h7f;
    endfunction
    // Eight-bit alignment with sticky-bit jamming (4-bit significand + G/R/S).
    function automatic logic [7:0] fp8_jam8(input logic [7:0] x, input logic [4:0] n);
        case (n)
            0: return x;
            1: return {1'b0, x[7:2], (x[1] | x[0])};
            2: return {2'b0, x[7:3], (|x[2:0])};
            3: return {3'b0, x[7:4], (|x[3:0])};
            4: return {4'b0, x[7:5], (|x[4:0])};
            5: return {5'b0, x[7:6], (|x[5:0])};
            6: return {6'b0, x[7], (|x[6:0])};
            default: return {7'b0, (|x)};
        endcase
    endfunction

    function automatic fp8_type fp8_add(input fp8_type a, b);
        fp8_type hi_operand, lo_operand;
        logic [4:0] el, es, exponent, rounded;
        logic [3:0] ml, ms;
        logic [7:0] aligned, total;
        logic subtract;
        logic [2:0] leading_zeros, normalize_shift;
        begin
            if (fp8_is_nan(a[6:0]) || fp8_is_nan(b[6:0])) return FP8_QNAN;
            hi_operand = (a[6:0] >= b[6:0]) ? a : b;
            lo_operand = (a[6:0] >= b[6:0]) ? b : a;
            el = (hi_operand[6:3] == 0) ? 5'd1 : {1'b0, hi_operand[6:3]};
            es = (lo_operand[6:3] == 0) ? 5'd1 : {1'b0, lo_operand[6:3]};
            ml = {(hi_operand[6:3] != 0), hi_operand[2:0]};
            ms = {(lo_operand[6:3] != 0), lo_operand[2:0]};
            aligned = fp8_jam8({1'b0, ms, 3'b000}, el - es);
            // One add/subtract datapath: invert B and use carry-in for subtraction.
            subtract = hi_operand[7] ^ lo_operand[7];
            total = {1'b0, ml, 3'b000} + (aligned ^ {8{subtract}}) + 8'(subtract);
            if (total == 0) return (a[7] && b[7]) ? 8'h80 : FP8_ZERO;
            exponent = el;
            if (total[7]) begin
                total = fp8_jam8(total, 5'd1);
                exponent = exponent + 1'b1;
            end
            // Normalize once, limited by the minimum normal exponent.
            casez (total[6:0])
                7'b1??????: leading_zeros = 0;
                7'b01?????: leading_zeros = 1;
                7'b001????: leading_zeros = 2;
                7'b0001???: leading_zeros = 3;
                7'b00001??: leading_zeros = 4;
                7'b000001?: leading_zeros = 5;
                default:    leading_zeros = 6;
            endcase
            normalize_shift = ({2'b0, leading_zeros} < exponent)
                ? leading_zeros : 3'(exponent - 1'b1);
            total = total << normalize_shift;
            exponent = exponent - {2'b0, normalize_shift};
            rounded = {1'b0, total[6:3]} + 5'(total[2] && (total[1] || total[0] || total[3]));
            if (rounded[4]) begin
                rounded  = rounded >> 1;
                exponent = exponent + 1'b1;
            end
            if (exponent > 15 || (exponent == 15 && rounded > 14)) return {hi_operand[7], 7'h7e};
            if (exponent == 1 && rounded < 8) return {hi_operand[7], 4'b0, rounded[2:0]};
            return {hi_operand[7], exponent[3:0], rounded[2:0]};
        end
    endfunction

    // Eight-bit product packer: select retained/guard/sticky bits directly.
    // No remainder subtractor or variable-width halfway calculation.
    function automatic fp8_type fp8_pack8(input logic sign, input logic [7:0] magnitude,
                                          input logic signed [6:0] scale);
        logic [2:0] msb;
        logic signed [6:0] exponent, shift;
        logic [3:0] retained, encoded;
        logic guard_bit, sticky;
        logic [4:0] rounded;
        begin
            if (magnitude == 0) return {sign, 7'b0};
            casez (magnitude)
                8'b1???????: msb = 7;
                8'b01??????: msb = 6;
                8'b001?????: msb = 5;
                8'b0001????: msb = 4;
                8'b00001???: msb = 3;
                8'b000001??: msb = 2;
                8'b0000001?: msb = 1;
                default:     msb = 0;
            endcase
            exponent = $signed({4'b0, msb}) + scale;
            if (exponent > 8) return {sign, 7'h7e};
            shift = (exponent >= -6) ? $signed({4'b0, msb}) - 7'sd3 : -7'sd9 - scale;
            retained = 0;
            guard_bit = 0;
            sticky = 0;
            // In-range retained significands fit in four bits. Negative shifts
            // only occur for magnitudes whose leading bit is below bit 3.
            case (shift)
                -7'sd3: retained = {magnitude[0], 3'b0};
                -7'sd2: retained = {magnitude[1:0], 2'b0};
                -7'sd1: retained = {magnitude[2:0], 1'b0};
                0: retained = magnitude[3:0];
                1: begin retained = magnitude[4:1]; guard_bit = magnitude[0]; end
                2: begin retained = magnitude[5:2]; guard_bit = magnitude[1]; sticky = magnitude[0]; end
                3: begin retained = magnitude[6:3]; guard_bit = magnitude[2]; sticky = |magnitude[1:0]; end
                4: begin retained = magnitude[7:4]; guard_bit = magnitude[3]; sticky = |magnitude[2:0]; end
                5: begin retained = {1'b0, magnitude[7:5]}; guard_bit = magnitude[4]; sticky = |magnitude[3:0]; end
                6: begin retained = {2'b0, magnitude[7:6]}; guard_bit = magnitude[5]; sticky = |magnitude[4:0]; end
                7: begin retained = {3'b0, magnitude[7]}; guard_bit = magnitude[6]; sticky = |magnitude[5:0]; end
                8: begin guard_bit = magnitude[7]; sticky = |magnitude[6:0]; end
                default: begin end // Magnitude is below half the smallest subnormal.
            endcase
            rounded = {1'b0, retained} + 5'(guard_bit && (sticky || retained[0]));
            if (exponent < -6) begin
                if (rounded >= 8) return {sign, 7'h08};
                return {sign, 4'b0, rounded[2:0]};
            end
            if (rounded[4]) begin
                rounded = rounded >> 1;
                exponent = exponent + 1'b1;
            end
            if (exponent > 8 || (exponent == 8 && rounded > 14)) return {sign, 7'h7e};
            encoded = 4'(exponent + 7'sd7);
            return {sign, encoded, rounded[2:0]};
        end
    endfunction

    function automatic fp8_type fp8_mul(input fp8_type a, b);
        logic [3:0] ma, mb;
        logic [7:0] product;
        logic signed [6:0] ea, eb;
        begin
            if (fp8_is_nan(a[6:0]) || fp8_is_nan(b[6:0])) return FP8_QNAN;
            ma = {(a[6:3] != 0), a[2:0]};
            mb = {(b[6:3] != 0), b[2:0]};
            ea = (a[6:3] == 0) ? -7'sd9 : $signed({3'b0, a[6:3]}) - 7'sd10;
            eb = (b[6:3] == 0) ? -7'sd9 : $signed({3'b0, b[6:3]}) - 7'sd10;
            product = ma * mb;
            return fp8_pack8(a[7] ^ b[7], product, ea + eb);
        end
    endfunction
