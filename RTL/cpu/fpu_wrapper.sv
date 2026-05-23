// Berkeley HardFloat bridge for RV32F execution.
`include "HardFloat_consts.vi"

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

    localparam int unsigned EW = 8;
    localparam int unsigned SW = 24;
    localparam logic [`floatControlWidth - 1:0] HF_CTL = `flControl_tininessAfterRounding;

    wire [6:0] op  = inst[6:0];
    wire [2:0] f3  = inst[14:12];
    wire [4:0] rs2 = inst[24:20];
    wire [6:0] f7  = inst[31:25];

    wire [2:0] rm_eff = (f3 == 3'b111) ? frm_csr : f3;
    wire       rm_bad = (rm_eff == 3'b101) || (rm_eff == 3'b110);

    wire is_r4_op = (op == 7'h43) || (op == 7'h47) || (op == 7'h4b) || (op == 7'h4f);
    wire fmt_s_r4 = (inst[26:25] == 2'b00);

    always_comb begin
        illegal = 1'b0;
        if (is_r4_op) begin
            if (!fmt_s_r4 || rm_bad)
                illegal = 1'b1;
        end else if (op == 7'b1010011) begin
            if (rm_bad && ((f7 == 7'h68) || (f7 == 7'h60) || (f7 == 7'h00) || (f7 == 7'h04)
                || (f7 == 7'h08) || (f7 == 7'h0C) || (f7 == 7'h2C) || (f7 == 7'h10) || (f7 == 7'h14)))
                illegal = 1'b1;
            else if (f7 == 7'h78 && !(rs2 == 5'b0 && f3 == 3'b000))
                illegal = 1'b1;
            else if (f7 == 7'h70 && !(rs2 == 5'b0 && f3 == 3'b000))
                illegal = 1'b1;
            else if (f7 == 7'h71 && !(rs2 == 5'b0 && f3 == 3'b001))
                illegal = 1'b1;
            else if (f7 == 7'h54 && !(rs2 == 5'b0 && (f3 == 3'b010 || f3 == 3'b001 || f3 == 3'b000)))
                illegal = 1'b1;
            else if (f7 == 7'h68 && !((rs2 == 5'b0 || rs2 == 5'b1)))
                illegal = 1'b1;
            else if (f7 == 7'h60 && !((rs2 == 5'b0 || rs2 == 5'b1)))
                illegal = 1'b1;
            else if ((f7 == 7'h2C) && !(rs2 == 5'b0))
                illegal = 1'b1;
            else if (!(f7 == 7'h78 || f7 == 7'h70 || f7 == 7'h71 || f7 == 7'h54 || f7 == 7'h68
                || f7 == 7'h60 || f7 == 7'h00 || f7 == 7'h04 || f7 == 7'h08 || f7 == 7'h0C
                || f7 == 7'h2C || f7 == 7'h10 || f7 == 7'h14))
                illegal = 1'b1;
        end else begin
            illegal = 1'b1;
        end
    end

    // HardFloat add/mul/madd are combinational. The wrapper holds these
    // operands for the whole ST_PIPE transaction before sampling the result.
    logic [31:0] pipe_inst_q;
    logic [31:0] pipe_pc_q;
    logic [31:0] pipe_frs1_q;
    logic [31:0] pipe_frs2_q;
    logic [31:0] pipe_frs3_q;
    logic [31:0] pipe_irs1_q;
    logic [2:0]  pipe_rm_q;

    wire [6:0] pipe_op  = pipe_inst_q[6:0];
    wire [2:0] pipe_f3  = pipe_inst_q[14:12];
    wire [4:0] pipe_rs2 = pipe_inst_q[24:20];
    wire [6:0] pipe_f7  = pipe_inst_q[31:25];

    wire [EW+SW:0] rec_a, rec_b, rec_c;
    fNToRecFN #(EW, SW) u_f2a (.in(pipe_frs1_q), .out(rec_a));
    fNToRecFN #(EW, SW) u_f2b (.in(pipe_frs2_q), .out(rec_b));
    fNToRecFN #(EW, SW) u_f2c (.in(pipe_frs3_q), .out(rec_c));

    wire [EW+SW:0] mul_rec, add_rec, sub_rec;
    wire [4:0]     exc_mul, exc_add, exc_sub;

    mulRecFN #(EW, SW) u_mul (
        .control(HF_CTL),
        .a(rec_a),
        .b(rec_b),
        .roundingMode(pipe_rm_q),
        .out(mul_rec),
        .exceptionFlags(exc_mul)
    );

    addRecFN #(EW, SW) u_add (
        .control(HF_CTL),
        .subOp(1'b0),
        .a(rec_a),
        .b(rec_b),
        .roundingMode(pipe_rm_q),
        .out(add_rec),
        .exceptionFlags(exc_add)
    );

    addRecFN #(EW, SW) u_sub (
        .control(HF_CTL),
        .subOp(1'b1),
        .a(rec_a),
        .b(rec_b),
        .roundingMode(pipe_rm_q),
        .out(sub_rec),
        .exceptionFlags(exc_sub)
    );

    wire [31:0] ieee_mul, ieee_add, ieee_sub;
    recFNToFN #(EW, SW) u_mul2f (.in(mul_rec), .out(ieee_mul));
    recFNToFN #(EW, SW) u_add2f (.in(add_rec), .out(ieee_add));
    recFNToFN #(EW, SW) u_sub2f (.in(sub_rec), .out(ieee_sub));

    logic [1:0] madd_op;
    always_comb begin
        unique case (pipe_op)
            7'h43:  madd_op = 2'b00;
            7'h47:  madd_op = 2'b01;
            7'h4b:  madd_op = 2'b10;
            7'h4f:  madd_op = 2'b11;
            default: madd_op = 2'b00;
        endcase
    end

    wire [EW+SW:0] madd_rec;
    wire [4:0]     exc_madd;
    mulAddRecFN #(EW, SW) u_madd (
        .control(HF_CTL),
        .op(madd_op),
        .a(rec_a),
        .b(rec_b),
        .c(rec_c),
        .roundingMode(pipe_rm_q),
        .out(madd_rec),
        .exceptionFlags(exc_madd)
    );

    wire [31:0] ieee_madd;
    recFNToFN #(EW, SW) u_madd2f (.in(madd_rec), .out(ieee_madd));

    wire [EW+SW:0] i2f_out, u2f_out;
    wire [4:0]     i2f_exc, u2f_exc;
    iNToRecFN #(32, EW, SW) u_i2f (
        .control(HF_CTL),
        .signedIn(1'b1),
        .in(pipe_irs1_q),
        .roundingMode(pipe_rm_q),
        .out(i2f_out),
        .exceptionFlags(i2f_exc)
    );

    iNToRecFN #(32, EW, SW) u_u2f (
        .control(HF_CTL),
        .signedIn(1'b0),
        .in(pipe_irs1_q),
        .roundingMode(pipe_rm_q),
        .out(u2f_out),
        .exceptionFlags(u2f_exc)
    );

    wire [31:0] fcvt_s_w_ieee, fcvt_s_wu_ieee;
    recFNToFN #(EW, SW) u_i2f2f (.in(i2f_out), .out(fcvt_s_w_ieee));
    recFNToFN #(EW, SW) u_u2f2f (.in(u2f_out), .out(fcvt_s_wu_ieee));

    wire [31:0] w2s_out, wu2s_out;
    wire [2:0]  w2s_xc, wu2s_xc;
    recFNToIN #(EW, SW, 32) u_w2s (
        .control(HF_CTL),
        .in(rec_a),
        .roundingMode(pipe_rm_q),
        .signedOut(1'b1),
        .out(w2s_out),
        .intExceptionFlags(w2s_xc)
    );

    recFNToIN #(EW, SW, 32) u_wu2s (
        .control(HF_CTL),
        .in(rec_a),
        .roundingMode(pipe_rm_q),
        .signedOut(1'b0),
        .out(wu2s_out),
        .intExceptionFlags(wu2s_xc)
    );

    localparam logic [31:0] CANON_QNAN = 32'h7fc0_0000;
    wire is_nan1  = (pipe_frs1_q[30:23] == 8'hFF) && (pipe_frs1_q[22:0] != 23'b0);
    wire is_nan2  = (pipe_frs2_q[30:23] == 8'hFF) && (pipe_frs2_q[22:0] != 23'b0);
    wire is_inf1  = (pipe_frs1_q[30:23] == 8'hFF) && (pipe_frs1_q[22:0] == 23'b0);
    wire is_zero1 = (pipe_frs1_q[30:23] == 8'b0) && (pipe_frs1_q[22:0] == 23'b0);
    wire is_zero2 = (pipe_frs2_q[30:23] == 8'b0) && (pipe_frs2_q[22:0] == 23'b0);
    wire is_sub1  = (pipe_frs1_q[30:23] == 8'b0) && (pipe_frs1_q[22:0] != 23'b0);
    wire sign1    = pipe_frs1_q[31];
    wire sign2    = pipe_frs2_q[31];
    wire is_pos_inf1  = is_inf1 && !sign1;
    wire is_neg_inf1  = is_inf1 && sign1;
    wire is_qnan1     = is_nan1 && pipe_frs1_q[22];
    wire is_snan1     = is_nan1 && !pipe_frs1_q[22];
    wire is_pos_norm1 = !sign1 && !is_zero1 && !is_inf1 && !is_nan1 && !is_sub1;
    wire is_neg_norm1 = sign1 && !is_zero1 && !is_inf1 && !is_nan1 && !is_sub1;
    wire is_pos_sub1  = !sign1 && is_sub1;
    wire is_neg_sub1  = sign1 && is_sub1;

    logic [9:0] fclass_bits;
    always_comb begin
        fclass_bits = 10'b0;
        if (is_qnan1)
            fclass_bits[9] = 1'b1;
        else if (is_snan1)
            fclass_bits[8] = 1'b1;
        else if (is_pos_inf1)
            fclass_bits[7] = 1'b1;
        else if (is_pos_norm1)
            fclass_bits[6] = 1'b1;
        else if (is_pos_sub1)
            fclass_bits[5] = 1'b1;
        else if (!sign1 && is_zero1)
            fclass_bits[4] = 1'b1;
        else if (sign1 && is_zero1)
            fclass_bits[3] = 1'b1;
        else if (is_neg_sub1)
            fclass_bits[2] = 1'b1;
        else if (is_neg_norm1)
            fclass_bits[1] = 1'b1;
        else if (is_neg_inf1)
            fclass_bits[0] = 1'b1;
    end

    wire feq_res = !is_nan1 && !is_nan2 && ((pipe_frs1_q == pipe_frs2_q) || (is_zero1 && is_zero2));
    logic flt_res;
    always_comb begin
        if (is_nan1 || is_nan2)
            flt_res = 1'b0;
        else if (is_zero1 && is_zero2)
            flt_res = 1'b0;
        else if (sign1 != sign2)
            flt_res = sign1 && !sign2;
        else if (!sign1)
            flt_res = (pipe_frs1_q < pipe_frs2_q);
        else
            flt_res = (pipe_frs1_q > pipe_frs2_q);
    end

    wire fle_res = !is_nan1 && !is_nan2 && (feq_res || flt_res);
    wire flt_total = (is_zero1 && is_zero2) ? (sign1 && !sign2) : flt_res;

    logic [31:0] comb_res;
    logic [4:0]  comb_ff;
    always_comb begin
        comb_res = 32'b0;
        comb_ff  = 5'b0;
        if (pipe_op == 7'b1010011) begin
            unique casez ({pipe_f7, pipe_rs2, pipe_f3})
                {7'h00, 5'b?, 3'b???}: begin comb_res = ieee_add; comb_ff = exc_add; end
                {7'h04, 5'b?, 3'b???}: begin comb_res = ieee_sub; comb_ff = exc_sub; end
                {7'h08, 5'b?, 3'b???}: begin comb_res = ieee_mul; comb_ff = exc_mul; end
                {7'h10, 5'b0, 3'b???}: begin comb_res = {pipe_frs2_q[31], pipe_frs1_q[30:0]}; end
                {7'h10, 5'b1, 3'b???}: begin comb_res = {~pipe_frs2_q[31], pipe_frs1_q[30:0]}; end
                {7'h10, 5'h2, 3'b???}: begin comb_res = {pipe_frs1_q[31] ^ pipe_frs2_q[31], pipe_frs1_q[30:0]}; end
                {7'h14, 5'b?, 3'b000}: begin
                    if (is_nan1 && is_nan2) begin
                        comb_res = CANON_QNAN;
                        comb_ff[4] = 1'b1;
                    end else if (is_nan1)
                        comb_res = pipe_frs2_q;
                    else if (is_nan2)
                        comb_res = pipe_frs1_q;
                    else if (flt_total)
                        comb_res = pipe_frs1_q;
                    else
                        comb_res = pipe_frs2_q;
                end
                {7'h14, 5'b?, 3'b001}: begin
                    if (is_nan1 && is_nan2) begin
                        comb_res = CANON_QNAN;
                        comb_ff[4] = 1'b1;
                    end else if (is_nan1)
                        comb_res = pipe_frs2_q;
                    else if (is_nan2)
                        comb_res = pipe_frs1_q;
                    else if (flt_total)
                        comb_res = pipe_frs2_q;
                    else
                        comb_res = pipe_frs1_q;
                end
                {7'h54, 5'b0, 3'b010}: begin comb_res = {31'b0, feq_res}; comb_ff[4] = is_nan1 | is_nan2; end
                {7'h54, 5'b0, 3'b001}: begin comb_res = {31'b0, flt_res}; comb_ff[4] = is_nan1 | is_nan2; end
                {7'h54, 5'b0, 3'b000}: begin comb_res = {31'b0, fle_res}; comb_ff[4] = is_nan1 | is_nan2; end
                {7'h71, 5'b0, 3'b001}: begin comb_res = {22'b0, fclass_bits}; end
                {7'h78, 5'b0, 3'b000}: begin comb_res = pipe_irs1_q; end
                {7'h70, 5'b0, 3'b000}: begin comb_res = pipe_frs1_q; end
                {7'h68, 5'b0, 3'b???}: begin comb_res = fcvt_s_w_ieee; comb_ff = i2f_exc; end
                {7'h68, 5'b1, 3'b???}: begin comb_res = fcvt_s_wu_ieee; comb_ff = u2f_exc; end
                {7'h60, 5'b0, 3'b???}: begin
                    comb_res = w2s_out;
                    comb_ff[4] = w2s_xc[2];
                    comb_ff[0] = w2s_xc[0] && !w2s_xc[2];
                end
                {7'h60, 5'b1, 3'b???}: begin
                    comb_res = wu2s_out;
                    comb_ff[4] = wu2s_xc[2];
                end
                default: ;
            endcase
        end else if ((pipe_op == 7'h43) || (pipe_op == 7'h47) || (pipe_op == 7'h4b) || (pipe_op == 7'h4f)) begin
            comb_res = ieee_madd;
            comb_ff  = exc_madd;
        end
    end

    wire is_div_op  = (op == 7'b1010011) && (f7 == 7'h0C);
    wire is_sqrt_op = (op == 7'b1010011) && (f7 == 7'h2C) && (rs2 == 5'b0);
    wire pipe_is_sqrt_op = (pipe_op == 7'b1010011) && (pipe_f7 == 7'h2C) && (pipe_rs2 == 5'b0);

    wire          ds_inReady;
    wire          ds_outValid;
    wire [EW+SW:0] ds_out_rec;
    wire [4:0]    ds_exc;
    logic         ds_inValid;
    logic         ds_sqrtOp;

    divSqrtRecFN_small #(EW, SW) u_divsqrt (
        .nReset(pl_resetn),
        .clock(pl_clk),
        .control(HF_CTL),
        .inReady(ds_inReady),
        .inValid(ds_inValid),
        .sqrtOp(ds_sqrtOp),
        .a(rec_a),
        .b(rec_b),
        .roundingMode(pipe_rm_q),
        .outValid(ds_outValid),
        .sqrtOpOut(),
        .out(ds_out_rec),
        .exceptionFlags(ds_exc)
    );

    wire [31:0] ds_ieee;
    recFNToFN #(EW, SW) u_ds2f (.in(ds_out_rec), .out(ds_ieee));

    typedef enum logic [1:0] {ST_IDLE, ST_PIPE, ST_DIV} st_e;
    st_e        st_q, st_d;
    logic [1:0] pipe_q, pipe_d;
    logic [31:0] res_q;
    logic [4:0]  ff_q;
    logic        ds_issued_q;

    wire fp_instr = idex_valid && (op == 7'b1010011 || is_r4_op) && !illegal;
    logic [63:0] fpu_done_tag_q;
    logic        fpu_done_valid_q;
    wire [63:0]  cur_tag = {idex_pc, inst};
    wire [63:0]  pipe_tag = {pipe_pc_q, pipe_inst_q};
    wire block_same_insn = fpu_done_valid_q && fp_instr && (cur_tag == fpu_done_tag_q) && (st_q == ST_IDLE);
    wire start_pipe = fp_instr && !is_div_op && !is_sqrt_op && !block_same_insn;
    wire start_ds   = fp_instr && (is_div_op || is_sqrt_op) && !block_same_insn;

    always_comb begin
        st_d   = st_q;
        pipe_d = pipe_q;
        unique case (st_q)
            ST_IDLE: begin
                if (start_ds) begin
                    st_d = ST_DIV;
                end else if (start_pipe) begin
                    st_d   = ST_PIPE;
                    pipe_d = 2'd0;
                end
            end
            ST_PIPE: begin
                if (pipe_q == 2'd2)
                    st_d = ST_IDLE;
                else
                    pipe_d = pipe_q + 2'd1;
            end
            ST_DIV: begin
                if (ds_outValid)
                    st_d = ST_IDLE;
            end
            default: st_d = ST_IDLE;
        endcase
    end

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            st_q             <= ST_IDLE;
            pipe_q           <= '0;
            pipe_inst_q      <= '0;
            pipe_pc_q        <= '0;
            pipe_frs1_q      <= '0;
            pipe_frs2_q      <= '0;
            pipe_frs3_q      <= '0;
            pipe_irs1_q      <= '0;
            pipe_rm_q        <= '0;
            res_q            <= '0;
            ff_q             <= '0;
            fpu_done_tag_q   <= '0;
            fpu_done_valid_q <= 1'b0;
        end else if (redirect_valid) begin
            st_q             <= ST_IDLE;
            pipe_q           <= '0;
            fpu_done_valid_q <= 1'b0;
        end else begin
            st_q   <= st_d;
            pipe_q <= pipe_d;
            if (start_pipe || start_ds) begin
                pipe_inst_q <= inst;
                pipe_pc_q   <= idex_pc;
                pipe_frs1_q <= frs1;
                pipe_frs2_q <= frs2;
                pipe_frs3_q <= frs3;
                pipe_irs1_q <= irs1;
                pipe_rm_q   <= rm_eff;
            end
            if (st_q == ST_PIPE && pipe_q == 2'd2) begin
                res_q <= comb_res;
                ff_q  <= comb_ff;
                fpu_done_tag_q   <= pipe_tag;
                fpu_done_valid_q <= 1'b1;
`ifndef SYNTHESIS
                if ($test$plusargs("FPU_DBG")) begin
                    $display("[FPU_DBG] pipe_done t=%0t pc=0x%08x inst=0x%08x f7=0x%02x f3=%0d rs2=%0d rm=%b frs1=0x%08x frs2=0x%08x frs3=0x%08x irs1=0x%08x res=0x%08x ff=%b",
                             $time, pipe_pc_q, pipe_inst_q, pipe_f7, pipe_f3, pipe_rs2, pipe_rm_q,
                             pipe_frs1_q, pipe_frs2_q, pipe_frs3_q, pipe_irs1_q, comb_res, comb_ff);
                end
`endif
            end else if (st_q == ST_DIV && ds_outValid) begin
                res_q <= ds_ieee;
                ff_q  <= ds_exc;
                fpu_done_tag_q   <= pipe_tag;
                fpu_done_valid_q <= 1'b1;
`ifndef SYNTHESIS
                if ($test$plusargs("FPU_DBG")) begin
                    $display("[FPU_DBG] divsqrt_done t=%0t pc=0x%08x inst=0x%08x sqrt=%0b rm=%b frs1=0x%08x frs2=0x%08x res=0x%08x ff=%b",
                             $time, pipe_pc_q, pipe_inst_q, ds_sqrtOp, pipe_rm_q,
                             pipe_frs1_q, pipe_frs2_q, ds_ieee, ds_exc);
                end
`endif
            end else if (fpu_done_valid_q && (!fp_instr || (cur_tag != fpu_done_tag_q))) begin
                fpu_done_valid_q <= 1'b0;
            end
        end
    end

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            ds_inValid  <= 1'b0;
            ds_sqrtOp   <= 1'b0;
            ds_issued_q <= 1'b0;
        end else if (redirect_valid) begin
            ds_inValid  <= 1'b0;
            ds_issued_q <= 1'b0;
        end else begin
            ds_inValid <= 1'b0;
            if (st_q == ST_IDLE)
                ds_issued_q <= 1'b0;
            if (st_q == ST_DIV && !ds_issued_q && ds_inReady) begin
                ds_inValid  <= 1'b1;
                ds_sqrtOp   <= pipe_is_sqrt_op;
                ds_issued_q <= 1'b1;
            end
            if (st_q == ST_DIV && ds_outValid)
                ds_issued_q <= 1'b0;
        end
    end

    assign stall_fp = (st_q == ST_PIPE) || (st_q == ST_DIV)
        || (fp_instr && st_q == ST_IDLE && (start_pipe || start_ds));
    assign result = res_q;
    assign fflags = ff_q;

endmodule
