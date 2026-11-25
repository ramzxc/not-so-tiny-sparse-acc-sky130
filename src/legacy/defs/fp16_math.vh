// Include once inside each module that uses FP16 arithmetic.
// No global include guard: declarations belong to each including module.
    typedef logic [15:0] fp16_type;

    localparam fp16_type FP16_ZERO    = 16'h0000;
    localparam fp16_type FP16_HALF    = 16'h3800;
    localparam fp16_type FP16_ONE     = 16'h3C00;
    localparam fp16_type FP16_NEG_ONE = 16'hBC00;
    localparam fp16_type FP16_POS_INF = 16'h7C00;
    localparam fp16_type FP16_QNAN    = 16'h7E00;

    // Narrow binary16 arithmetic: 11 significand bits plus guard, round,
    // sticky and carry fit in 16 bits. Only the exact 11x11 product is wider.
    function automatic logic [15:0] fp16_rshift_jam(
        input logic [15:0] value,
        input logic [7:0] distance
    );
        logic [15:0] shifted;
        logic sticky;
    begin
        shifted = (distance < 16) ? (value >> distance) : 16'b0;
        sticky = 1'b0;
        for (int i = 0; i < 16; i++)
            if (i < distance) sticky = sticky | value[i];
        shifted[0] = shifted[0] | sticky;
        fp16_rshift_jam = shifted;
    end
    endfunction

    // Hidden bit at bit 13, G/R/S at bits 2:0; exponent uses bias 15.
    function automatic fp16_type fp16_round_pack(
        input logic sign,
        input logic [15:0] significand,
        input logic signed [7:0] exponent
    );
        logic [15:0] sig;
        logic signed [7:0] exp_work;
        logic [11:0] rounded;
    begin
        sig = significand;
        exp_work = exponent;
        if (sig[14]) begin
            sig = fp16_rshift_jam(sig, 8'd1);
            exp_work = exp_work + 8'sd1;
        end
        // A bounded priority search followed by one shift avoids a chain of
        // conditional one-bit shifters during cancellation normalization.
        begin : normalize
            logic [3:0] leading;
            logic found;
            leading = 4'd13;
            found = 1'b0;
            for (int i = 13; i >= 0; i--) begin
                if (!found && sig[i]) begin
                    leading = 4'(13-i);
                    found = 1'b1;
                end
            end
            sig = sig << leading;
            exp_work = exp_work - $signed({4'b0, leading});
        end
        if (exp_work < 1) begin
            sig = fp16_rshift_jam(sig, 8'(8'sd1 - exp_work));
            exp_work = 8'sd1;
        end
        rounded = {1'b0, sig[13:3]} +
                  {11'b0, (sig[2] && (sig[1] || sig[0] || sig[3]))};
        if (rounded[11]) begin
            rounded = rounded >> 1;
            exp_work = exp_work + 8'sd1;
        end
        if (significand == 0)
            fp16_round_pack = {sign, 15'b0};
        else if (exp_work >= 31)
            fp16_round_pack = {sign, 5'h1f, 10'b0};
        else if (!rounded[10])
            fp16_round_pack = {sign, 5'b0, rounded[9:0]};
        else
            fp16_round_pack = {sign, exp_work[4:0], rounded[9:0]};
    end
    endfunction

    function automatic fp16_type fp16_add(input fp16_type a, input fp16_type b);
        logic [15:0] big_sig, small_sig, result_sig;
        logic [4:0] big_exp, small_exp;
        logic big_sign, small_sign;
        fp16_type big_value, small_value;
    begin
        if ((a[14:10] == 31 && a[9:0] != 0) ||
            (b[14:10] == 31 && b[9:0] != 0))
            fp16_add = FP16_QNAN;
        else if (a[14:10] == 31 && b[14:10] == 31 && a[15] != b[15])
            fp16_add = FP16_QNAN;
        else if (a[14:10] == 31) fp16_add = a;
        else if (b[14:10] == 31) fp16_add = b;
        else begin
            big_value = (a[14:0] >= b[14:0]) ? a : b;
            small_value = (a[14:0] >= b[14:0]) ? b : a;
            big_sign = big_value[15];
            small_sign = small_value[15];
            big_exp = (big_value[14:10] == 0) ? 5'd1 : big_value[14:10];
            small_exp = (small_value[14:10] == 0) ? 5'd1 : small_value[14:10];
            big_sig = {2'b0, (big_value[14:10] != 0), big_value[9:0], 3'b0};
            small_sig = {2'b0, (small_value[14:10] != 0), small_value[9:0], 3'b0};
            small_sig = fp16_rshift_jam(small_sig, {3'b0,big_exp} - {3'b0,small_exp});
            result_sig = (big_sign == small_sign) ? big_sig + small_sig : big_sig - small_sig;
            // Preserve the previous helper's +zero for exact cancellation.
            fp16_add = fp16_round_pack(big_sign && (result_sig != 0), result_sig,
                                      $signed({3'b0,big_exp}));
        end
    end
    endfunction

    function automatic fp16_type fp16_mul(input fp16_type a, input fp16_type b);
        logic [10:0] sig_a, sig_b;
        logic [21:0] product, shifted;
        logic [15:0] sig;
        logic signed [7:0] exp_a, exp_b, result_exp;
        logic [4:0] msb, distance;
        logic found, sticky;
    begin
        if ((a[14:10] == 31 && a[9:0] != 0) ||
            (b[14:10] == 31 && b[9:0] != 0) ||
            (a[14:10] == 31 && b[14:0] == 0) ||
            (b[14:10] == 31 && a[14:0] == 0))
            fp16_mul = FP16_QNAN;
        else if (a[14:10] == 31 || b[14:10] == 31)
            fp16_mul = {a[15]^b[15], 5'h1f, 10'b0};
        else begin
            sig_a = {(a[14:10] != 0), a[9:0]};
            sig_b = {(b[14:10] != 0), b[9:0]};
            exp_a = (a[14:10] == 0) ? 8'sd1 : $signed({3'b0,a[14:10]});
            exp_b = (b[14:10] == 0) ? 8'sd1 : $signed({3'b0,b[14:10]});
            product = sig_a * sig_b;
            msb = 0;
            found = 0;
            for (int i = 21; i >= 0; i--) begin
                if (!found && product[i]) begin
                    msb = 5'(i);
                    found = 1;
                end
            end
            result_exp = exp_a + exp_b - 8'sd35 + $signed({3'b0,msb});
            sticky = 0;
            distance = (msb > 13) ? msb - 5'd13 : 0;
            shifted = product >> distance;
            for (int i = 0; i < 22; i++)
                if (i < distance) sticky = sticky | product[i];
            sig = (msb > 13) ? shifted[15:0] : (product[15:0] << (5'd13-msb));
            sig[0] = sig[0] | sticky;
            fp16_mul = fp16_round_pack(a[15]^b[15], sig, result_exp);
        end
    end
    endfunction

    function automatic fp16_type fp16_shift_right(input fp16_type a, input integer k);
        logic [15:0] sig;
        logic signed [7:0] exponent;
    begin
        if (a[14:10] == 31 && a[9:0] != 0)
            fp16_shift_right = FP16_QNAN;
        else if (a[14:10] == 31 || a[14:0] == 0)
            fp16_shift_right = a;
        // Saturate before narrowing the public integer shift argument.
        else if (k > 64) fp16_shift_right = {a[15],15'b0};
        else if (k < -64) fp16_shift_right = {a[15],5'h1f,10'b0};
        else begin
            sig = {2'b0, (a[14:10] != 0), a[9:0], 3'b0};
            exponent = (a[14:10] == 0) ? 8'sd1 : $signed({3'b0,a[14:10]});
            fp16_shift_right = fp16_round_pack(a[15], sig, exponent - 8'(k));
        end
    end
    endfunction

    //////////////////
    //              //
    //      FP RELU //
    //              //
    //////////////////

    function automatic fp16_type fp16_relu(input fp16_type x);
    begin
        if ((x[14:10] == 5'h1F) && (x[9:0] != 0))
            fp16_relu = FP16_QNAN;
        else if (x[15])
            fp16_relu = FP16_ZERO;
        else
            fp16_relu = x;
    end
    endfunction

    ///////////////////////
    //                   //
    //      FP SIGMOID   //
    //                   //
    ///////////////////////

    // Tiny hard activations, evaluated with binary16 arithmetic.
    // Sigmoid = clamp(round16(round16(x/4) + 0.5), 0, 1).
    function automatic fp16_type fp16_sigmoid(input fp16_type x);
        fp16_type y;
    begin
        y = fp16_add(fp16_shift_right(x, 2), FP16_HALF);
        if (x[14:10] == 31 && x[9:0] != 0) fp16_sigmoid = FP16_QNAN;
        else if (y[15]) fp16_sigmoid = FP16_ZERO;
        else if (y[14:0] > FP16_ONE[14:0]) fp16_sigmoid = FP16_ONE;
        else fp16_sigmoid = y;
    end
    endfunction

    // Tanh = clamp(x, -1, 1); preserve signed zero.
    function automatic fp16_type fp16_tanh(input fp16_type x);
    begin
        if (x[14:10] == 31 && x[9:0] != 0) fp16_tanh = FP16_QNAN;
        else if (x[14:0] > FP16_ONE[14:0]) fp16_tanh = {x[15], FP16_ONE[14:0]};
        else fp16_tanh = x;
    end
    endfunction

    function automatic fp16_type fp16_heaviside_step(input fp16_type x);
    begin
        if (x[14:10] == 31 && x[9:0] != 0) fp16_heaviside_step = FP16_QNAN;
        else fp16_heaviside_step = !x[15] && x[14:0] != 0 ? FP16_ONE : FP16_ZERO;
    end
    endfunction

    // Preserve existing activation codes while dropping unused TPU modes.
    typedef enum logic [3:0] {
        no_activation = 4'd0,
        relu = 4'd1,
        sigmoid = 4'd9,
        tanh = 4'd10,
        heaviside_step = 4'd11
    } activation_type;
