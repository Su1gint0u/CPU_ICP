// Execute stage: forwarding, ALU + RV32M, branch/trap redirect, EX/MEM register, BP + fence ctl outputs.
module cpu_ex_stage #(
    parameter int unsigned XLEN = 32,
    parameter int unsigned ROB_TAG_W = 5
) (
    input  logic pl_clk,
    input  logic pl_resetn,

    input  logic stall_mem,
    input  logic fence_busy,

    input  logic        idex_valid,
    input  logic [31:0] idex_pc,
    input  logic [31:0] idex_inst,
    input  logic [4:0]  idex_rs1,
    input  logic [4:0]  idex_rs2,
    input  logic [4:0]  idex_rd,
    input  logic [6:0]  idex_opcode,
    input  logic [2:0]  idex_funct3,
    input  logic [6:0]  idex_funct7,
    input  logic [31:0] idex_imm_i,
    input  logic [31:0] idex_imm_s,
    input  logic [31:0] idex_imm_b,
    input  logic [31:0] idex_imm_u,
    input  logic [31:0] idex_imm_j,
    input  logic [31:0] idex_rs1_val,
    input  logic [31:0] idex_rs2_val,
    input  logic        idex_regwrite,
    input  logic        idex_mem_read,
    input  logic        idex_mem_write,
    input  logic        idex_is_load,
    input  logic        idex_is_store,
    input  logic        idex_is_amo,
    input  logic        idex_is_branch,
    input  logic        idex_is_jal,
    input  logic        idex_is_jalr,
    input  logic        idex_is_fence,
    input  logic [2:0]  idex_fence_op,
    input  logic        idex_illegal,
    input  logic        idex_err,
    input  logic        idex_is_csr,
    input  logic        idex_is_fp_load,
    input  logic        idex_is_fp_store,
    input  logic        idex_is_fp_op,
    input  logic        idex_fregwrite,
    input  logic [31:0] idex_frs1_val,
    input  logic [31:0] idex_frs2_val,
    input  logic [31:0] idex_frs3_val,
    input  logic        idex_bp_pred_taken,
    input  logic [63:0] idex_bp_pred_meta,
    input  logic [5:0]  idex_prs1, idex_prs2, idex_prd,
    input  logic [ROB_TAG_W-1:0] idex_rob_ptr,
    input  logic [2:0]  frm_csr,

    // Slot 1 (ISSUE_WIDTH=2) — used for second ALU only
    input  logic        idex1_valid,
    input  logic [31:0] idex1_pc, idex1_inst,
    input  logic [4:0]  idex1_rd,
    input  logic [6:0]  idex1_opcode,
    input  logic [2:0]  idex1_funct3,
    input  logic [6:0]  idex1_funct7,
    input  logic [31:0] idex1_rs1_val, idex1_rs2_val,
    input  logic [31:0] idex1_imm_i, idex1_imm_s, idex1_imm_u,
    input  logic [31:0] idex1_imm_b, idex1_imm_j,
    input  logic        idex1_bp_pred_taken,
    input  logic [5:0]  idex1_prs1, idex1_prs2, idex1_prd,
    input  logic [ROB_TAG_W-1:0] idex1_rob_ptr,

    input  logic        exmem_fregwrite_i,
    input  logic        memwb_is_fp_load,

    input  logic [31:0] mtvec_q,
    input  logic [31:0] mepc_q,
    input  logic [31:0] csr_rdata,

    input  logic        exmem_valid,
    input  logic [4:0]  exmem_rd,
    input  logic        exmem_regwrite,
    input  logic        exmem_is_load,
    input  logic        exmem_is_amo,
    input  logic [31:0]  exmem_alu_result,
    input  logic [5:0]   exmem_prd_i,

    input  logic        memwb_valid,
    input  logic [4:0]  memwb_rd,
    input  logic        memwb_regwrite,
    input  logic [31:0]  memwb_wdata,
    input  logic [5:0]   memwb_prd_i,

    input  logic        exmem1_valid,
    input  logic        exmem1_regwrite,
    input  logic [31:0] exmem1_alu_result,
    input  logic [5:0]  exmem1_prd_i,

    input  logic        i_req_valid,
    input  logic        stall_all,
    input  logic        fetch_inflight,

    output logic        trap_taken,
    output logic [31:0] trap_cause_val_comb,
    output logic        mret_taken,

    output logic        redirect_valid,
    output logic [31:0] redirect_pc,

    output logic        bp_if_valid,
    output logic [31:0] bp_if_pc,
    output logic        bp_upd_valid,
    output logic [31:0] bp_upd_pc,
    output logic        bp_upd_taken,
    output logic        bp_upd_mispredict,
    // Same-cycle RAT checkpoint pop (registered bp_upd_mispredict is one cycle late vs redirect).
    output logic        bp_rat_cp_pop,
    // Checkpoint release: branch resolved correctly → pop without restoring RAT.
    output logic        bp_rat_cp_release,
    output logic [5:0]  bp_rat_cp_pop_rob_ptr,
    output logic [5:0]  bp_rat_cp_release_rob_ptr,
    output logic        bp_rat_cp_fixup_valid,
    output logic [4:0]  bp_rat_cp_fixup_rd,
    output logic [5:0]  bp_rat_cp_fixup_prd,
    // Rob_ptr of the instruction triggering redirect (for correct squash pointer)
    output logic [5:0]  fu_redirect_rob_ptr,
    output logic [63:0] bp_upd_meta,
    output logic [31:0] bp_upd_branch_target,

    output logic        ctl_req_valid,
    output logic [2:0]  ctl_req_op,
    output logic [31:0] ctl_req_addr,

    input  logic [31:0] if_pc_for_bp,

    output logic        exmem_valid_o,
    output logic [31:0] exmem_pc_o,
    output logic [31:0] exmem_inst_o,
    output logic [4:0]  exmem_rd_o,
    output logic [5:0]  exmem_prd_o,
    output logic [ROB_TAG_W-1:0] exmem_rob_ptr_o,
    output logic        exmem_regwrite_o,
    output logic        exmem_is_load_o,
    output logic        exmem_is_store_o,
    output logic        exmem_is_amo_o,
    output logic        exmem_is_branch_o,
    output logic        exmem_is_jal_o,
    output logic        exmem_is_jalr_o,
    output logic        exmem_is_fence_o,
    output logic        exmem_is_csr_o,
    output logic        exmem_mem_read_o,
    output logic [31:0] exmem_alu_result_o,
    output logic [31:0] exmem_mem_addr_o,
    output logic [2:0]  exmem_mem_cmd_o,
    output logic [2:0]  exmem_mem_size_o,
    output logic [31:0] exmem_store_wdata_o,
    output logic [3:0]  exmem_store_wstrb_o,
    output logic [2:0]  exmem_load_funct3_o,
    output logic [4:0]  exmem_amo_funct_o,
    output logic        exmem_amo_aq_o,
    output logic        exmem_amo_rl_o,
    output logic        exmem_fregwrite_o,
    output logic        exmem_is_fp_load_o,

    // Slot 1 EX/MEM (ALU ops only)
    output logic        exmem1_valid_o,
    output logic [31:0] exmem1_alu_result_o,
    output logic [4:0]  exmem1_rd_o,
    output logic [5:0]  exmem1_prd_o,
    output logic [ROB_TAG_W-1:0] exmem1_rob_ptr_o,
    output logic        exmem1_regwrite_o,
    output logic [31:0] exmem1_pc_o, exmem1_inst_o,
    output logic        exmem1_redirect_valid,
    output logic [31:0] exmem1_redirect_pc,
    output logic        exmem1_is_load_o, exmem1_is_store_o,
    output logic [31:0] exmem1_mem_addr_o,
    output logic [2:0]  exmem1_mem_cmd_o, exmem1_mem_size_o,
    output logic [31:0] exmem1_store_wdata_o,
    output logic [3:0]  exmem1_store_wstrb_o,

    output logic [4:0]  fp_fflags_inc,
    output logic        fp_fflags_we,

    output logic        stall_fp,
    output logic [7:0]  dbg_flags,

    output logic        csr_wr_en,
    output logic [11:0] csr_wr_addr,
    output logic [31:0] csr_wr_data
);

    localparam logic [2:0] D_CMD_LD = 3'b001;
    localparam logic [2:0] D_CMD_ST = 3'b010;
    localparam logic [2:0] D_CMD_AMO = 3'b011;
    localparam logic [2:0] SZ_1B = 3'd0;
    localparam logic [2:0] SZ_2B = 3'd1;
    localparam logic [2:0] SZ_4B = 3'd2;

    function automatic logic [2:0] load_size(input logic [2:0] funct3);
        unique case (funct3)
            3'b000, 3'b100: load_size = SZ_1B; // LB/LBU
            3'b001, 3'b101: load_size = SZ_2B; // LH/LHU
            3'b010:         load_size = SZ_4B; // LW
            default:        load_size = SZ_4B;
        endcase
    endfunction

    function automatic logic [2:0] store_size(input logic [2:0] funct3);
        unique case (funct3)
            3'b000:  store_size = SZ_1B; // SB
            3'b001:  store_size = SZ_2B; // SH
            3'b010:  store_size = SZ_4B; // SW
            default: store_size = SZ_4B;
        endcase
    endfunction

    function automatic logic [3:0] store_wstrb(input logic [31:0] addr, input logic [2:0] funct3);
        unique case (funct3)
            3'b000:  store_wstrb = 4'b0001 << addr[1:0];
            3'b001:  store_wstrb = addr[1] ? 4'b1100 : 4'b0011;
            3'b010:  store_wstrb = 4'b1111;
            default: store_wstrb = 4'b1111;
        endcase
    endfunction

    localparam logic [2:0] CTL_FENCE      = 3'b000;
    localparam logic [2:0] CTL_FENCE_I    = 3'b001;

    logic [31:0] fwd_rs1_val, fwd_rs2_val;
    logic [31:0] eff_s_addr;
    logic [31:0] eff_i_addr;

    always_comb begin
        eff_s_addr = fwd_rs1_val + idex_imm_s;
        eff_i_addr = fwd_rs1_val + idex_imm_i;
    end

    always_comb begin
        fwd_rs1_val = idex_rs1_val;
        if (exmem_valid && exmem_regwrite && !exmem_is_load && !exmem_is_amo && (exmem_prd_i != 6'd0)
            && (exmem_prd_i == idex_prs1)) begin
            fwd_rs1_val = exmem_alu_result;
        end else if (exmem1_valid && exmem1_regwrite && (exmem1_prd_i != 6'd0)
            && (exmem1_prd_i == idex_prs1)) begin
            fwd_rs1_val = exmem1_alu_result;
        end else if (memwb_valid && memwb_regwrite && (memwb_prd_i != 6'd0)
            && (memwb_prd_i == idex_prs1)) begin
            fwd_rs1_val = memwb_wdata;
        end

        fwd_rs2_val = idex_rs2_val;
        if (exmem_valid && exmem_regwrite && !exmem_is_load && !exmem_is_amo && (exmem_prd_i != 6'd0)
            && (exmem_prd_i == idex_prs2)) begin
            fwd_rs2_val = exmem_alu_result;
        end else if (exmem1_valid && exmem1_regwrite && (exmem1_prd_i != 6'd0)
            && (exmem1_prd_i == idex_prs2)) begin
            fwd_rs2_val = exmem1_alu_result;
        end else if (memwb_valid && memwb_regwrite && (memwb_prd_i != 6'd0)
            && (memwb_prd_i == idex_prs2)) begin
            fwd_rs2_val = memwb_wdata;
        end
    end

    logic [31:0] fwd_frs1_val;
    logic [31:0] fwd_frs2_val;

    always_comb begin
        fwd_frs1_val = idex_frs1_val;
        if (exmem_valid && exmem_fregwrite_i && !exmem_is_load && (exmem_prd_i != 6'd0)
            && (exmem_prd_i == idex_prs1)) begin
            fwd_frs1_val = exmem_alu_result;
        end else if (memwb_valid && memwb_is_fp_load && (memwb_prd_i != 6'd0)
            && (memwb_prd_i == idex_prs1)) begin
            fwd_frs1_val = memwb_wdata;
        end

        fwd_frs2_val = idex_frs2_val;
        if (exmem_valid && exmem_fregwrite_i && !exmem_is_load && (exmem_prd_i != 6'd0)
            && (exmem_prd_i == idex_prs2)) begin
            fwd_frs2_val = exmem_alu_result;
        end else if (memwb_valid && memwb_is_fp_load && (memwb_prd_i != 6'd0)
            && (memwb_prd_i == idex_prs2)) begin
            fwd_frs2_val = memwb_wdata;
        end
    end

    logic [31:0] fwd_frs3_val;
    wire   [4:0] idex_frs3_addr = idex_inst[31:27];
    wire         idex_is_fp_r4  = (idex_opcode == 7'h43) || (idex_opcode == 7'h47) || (idex_opcode == 7'h4b)
        || (idex_opcode == 7'h4f);

    always_comb begin
        fwd_frs3_val = idex_frs3_val;
        if (exmem_valid && exmem_fregwrite_i && !exmem_is_load && idex_is_fp_r4
            && (exmem_rd == idex_frs3_addr)) begin
            fwd_frs3_val = exmem_alu_result;
        end else if (memwb_valid && memwb_is_fp_load && idex_is_fp_r4
            && (memwb_rd == idex_frs3_addr)) begin
            fwd_frs3_val = memwb_wdata;
        end
    end

    logic [31:0] fp_result;
    logic        fp_illegal_fpu;
    logic [4:0]  fp_fflags_raw;
    logic        stall_fpu;

    fpu_wrapper u_fpu (
        .pl_clk     (pl_clk),
        .pl_resetn  (pl_resetn),
        .redirect_valid (redirect_valid),
        .idex_valid (idex_valid),
        .idex_pc    (idex_pc),
        .inst       (idex_inst),
        .frs1       (fwd_frs1_val),
        .frs2       (fwd_frs2_val),
        .frs3       (fwd_frs3_val),
        .irs1       (fwd_rs1_val),
        .frm_csr    (frm_csr),
        .result     (fp_result),
        .illegal    (fp_illegal_fpu),
        .fflags     (fp_fflags_raw),
        .stall_fp   (stall_fpu)
    );

    assign fp_fflags_we  = idex_valid && idex_is_fp_op && !fp_illegal_fpu && !idex_err && !idex_illegal
        && !stall_mem && !fence_busy && !stall_fp;
    assign fp_fflags_inc = fp_fflags_raw;

    logic [31:0] ex_alu;
    wire  [31:0] ex_branch_target = idex_pc + idex_imm_b;
    logic        ex_take_branch;
    logic [31:0] ex_jump_target;

    // ── FU sub-modules (active, replace monolithic always_comb case) ──
    logic fu_alu_op, fu_muldiv_op, fu_bru_op;
    logic [31:0] fu_alu_result, fu_muldiv_result;
    logic        fu_bru_take, fu_bru_redirect;
    logic [31:0] fu_bru_redirect_pc, fu_bru_jump_target;
    logic        fu_mul1_op;
    logic        md0_start, md0_clear, md0_busy, md0_done;
    logic        md1_start, md1_clear, md1_busy, md1_done;
    logic        muldiv_wait;
    logic        slot0_can_capture;
    logic        slot1_can_capture;

    assign fu_alu_op = idex_valid && (
        (idex_opcode == 7'b0110011 && idex_funct7 != 7'h01) || (idex_opcode == 7'b0010011)
        || (idex_opcode == 7'b0110111) || (idex_opcode == 7'b0010111));
    assign fu_muldiv_op = idex_valid && (idex_opcode == 7'b0110011 && idex_funct7 == 7'h01);
    assign fu_bru_op = idex_valid && (
        (idex_opcode == 7'b1101111) || (idex_opcode == 7'b1100111) || (idex_opcode == 7'b1100011));

    cpu_alu u_alu (
        .opcode(idex_opcode), .funct3(idex_funct3), .funct7(idex_funct7),
        .fwd_rs1_val(fwd_rs1_val), .fwd_rs2_val(fwd_rs2_val),
        .imm_i(idex_imm_i), .imm_u(idex_imm_u), .pc(idex_pc),
        .result(fu_alu_result)
    );
    logic [31:0] fu_alu1_result;
    logic [31:0] fwd1_rs1_val, fwd1_rs2_val;

    always_comb begin
        fwd1_rs1_val = idex1_rs1_val;
        if (exmem_valid && exmem_regwrite && !exmem_is_load && !exmem_is_amo && (exmem_prd_i != 6'd0) && (exmem_prd_i == idex1_prs1))
            fwd1_rs1_val = exmem_alu_result;
        else if (exmem1_valid && exmem1_regwrite && (exmem1_prd_i != 6'd0) && (exmem1_prd_i == idex1_prs1))
            fwd1_rs1_val = exmem1_alu_result;
        else if (memwb_valid && memwb_regwrite && (memwb_prd_i != 6'd0) && (memwb_prd_i == idex1_prs1))
            fwd1_rs1_val = memwb_wdata;
        fwd1_rs2_val = idex1_rs2_val;
        if (exmem_valid && exmem_regwrite && !exmem_is_load && !exmem_is_amo && (exmem_prd_i != 6'd0) && (exmem_prd_i == idex1_prs2))
            fwd1_rs2_val = exmem_alu_result;
        else if (exmem1_valid && exmem1_regwrite && (exmem1_prd_i != 6'd0) && (exmem1_prd_i == idex1_prs2))
            fwd1_rs2_val = exmem1_alu_result;
        else if (memwb_valid && memwb_regwrite && (memwb_prd_i != 6'd0) && (memwb_prd_i == idex1_prs2))
            fwd1_rs2_val = memwb_wdata;
    end

    cpu_alu u_alu1 (
        .opcode(idex1_opcode), .funct3(idex1_funct3), .funct7(idex1_funct7),
        .fwd_rs1_val(fwd1_rs1_val), .fwd_rs2_val(fwd1_rs2_val),
        .imm_i(idex1_imm_i), .imm_u(idex1_imm_u), .pc(idex1_pc),
        .result(fu_alu1_result)
    );
    logic [31:0] fu_alu2_result, fu_alu3_result;
    cpu_alu u_alu2 (
        .opcode(idex1_opcode), .funct3(idex1_funct3), .funct7(idex1_funct7),
        .fwd_rs1_val(fwd1_rs1_val), .fwd_rs2_val(fwd1_rs2_val),
        .imm_i(idex1_imm_i), .imm_u(idex1_imm_u), .pc(idex1_pc),
        .result(fu_alu2_result)
    );
    cpu_alu u_alu3 (
        .opcode(idex1_opcode), .funct3(idex1_funct3), .funct7(idex1_funct7),
        .fwd_rs1_val(fwd1_rs1_val), .fwd_rs2_val(fwd1_rs2_val),
        .imm_i(idex1_imm_i), .imm_u(idex1_imm_u), .pc(idex1_pc),
        .result(fu_alu3_result)
    );
    logic [31:0] fu_bru1_jump_target, fu_bru1_redirect_pc;
    logic fu_bru1_take, fu_bru1_redirect;
    cpu_bru u_bru1 (
        .opcode(idex1_opcode), .funct3(idex1_funct3),
        .fwd_rs1_val(fwd1_rs1_val), .fwd_rs2_val(fwd1_rs2_val),
        .idex_pc(idex1_pc), .imm_b(idex1_imm_b), .imm_j(idex1_imm_j),
        .imm_i(idex1_imm_i), .idex_valid(idex1_valid),
        .bp_pred_taken(idex1_bp_pred_taken),
        .branch_target(),
        .take_branch(fu_bru1_take), .jump_target(fu_bru1_jump_target),
        .redirect_valid(fu_bru1_redirect), .redirect_pc(fu_bru1_redirect_pc)
    );
    logic [31:0] fu_mul1_result;
    assign fu_mul1_op = idex1_valid && (idex1_opcode == 7'b0110011) && (idex1_funct7 == 7'h01);

    assign slot0_can_capture = !fence_busy && !stall_fpu
        && (!stall_mem || !(exmem_valid_o && (exmem_is_load_o || exmem_is_store_o || exmem_is_amo_o || exmem_is_fp_load_o)));
    assign slot1_can_capture = !fence_busy && !stall_fpu && !stall_mem;

    assign md0_start = fu_muldiv_op && !md0_busy && !md0_done;
    assign md1_start = fu_mul1_op && !md1_busy && !md1_done;
    assign md0_clear = fu_muldiv_op && md0_done && slot0_can_capture;
    assign md1_clear = fu_mul1_op && md1_done && slot1_can_capture;
    assign muldiv_wait = (fu_muldiv_op && !md0_done) || (fu_mul1_op && !md1_done);
    assign stall_fp = stall_fpu || muldiv_wait;
    assign dbg_flags = {
        muldiv_wait,
        stall_fpu,
        md1_done,
        md1_busy,
        md1_start,
        md0_done,
        md0_busy,
        md0_start
    };

    cpu_muldiv u_md1 (
        .pl_clk(pl_clk), .pl_resetn(pl_resetn),
        .start(md1_start), .clear(md1_clear),
        .funct3(idex1_funct3), .fwd_rs1_val(fwd1_rs1_val), .fwd_rs2_val(fwd1_rs2_val),
        .busy(md1_busy), .done(md1_done),
        .result(fu_mul1_result)
    );
    cpu_muldiv u_md (
        .pl_clk(pl_clk), .pl_resetn(pl_resetn),
        .start(md0_start), .clear(md0_clear),
        .funct3(idex_funct3), .fwd_rs1_val(fwd_rs1_val), .fwd_rs2_val(fwd_rs2_val),
        .busy(md0_busy), .done(md0_done),
        .result(fu_muldiv_result)
    );
    cpu_bru u_bru (
        .opcode(idex_opcode), .funct3(idex_funct3),
        .fwd_rs1_val(fwd_rs1_val), .fwd_rs2_val(fwd_rs2_val),
        .idex_pc(idex_pc), .imm_b(idex_imm_b), .imm_j(idex_imm_j),
        .imm_i(idex_imm_i), .idex_valid(idex_valid),
        .bp_pred_taken(idex_bp_pred_taken),
        .branch_target(ex_branch_target),
        .take_branch(fu_bru_take), .jump_target(fu_bru_jump_target),
        .redirect_valid(fu_bru_redirect), .redirect_pc(fu_bru_redirect_pc)
    );

    wire idex_ctrl_valid = idex_valid && (idex_is_branch || idex_is_jal || idex_is_jalr);
    wire idex_nonctrl_spec_redirect = idex_valid && idex_bp_pred_taken
        && !(idex_is_branch || idex_is_jal || idex_is_jalr);
    wire idex1_is_ctrl = (idex1_opcode == 7'b1100011) || (idex1_opcode == 7'b1101111)
        || (idex1_opcode == 7'b1100111);
    wire idex1_ctrl_valid = idex1_valid && idex1_is_ctrl;
    wire idex_ctrl_redirect = idex_ctrl_valid && fu_bru_redirect;
    wire idex1_ctrl_redirect = idex1_ctrl_valid && fu_bru1_redirect;
    wire rat_pop_slot0 = idex_ctrl_redirect;
    wire rat_pop_slot1 = !rat_pop_slot0 && idex1_ctrl_redirect;
    wire rat_pop_any = rat_pop_slot0 || rat_pop_slot1;

    assign bp_rat_cp_pop = rat_pop_any;
    assign bp_rat_cp_pop_rob_ptr = rat_pop_slot0 ? idex_rob_ptr : idex1_rob_ptr;
    // Checkpoint release: control-flow resolved without redirect; a same-cycle older pop wins.
    assign bp_rat_cp_release = !rat_pop_any && (
        (idex_ctrl_valid && !fu_bru_redirect)
        || (idex1_ctrl_valid && !fu_bru1_redirect)
    );
    assign bp_rat_cp_release_rob_ptr = (idex_ctrl_valid && !fu_bru_redirect)
        ? idex_rob_ptr : idex1_rob_ptr;
    assign bp_rat_cp_fixup_valid = (rat_pop_slot0 && idex_regwrite && (idex_rd != 5'd0))
        || (rat_pop_slot1 && ((idex1_opcode == 7'b1101111) || (idex1_opcode == 7'b1100111))
            && (idex1_rd != 5'd0));
    assign bp_rat_cp_fixup_rd = rat_pop_slot0 ? idex_rd : idex1_rd;
    assign bp_rat_cp_fixup_prd = rat_pop_slot0 ? idex_prd : idex1_prd;

    always_comb begin
        redirect_valid = 1'b0;
        redirect_pc    = 32'b0;
        fu_redirect_rob_ptr = 6'd0;
        ex_alu = 32'b0;
        ex_take_branch = 1'b0;
        ex_jump_target = 32'b0;

        if (trap_taken) begin
            redirect_valid = idex_valid;
            redirect_pc    = (mtvec_q & ~32'h3)
                + ((mtvec_q[1:0] == 2'b01) ? ((trap_cause_val_comb & 32'h7FFF_FFFF) << 2) : 32'b0);
            fu_redirect_rob_ptr = idex_rob_ptr;
        end else if (mret_taken) begin
            redirect_valid = idex_valid;
            redirect_pc    = mepc_q;
            fu_redirect_rob_ptr = idex_rob_ptr;
        end else if (idex_valid && idex_is_csr) begin
            ex_alu = csr_rdata;
`ifndef SYNTHESIS
            if ($test$plusargs("CSR_DBG")) begin
                $display("[EX_CSR_DBG] %m t=%0t pc=0x%08x inst=0x%08x rd=%0d prd=%0d rob=%0d csr=0x%03x rdata=0x%08x",
                         $time, idex_pc, idex_inst, idex_rd, idex_prd, idex_rob_ptr,
                         idex_inst[31:20], csr_rdata);
            end
`endif
        end else if (idex_valid && idex_is_fp_op && !trap_taken) begin
            ex_alu = fp_result;
        end else if (fu_alu_op) begin
            ex_alu = fu_alu_result;
        end else if (fu_muldiv_op) begin
            ex_alu = fu_muldiv_result;
        end else if (fu_bru_op) begin
            ex_take_branch = fu_bru_take;
            ex_jump_target = fu_bru_jump_target;
            redirect_valid = fu_bru_redirect;
            redirect_pc    = fu_bru_redirect_pc;
            fu_redirect_rob_ptr = idex_rob_ptr;
            if (idex_opcode == 7'b1101111 || idex_opcode == 7'b1100111)
                ex_alu = idex_pc + 32'd4;
        end

        if (!trap_taken && !mret_taken && idex_nonctrl_spec_redirect) begin
            // Recover a BTB alias without suppressing the real instruction at this PC.
            redirect_valid = 1'b1;
            redirect_pc    = idex_pc + 32'd4;
            fu_redirect_rob_ptr = idex_rob_ptr;
        end
    end

    logic        csr_imm_form;
    logic [31:0] csr_uop;

    always_comb begin
        csr_wr_en    = 1'b0;
        csr_wr_addr  = idex_inst[31:20];
        csr_wr_data  = 32'b0;
        csr_imm_form = idex_funct3[2];
        csr_uop      = csr_imm_form ? {27'b0, idex_rs1} : fwd_rs1_val;
        if (idex_valid && idex_is_csr && !trap_taken && !mret_taken && !stall_mem && !fence_busy) begin
            unique case (idex_funct3)
                3'b001: begin
                    csr_wr_data = csr_uop;
                    csr_wr_en   = 1'b1;
                end
                3'b010: begin
                    if (csr_imm_form || (idex_rs1 != 5'd0)) begin
                        csr_wr_data = csr_rdata | csr_uop;
                        csr_wr_en   = 1'b1;
                    end
                end
                3'b011: begin
                    if (csr_imm_form || (idex_rs1 != 5'd0)) begin
                        csr_wr_data = csr_rdata & ~csr_uop;
                        csr_wr_en   = 1'b1;
                    end
                end
                3'b101: begin
                    csr_wr_data = csr_uop;
                    csr_wr_en   = 1'b1;
                end
                3'b110: begin
                    if (idex_rs1 != 5'd0) begin
                        csr_wr_data = csr_rdata | csr_uop;
                        csr_wr_en   = 1'b1;
                    end
                end
                3'b111: begin
                    if (idex_rs1 != 5'd0) begin
                        csr_wr_data = csr_rdata & ~csr_uop;
                        csr_wr_en   = 1'b1;
                    end
                end
                default: begin
                end
            endcase
        end
    end

    // Combinational BP queries + update logic
    logic        bp_upd_valid_comb;
    logic [31:0] bp_upd_pc_comb;
    logic        bp_upd_taken_comb;
    logic        bp_upd_mispredict_comb;
    logic [31:0] bp_upd_branch_target_comb;
    logic [63:0] bp_upd_meta_comb;

    always_comb begin
        bp_if_valid = i_req_valid && !stall_all && !fetch_inflight;
        bp_if_pc    = if_pc_for_bp;
        bp_upd_valid_comb = idex_valid && (idex_is_branch || idex_is_jal || idex_is_jalr);
        bp_upd_pc_comb    = idex_pc;
        bp_upd_taken_comb = idex_is_branch ? ex_take_branch : 1'b1;
        bp_upd_mispredict_comb = bp_upd_valid_comb && idex_is_branch
            && (idex_bp_pred_taken != ex_take_branch);
        bp_upd_branch_target_comb = (idex_is_jal || idex_is_jalr) ? ex_jump_target : ex_branch_target;
        bp_upd_meta_comb = idex_bp_pred_meta;
        if (bp_upd_valid_comb) begin
            if (idex_is_branch)
                bp_upd_meta_comb = {idex_bp_pred_meta[63:32], 2'b00, idex_bp_pred_meta[29:0]};
            else if (idex_is_jal)
                bp_upd_meta_comb = {32'b0, 2'b01, 3'b0, idex_rd, 22'b0};
            else if (idex_is_jalr)
                bp_upd_meta_comb = {32'b0, 2'b10, 3'b0, idex_rd, idex_rs1, idex_imm_i[11:0], 5'b0};
        end
    end

    // BP update register: ensures update survives redirect-induced idex_valid clear
    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            bp_upd_valid <= 1'b0;
            bp_upd_pc <= '0;
            bp_upd_taken <= 1'b0;
            bp_upd_mispredict <= 1'b0;
            bp_upd_meta <= '0;
            bp_upd_branch_target <= '0;
        end else begin
            if (bp_upd_valid_comb) begin
                bp_upd_valid <= 1'b1;
                bp_upd_pc <= bp_upd_pc_comb;
                bp_upd_taken <= bp_upd_taken_comb;
                bp_upd_mispredict <= bp_upd_mispredict_comb;
                bp_upd_meta <= bp_upd_meta_comb;
                bp_upd_branch_target <= bp_upd_branch_target_comb;
            end else begin
                bp_upd_valid <= 1'b0;
            end
        end
    end

    always_comb begin
        ctl_req_valid = 1'b0;
        ctl_req_op = CTL_FENCE;
        ctl_req_addr = 32'b0;
        if (idex_valid && idex_is_fence && !fence_busy) begin
            ctl_req_valid = 1'b1;
            ctl_req_op = idex_fence_op;
            ctl_req_addr = idex_pc;
        end
    end

    logic inst_known;
    always_comb begin
        trap_taken = 1'b0;
        mret_taken = 1'b0;
        trap_cause_val_comb = 32'd0;
        // Guard against transient X instruction words reaching EX and being decoded as illegal traps.
        inst_known = 1'b1;
        if (idex_valid) begin
            if (idex_err && inst_known) begin
                trap_taken = 1'b1;
                trap_cause_val_comb = 32'd1;
            end else if (inst_known && idex_inst == 32'h00000073) begin
                trap_taken = 1'b1;
                trap_cause_val_comb = 32'd11;
            end else if (inst_known && idex_inst == 32'h00100073) begin
                trap_taken = 1'b1;
                trap_cause_val_comb = 32'd3;
            end else if (idex_illegal && inst_known && !idex_is_fp_op && !idex_is_fp_load && !idex_is_fp_store) begin
                trap_taken = 1'b1;
                trap_cause_val_comb = 32'd2;
            end else if (idex_is_fp_op && 1'b0 && fp_illegal_fpu) begin
                trap_taken = 1'b1;
                trap_cause_val_comb = 32'd2;
            end else if (inst_known && idex_inst == 32'h30200073) begin
                mret_taken = 1'b1;
            end
        end
    end

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            exmem_valid_o <= 1'b0;
            exmem_pc_o <= '0;
            exmem_inst_o <= '0;
            exmem_rd_o <= '0;
            exmem_regwrite_o <= 1'b0;
            exmem_is_load_o <= 1'b0;
            exmem_is_store_o <= 1'b0;
            exmem_is_amo_o <= 1'b0;
            exmem_is_branch_o <= 1'b0;
            exmem_is_jal_o <= 1'b0;
            exmem_is_jalr_o <= 1'b0;
            exmem_is_fence_o <= 1'b0;
            exmem_is_csr_o <= 1'b0;
            exmem_mem_read_o <= 1'b0;
            exmem_alu_result_o <= '0;
            exmem_mem_addr_o <= '0;
            exmem_mem_cmd_o <= D_CMD_LD;
            exmem_mem_size_o <= SZ_4B;
            exmem_store_wdata_o <= '0;
            exmem_store_wstrb_o <= '0;
            exmem_load_funct3_o <= '0;
            exmem_amo_funct_o <= '0;
            exmem_amo_aq_o    <= 1'b0;
            exmem_amo_rl_o    <= 1'b0;
            exmem_fregwrite_o <= 1'b0;
            exmem_is_fp_load_o <= 1'b0;
            exmem_prd_o <= '0;
            exmem_rob_ptr_o <= '0;
            exmem1_valid_o <= 1'b0;
            exmem1_alu_result_o <= '0;
            exmem1_rd_o <= '0;
            exmem1_prd_o <= '0;
            exmem1_rob_ptr_o <= '0;
            exmem1_regwrite_o <= 1'b0;
            exmem1_pc_o <= '0; exmem1_inst_o <= '0;
            exmem1_redirect_valid <= 1'b0; exmem1_redirect_pc <= '0;
            exmem1_is_load_o <= 1'b0; exmem1_is_store_o <= 1'b0;
            exmem1_mem_addr_o <= '0; exmem1_mem_cmd_o <= '0; exmem1_mem_size_o <= '0;
            exmem1_store_wdata_o <= '0; exmem1_store_wstrb_o <= '0;
        end else begin
            // Freeze slot0 only when LSU backpressures and slot0 currently holds a pending memory op.
            // This prevents dropping in-flight loads/stores while still allowing non-memory ops to flow.
            if (!fence_busy && !stall_fp
                && (!stall_mem || !(exmem_valid_o && (exmem_is_load_o || exmem_is_store_o || exmem_is_amo_o || exmem_is_fp_load_o)))) begin
                exmem_amo_aq_o <= 1'b0;
                exmem_amo_rl_o <= 1'b0;
                exmem_valid_o <= idex_valid && !idex_is_fence;
                exmem_pc_o <= idex_pc;
                exmem_inst_o <= idex_inst;
                exmem_rd_o <= idex_rd;
                exmem_prd_o <= idex_prd;
                exmem_rob_ptr_o <= idex_rob_ptr;
                exmem_is_load_o <= idex_is_csr ? 1'b0 : (idex_is_load || idex_is_fp_load);
                exmem_is_store_o <= idex_is_csr ? 1'b0 : (idex_is_store || idex_is_fp_store);
                exmem_is_amo_o <= idex_is_csr ? 1'b0 : idex_is_amo;
                exmem_is_branch_o <= idex_is_csr ? 1'b0 : idex_is_branch;
                exmem_is_jal_o    <= idex_is_csr ? 1'b0 : idex_is_jal;
                exmem_is_jalr_o   <= idex_is_csr ? 1'b0 : idex_is_jalr;
                exmem_is_fence_o  <= idex_is_csr ? 1'b0 : idex_is_fence;
                exmem_is_csr_o    <= idex_is_csr;
                exmem_mem_read_o <= idex_is_csr ? 1'b0 : idex_mem_read;

                exmem_alu_result_o <= ex_alu;
                exmem_load_funct3_o <= idex_funct3;

                exmem_mem_addr_o <= fwd_rs1_val + idex_imm_i;
                exmem_mem_cmd_o  <= idex_is_load ? D_CMD_LD : D_CMD_ST;
                exmem_mem_size_o <= SZ_4B;
                exmem_store_wdata_o <= idex_is_fp_store ? fwd_frs2_val : fwd_rs2_val;
                exmem_store_wstrb_o <= 4'b1111;

                exmem_regwrite_o <= idex_regwrite && !trap_taken && !mret_taken;
                exmem_fregwrite_o <= idex_fregwrite && !trap_taken && !mret_taken;
                exmem_is_fp_load_o <= idex_is_fp_load;

                if (idex_is_csr) begin
                    exmem_mem_addr_o <= 32'b0;
                    exmem_mem_cmd_o  <= D_CMD_LD;
                    exmem_mem_size_o <= SZ_4B;
                    exmem_store_wstrb_o <= 4'b0000;
                end else if (idex_is_amo) begin
                    exmem_mem_addr_o <= fwd_rs1_val;
                    exmem_mem_cmd_o  <= D_CMD_AMO;
                    exmem_mem_size_o <= SZ_4B;
                    exmem_store_wdata_o <= fwd_rs2_val;
                    exmem_store_wstrb_o <= 4'b1111;
                    exmem_load_funct3_o <= 3'b010;
                    exmem_amo_funct_o <= idex_funct7[6:2];
                    exmem_amo_aq_o     <= idex_funct7[1];
                    exmem_amo_rl_o     <= idex_funct7[0];
                end else if (idex_is_load) begin
                    exmem_mem_addr_o <= eff_i_addr;
                    exmem_mem_cmd_o  <= D_CMD_LD;
                    exmem_mem_size_o <= load_size(idex_funct3);
`ifndef SYNTHESIS
                    if ($isunknown(eff_i_addr)) begin
                        $display("[EX_DBG] load_addr_x pc=0x%08x inst=0x%08x rs1=%0d rs1_val=0x%08x fwd_rs1=0x%08x imm_i=0x%08x prs1=%0d",
                                 idex_pc, idex_inst, idex_rs1, idex_rs1_val, fwd_rs1_val, idex_imm_i, idex_prs1);
                    end
`endif
                end else if (idex_is_fp_load) begin
                    exmem_mem_addr_o <= eff_i_addr;
                    exmem_mem_cmd_o  <= D_CMD_LD;
                    exmem_mem_size_o <= SZ_4B;
                    exmem_load_funct3_o <= 3'b010;
                    exmem_store_wstrb_o <= 4'b0000;
                end else if (idex_is_fp_store) begin
                    exmem_mem_addr_o <= eff_s_addr;
                    exmem_mem_cmd_o  <= D_CMD_ST;
                    exmem_mem_size_o <= SZ_4B;
                    exmem_store_wdata_o <= fwd_frs2_val;
                    exmem_store_wstrb_o <= 4'b1111;
                end else if (idex_is_store) begin
                    exmem_mem_addr_o <= eff_s_addr;
                    exmem_mem_cmd_o  <= D_CMD_ST;
                    exmem_mem_size_o <= store_size(idex_funct3);
                    exmem_store_wstrb_o <= store_wstrb(eff_s_addr, idex_funct3);
                end
                end
            // Slot 1 EX/MEM: blocked by stall_mem when LSQ backpressures
            if (!fence_busy && !stall_fp && !stall_mem) begin
                automatic logic is_alu  = idex1_opcode inside {7'b0110011, 7'b0010011, 7'b0110111, 7'b0010111};
                automatic logic is_mul  = (idex1_opcode == 7'b0110011) && (idex1_funct7 == 7'h01);
                automatic logic is_bru  = idex1_opcode inside {7'b1100011, 7'b1101111, 7'b1100111};
                automatic logic is_load = (idex1_opcode == 7'b0000011);
                automatic logic is_store= (idex1_opcode == 7'b0100011);
                if (idex1_valid && (is_alu || is_mul || is_bru || is_load || is_store)) begin
                    exmem1_valid_o         <= 1'b1;
                    exmem1_pc_o            <= idex1_pc;
                    exmem1_inst_o          <= idex1_inst;
                    exmem1_alu_result_o    <= is_mul       ? fu_mul1_result
                                           : (is_bru && (idex1_opcode == 7'b1101111 || idex1_opcode == 7'b1100111)
                                              && (idex1_rd != 5'd0)) ? (idex1_pc + 32'd4)
                                           : fu_alu1_result;
                    exmem1_rd_o            <= idex1_rd;
                    exmem1_prd_o           <= idex1_prd;
                    exmem1_rob_ptr_o       <= idex1_rob_ptr;
                    exmem1_regwrite_o      <= (idex1_rd != 5'd0) && !is_store;
                    exmem1_redirect_valid  <= is_bru && fu_bru1_redirect;
                    exmem1_redirect_pc     <= fu_bru1_redirect_pc;
                    exmem1_is_load_o       <= is_load;
                    exmem1_is_store_o      <= is_store;
                    exmem1_mem_addr_o      <= fwd1_rs1_val + (is_store ? idex1_imm_s : idex1_imm_i);
                    exmem1_mem_cmd_o       <= is_load ? D_CMD_LD : D_CMD_ST;
                    exmem1_mem_size_o      <= is_load ? load_size(idex1_funct3) : store_size(idex1_funct3);
                    exmem1_store_wdata_o   <= fwd1_rs2_val;
                    exmem1_store_wstrb_o   <= is_store
                        ? store_wstrb(fwd1_rs1_val + idex1_imm_s, idex1_funct3)
                        : 4'b0000;
                end else begin
                    exmem1_valid_o <= 1'b0;
                    exmem1_redirect_valid <= 1'b0;
                    exmem1_redirect_pc <= '0;
                end
            end
            end
    end

`ifndef SYNTHESIS
    always_ff @(posedge pl_clk) begin
        if (pl_resetn && !idex1_valid
            && ((idex1_prd != 6'd0) || (idex1_prs1 != 6'd0) || (idex1_prs2 != 6'd0)
            || (idex1_opcode != 7'd0) || (idex1_funct3 != 3'd0) || (idex1_funct7 != 7'd0))) begin
            $error("[EX_ASSERT] slot1 input not sanitized when invalid");
        end
    end
`endif

endmodule
