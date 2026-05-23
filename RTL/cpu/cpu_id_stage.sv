// Instruction decode + ID/EX pipeline register (hazard detect for load-use).
module cpu_id_stage (
    input  logic        pl_clk,
    input  logic        pl_resetn,

    input  logic [31:0] ifid_inst,
    input  logic        ifid_valid,
    input  logic [31:0] ifid_pc,
    input  logic        ifid_err,
    input  logic        ifid_bp_pred_taken,
    input  logic [63:0] ifid_bp_pred_meta,
    input  logic [31:0] ifid1_inst,
    input  logic        ifid1_bp_pred_taken,
    input  logic [63:0] ifid1_bp_pred_meta,
    input  logic        ifid1_valid,

    input  logic [31:0] rf_rs1_val,
    input  logic [31:0] rf_rs2_val,
    input  logic [31:0] frf_rs1_val,
    input  logic [31:0] frf_rs2_val,
    input  logic [31:0] frf_rs3_val,
    // Slot 1 independent register reads (ISSUE_WIDTH=2)
    input  logic [31:0] rf_rs1_val_1, rf_rs2_val_1,
    input  logic [31:0] frf_rs1_val_1, frf_rs2_val_1, frf_rs3_val_1,
    input  logic        frf_we,
    input  logic [4:0]  frf_waddr,
    input  logic        frf_we_b,
    input  logic [4:0]  frf_waddr_b,

    input  logic        stall_mem,
    input  logic        stall_fp,
    input  logic        fence_busy,
    input  logic        stall_iq,
    input  logic        stall_prf,
    input  logic        stall_rob,
    input  logic        redirect_valid,

    // mstatus.FS == Off: FP insns and fflags/frm/fcsr CSR access are illegal.
    input  logic        mstatus_fs_off,

    output logic        stall_load_use,
    output logic        stall_csr,
    output logic        consume_ifid,
    // Combinational next-state of ID/EX valids (for ROB tail retract; avoids @(posedge) read races).
    output logic        idex_next_valid,
    output logic        idex1_next_valid,

    output logic        idex_valid,
    output logic [31:0] idex_pc,
    output logic [31:0] idex_inst,
    output logic        idex_err,
    output logic [4:0]  idex_rs1,
    output logic [4:0]  idex_rs2,
    output logic [4:0]  idex_rd,
    output logic [6:0]  idex_opcode,
    output logic [2:0]  idex_funct3,
    output logic [6:0]  idex_funct7,
    output logic [31:0] idex_imm_i,
    output logic [31:0] idex_imm_s,
    output logic [31:0] idex_imm_b,
    output logic [31:0] idex_imm_u,
    output logic [31:0] idex_imm_j,
    output logic [31:0] idex_rs1_val,
    output logic [31:0] idex_rs2_val,
    output logic        idex_regwrite,
    output logic        idex_mem_read,
    output logic        idex_mem_write,
    output logic        idex_is_load,
    output logic        idex_is_store,
    output logic        idex_is_amo,
    output logic        idex_is_branch,
    output logic        idex_is_jal,
    output logic        idex_is_jalr,
    output logic        idex_is_fence,
    output logic [2:0]  idex_fence_op,
    output logic        idex_illegal,
    output logic        idex_is_csr,
    output logic        idex_is_fp_load,
    output logic        idex_is_fp_store,
    output logic        idex_is_fp_op,
    output logic        idex_fregwrite,
    output logic [31:0] idex_frs1_val,
    output logic [31:0] idex_frs2_val,
    output logic [31:0] idex_frs3_val,

    output logic        idex_bp_pred_taken,
    output logic [63:0] idex_bp_pred_meta,

    // Combinational regwrite flags (for PRF/RAT gating at consume_ifid time)
    output logic        id_regwrite,
    output logic        id1_regwrite,

    // Slot 1 ID/EX pipeline (ISSUE_WIDTH=2)
    output logic        idex1_valid,
    output logic [31:0] idex1_pc,
    output logic [31:0] idex1_inst,
    output logic [4:0]  idex1_rs1,
    output logic [4:0]  idex1_rs2,
    output logic [4:0]  idex1_rd,
    output logic [6:0]  idex1_opcode,
    output logic [2:0]  idex1_funct3,
    output logic [6:0]  idex1_funct7,
    output logic [31:0] idex1_imm_i,
    output logic [31:0] idex1_imm_s,
    output logic [31:0] idex1_imm_b,
    output logic [31:0] idex1_imm_u,
    output logic [31:0] idex1_imm_j,
    output logic [31:0] idex1_rs1_val,
    output logic [31:0] idex1_rs2_val,
    output logic        idex1_regwrite,
    output logic        idex1_is_load,
    output logic        idex1_is_store,
    output logic        idex1_is_amo,
    output logic        idex1_is_branch,
    output logic        idex1_is_jal,
    output logic        idex1_is_jalr,
    output logic        idex1_is_fence,
    output logic [2:0]  idex1_fence_op,
    output logic        idex1_is_csr,
    output logic        idex1_is_fp_load,
    output logic        idex1_is_fp_store,
    output logic        idex1_is_fp_op,
    output logic        idex1_fregwrite,
    output logic [31:0] idex1_frs1_val,
    output logic [31:0] idex1_frs2_val,
    output logic [31:0] idex1_frs3_val,
    output logic        idex1_bp_pred_taken,
    output logic [63:0] idex1_bp_pred_meta
);

    localparam logic [2:0] CTL_FENCE      = 3'b000;
    localparam logic [2:0] CTL_FENCE_I    = 3'b001;

    logic [6:0]  id_opcode;
    logic [4:0]  id_rs1;
    logic [4:0]  id_rs2;
    logic [4:0]  id_rd;
    logic [2:0]  id_funct3;
    logic [6:0]  id_funct7;

    logic [31:0] id_imm_i, id_imm_s, id_imm_b, id_imm_u, id_imm_j;
    logic [12:0] imm_b13;
    logic [20:0] imm_j21;

    // ── cpu_decode instance (replaces inline always_comb decode) ──
    logic id_uses_rs1, id_uses_rs2, id_uses_frs1, id_uses_frs2, id_uses_frs3;
    logic id_is_load, id_is_store, id_is_amo, id_is_fp_load, id_is_fp_store, id_is_fp_op;
    logic id_is_branch, id_is_jal, id_is_jalr, id_is_fence, id_is_csr;
    logic id_fregwrite, id_illegal;
    logic [2:0] id_fence_op;

    // Slot 1 combinational decode (ISSUE_WIDTH=2)
    logic [6:0]  id1_opcode;
    logic [4:0]  id1_rs1, id1_rs2, id1_rd;
    logic [2:0]  id1_funct3;
    logic [6:0]  id1_funct7;
    logic [31:0] id1_imm_i, id1_imm_s, id1_imm_b, id1_imm_u, id1_imm_j;
    logic        id1_is_load, id1_is_store, id1_is_amo;
    logic        id1_is_branch, id1_is_jal, id1_is_jalr, id1_is_fence, id1_is_csr;
    logic        id1_is_fp_load, id1_is_fp_store, id1_is_fp_op, id1_fregwrite, id1_illegal;
    logic [2:0]  id1_fence_op;
    logic id1_uses_rs1, id1_uses_rs2, id1_uses_frs1, id1_uses_frs2, id1_uses_frs3;

    cpu_decode u_decode (
        .inst(ifid_inst), .mstatus_fs_off(mstatus_fs_off),
        .opcode(id_opcode), .rs1(id_rs1), .rs2(id_rs2), .rd(id_rd),
        .funct3(id_funct3), .funct7(id_funct7),
        .imm_i(id_imm_i), .imm_s(id_imm_s), .imm_b(id_imm_b),
        .imm_u(id_imm_u), .imm_j(id_imm_j),
        .is_load(id_is_load), .is_store(id_is_store), .is_amo(id_is_amo),
        .is_branch(id_is_branch), .is_jal(id_is_jal), .is_jalr(id_is_jalr),
        .is_fence(id_is_fence), .fence_op(id_fence_op),
        .is_csr(id_is_csr), .is_fp_load(id_is_fp_load),
        .is_fp_store(id_is_fp_store), .is_fp_op(id_is_fp_op),
        .fregwrite(id_fregwrite), .illegal(id_illegal),
        .uses_rs1(id_uses_rs1), .uses_rs2(id_uses_rs2),
        .uses_frs1(id_uses_frs1), .uses_frs2(id_uses_frs2), .uses_frs3(id_uses_frs3)
    );

    // Slot 1 decode (verification parallel for ISSUE_WIDTH=2)
    cpu_decode u_decode1 (
        .inst(ifid1_inst), .mstatus_fs_off(mstatus_fs_off),
        .opcode(id1_opcode), .rs1(id1_rs1), .rs2(id1_rs2), .rd(id1_rd),
        .funct3(id1_funct3), .funct7(id1_funct7),
        .imm_i(id1_imm_i), .imm_s(id1_imm_s), .imm_b(id1_imm_b),
        .imm_u(id1_imm_u), .imm_j(id1_imm_j),
        .is_load(id1_is_load), .is_store(id1_is_store), .is_amo(id1_is_amo),
        .is_branch(id1_is_branch), .is_jal(id1_is_jal), .is_jalr(id1_is_jalr),
        .is_fence(id1_is_fence), .fence_op(id1_fence_op),
        .is_csr(id1_is_csr), .is_fp_load(id1_is_fp_load),
        .is_fp_store(id1_is_fp_store), .is_fp_op(id1_is_fp_op),
        .fregwrite(id1_fregwrite), .illegal(id1_illegal),
        .uses_rs1(id1_uses_rs1), .uses_rs2(id1_uses_rs2),
        .uses_frs1(id1_uses_frs1), .uses_frs2(id1_uses_frs2), .uses_frs3(id1_uses_frs3)
    );

    // Combinational regwrite: export for PRF/RAT gating at consume_ifid time
    assign id_regwrite = id_is_load || id_is_amo || id_is_jal || id_is_jalr
        || (id_opcode == 7'b0110011) || (id_opcode == 7'b0010011)
        || (id_opcode == 7'b0110111) || (id_opcode == 7'b0010111)
        || (id_is_csr && (id_rd != 5'd0))
        || (id_is_fp_op && (id_rd != 5'd0) && !id_fregwrite);
    assign id1_regwrite = id1_is_load || id1_is_amo || id1_is_jal || id1_is_jalr
        || (id1_opcode == 7'b0110011) || (id1_opcode == 7'b0010011)
        || (id1_opcode == 7'b0110111) || (id1_opcode == 7'b0010111)
        || (id1_is_csr && (id1_rd != 5'd0))
        || (id1_is_fp_op && (id1_rd != 5'd0) && !id1_fregwrite);
    // Removed: always_comb decode blocks (opcode extraction, operand usage,
    // instruction classification, illegal detection).
    wire  [4:0]  id_rs3 = ifid_inst[31:27];

    wire id_is_csr_pat = (ifid_inst[6:0] == 7'b1110011) && ((ifid_inst[14:12] == 3'b001)
        || (ifid_inst[14:12] == 3'b010) || (ifid_inst[14:12] == 3'b011)
        || (ifid_inst[14:12] == 3'b101) || (ifid_inst[14:12] == 3'b110)
        || (ifid_inst[14:12] == 3'b111));

    wire [11:0] id_csr_addr_u = ifid_inst[31:20];
    wire        id_csr_is_fp_csr = (id_csr_addr_u == 12'h001) || (id_csr_addr_u == 12'h002)
        || (id_csr_addr_u == 12'h003);

    logic [31:0] fp_busy_q;
    logic [31:0] fp_busy_d;
    logic        stall_fp_busy;

    wire id_fp_writes_frd = id_is_fp_load || (id_is_fp_op && id_fregwrite);
    wire id1_fp_writes_frd = id1_is_fp_load || (id1_is_fp_op && id1_fregwrite);
    wire id_any_fp = id_is_fp_load || id_is_fp_store || id_is_fp_op;
    wire id1_any_fp = id1_is_fp_load || id1_is_fp_store || id1_is_fp_op;
    wire id_bundle_has_fp = id_any_fp || (ifid1_valid && id1_any_fp);
    wire id1_fp_visible = ifid1_valid && !id_bundle_has_fp;

    always_comb begin
        fp_busy_d = fp_busy_q;
        if (frf_we)
            fp_busy_d[frf_waddr] = 1'b0;
        if (frf_we_b)
            fp_busy_d[frf_waddr_b] = 1'b0;
        if (consume_ifid && ifid_valid && id_fp_writes_frd)
            fp_busy_d[id_rd] = 1'b1;
        if (consume_ifid && ifid_valid && id1_fp_visible && id1_fp_writes_frd)
            fp_busy_d[id1_rd] = 1'b1;
    end

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn)
            fp_busy_q <= 32'b0;
        else if (redirect_valid)
            fp_busy_q <= 32'b0;
        else
            fp_busy_q <= fp_busy_d;
    end


    function automatic logic id_csr_insn_writes(input logic [31:0] ins);
        logic [2:0] f3; logic [4:0] rs1f;
        f3 = ins[14:12]; rs1f = ins[19:15];
        unique case (f3)
            3'b001, 3'b101: id_csr_insn_writes = 1'b1;
            3'b010, 3'b011, 3'b110, 3'b111: id_csr_insn_writes = (rs1f != 5'd0);
            default: id_csr_insn_writes = 1'b0;
        endcase
    endfunction
    logic stall_fp_load_use;
    always_comb begin
        stall_load_use = 1'b0;
        if (ifid_valid && idex_valid && (idex_is_load || idex_is_amo) && (idex_rd != 5'd0)) begin
            if (id_uses_rs1 && (id_rs1 == idex_rd)) stall_load_use = 1'b1;
            if (id_uses_rs2 && (id_rs2 == idex_rd)) stall_load_use = 1'b1;
            // Slot 1 check
            if ((ifid1_valid == 1'b1) && id1_uses_rs1 && (id1_rs1 == idex_rd)) stall_load_use = 1'b1;
            if ((ifid1_valid == 1'b1) && id1_uses_rs2 && (id1_rs2 == idex_rd)) stall_load_use = 1'b1;
        end
    end

    always_comb begin
        stall_fp_load_use = 1'b0;
        if (ifid_valid && idex_valid && idex_is_fp_load) begin
            if (id_uses_frs1 && (id_rs1 == idex_rd)) stall_fp_load_use = 1'b1;
            if (id_uses_frs2 && (id_rs2 == idex_rd)) stall_fp_load_use = 1'b1;
            if (id_uses_frs3 && (id_rs3 == idex_rd)) stall_fp_load_use = 1'b1;
            // Slot 1 check. If this bundle contains an FP instruction, core-level
            // split/refetch handles slot 1 so only slot 0 participates here.
            if (id1_fp_visible && id1_uses_frs1 && (id1_rs1 == idex_rd)) stall_fp_load_use = 1'b1;
            if (id1_fp_visible && id1_uses_frs2 && (id1_rs2 == idex_rd)) stall_fp_load_use = 1'b1;
        end
    end

    always_comb begin
        stall_fp_busy = 1'b0;
        if (ifid_valid) begin
            if (id_any_fp && (|fp_busy_q)) stall_fp_busy = 1'b1;
            if (id_uses_frs1 && fp_busy_q[id_rs1]) stall_fp_busy = 1'b1;
            if (id_uses_frs2 && fp_busy_q[id_rs2]) stall_fp_busy = 1'b1;
            if (id_uses_frs3 && fp_busy_q[id_rs3]) stall_fp_busy = 1'b1;
            if (id_fp_writes_frd && fp_busy_q[id_rd]) stall_fp_busy = 1'b1;

            if (id1_fp_visible) begin
                if (id1_uses_frs1 && fp_busy_q[id1_rs1]) stall_fp_busy = 1'b1;
                if (id1_uses_frs2 && fp_busy_q[id1_rs2]) stall_fp_busy = 1'b1;
                if (id1_uses_frs3 && fp_busy_q[ifid1_inst[31:27]]) stall_fp_busy = 1'b1;
                if (id1_fp_writes_frd && fp_busy_q[id1_rd]) stall_fp_busy = 1'b1;

                if (id_fp_writes_frd) begin
                    if (id1_uses_frs1 && (id1_rs1 == id_rd)) stall_fp_busy = 1'b1;
                    if (id1_uses_frs2 && (id1_rs2 == id_rd)) stall_fp_busy = 1'b1;
                    if (id1_uses_frs3 && (ifid1_inst[31:27] == id_rd)) stall_fp_busy = 1'b1;
                    if (id1_fp_writes_frd && (id1_rd == id_rd)) stall_fp_busy = 1'b1;
                end
            end
        end
    end

    always_comb begin
        stall_csr = 1'b0;
        if (ifid_valid && idex_valid && idex_is_csr) begin
            if (id_is_csr && id_csr_insn_writes(idex_inst) && (idex_inst[31:20] == ifid_inst[31:20]))
                stall_csr = 1'b1;
            // Slot 1 check
            if ((ifid1_valid == 1'b1) && id1_is_csr && id_csr_insn_writes(idex_inst) && (idex_inst[31:20] == ifid1_inst[31:20]))
                stall_csr = 1'b1;
        end
    end

    logic pipeline_advance;
    assign pipeline_advance = !stall_mem && !stall_fp && !fence_busy && !stall_csr && !stall_iq
        && !stall_prf && !stall_rob && !redirect_valid;
    assign consume_ifid     = pipeline_advance && ifid_valid && !stall_load_use && !stall_fp_load_use && !stall_fp_busy;

    always_comb begin
        idex_next_valid  = idex_valid;
        idex1_next_valid = idex1_valid;
        if (!pl_resetn) begin
            idex_next_valid  = 1'b0;
            idex1_next_valid = 1'b0;
        end else if (redirect_valid) begin
            idex_next_valid  = 1'b0;
            idex1_next_valid = 1'b0;
        end else if (stall_mem || stall_fp || fence_busy || stall_csr || stall_iq || stall_prf || stall_rob) begin
            idex_next_valid  = idex_valid;
            idex1_next_valid = idex1_valid;
        end else if (stall_load_use || stall_fp_load_use || stall_fp_busy) begin
            idex_next_valid  = 1'b0;
            idex1_next_valid = 1'b0;
        end else if (ifid_valid) begin
            idex_next_valid  = 1'b1;
            idex1_next_valid = ifid1_valid ? 1'b1 : 1'b0;
        end else begin
            idex_next_valid  = 1'b0;
            idex1_next_valid = 1'b0;
        end
    end

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            idex_valid <= 1'b0;
            idex_pc <= '0;
            idex_inst <= '0;
            idex_err <= 1'b0;
            idex_rs1 <= '0;
            idex_rs2 <= '0;
            idex_rd <= '0;
            idex_opcode <= '0;
            idex_funct3 <= '0;
            idex_funct7 <= '0;
            idex_imm_i <= '0;
            idex_imm_s <= '0;
            idex_imm_b <= '0;
            idex_imm_u <= '0;
            idex_imm_j <= '0;
            idex_rs1_val <= '0;
            idex_rs2_val <= '0;
            idex_regwrite <= 1'b0;
            idex_mem_read <= 1'b0;
            idex_mem_write <= 1'b0;
            idex_is_load <= 1'b0;
            idex_is_store <= 1'b0;
            idex_is_amo   <= 1'b0;
            idex_is_branch <= 1'b0;
            idex_is_jal <= 1'b0;
            idex_is_jalr <= 1'b0;
            idex_is_fence <= 1'b0;
            idex_fence_op <= CTL_FENCE;
            idex_illegal  <= 1'b0;
            idex_is_csr   <= 1'b0;
            idex_is_fp_load  <= 1'b0;
            idex_is_fp_store <= 1'b0;
            idex_is_fp_op    <= 1'b0;
            idex_fregwrite   <= 1'b0;
            idex_frs1_val    <= '0;
            idex_frs2_val    <= '0;
            idex_frs3_val    <= '0;
            idex_bp_pred_taken <= 1'b0;
            idex_bp_pred_meta  <= '0;
            // Slot 1 reset
            idex1_valid <= 1'b0;
            idex1_pc <= '0; idex1_inst <= '0;
            idex1_rs1 <= '0; idex1_rs2 <= '0; idex1_rd <= '0;
            idex1_opcode <= '0; idex1_funct3 <= '0; idex1_funct7 <= '0;
            idex1_imm_i <= '0; idex1_imm_s <= '0; idex1_imm_b <= '0; idex1_imm_u <= '0; idex1_imm_j <= '0;
            idex1_rs1_val <= '0; idex1_rs2_val <= '0;
            idex1_regwrite <= 1'b0;
            idex1_is_load <= 1'b0; idex1_is_store <= 1'b0; idex1_is_amo <= 1'b0;
            idex1_is_branch <= 1'b0; idex1_is_jal <= 1'b0; idex1_is_jalr <= 1'b0;
            idex1_is_fence <= 1'b0; idex1_fence_op <= '0;
            idex1_is_csr <= 1'b0;
            idex1_is_fp_load <= 1'b0; idex1_is_fp_store <= 1'b0; idex1_is_fp_op <= 1'b0;
            idex1_fregwrite <= 1'b0;
            idex1_frs1_val <= '0; idex1_frs2_val <= '0; idex1_frs3_val <= '0;
            idex1_bp_pred_taken <= 1'b0; idex1_bp_pred_meta <= '0;
        end else begin
            if (redirect_valid) begin
                idex_valid  <= 1'b0;
                idex1_valid <= 1'b0;
            end else if (stall_mem || stall_fp || fence_busy || stall_csr || stall_iq || stall_prf || stall_rob) begin
            end else begin
                if (stall_load_use || stall_fp_load_use || stall_fp_busy) begin
                    idex_valid  <= 1'b0;
                    idex1_valid <= 1'b0;
                end else begin
                if (ifid_valid) begin
                    idex_valid <= 1'b1;
                    idex_pc <= ifid_pc;
                    idex_inst <= ifid_inst;
                    idex_err <= ifid_err;

                        idex_rs1 <= id_rs1;
                        idex_rs2 <= id_rs2;
                        idex_rd <= id_rd;
                        idex_opcode <= id_opcode;
                        idex_funct3 <= id_funct3;
                        idex_funct7 <= id_funct7;

                        idex_imm_i <= id_imm_i;
                        idex_imm_s <= id_imm_s;
                        idex_imm_b <= id_imm_b;
                        idex_imm_u <= id_imm_u;
                        idex_imm_j <= id_imm_j;

                        idex_rs1_val <= rf_rs1_val;
                        idex_rs2_val <= rf_rs2_val;
                        idex_frs1_val <= frf_rs1_val;
                        idex_frs2_val <= frf_rs2_val;
                        idex_frs3_val <= frf_rs3_val;

                        idex_is_load <= id_is_load;
                        idex_is_store <= id_is_store;
                        idex_is_amo   <= id_is_amo;
                        idex_is_fp_load <= id_is_fp_load;
                        idex_is_fp_store <= id_is_fp_store;
                        idex_is_fp_op <= id_is_fp_op;
                        idex_fregwrite <= id_fregwrite;
                        idex_is_branch <= id_is_branch;
                        idex_is_jal <= id_is_jal;
                        idex_is_jalr <= id_is_jalr;
                        idex_is_fence <= id_is_fence;
                        idex_fence_op <= id_fence_op;
                        idex_illegal   <= id_illegal;
                        idex_is_csr    <= id_is_csr;

                        idex_mem_read <= id_is_load || id_is_fp_load;
                        idex_mem_write <= id_is_store || id_is_fp_store;

                        idex_regwrite <= (id_is_load || id_is_amo || id_is_jal || id_is_jalr ||
                                         (id_opcode == 7'b0110011) ||
                                         (id_opcode == 7'b0010011) ||
                                         (id_opcode == 7'b0110111) ||
                                         (id_opcode == 7'b0010111) ||
                                         (id_is_csr && (id_rd != 5'd0)) ||
                                         (id_is_fp_op && (id_rd != 5'd0) && !id_fregwrite));

                        idex_bp_pred_taken <= ifid_bp_pred_taken;
                        idex_bp_pred_meta  <= ifid_bp_pred_meta;
                    end else begin
                        idex_valid  <= 1'b0;
                        idex1_valid <= 1'b0;
                    end
                    // Slot 1 pipeline capture
                    if (ifid1_valid) begin
                        idex1_valid <= 1'b1;
                        idex1_pc   <= ifid_pc + 32'd4;
                        idex1_inst <= ifid1_inst;
                        idex1_rs1  <= id1_rs1;
                        idex1_rs2  <= id1_rs2;
                        idex1_rd   <= id1_rd;
                        idex1_opcode <= id1_opcode;
                        idex1_funct3 <= id1_funct3;
                        idex1_funct7 <= id1_funct7;
                        idex1_imm_i <= id1_imm_i;
                        idex1_imm_s <= id1_imm_s;
                        idex1_imm_b <= id1_imm_b;
                        idex1_imm_u <= id1_imm_u;
                        idex1_imm_j <= id1_imm_j;
                        idex1_rs1_val <= rf_rs1_val_1;
                        idex1_rs2_val <= rf_rs2_val_1;
                        idex1_regwrite <= id1_regwrite;
                        idex1_is_load <= id1_is_load;
                        idex1_is_store<= id1_is_store;
                        idex1_is_amo  <= id1_is_amo;
                        idex1_is_fp_load <= id1_is_fp_load;
                        idex1_is_fp_store <= id1_is_fp_store;
                        idex1_is_fp_op <= id1_is_fp_op;
                        idex1_fregwrite <= id1_fregwrite;
                        idex1_is_branch <= id1_is_branch;
                        idex1_is_jal <= id1_is_jal;
                        idex1_is_jalr <= id1_is_jalr;
                        idex1_is_fence <= id1_is_fence;
                        idex1_fence_op <= id1_fence_op;
                        idex1_is_csr    <= id1_is_csr;
                        idex1_frs1_val <= frf_rs1_val_1;
                        idex1_frs2_val <= frf_rs2_val_1;
                        idex1_frs3_val <= frf_rs3_val_1;
                        idex1_bp_pred_taken <= ifid1_bp_pred_taken;
                        idex1_bp_pred_meta  <= ifid1_bp_pred_meta;
                    end else begin
                        idex1_valid <= 1'b0;
                    end
                end
            end
        end
    end

endmodule
