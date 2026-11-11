// THIS TPU consists of following components
// - DRAM
// - Weight Buffer (WB) / Weight Cache
// - Unified Buffer (UB): Stores Input & Output
// - Accumulation Buffer (AB): Stores partial output
// - Activation (Act): Activation functional unit
// - Vector Processor (VPU): Vector processor
`ifndef ACC_SRAM_BYTES
`define ACC_SRAM_BYTES 512
`endif
package tpu_pkg;
    localparam int DEFAULT_SRAM_BYTES = `ACC_SRAM_BYTES;

    // DRAM remains byte-addressable. BYTE_WIDTH is the addressable storage unit,
    // while every TPU architectural data element is IEEE-754 binary16 (FP16).
    // FIXME -> fixed point & run-time configurable quantization
    parameter int BYTE_WIDTH              = 8;
    parameter int FP16_WIDTH              = 16;
    parameter int FP16_BYTES              = FP16_WIDTH / BYTE_WIDTH;

    ////////////////////////////////========
    //                                    //
    //      Instruction format bitwidth   //
    //                                    //
    ////////////////////////////////========

    parameter int INSTRUCTION_WIDTH      = 64;
    parameter int BUFFER_ADDR_WIDTH      = 16;
    parameter int ACCUMULATOR_ADDR_WIDTH = 8;
    parameter int WEIGHT_ADDR_WIDTH      = 24;
    parameter int DRAM_ADDR_WIDTH        = 32;
    parameter int OPCODE_WIDTH           = 8;
    parameter int LENGTH_WIDTH           = 8;

    ////////////////////////////
    //                        //
    //      ISA OPCODE LIST   //
    //                        //
    ////////////////////////////

    // Nop
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_NOP        = 8'h00;
    // Halt the operation
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_HALT       = 8'h02;

    // Perform an activation function
    // From AB -> Act -> UB
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_ACTIVATE    = 8'h80;
    // Execute VPU (Vector MAC Unit)
    // - (Use preloaded weight)
    // - Load data from the UB
    // - Store/Accumulate results to the AB
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_VPU        = 8'h20;
    // Transfer data from the WB -> VPU
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_WEIGHT     = 8'h08;
    // Transfer data from the UB -> VPU
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_INPUT      = 8'h10;

    localparam logic [OPCODE_WIDTH-1:0] OPCODE_VPU_VEC_MUL = 8'h20; // 0010_0000
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_VPU_VEC_ADD = 8'h22; // 0010_0010
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_VPU_VEC_SUB = 8'h24; // 0010_0100

    localparam logic [OPCODE_WIDTH-1:0] OPCODE_VPU_SCALAR_MUL = 8'h30; // 0011_0000
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_VPU_SCALAR_ADD = 8'h32; // 0011_0010
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_VPU_SCALAR_SUB = 8'h34; // 0011_0100

    // Memory transfer ISA
    // SRC_TO_DST
    // the last three bits become the sub-opcode
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_MEM            = 8'h40;
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_DRAM_TO_BUFFER = 8'h40;
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_DRAM_TO_WEIGHT = 8'h41;
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_BUFFER_TO_DRAM = 8'h42;
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_ACC_TO_DRAM    = 8'h43;
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_DRAM_TO_ACC    = 8'h44;

    // Synchronize
    // The host waits for the TPU until it flushes the instructions
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_SYNCHRONIZE = 8'hFF;

    ////////////////////////////
    //                        //
    //      TYPE DEFINITION   //
    //                        //
    ////////////////////////////

    // Byte type is used only by the byte-addressable DRAM model and beat packers.
    typedef logic [BYTE_WIDTH-1:0] byte_type;

    // All architectural operands/results use FP16.
    typedef logic [FP16_WIDTH-1:0] fp16_type;

    // Address types for the buffers and dram
    typedef logic [BUFFER_ADDR_WIDTH-1:0]      buffer_addr_type;
    typedef logic [DRAM_ADDR_WIDTH-1:0]        dram_addr_type;
    typedef logic [ACCUMULATOR_ADDR_WIDTH-1:0] accumulator_addr_type;
    typedef logic [WEIGHT_ADDR_WIDTH-1:0]      weight_addr_type;

    // Cache Replacement Policy Type (3 bits for 5 policies)
    typedef enum logic [2:0] {
        POLICY_DECAYED_LFU, // Baseline 1: Decayed LFU
        POLICY_SLRU,        // Baseline 2: Segmented LRU (Scan-Resistant)
        POLICY_FIFO,        // Ultra-low power fallback
        POLICY_CUSTOM,      // Custom Hybrid Policy (Transplanted from C++)
        POLICY_RANDOM       // Random Replacement
    } repl_policy_e;

    ////////////////////////////////
    //                            //
    //      CONSTANT DEFINITION   //
    //                            //
    ////////////////////////////////

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

    function automatic fp16_type fp16_sigmoid(input fp16_type x);
        fp16_type abs_x;
        fp16_type pwl_pos;
        fp16_type neg_pwl;
    begin
        if ((x[14:10] == 5'h1F) && (x[9:0] != 0)) begin
            fp16_sigmoid = FP16_QNAN;
        end
        else if ({1'b0, x[14:0]} >= 16'h4500)  begin
            fp16_sigmoid = x[15] ? FP16_ZERO : FP16_ONE;
        end
        else begin
            abs_x = {1'b0, x[14:0]};
            if (abs_x < 16'h3C00) begin
                pwl_pos = fp16_add(fp16_shift_right(abs_x, 2), FP16_HALF);
            end
            else if (abs_x < 16'h40C0) begin
                pwl_pos = fp16_add(fp16_shift_right(abs_x, 3), 16'h3900);
            end
            else begin
                pwl_pos = fp16_add(fp16_shift_right(abs_x, 5), 16'h3AC0);
            end

            if (x[15]) begin
                neg_pwl = {~pwl_pos[15], pwl_pos[14:0]};
                fp16_sigmoid = fp16_add(FP16_ONE, neg_pwl);
            end
            else begin
                fp16_sigmoid = pwl_pos;
            end
        end
    end
    endfunction

    //////////////////
    //              //
    //      FP TANH //
    //              //
    //////////////////

    function automatic fp16_type fp16_tanh(input fp16_type x);
        fp16_type x_mult2;
        fp16_type sig_val;
        fp16_type two_sig;
    begin
        if ((x[14:10] == 5'h1F) && (x[9:0] != 0)) begin
            fp16_tanh = FP16_QNAN;
        end
        else if ({1'b0, x[14:0]} >= 16'h4200) begin
            fp16_tanh = x[15] ? FP16_NEG_ONE : FP16_ONE;
        end
        else begin
            x_mult2 = fp16_shift_right(x, -1);
            sig_val = fp16_sigmoid(x_mult2);

            two_sig = fp16_shift_right(sig_val, -1);

            fp16_tanh = fp16_add(two_sig, FP16_NEG_ONE);
        end
    end
    endfunction

    //////////////////////////////
    //                          //
    //    FP16 Heaviside Step   //
    //                          //
    //////////////////////////////

    function automatic fp16_type fp16_heaviside_step(input fp16_type x);
    begin
        if (x[15] == 1'b0 && (x[14:0] != '0)) 
            fp16_heaviside_step = FP16_ONE;
        else
            fp16_heaviside_step = FP16_ZERO;
    end
    endfunction

    typedef enum logic [3:0] {
        no_activation,
        relu,
        relu6,
        crelu,
        elu,
        selu,
        softplus,
        softsign,
        dropout,
        sigmoid,
        tanh,
        heaviside_step
    } activation_type;

    typedef enum logic [2:0] {
        mem_op_load_buffer,
        mem_op_load_weight,
        mem_op_store_buffer,
        mem_op_store_acc,
        mem_op_load_acc,
        mem_op_none
    } memory_op_type;

    typedef enum logic [2:0] {
        vpu_op_mul,
        vpu_op_add,
        vpu_op_sub,
        vpu_op_none
    } vpu_op_type;

    typedef struct packed {
        logic [INSTRUCTION_WIDTH-LENGTH_WIDTH-OPCODE_WIDTH-1:0] empty;
        logic [LENGTH_WIDTH-1:0] length;
        logic [OPCODE_WIDTH-1:0] opcode;
    } inst_type;

    typedef struct packed {
        logic [INSTRUCTION_WIDTH-WEIGHT_ADDR_WIDTH-BUFFER_ADDR_WIDTH-1-OPCODE_WIDTH-1:0] empty;
        logic [WEIGHT_ADDR_WIDTH-1:0] weight_addr;
        logic [BUFFER_ADDR_WIDTH-1:0] unified_addr;
        logic is_unified;
        logic [OPCODE_WIDTH-1:0] opcode;
    } weight_inst_type;

    typedef struct packed {
        logic [INSTRUCTION_WIDTH-BUFFER_ADDR_WIDTH-OPCODE_WIDTH-1:0] empty;
        logic [BUFFER_ADDR_WIDTH-1:0] input_addr;
        logic [OPCODE_WIDTH-1:0] opcode;
    } input_inst_type;

    typedef struct packed {
        logic [INSTRUCTION_WIDTH-BUFFER_ADDR_WIDTH-ACCUMULATOR_ADDR_WIDTH-LENGTH_WIDTH-OPCODE_WIDTH-1:0] empty;
        logic [BUFFER_ADDR_WIDTH-1:0] buffer_addr;
        logic [ACCUMULATOR_ADDR_WIDTH-1:0] acc_addr;
        logic [LENGTH_WIDTH-1:0] length;
        logic [OPCODE_WIDTH-1:0] opcode;
    } vpu_inst_type;

    typedef struct packed {
        logic [DRAM_ADDR_WIDTH-1:0] dram_addr;
        logic [BUFFER_ADDR_WIDTH-1:0] sram_addr;
        logic [LENGTH_WIDTH-1:0] length;
        logic [OPCODE_WIDTH-1:0] opcode;
    } dram_inst_type;

    typedef struct packed {
        logic [INSTRUCTION_WIDTH-BUFFER_ADDR_WIDTH-ACCUMULATOR_ADDR_WIDTH-LENGTH_WIDTH-OPCODE_WIDTH-1:0] empty;
        logic [BUFFER_ADDR_WIDTH-1:0] buffer_addr;
        logic [ACCUMULATOR_ADDR_WIDTH-1:0] acc_addr;
        logic [LENGTH_WIDTH-1:0] length;
        logic [OPCODE_WIDTH-1:0] opcode;
    } activate_inst_type;

    typedef union packed {
        inst_type          generic;
        weight_inst_type   weight;
        vpu_inst_type      vpu;
        dram_inst_type     dram;
        activate_inst_type activate;
        logic [INSTRUCTION_WIDTH-1:0] raw;
    } instruction_union_type;

endpackage
