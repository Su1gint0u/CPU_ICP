// Self-contained RV32F single-precision unit for the approval instruction set.
// Supported FP ops: FCVT.S.W[U], FCVT.W[U].S, FADD.S, FSUB.S, FMUL.S,
// FDIV.S and FSQRT.S. FLW/FSW are handled by the existing LSU/FRF path.
module fpu_wrapper (
    input  logic        pl_clk,
    input  logic        pl_resetn,
    input  logic        redirect_valid,
    input  logic        idex_valid,
    input  logic [31:0] idex_pc,
    input  logic [31:0] inst,
    input  logic [31:0] frs1,
    input  logic [31:0] frs2,
    input  logic [31:0] frs3,
    input  logic [31:0] irs1,
    input  logic [2:0]  frm_csr,
    output logic [31:0] result,
    output logic        illegal,
    output logic [4:0]  fflags,
    output logic        stall_fp
);

    localparam logic [31:0] CANON_QNAN = 32'h7fc0_0000;
    localparam logic [31:0] POS_INF    = 32'h7f80_0000;
    localparam logic [31:0] NEG_INF    = 32'hff80_0000;

    localparam logic [4:0] FF_NX = 5'b00001;
    localparam logic [4:0] FF_UF = 5'b00010;
    localparam logic [4:0] FF_OF = 5'b00100;
    localparam logic [4:0] FF_DZ = 5'b01000;
    localparam logic [4:0] FF_NV = 5'b10000;

    typedef struct packed {
        logic [31:0] bits;
        logic [4:0]  flags;
    } fp_out_t;

    wire [6:0] op  = inst[6:0];
    wire [2:0] f3  = inst[14:12];
    wire [4:0] rs2 = inst[24:20];
    wire [6:0] f7  = inst[31:25];

    wire [2:0] rm_eff = (f3 == 3'b111) ? frm_csr : f3;
    wire       rm_bad = (rm_eff == 3'b101) || (rm_eff == 3'b110);

    wire legal_fadd  = (op == 7'b1010011) && (f7 == 7'h00);
    wire legal_fsub  = (op == 7'b1010011) && (f7 == 7'h04);
    wire legal_fmul  = (op == 7'b1010011) && (f7 == 7'h08);
    wire legal_fdiv  = (op == 7'b1010011) && (f7 == 7'h0C);
    wire legal_fsqrt = (op == 7'b1010011) && (f7 == 7'h2C) && (rs2 == 5'd0);
    wire legal_i2f   = (op == 7'b1010011) && (f7 == 7'h68) && ((rs2 == 5'd0) || (rs2 == 5'd1));
    wire legal_f2i   = (op == 7'b1010011) && (f7 == 7'h60) && ((rs2 == 5'd0) || (rs2 == 5'd1));
    wire legal_fp_op = legal_fadd || legal_fsub || legal_fmul || legal_fdiv || legal_fsqrt
        || legal_i2f || legal_f2i;

    always_comb begin
        illegal = 1'b0;
        if (op != 7'b1010011)
            illegal = 1'b1;
        else if (!legal_fp_op)
            illegal = 1'b1;
        else if (rm_bad)
            illegal = 1'b1;
    end

    function automatic logic fp_is_nan(input logic [31:0] x);
        fp_is_nan = (x[30:23] == 8'hff) && (x[22:0] != 23'd0);
    endfunction

    function automatic logic fp_is_snan(input logic [31:0] x);
        fp_is_snan = fp_is_nan(x) && !x[22];
    endfunction

    function automatic logic fp_is_inf(input logic [31:0] x);
        fp_is_inf = (x[30:23] == 8'hff) && (x[22:0] == 23'd0);
    endfunction

    function automatic logic fp_is_zero(input logic [31:0] x);
        fp_is_zero = (x[30:23] == 8'd0) && (x[22:0] == 23'd0);
    endfunction

    function automatic logic [23:0] fp_mant24(input logic [31:0] x);
        fp_mant24 = (x[30:23] == 8'd0) ? {1'b0, x[22:0]} : {1'b1, x[22:0]};
    endfunction

    function automatic logic [26:0] shr_jam27(input logic [26:0] v, input int unsigned sh);
        logic sticky;
        if (sh == 0) begin
            shr_jam27 = v;
        end else if (sh >= 27) begin
            shr_jam27 = {26'd0, |v};
        end else begin
            sticky = |(v & ((27'd1 << sh) - 27'd1));
            shr_jam27 = (v >> sh);
            shr_jam27[0] = shr_jam27[0] | sticky;
        end
    endfunction

    function automatic logic round_inc(
        input logic sign,
        input logic [2:0] rm,
        input logic lsb,
        input logic guard,
        input logic round_bit,
        input logic sticky
    );
        logic any;
        begin
            any = guard | round_bit | sticky;
            unique case (rm)
                3'b000: round_inc = guard && (round_bit || sticky || lsb); // RNE
                3'b001: round_inc = 1'b0;                                  // RTZ
                3'b010: round_inc = sign && any;                            // RDN
                3'b011: round_inc = !sign && any;                           // RUP
                3'b100: round_inc = guard;                                  // RMM
                default: round_inc = 1'b0;
            endcase
        end
    endfunction

    function automatic fp_out_t pack_round(
        input logic       sign,
        input int         exp_i,
        input logic [26:0] mant_ext,
        input logic [2:0] rm
    );
        fp_out_t r;
        logic inc;
        logic [24:0] rounded;
        logic [7:0] exp_bits;
        logic inexact;
        int exp_work;
        begin
            exp_work = exp_i;
            r.bits  = {sign, 31'd0};
            r.flags = 5'b0;
            if (mant_ext == 27'd0) begin
                pack_round = r;
            end else if (exp_work >= 255) begin
                r.bits  = sign ? NEG_INF : POS_INF;
                r.flags = FF_OF | FF_NX;
                pack_round = r;
            end else if (exp_work <= 0) begin
                r.bits  = {sign, 31'd0};
                r.flags = FF_UF | FF_NX;
                pack_round = r;
            end else begin
                inexact = |mant_ext[2:0];
                inc = round_inc(sign, rm, mant_ext[3], mant_ext[2], mant_ext[1], mant_ext[0]);
                rounded = {1'b0, mant_ext[26:3]} + {24'd0, inc};
                if (rounded[24]) begin
                    exp_work = exp_work + 1;
                    rounded = 25'h0800000;
                end
                if (exp_work >= 255) begin
                    r.bits  = sign ? NEG_INF : POS_INF;
                    r.flags = FF_OF | FF_NX;
                end else begin
                    exp_bits = exp_work[7:0];
                    r.bits = {sign, exp_bits, rounded[22:0]};
                    r.flags = inexact ? FF_NX : 5'b0;
                end
                pack_round = r;
            end
        end
    endfunction

    function automatic int msb_index32(input logic [31:0] v);
        int idx;
        begin
            idx = 0;
            for (int i = 0; i < 32; i++) begin
                if (v[i])
                    idx = i;
            end
            msb_index32 = idx;
        end
    endfunction

    function automatic int norm_shift27(input logic [26:0] v);
        int sh;
        begin
            sh = 0;
            for (int i = 0; i < 27; i++) begin
                if (v[i])
                    sh = 26 - i;
            end
            norm_shift27 = sh;
        end
    endfunction

    function automatic fp_out_t fp_i2f(input logic [31:0] in, input logic signed_in, input logic [2:0] rm);
        fp_out_t r;
        logic sign;
        logic [31:0] mag;
        int msb;
        int sh;
        logic [26:0] mant_ext;
        begin
            sign = signed_in && in[31];
            mag = sign ? (~in + 32'd1) : in;
            if (mag == 32'd0) begin
                r.bits = 32'd0;
                r.flags = 5'b0;
                fp_i2f = r;
            end else begin
                msb = msb_index32(mag);
                if (msb <= 26) begin
                    mant_ext = {27'd0} | (mag << (26 - msb));
                end else begin
                    sh = msb - 26;
                    mant_ext = mag >> sh;
                    if (|(mag & ((32'd1 << sh) - 32'd1)))
                        mant_ext[0] = 1'b1;
                end
                fp_i2f = pack_round(sign, 127 + msb, mant_ext, rm);
            end
        end
    endfunction

    function automatic fp_out_t fp_f2i(input logic [31:0] in, input logic unsigned_out, input logic [2:0] rm);
        fp_out_t r;
        logic sign;
        int exp_unb;
        logic [23:0] mant;
        logic [63:0] mag64;
        logic [63:0] int_part;
        logic [63:0] rem;
        logic [63:0] half;
        logic inc;
        int sh;
        begin
            r.bits = 32'd0;
            r.flags = 5'b0;
            sign = in[31];
            if (fp_is_nan(in) || fp_is_inf(in)) begin
                r.flags = FF_NV;
                if (unsigned_out)
                    r.bits = sign ? 32'd0 : 32'hffff_ffff;
                else
                    r.bits = sign ? 32'h8000_0000 : 32'h7fff_ffff;
                fp_f2i = r;
            end else if (fp_is_zero(in)) begin
                fp_f2i = r;
            end else begin
                exp_unb = int'(in[30:23]) - 127;
                mant = fp_mant24(in);
                int_part = 64'd0;
                rem = 64'd0;
                half = 64'd0;
                if (exp_unb >= 63) begin
                    int_part = 64'hffff_ffff_ffff_ffff;
                end else if (exp_unb >= 23) begin
                    int_part = {40'd0, mant} << (exp_unb - 23);
                end else if (exp_unb >= 0) begin
                    sh = 23 - exp_unb;
                    int_part = mant >> sh;
                    rem = mant & ((64'd1 << sh) - 64'd1);
                    half = 64'd1 << (sh - 1);
                end else begin
                    int_part = 64'd0;
                    rem = mant;
                    if (exp_unb == -1)
                        half = 64'd1 << 23;
                    else
                        half = 64'hffff_ffff_ffff_ffff;
                end

                inc = 1'b0;
                if (rem != 64'd0) begin
                    unique case (rm)
                        3'b000: inc = (rem > half) || ((rem == half) && int_part[0]);
                        3'b001: inc = 1'b0;
                        3'b010: inc = sign;
                        3'b011: inc = !sign;
                        3'b100: inc = (rem >= half);
                        default: inc = 1'b0;
                    endcase
                end
                mag64 = int_part + {63'd0, inc};

                if (unsigned_out) begin
                    if (sign && (mag64 != 64'd0)) begin
                        r.bits = 32'd0;
                        r.flags = FF_NV;
                    end else if (mag64 > 64'hffff_ffff) begin
                        r.bits = 32'hffff_ffff;
                        r.flags = FF_NV;
                    end else begin
                        r.bits = mag64[31:0];
                        r.flags = (rem != 64'd0) ? FF_NX : 5'b0;
                    end
                end else begin
                    if (!sign && (mag64 > 64'h7fff_ffff)) begin
                        r.bits = 32'h7fff_ffff;
                        r.flags = FF_NV;
                    end else if (sign && (mag64 > 64'h8000_0000)) begin
                        r.bits = 32'h8000_0000;
                        r.flags = FF_NV;
                    end else begin
                        r.bits = sign ? (~mag64[31:0] + 32'd1) : mag64[31:0];
                        r.flags = (rem != 64'd0) ? FF_NX : 5'b0;
                    end
                end
                fp_f2i = r;
            end
        end
    endfunction

    function automatic fp_out_t fp_addsub(input logic [31:0] a, input logic [31:0] b, input logic sub_op, input logic [2:0] rm);
        fp_out_t r;
        logic [31:0] bb;
        logic sign_a, sign_b, sign_r;
        int exp_a, exp_b, exp_r, diff;
        int norm_sh;
        logic [26:0] ma, mb, mant_r;
        logic [27:0] sum;
        begin
            bb = b ^ {sub_op, 31'd0};
            r.bits = 32'd0;
            r.flags = 5'b0;
            if (fp_is_nan(a) || fp_is_nan(bb)) begin
                r.bits = CANON_QNAN;
                r.flags = (fp_is_snan(a) || fp_is_snan(bb)) ? FF_NV : 5'b0;
                fp_addsub = r;
            end else if (fp_is_inf(a) || fp_is_inf(bb)) begin
                if (fp_is_inf(a) && fp_is_inf(bb) && (a[31] != bb[31])) begin
                    r.bits = CANON_QNAN;
                    r.flags = FF_NV;
                end else begin
                    r.bits = fp_is_inf(a) ? {a[31], POS_INF[30:0]} : {bb[31], POS_INF[30:0]};
                end
                fp_addsub = r;
            end else if (fp_is_zero(a)) begin
                r.bits = bb;
                fp_addsub = r;
            end else if (fp_is_zero(bb)) begin
                r.bits = a;
                fp_addsub = r;
            end else begin
                sign_a = a[31];
                sign_b = bb[31];
                exp_a = (a[30:23] == 8'd0) ? 1 : int'(a[30:23]);
                exp_b = (bb[30:23] == 8'd0) ? 1 : int'(bb[30:23]);
                ma = {fp_mant24(a), 3'b000};
                mb = {fp_mant24(bb), 3'b000};
                exp_r = exp_a;
                if (exp_a >= exp_b) begin
                    diff = exp_a - exp_b;
                    mb = shr_jam27(mb, diff);
                    exp_r = exp_a;
                end else begin
                    diff = exp_b - exp_a;
                    ma = shr_jam27(ma, diff);
                    exp_r = exp_b;
                end

                if (sign_a == sign_b) begin
                    sum = {1'b0, ma} + {1'b0, mb};
                    sign_r = sign_a;
                    if (sum[27]) begin
                        mant_r = sum[27:1];
                        mant_r[0] = mant_r[0] | sum[0];
                        exp_r = exp_r + 1;
                    end else begin
                        mant_r = sum[26:0];
                    end
                end else begin
                    if (ma >= mb) begin
                        mant_r = ma - mb;
                        sign_r = sign_a;
                    end else begin
                        mant_r = mb - ma;
                        sign_r = sign_b;
                    end
                    if (mant_r == 27'd0) begin
                        r.bits = 32'd0;
                        fp_addsub = r;
                        return r;
                    end
                    norm_sh = norm_shift27(mant_r);
                    if (norm_sh > (exp_r - 1))
                        norm_sh = exp_r - 1;
                    if (norm_sh > 0) begin
                        mant_r = mant_r << norm_sh;
                        exp_r = exp_r - norm_sh;
                    end
                end
                fp_addsub = pack_round(sign_r, exp_r, mant_r, rm);
            end
        end
    endfunction

    function automatic fp_out_t fp_mul(input logic [31:0] a, input logic [31:0] b, input logic [2:0] rm);
        fp_out_t r;
        logic sign_r;
        int exp_r;
        logic [47:0] prod;
        logic [26:0] mant_r;
        begin
            r.bits = 32'd0;
            r.flags = 5'b0;
            sign_r = a[31] ^ b[31];
            if (fp_is_nan(a) || fp_is_nan(b)) begin
                r.bits = CANON_QNAN;
                r.flags = (fp_is_snan(a) || fp_is_snan(b)) ? FF_NV : 5'b0;
                fp_mul = r;
            end else if ((fp_is_zero(a) && fp_is_inf(b)) || (fp_is_inf(a) && fp_is_zero(b))) begin
                r.bits = CANON_QNAN;
                r.flags = FF_NV;
                fp_mul = r;
            end else if (fp_is_inf(a) || fp_is_inf(b)) begin
                r.bits = {sign_r, POS_INF[30:0]};
                fp_mul = r;
            end else if (fp_is_zero(a) || fp_is_zero(b)) begin
                r.bits = {sign_r, 31'd0};
                fp_mul = r;
            end else begin
                prod = fp_mant24(a) * fp_mant24(b);
                if (prod[47]) begin
                    exp_r = int'(a[30:23]) + int'(b[30:23]) - 127 + 1;
                    mant_r = prod[47:21];
                    if (|prod[20:0])
                        mant_r[0] = 1'b1;
                end else begin
                    exp_r = int'(a[30:23]) + int'(b[30:23]) - 127;
                    mant_r = prod[46:20];
                    if (|prod[19:0])
                        mant_r[0] = 1'b1;
                end
                fp_mul = pack_round(sign_r, exp_r, mant_r, rm);
            end
        end
    endfunction

    typedef struct packed {
        logic               special;
        logic [31:0]        bits;
        logic [4:0]         flags;
        logic               sign;
        logic signed [10:0] exp;
        logic [50:0]        dividend;
        logic [23:0]        divisor;
        logic [63:0]        radicand;
    } long_init_t;

    function automatic long_init_t fp_div_init(input logic [31:0] a, input logic [31:0] b);
        long_init_t r;
        logic sign_r;
        begin
            r = '0;
            sign_r = a[31] ^ b[31];
            r.sign = sign_r;
            if (fp_is_nan(a) || fp_is_nan(b)) begin
                r.special = 1'b1;
                r.bits = CANON_QNAN;
                r.flags = (fp_is_snan(a) || fp_is_snan(b)) ? FF_NV : 5'b0;
            end else if ((fp_is_zero(a) && fp_is_zero(b)) || (fp_is_inf(a) && fp_is_inf(b))) begin
                r.special = 1'b1;
                r.bits = CANON_QNAN;
                r.flags = FF_NV;
            end else if (fp_is_zero(b)) begin
                r.special = 1'b1;
                r.bits = {sign_r, POS_INF[30:0]};
                r.flags = FF_DZ;
            end else if (fp_is_inf(a)) begin
                r.special = 1'b1;
                r.bits = {sign_r, POS_INF[30:0]};
            end else if (fp_is_inf(b) || fp_is_zero(a)) begin
                r.special = 1'b1;
                r.bits = {sign_r, 31'd0};
            end else begin
                r.special = 1'b0;
                r.exp = $signed({3'b000, a[30:23]}) - $signed({3'b000, b[30:23]}) + 11'sd127;
                r.dividend = {fp_mant24(a), 27'd0};
                r.divisor = fp_mant24(b);
            end
            fp_div_init = r;
        end
    endfunction

    function automatic long_init_t fp_sqrt_init(input logic [31:0] a);
        long_init_t r;
        int exp_unb;
        logic [24:0] rad_mant;
        begin
            r = '0;
            if (fp_is_nan(a)) begin
                r.special = 1'b1;
                r.bits = CANON_QNAN;
                r.flags = fp_is_snan(a) ? FF_NV : 5'b0;
            end else if (a[31] && !fp_is_zero(a)) begin
                r.special = 1'b1;
                r.bits = CANON_QNAN;
                r.flags = FF_NV;
            end else if (fp_is_inf(a) || fp_is_zero(a)) begin
                r.special = 1'b1;
                r.bits = a;
            end else begin
                r.special = 1'b0;
                exp_unb = int'(a[30:23]) - 127;
                if ((exp_unb & 1) != 0) begin
                    rad_mant = {fp_mant24(a), 1'b0};
                    r.exp = ((exp_unb - 1) / 2) + 127;
                end else begin
                    rad_mant = {1'b0, fp_mant24(a)};
                    r.exp = (exp_unb / 2) + 127;
                end
                r.radicand = {39'd0, rad_mant} << 29;
            end
            fp_sqrt_init = r;
        end
    endfunction

    function automatic fp_out_t fp_div_finish(
        input logic               sign,
        input logic signed [10:0] exp_base,
        input logic [27:0]        quotient,
        input logic [24:0]        remainder,
        input logic [2:0]         rm
    );
        fp_out_t r;
        logic [26:0] mant_r;
        int exp_r;
        begin
            if (quotient[27]) begin
                exp_r = exp_base;
                mant_r = quotient[27:1];
                if (quotient[0] || (remainder != 25'd0))
                    mant_r[0] = 1'b1;
            end else begin
                exp_r = exp_base - 1;
                mant_r = quotient[26:0];
                if (remainder != 25'd0)
                    mant_r[0] = 1'b1;
            end
            r = pack_round(sign, exp_r, mant_r, rm);
            fp_div_finish = r;
        end
    endfunction

    function automatic fp_out_t fp_sqrt_finish(
        input logic signed [10:0] exp_base,
        input logic [31:0]        root,
        input logic [65:0]        remainder,
        input logic [2:0]         rm
    );
        fp_out_t r;
        logic [26:0] mant_r;
        begin
            mant_r = root[26:0];
            if (remainder != 66'd0)
                mant_r[0] = 1'b1;
            r = pack_round(1'b0, exp_base, mant_r, rm);
            fp_sqrt_finish = r;
        end
    endfunction

    logic [31:0] pipe_inst_q;
    logic [31:0] pipe_pc_q;
    logic [31:0] pipe_frs1_q;
    logic [31:0] pipe_frs2_q;
    logic [31:0] pipe_irs1_q;
    logic [2:0]  pipe_rm_q;

    wire [6:0] pipe_op  = pipe_inst_q[6:0];
    wire [2:0] pipe_f3  = pipe_inst_q[14:12];
    wire [4:0] pipe_rs2 = pipe_inst_q[24:20];
    wire [6:0] pipe_f7  = pipe_inst_q[31:25];

    fp_out_t comb_out;
    always_comb begin
        comb_out.bits = 32'd0;
        comb_out.flags = 5'b0;
        if (pipe_op == 7'b1010011) begin
            unique case (pipe_f7)
                7'h00: comb_out = fp_addsub(pipe_frs1_q, pipe_frs2_q, 1'b0, pipe_rm_q);
                7'h04: comb_out = fp_addsub(pipe_frs1_q, pipe_frs2_q, 1'b1, pipe_rm_q);
                7'h08: comb_out = fp_mul(pipe_frs1_q, pipe_frs2_q, pipe_rm_q);
                7'h68: comb_out = fp_i2f(pipe_irs1_q, pipe_rs2 == 5'd0, pipe_rm_q);
                7'h60: comb_out = fp_f2i(pipe_frs1_q, pipe_rs2 == 5'd1, pipe_rm_q);
                default: begin
                    comb_out.bits = 32'd0;
                    comb_out.flags = 5'b0;
                end
            endcase
        end
    end

    wire is_div_op  = (op == 7'b1010011) && (f7 == 7'h0C);
    wire is_sqrt_op = (op == 7'b1010011) && (f7 == 7'h2C) && (rs2 == 5'd0);
    wire is_long_op = is_div_op || is_sqrt_op;

    long_init_t div_init_now;
    long_init_t sqrt_init_now;
    always_comb begin
        div_init_now = fp_div_init(frs1, frs2);
        sqrt_init_now = fp_sqrt_init(frs1);
    end

    wire start_long_special = is_div_op ? div_init_now.special : sqrt_init_now.special;

    typedef enum logic [1:0] {ST_IDLE, ST_PIPE, ST_LONG} st_e;
    st_e        st_q, st_d;
    logic [1:0] pipe_q, pipe_d;
    logic [5:0] long_q, long_d;
    logic [31:0] res_q;
    logic [4:0]  ff_q;

    logic               long_is_div_q;
    logic               long_special_q;
    logic [31:0]        long_special_bits_q;
    logic [4:0]         long_special_flags_q;
    logic               long_sign_q;
    logic signed [10:0] long_exp_q;
    logic [2:0]         long_rm_q;

    logic [50:0] div_dividend_q;
    logic [23:0] div_divisor_q;
    logic [27:0] div_quot_q;
    logic [24:0] div_rem_q;

    logic [63:0] sqrt_rad_q;
    logic [65:0] sqrt_rem_q;
    logic [31:0] sqrt_root_q;

    logic [27:0] div_quot_next;
    logic [24:0] div_rem_next;
    logic [24:0] div_rem_shift;
    logic [31:0] sqrt_root_next;
    logic [65:0] sqrt_rem_next;
    logic [65:0] sqrt_rem_shift;
    logic [65:0] sqrt_trial;
    logic [1:0]  sqrt_pair;

    always_comb begin
        div_rem_shift = {div_rem_q[23:0], div_dividend_q[50]};
        if (div_rem_shift >= {1'b0, div_divisor_q}) begin
            div_rem_next = div_rem_shift - {1'b0, div_divisor_q};
            div_quot_next = {div_quot_q[26:0], 1'b1};
        end else begin
            div_rem_next = div_rem_shift;
            div_quot_next = {div_quot_q[26:0], 1'b0};
        end
    end

    always_comb begin
        sqrt_root_next = sqrt_root_q;
        sqrt_rem_next = sqrt_rem_q;
        sqrt_pair = sqrt_rad_q[63:62];
        sqrt_rem_shift = {sqrt_rem_q[63:0], sqrt_pair};
        sqrt_trial = {32'd0, sqrt_root_q, 2'b01};
        if (sqrt_rem_shift >= sqrt_trial) begin
            sqrt_rem_next = sqrt_rem_shift - sqrt_trial;
            sqrt_root_next = {sqrt_root_q[30:0], 1'b1};
        end else begin
            sqrt_rem_next = sqrt_rem_shift;
            sqrt_root_next = {sqrt_root_q[30:0], 1'b0};
        end
    end

    fp_out_t long_finish_out;
    always_comb begin
        long_finish_out.bits = long_special_bits_q;
        long_finish_out.flags = long_special_flags_q;
        if (!long_special_q) begin
            if (long_is_div_q)
                long_finish_out = fp_div_finish(long_sign_q, long_exp_q, div_quot_next, div_rem_next, long_rm_q);
            else
                long_finish_out = fp_sqrt_finish(long_exp_q, sqrt_root_next, sqrt_rem_next, long_rm_q);
        end
    end

    wire fp_instr = idex_valid && legal_fp_op && !illegal;
    logic [63:0] fpu_done_tag_q;
    logic        fpu_done_valid_q;
    wire [63:0] cur_tag  = {idex_pc, inst};
    wire [63:0] pipe_tag = {pipe_pc_q, pipe_inst_q};
    wire block_same_insn = fpu_done_valid_q && fp_instr && (cur_tag == fpu_done_tag_q) && (st_q == ST_IDLE);
    wire start_pipe = fp_instr && !is_long_op && !block_same_insn;
    wire start_long = fp_instr && is_long_op && !block_same_insn;
    wire launch_pipe = (st_q == ST_IDLE) && start_pipe;
    wire launch_long = (st_q == ST_IDLE) && start_long;

    always_comb begin
        st_d = st_q;
        pipe_d = pipe_q;
        long_d = long_q;
        unique case (st_q)
            ST_IDLE: begin
                if (start_long) begin
                    st_d = ST_LONG;
                    if (start_long_special)
                        long_d = 6'd0;
                    else if (is_div_op)
                        long_d = 6'd50;
                    else
                        long_d = 6'd31;
                end else if (start_pipe) begin
                    st_d = ST_PIPE;
                    pipe_d = 2'd0;
                end
            end
            ST_PIPE: begin
                if (pipe_q == 2'd2)
                    st_d = ST_IDLE;
                else
                    pipe_d = pipe_q + 2'd1;
            end
            ST_LONG: begin
                if (long_q == 6'd0)
                    st_d = ST_IDLE;
                else
                    long_d = long_q - 4'd1;
            end
            default: st_d = ST_IDLE;
        endcase
    end

    always_ff @(posedge pl_clk) begin
        if (!pl_resetn) begin
            st_q             <= ST_IDLE;
            pipe_q           <= '0;
            long_q           <= '0;
            pipe_inst_q      <= '0;
            pipe_pc_q        <= '0;
            pipe_frs1_q      <= '0;
            pipe_frs2_q      <= '0;
            pipe_irs1_q      <= '0;
            pipe_rm_q        <= '0;
            res_q            <= '0;
            ff_q             <= '0;
            fpu_done_tag_q   <= '0;
            fpu_done_valid_q <= 1'b0;
            long_is_div_q        <= 1'b0;
            long_special_q       <= 1'b0;
            long_special_bits_q  <= '0;
            long_special_flags_q <= '0;
            long_sign_q          <= 1'b0;
            long_exp_q           <= '0;
            long_rm_q            <= '0;
            div_dividend_q       <= '0;
            div_divisor_q        <= '0;
            div_quot_q           <= '0;
            div_rem_q            <= '0;
            sqrt_rad_q           <= '0;
            sqrt_rem_q           <= '0;
            sqrt_root_q          <= '0;
        end else if (redirect_valid) begin
            st_q             <= ST_IDLE;
            pipe_q           <= '0;
            long_q           <= '0;
            fpu_done_valid_q <= 1'b0;
            long_special_q   <= 1'b0;
            div_quot_q       <= '0;
            div_rem_q        <= '0;
            sqrt_rem_q       <= '0;
            sqrt_root_q      <= '0;
        end else begin
            st_q   <= st_d;
            pipe_q <= pipe_d;
            long_q <= long_d;
            if (launch_pipe || launch_long) begin
                pipe_inst_q <= inst;
                pipe_pc_q   <= idex_pc;
                pipe_frs1_q <= frs1;
                pipe_frs2_q <= frs2;
                pipe_irs1_q <= irs1;
                pipe_rm_q   <= rm_eff;
            end

            if (launch_long) begin
                long_is_div_q <= is_div_op;
                long_rm_q <= rm_eff;
                if (is_div_op) begin
                    long_special_q       <= div_init_now.special;
                    long_special_bits_q  <= div_init_now.bits;
                    long_special_flags_q <= div_init_now.flags;
                    long_sign_q          <= div_init_now.sign;
                    long_exp_q           <= div_init_now.exp;
                    div_dividend_q       <= div_init_now.dividend;
                    div_divisor_q        <= div_init_now.divisor;
                    div_quot_q           <= '0;
                    div_rem_q            <= '0;
                end else begin
                    long_special_q       <= sqrt_init_now.special;
                    long_special_bits_q  <= sqrt_init_now.bits;
                    long_special_flags_q <= sqrt_init_now.flags;
                    long_sign_q          <= 1'b0;
                    long_exp_q           <= sqrt_init_now.exp;
                    sqrt_rad_q           <= sqrt_init_now.radicand;
                    sqrt_rem_q           <= '0;
                    sqrt_root_q          <= '0;
                end
            end else if (st_q == ST_LONG && !long_special_q) begin
                if (long_is_div_q) begin
                    div_quot_q <= div_quot_next;
                    div_rem_q  <= div_rem_next;
                    div_dividend_q <= {div_dividend_q[49:0], 1'b0};
                end else begin
                    sqrt_root_q <= sqrt_root_next;
                    sqrt_rem_q  <= sqrt_rem_next;
                    sqrt_rad_q  <= {sqrt_rad_q[61:0], 2'b00};
                end
            end

            if ((st_q == ST_PIPE && pipe_q == 2'd2) || (st_q == ST_LONG && long_q == 6'd0)) begin
                res_q <= (st_q == ST_PIPE) ? comb_out.bits : long_finish_out.bits;
                ff_q  <= (st_q == ST_PIPE) ? comb_out.flags : long_finish_out.flags;
                fpu_done_tag_q   <= pipe_tag;
                fpu_done_valid_q <= 1'b1;
`ifndef SYNTHESIS
                if ($test$plusargs("FPU_DBG")) begin
                    $display("[FPU_DBG] done t=%0t pc=0x%08x inst=0x%08x f7=0x%02x f3=%0d rs2=%0d rm=%b frs1=0x%08x frs2=0x%08x irs1=0x%08x res=0x%08x ff=%b long_div=%b special=%b exp=%0d q=0x%07x rem=0x%07x root=0x%08x sqrt_rem=0x%017x",
                             $time, pipe_pc_q, pipe_inst_q, pipe_f7, pipe_f3, pipe_rs2, pipe_rm_q,
                             pipe_frs1_q, pipe_frs2_q, pipe_irs1_q,
                             (st_q == ST_PIPE) ? comb_out.bits : long_finish_out.bits,
                             (st_q == ST_PIPE) ? comb_out.flags : long_finish_out.flags,
                             long_is_div_q, long_special_q, long_exp_q, div_quot_next, div_rem_next,
                             sqrt_root_next, sqrt_rem_next);
                end
`endif
            end else if (fpu_done_valid_q && (!fp_instr || (cur_tag != fpu_done_tag_q))) begin
                fpu_done_valid_q <= 1'b0;
            end
        end
    end

    assign stall_fp = (st_q == ST_PIPE) || (st_q == ST_LONG)
        || (fp_instr && st_q == ST_IDLE && (start_pipe || start_long));
    assign result = res_q;
    assign fflags = ff_q;

    // frs3 is intentionally unused because fused R4 FP ops are outside the
    // approval instruction set.
    wire unused_frs3 = ^frs3;

endmodule
