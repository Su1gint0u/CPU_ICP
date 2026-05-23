// 5-stage in-order RV32IMAF CPU + Zicsr CSR subset + RV32F F0 + RV32A (AMO in L1D).
// See cpu_if_stage.sv, cpu_id_stage.sv, cpu_ex_stage.sv, cpu_mem_stage.sv, cpu_wb_stage.sv.

module cpu_core #(
    parameter int unsigned XLEN       = 32,
    parameter int unsigned ISSUE_WIDTH = 2,
    parameter int unsigned FETCH_W     = 64,
    parameter logic [XLEN-1:0] RESET_PC = 32'h8000_0000,
    parameter logic [31:0] P_MHARTID = 32'h0
) (
    input  logic                   pl_clk,
    input  logic                   pl_resetn,

    output logic                   i_req_valid,
    input  logic                   i_req_ready,
    output logic [31:0]           i_req_addr,
    input  logic                   i_resp_valid,
    input  logic [FETCH_W-1:0]   i_resp_data,
    input  logic                   i_resp_err,

    output logic                   d_req_valid,
    input  logic                   d_req_ready,
    output logic [31:0]           d_req_addr,
    output logic [2:0]            d_req_cmd,
    output logic [2:0]            d_req_size,
    output logic [XLEN-1:0]       d_req_wdata,
    output logic [3:0]            d_req_wstrb,
    output logic [4:0]             d_req_amo_funct,
    output logic                   d_req_amo_aq,
    output logic                   d_req_amo_rl,
    input  logic                   d_resp_valid,
    input  logic [XLEN-1:0]      d_resp_rdata,
    input  logic                   d_resp_err,

    output logic                   ctl_req_valid,
    output logic [2:0]            ctl_req_op,
    output logic [31:0]           ctl_req_addr,
    input  logic                   ctl_done,
    input  logic                   ctl_err,

    output logic                   bp_if_valid,
    output logic [31:0]           bp_if_pc,
    input  logic                   bp_pred_taken,
    input  logic [63:0]           bp_pred_meta,
    input  logic                   bp_pred_taken1,
    input  logic [63:0]           bp_pred_meta1,
    input  logic                   bp_if_spec_taken,
    input  logic [31:0]           bp_if_spec_target,
    output logic                   bp_upd_valid,
    output logic [31:0]           bp_upd_pc,
    output logic                   bp_upd_taken,
    output logic                   bp_upd_mispredict,
    output logic [63:0]           bp_upd_meta,
    output logic [31:0]           bp_upd_branch_target,

    input  logic                   irq_m_soft_i,
    input  logic                   irq_m_timer_i,
    input  logic                   irq_m_ext_i,

    // Architectural retire interface — directly drives difftest/tracer.
    // In OoO, this is driven from the ROB head instead of cpu_wb_stage.
    output logic                   retire_valid,
    output logic [31:0]           retire_pc,
    output logic [31:0]           retire_inst,
    output logic                   retire_regwrite,
    output logic [4:0]            retire_waddr,
    output logic [31:0]           retire_wdata,
    output logic                   retire1_valid,
    output logic [31:0]           retire1_pc,
    output logic [31:0]           retire1_inst,
    output logic                   retire1_regwrite,
    output logic [4:0]            retire1_waddr,
    output logic [31:0]           retire1_wdata,

    output logic [7:0]            perf_backend_flags,
    output logic [7:0]            dbg_stall_flags,
    output logic [7:0]            dbg_ex_flags,

    output logic                   mon_trap_occurred
);

    function automatic logic [31:0] csr_trap_entry_pc(input logic [31:0] mtv, input logic [31:0] cause);
        csr_trap_entry_pc = (mtv & ~32'h3)
            + ((mtv[1:0] == 2'b01) ? ((cause & 32'h7FFF_FFFF) << 2) : 32'b0);
    endfunction

    function automatic logic [31:0] ifid_jal_target_pc(input logic [31:0] inst, input logic [31:0] pc);
        logic [31:0] imm;
        imm = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};
        ifid_jal_target_pc = pc + imm;
    endfunction

    function automatic logic [31:0] ifid_b_target_pc(input logic [31:0] inst, input logic [31:0] pc);
        logic [31:0] imm;
        imm = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
        ifid_b_target_pc = pc + imm;
    endfunction

    logic [31:0] csr_rdata;
    logic [31:0] csr_rdata_q;
    logic        csr_wr_en;
    logic [11:0] csr_wr_addr;
    logic [31:0] csr_wr_data;

    logic [31:0] mtvec_q_o;
    logic [31:0] mepc_q_o;
    logic [31:0] mstatus_q_o;
    logic [31:0] mie_q_o;
    logic [31:0] mip_live_o;
    logic [2:0]  frm_q_o;

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn)
            csr_rdata_q <= 32'b0;
        else
            csr_rdata_q <= csr_rdata;
    end

    logic [31:0] irq_mcause_sel;
    always_comb begin
        irq_mcause_sel = 32'h8000_000B;
        if (mie_q_o[11] && mip_live_o[11])
            irq_mcause_sel = 32'h8000_000B;
        else if (mie_q_o[7] && mip_live_o[7])
            irq_mcause_sel = 32'h8000_0007;
        else if (mie_q_o[3] && mip_live_o[3])
            irq_mcause_sel = 32'h8000_0003;
    end

    wire irq_pe = (mie_q_o[11] & mip_live_o[11]) | (mie_q_o[7] & mip_live_o[7]) | (mie_q_o[3] & mip_live_o[3]);

    wire mstatus_fs_off = (mstatus_q_o[14:13] == 2'b00);

    logic fence_busy;
    logic stall_mem;
    logic stall_load_use;
    logic stall_csr;
    logic stall_fp;
    logic stall_prf;
    logic rob_retract_en;
    logic bp_rat_cp_pop;  // same-cycle RAT restore on control-flow redirect (see cpu_ex_stage)
    logic bp_rat_cp_release;
    logic [5:0] bp_rat_cp_pop_rob_ptr;
    logic [5:0] bp_rat_cp_release_rob_ptr;
    logic bp_rat_cp_fixup_valid;
    logic [4:0] bp_rat_cp_fixup_rd;
    logic [5:0] bp_rat_cp_fixup_prd;
    logic rat_cp_empty;
    logic        ifid_valid;
    logic [31:0] ifid_pc;
    logic [31:0] ifid_inst;
    logic        ifid_err;
    logic        ifid1_valid;
    logic [31:0] ifid1_pc, ifid1_inst;
    logic        ifid1_err;
    logic        ifid1_bp_pred_taken;
    logic [63:0] ifid1_bp_pred_meta;
    logic        ifid_bp_pred_taken;
    logic [63:0] ifid_bp_pred_meta;

    logic        rob_full_q;
    logic        rob_full_dual_q;
    logic        iq_full_q, iq_full_dual_q;
    wire         consume_ifid;
    logic [5:0]  allocate_prd, allocate1_prd;
    wire         ifid_known = 1'b1;
    wire         ifid_usable = (ifid_valid == 1'b1) && ifid_known;
    wire         ifid1_known = 1'b1;
    wire         ifid1_present = (ifid1_valid == 1'b1)
        || ((FETCH_W >= 64) && ifid_usable && ifid1_known && (ifid1_pc == (ifid_pc + 32'd4)));
    wire         ifid1_usable = ifid1_present && ifid1_known;
    // Dual-fetch packets must be adjacent words from the same fetch group.
    wire         ifid1_pair_ok = ifid1_usable && (ifid1_pc == (ifid_pc + 32'd4));
    // Same-bundle slot1 is architecturally dead when slot0 redirects IF (JAL, predicted-taken
    // branch/JALR) or serializes instruction stream (FENCE.I). Without this, shadow ops still
    // rename and retire — breaks bundle_decomp_test (e.g. addi x10,0,0x42 after taken beq).
    wire  [6:0]  ifid0_opc = ifid_inst[6:0];
    wire         ifid0_is_ctrl = (ifid0_opc == 7'b1100011) || (ifid0_opc == 7'b1101111) || (ifid0_opc == 7'b1100111);
    // Branch with rs1==rs2: BEQ/BGE/BGEU always taken; BPU may not set pred_taken for slot1.
    wire         ifid_branch_same_rs_taken = (ifid0_opc == 7'b1100011) && (
           ((ifid_inst[14:12] == 3'b000) && (ifid_inst[19:15] == ifid_inst[24:20]))
        || ((ifid_inst[14:12] == 3'b101) && (ifid_inst[19:15] == ifid_inst[24:20]))
        || ((ifid_inst[14:12] == 3'b111) && (ifid_inst[19:15] == ifid_inst[24:20]))
    );
    wire         ifid0_pred_taken_branch = (ifid0_opc == 7'b1100011) && ifid_bp_pred_taken;
    // Slot1 is dead only when slot0 redirects the fetch stream. A not-predicted-taken branch
    // must keep the architectural PC+4 instruction in slot1; a later taken branch redirect
    // squashes it through the ROB exact-tag path.
    wire         ifid_slot0_annuls_slot1 =
          (ifid0_opc == 7'b1101111) // JAL
        | ifid0_pred_taken_branch
        | (ifid0_opc == 7'b1100111) // JALR
        | ifid_branch_same_rs_taken
        | (ifid0_opc == 7'b0001111); // FENCE/FENCE.I serializes the following slot
    wire         ifid_effective_dual = ifid1_pair_ok && !ifid_slot0_annuls_slot1;

    // Slot1 at PC+4 in a 64b line may be JAL / statically-taken branch; fall-through (next line)
    // must never rename — BPU meta is for fetch-aligned PC, not slot1. Redirect following cycle.
    wire  [6:0]  ifid1_opc_d = ifid1_inst[6:0];
    wire         ifid1_is_ctrl = (ifid1_opc_d == 7'b1100011) || (ifid1_opc_d == 7'b1101111)
        || (ifid1_opc_d == 7'b1100111);
    wire         ifid0_is_fp_class = (ifid0_opc == 7'b0000111) || (ifid0_opc == 7'b0100111)
        || (ifid0_opc == 7'b1010011)
        || (ifid0_opc == 7'h43) || (ifid0_opc == 7'h47)
        || (ifid0_opc == 7'h4b) || (ifid0_opc == 7'h4f);
    wire         ifid1_is_fp_class = (ifid1_opc_d == 7'b0000111) || (ifid1_opc_d == 7'b0100111)
        || (ifid1_opc_d == 7'b1010011)
        || (ifid1_opc_d == 7'h43) || (ifid1_opc_d == 7'h47)
        || (ifid1_opc_d == 7'h4b) || (ifid1_opc_d == 7'h4f);
    wire         ifid_bundle_has_fp = ifid0_is_fp_class || (ifid1_pair_ok && ifid1_is_fp_class);
    wire         ifid1_branch_same_rs_taken_d = (ifid1_opc_d == 7'b1100011) && (
           ((ifid1_inst[14:12] == 3'b000) && (ifid1_inst[19:15] == ifid1_inst[24:20]))
        || ((ifid1_inst[14:12] == 3'b101) && (ifid1_inst[19:15] == ifid1_inst[24:20]))
        || ((ifid1_inst[14:12] == 3'b111) && (ifid1_inst[19:15] == ifid1_inst[24:20]))
    );
    wire         ifid1_pred_taken_branch = (ifid1_opc_d == 7'b1100011) && ifid1_bp_pred_taken;
    wire         ifid1_redirect_static_d = ifid1_pair_ok && !ifid_slot0_annuls_slot1 && !ifid0_is_ctrl && (
          (ifid1_opc_d == 7'b1101111)
        | ifid1_branch_same_rs_taken_d
        | ifid1_pred_taken_branch
    );
    wire  [31:0] ifid1_redirect_target_d = (ifid1_opc_d == 7'b1101111)
        ? ifid_jal_target_pc(ifid1_inst, ifid1_pc)
        : ifid_b_target_pc(ifid1_inst, ifid1_pc);
    wire         ifid_dual_alloc_ready = ifid_effective_dual && !(ifid0_is_ctrl && ifid1_is_ctrl)
        && !ifid_bundle_has_fp && (allocate1_prd != 6'd0) && !rob_full_dual_q && !iq_full_dual_q;
    wire         ifid1_decode_valid = ifid_dual_alloc_ready;
    wire         stall_rob = ifid_usable && rob_full_q;
    wire         stall_iq  = ifid_usable && iq_full_q;
    wire         stall_rob_or_retract = stall_rob || rob_retract_en;

    logic stall_all;

    assign stall_all = stall_mem || fence_busy || stall_load_use || stall_fp || stall_csr || stall_iq
        || stall_prf || stall_rob_or_retract;
    assign dbg_stall_flags = {
        stall_rob_or_retract,
        stall_prf,
        stall_iq,
        stall_csr,
        stall_fp,
        stall_load_use,
        stall_mem,
        stall_all
    };

    logic        redirect_valid;
    logic [31:0] redirect_pc;
    logic [5:0]  fu_redirect_rob_ptr;
    logic        exmem1_redirect_valid;
    logic [31:0] exmem1_redirect_pc;

    logic        mem_fault_redirect;
    logic [31:0] mem_fault_mepc;
    logic [31:0] mem_fault_mcause;
    logic [5:0]  mem_fault_prd;
    logic [5:0]  mem_fault_rob_ptr;

    wire         ctl_fault_redirect;
    assign ctl_fault_redirect = fence_busy && ctl_done && ctl_err;

    wire         redirect_valid_any;
    wire  [31:0] redirect_pc_any;
    wire         redirect_blocks_dispatch;
    wire         iq_global_flush;
    logic        ifid_pending_slot1_redir;
    logic [31:0] ifid_slot1_redir_pc;
    logic [5:0]  ifid_slot1_redir_rob_ptr;

    // -----------------------------
    // IF/ID
    // -----------------------------

    logic [31:0] pc_q_o;
    logic        fetch_inflight;
    logic        mon_if_req_issue;
    logic        mon_if_resp_accept;
    logic        mon_if_resp_drop;
    logic        mon_if_buf_write;
    logic        mon_if_buf_read;

    logic        rf_we;
    logic [4:0]  rf_waddr;
    logic [31:0] rf_wdata;
    logic        rf_we_combo;
    logic [4:0]  rf_waddr_combo;
    logic [31:0] rf_wdata_combo;

    logic [31:0] frf_rs1_val;
    logic [31:0] frf_rs2_val;
    logic [31:0] frf_rs3_val;
    logic [31:0] frf_rs1_val_1, frf_rs2_val_1, frf_rs3_val_1;
    logic        frf_we;
    logic [4:0]  frf_waddr;
    logic [31:0] frf_wdata;
    logic        frf_we_b;
    logic [4:0]  frf_waddr_b;
    logic [31:0] frf_wdata_b;

    cpu_if_stage #(
        .FETCH_W (FETCH_W),
        .RESET_PC(RESET_PC)
    ) u_if (
        .pl_clk       (pl_clk),
        .pl_resetn    (pl_resetn),
        .stall_all    (stall_all),
        .redirect_valid(redirect_valid_any),
        .redirect_pc  (redirect_pc_any),
        .consume_ifid (consume_ifid),
        .i_req_ready  (i_req_ready),
        .i_resp_valid (i_resp_valid),
        .i_resp_data  (i_resp_data),
        .i_resp_err   (i_resp_err),
        .bp_if_spec_taken(bp_if_spec_taken),
        .bp_if_spec_target(bp_if_spec_target),
        .bp_pred_taken(bp_pred_taken),
        .bp_pred_meta (bp_pred_meta),
        .bp_pred_taken1(bp_pred_taken1),
        .bp_pred_meta1 (bp_pred_meta1),
        .i_req_valid  (i_req_valid),
        .i_req_addr   (i_req_addr),
        .ifid_valid   (ifid_valid),
        .ifid_pc      (ifid_pc),
        .ifid_inst    (ifid_inst),
        .ifid_err     (ifid_err),
        .ifid_bp_pred_taken(ifid_bp_pred_taken),
        .ifid_bp_pred_meta (ifid_bp_pred_meta),
        .ifid1_valid  (ifid1_valid),
        .ifid1_pc     (ifid1_pc),
        .ifid1_inst   (ifid1_inst),
        .ifid1_err    (ifid1_err),
        .ifid1_bp_pred_taken(ifid1_bp_pred_taken),
        .ifid1_bp_pred_meta(ifid1_bp_pred_meta),
        .fetch_inflight(fetch_inflight),
        .pc_q_o       (pc_q_o),
        .mon_if_req_issue(mon_if_req_issue),
        .mon_if_resp_accept(mon_if_resp_accept),
        .mon_if_resp_drop(mon_if_resp_drop),
        .mon_if_buf_write(mon_if_buf_write),
        .mon_if_buf_read(mon_if_buf_read)
    );

    // -----------------------------
    // Register file read (async)
    // -----------------------------
    logic [31:0] rf_rs1_val;
    logic [31:0] rf_rs2_val;
    logic [31:0] rf_rs1_val_1, rf_rs2_val_1;
    logic [4:0]  fp_fflags_inc;
    logic        rob_release_en, rob_release1_en;
    logic [5:0]  rob_release_prd, rob_release1_prd;

    cpu_f_regfile u_frf (
        .pl_clk   (pl_clk),
        .pl_resetn(pl_resetn),
        .raddr1   (ifid_inst[19:15]),
        .raddr2   (ifid_inst[24:20]),
        .raddr3   (ifid_inst[31:27]),
        .rdata1   (frf_rs1_val),
        .rdata2   (frf_rs2_val),
        .rdata3   (frf_rs3_val),
        // Slot 1 FP reads (ISSUE_WIDTH=2)
        .raddr4   (ifid1_inst[19:15]),
        .raddr5   (ifid1_inst[24:20]),
        .raddr6   (ifid1_inst[31:27]),
        .rdata4   (frf_rs1_val_1),
        .rdata5   (frf_rs2_val_1),
        .rdata6   (frf_rs3_val_1),
        .we       (frf_we),
        .waddr    (frf_waddr),
        .wdata    (frf_wdata),
        .we_b     (frf_we_b),
        .waddr_b  (frf_waddr_b),
        .wdata_b  (frf_wdata_b)
    );

    // -----------------------------
    // ID/EX
    // -----------------------------
    logic        idex_valid;
    logic [31:0] idex_pc;
    logic [31:0] idex_inst;
    logic        idex_err;
    logic [4:0]  idex_rs1;
    logic [4:0]  idex_rs2;
    logic [4:0]  idex_rd;
    logic [6:0]  idex_opcode;
    logic [2:0]  idex_funct3;
    logic [6:0]  idex_funct7;
    logic [31:0] idex_imm_i;
    logic [31:0] idex_imm_s;
    logic [31:0] idex_imm_b;
    logic [31:0] idex_imm_u;
    logic [31:0] idex_imm_j;
    logic [31:0] idex_rs1_val;
    logic [31:0] idex_rs2_val;
    logic        idex_regwrite;
    logic        idex_mem_read;
    logic        idex_mem_write;
    logic        idex_is_load;
    logic        idex_is_store;
    logic        idex_is_amo;
    logic        idex_is_branch;
    logic        idex_is_jal;
    logic        idex_is_jalr;
    logic        idex_is_fence;
    logic [2:0]  idex_fence_op;
    logic        idex_illegal;
    logic        idex_is_csr;
    logic        idex_is_fp_load;
    logic        idex_is_fp_store;
    logic        idex_is_fp_op;
    logic        idex_fregwrite;
    logic [31:0] idex_frs1_val;
    logic [31:0] idex_frs2_val;
    logic [31:0] idex_frs3_val;
    logic        idex_bp_pred_taken;
    logic [63:0] idex_bp_pred_meta;

    // Slot 1 ID/EX signals (ISSUE_WIDTH=2)
    logic        idex1_valid;
    logic [31:0] idex1_pc, idex1_inst;
    logic [4:0]  idex1_rs1, idex1_rs2, idex1_rd;
    logic [6:0]  idex1_opcode;
    logic [2:0]  idex1_funct3;
    logic [6:0]  idex1_funct7;
    logic [31:0] idex1_imm_i, idex1_imm_s, idex1_imm_b, idex1_imm_u, idex1_imm_j;
    logic [31:0] idex1_rs1_val, idex1_rs2_val;
    logic        idex1_regwrite;
    logic        idex1_is_load, idex1_is_store, idex1_is_amo;
    logic        idex1_is_branch, idex1_is_jal, idex1_is_jalr;
    logic        idex1_is_fence;
    logic [2:0]  idex1_fence_op;
    logic        idex1_is_csr;
    logic        idex1_is_fp_load, idex1_is_fp_store, idex1_is_fp_op, idex1_fregwrite;
    logic [31:0] idex1_frs1_val, idex1_frs2_val, idex1_frs3_val;
    logic        idex1_bp_pred_taken;
    logic [63:0] idex1_bp_pred_meta;
    logic        id_regwrite, id1_regwrite;
    logic        idex_next_valid, idex1_next_valid;

    cpu_id_stage u_id (
        .pl_clk       (pl_clk),
        .pl_resetn    (pl_resetn),
        .ifid_inst    (ifid_inst),
        .ifid_valid   (ifid_valid),
        .ifid_pc      (ifid_pc),
        .ifid_err     (ifid_err),
        .ifid_bp_pred_taken(ifid_bp_pred_taken),
        .ifid_bp_pred_meta (ifid_bp_pred_meta),
        .ifid1_inst   (ifid1_inst),
        .ifid1_valid  (ifid1_decode_valid),
        .ifid1_bp_pred_taken(ifid1_bp_pred_taken),
        .ifid1_bp_pred_meta (ifid1_bp_pred_meta),
        .rf_rs1_val   (rf_rs1_val),
        .rf_rs2_val   (rf_rs2_val),
        .rf_rs1_val_1 (rf_rs1_val_1),
        .rf_rs2_val_1 (rf_rs2_val_1),
        .frf_rs1_val  (frf_rs1_val),
        .frf_rs2_val  (frf_rs2_val),
        .frf_rs3_val  (frf_rs3_val),
        .frf_rs1_val_1(frf_rs1_val_1),
        .frf_rs2_val_1(frf_rs2_val_1),
        .frf_rs3_val_1(frf_rs3_val_1),
        .frf_we       (frf_we),
        .frf_waddr    (frf_waddr),
        .frf_we_b     (frf_we_b),
        .frf_waddr_b  (frf_waddr_b),
        .stall_mem    (stall_mem),
        .stall_fp     (stall_fp),
        .fence_busy   (fence_busy),
        .stall_iq     (stall_iq),
        .stall_prf    (stall_prf),
        .stall_rob    (stall_rob_or_retract),
        .redirect_valid(redirect_valid_any),
        .mstatus_fs_off(mstatus_fs_off),
        .stall_load_use(stall_load_use),
        .consume_ifid (consume_ifid),
        .idex_next_valid  (idex_next_valid),
        .idex1_next_valid (idex1_next_valid),
        .idex_valid   (idex_valid),
        .idex_pc      (idex_pc),
        .idex_inst    (idex_inst),
        .idex_err     (idex_err),
        .idex_rs1     (idex_rs1),
        .idex_rs2     (idex_rs2),
        .idex_rd      (idex_rd),
        .idex_opcode  (idex_opcode),
        .idex_funct3  (idex_funct3),
        .idex_funct7  (idex_funct7),
        .idex_imm_i   (idex_imm_i),
        .idex_imm_s   (idex_imm_s),
        .idex_imm_b   (idex_imm_b),
        .idex_imm_u   (idex_imm_u),
        .idex_imm_j   (idex_imm_j),
        .idex_rs1_val (idex_rs1_val),
        .idex_rs2_val (idex_rs2_val),
        .idex_regwrite(idex_regwrite),
        .idex_mem_read(idex_mem_read),
        .idex_mem_write(idex_mem_write),
        .idex_is_load (idex_is_load),
        .idex_is_store(idex_is_store),
        .idex_is_amo  (idex_is_amo),
        .idex_is_branch(idex_is_branch),
        .idex_is_jal  (idex_is_jal),
        .idex_is_jalr (idex_is_jalr),
        .idex_is_fence(idex_is_fence),
        .idex_fence_op(idex_fence_op),
        .idex_illegal (idex_illegal),
        .idex_is_csr  (idex_is_csr),
        .idex_is_fp_load (idex_is_fp_load),
        .idex_is_fp_store(idex_is_fp_store),
        .idex_is_fp_op   (idex_is_fp_op),
        .idex_fregwrite  (idex_fregwrite),
        .idex_frs1_val   (idex_frs1_val),
        .idex_frs2_val   (idex_frs2_val),
        .idex_frs3_val   (idex_frs3_val),
        .idex_bp_pred_taken(idex_bp_pred_taken),
        .idex_bp_pred_meta (idex_bp_pred_meta),
        .id_regwrite   (id_regwrite),
        .id1_regwrite  (id1_regwrite),
        // Slot 1 outputs
        .idex1_valid      (idex1_valid),
        .idex1_pc         (idex1_pc),
        .idex1_inst       (idex1_inst),
        .idex1_rs1        (idex1_rs1),
        .idex1_rs2        (idex1_rs2),
        .idex1_rd         (idex1_rd),
        .idex1_opcode     (idex1_opcode),
        .idex1_funct3     (idex1_funct3),
        .idex1_funct7     (idex1_funct7),
        .idex1_imm_i      (idex1_imm_i),
        .idex1_imm_s      (idex1_imm_s),
        .idex1_imm_b      (idex1_imm_b),
        .idex1_imm_u      (idex1_imm_u),
        .idex1_imm_j      (idex1_imm_j),
        .idex1_rs1_val    (idex1_rs1_val),
        .idex1_rs2_val    (idex1_rs2_val),
        .idex1_regwrite   (idex1_regwrite),
        .idex1_is_load    (idex1_is_load),
        .idex1_is_store   (idex1_is_store),
        .idex1_is_amo     (idex1_is_amo),
        .idex1_is_branch  (idex1_is_branch),
        .idex1_is_jal     (idex1_is_jal),
        .idex1_is_jalr    (idex1_is_jalr),
        .idex1_is_fence   (idex1_is_fence),
        .idex1_fence_op   (idex1_fence_op),
        .idex1_is_csr     (idex1_is_csr),
        .idex1_is_fp_load (idex1_is_fp_load),
        .idex1_is_fp_store(idex1_is_fp_store),
        .idex1_is_fp_op   (idex1_is_fp_op),
        .idex1_fregwrite  (idex1_fregwrite),
        .idex1_frs1_val   (idex1_frs1_val),
        .idex1_frs2_val   (idex1_frs2_val),
        .idex1_frs3_val   (idex1_frs3_val),
        .idex1_bp_pred_taken(idex1_bp_pred_taken),
        .idex1_bp_pred_meta (idex1_bp_pred_meta),
        .stall_csr       (stall_csr)
    );

    // -----------------------------
    // EX / EX-MEM
    // -----------------------------
    logic        trap_taken;
    logic [31:0] trap_cause_val_comb;
    logic        mret_taken;

    logic        exmem_valid;
    logic [31:0] exmem_pc;
    logic [31:0] exmem_inst;
    logic [4:0]  exmem_rd;
    logic [5:0]  exmem_prd;
    logic [5:0]  exmem_rob_ptr;
    logic        exmem_regwrite;
    logic        exmem_is_load;
    logic        exmem_is_store;
    logic        exmem_is_amo;
    logic        exmem_is_branch;
    logic        exmem_is_jal;
    logic        exmem_is_jalr;
    logic        exmem_is_fence;
    logic        exmem_is_csr;
    logic        exmem_mem_read;
    logic [31:0] exmem_alu_result;
    logic [31:0] exmem_mem_addr;
    logic [2:0]  exmem_mem_cmd;
    logic [2:0]  exmem_mem_size;
    logic [31:0] exmem_store_wdata;
    logic [3:0]  exmem_store_wstrb;
    logic [2:0]  exmem_load_funct3;
    logic [4:0]  exmem_amo_funct;
    logic        exmem_amo_aq;
    logic        exmem_amo_rl;
    logic        exmem_fregwrite;
    logic        exmem_is_fp_load;
    // Slot 1 EX/MEM
    logic        exmem1_valid;
    logic [31:0] exmem1_alu_result;
    logic [4:0]  exmem1_rd;
    logic [5:0]  exmem1_prd;
    logic [5:0]  exmem1_rob_ptr;
    logic        exmem1_regwrite;
    logic [31:0] exmem1_pc;
    logic [31:0] exmem1_inst;
    logic        exmem1_is_load;
    logic        exmem1_is_store;
    logic [31:0] exmem1_mem_addr;
    logic [2:0]  exmem1_mem_cmd;
    logic [2:0]  exmem1_mem_size;
    logic [31:0] exmem1_store_wdata;
    logic [3:0]  exmem1_store_wstrb;

    logic        memwb_valid;
    logic [31:0] memwb_pc;
    logic [31:0] memwb_inst;
    logic [4:0]  memwb_rd;
    logic [5:0]  memwb_prd;
    logic [5:0]  memwb_rob_ptr;
    logic        memwb_regwrite;
    logic [31:0] memwb_wdata;
    logic [2:0]  memwb_load_funct3;
    logic        memwb_is_fp_load;

    wire exmem_cdb = exmem_valid && exmem_regwrite && !exmem_is_load && !exmem_is_amo && (exmem_prd != 6'd0);
    wire exmem1_cdb = exmem1_valid && exmem1_regwrite && (exmem1_prd != 6'd0);
    // Stores: LSQ clears memwb_regwrite but still complete ROB / scoreboard with allocated prd.
    wire memwb_is_store_opc = (memwb_inst[6:0] == 7'b0100011) || (memwb_inst[6:0] == 7'b0100111);
    wire memwb_prf_we = memwb_valid && memwb_regwrite && (memwb_prd != 6'd0);
    wire memwb_rob_done = memwb_valid && (memwb_prd != 6'd0)
        && (memwb_regwrite || memwb_is_store_opc || memwb_is_fp_load);

    // 1-cycle hold registers to extend forwarding window
    logic        exmem_held_valid, exmem1_held_valid;
    logic [31:0] exmem_held_alu_result, exmem1_held_alu_result;
    logic [5:0]  exmem_held_prd, exmem1_held_prd;
    logic        exmem_held_regwrite, exmem1_held_regwrite;
    always_ff @(posedge pl_clk or negedge pl_resetn)
        if (!pl_resetn) begin
            exmem_held_valid <= 1'b0; exmem1_held_valid <= 1'b0;
            exmem_held_alu_result <= '0; exmem1_held_alu_result <= '0;
            exmem_held_prd <= '0; exmem1_held_prd <= '0;
            exmem_held_regwrite <= 1'b0; exmem1_held_regwrite <= 1'b0;
        end else begin
            exmem_held_valid <= exmem_valid; exmem1_held_valid <= exmem1_valid;
            exmem_held_alu_result <= exmem_alu_result; exmem1_held_alu_result <= exmem1_alu_result;
            exmem_held_prd <= exmem_prd; exmem1_held_prd <= exmem1_prd;
            exmem_held_regwrite <= exmem_regwrite; exmem1_held_regwrite <= exmem1_regwrite;
        end

    wire fp_fs_dirty_evt = memwb_valid && memwb_is_fp_load;

    // ── IQ issue output wires ────────────────────────────────────
    logic        iq_issue_valid;
    logic [31:0] iq_issue_pc, iq_issue_inst;
    logic [4:0]  iq_issue_rd;
    logic        iq_issue_regwrite;
    logic        iq_issue_is_load, iq_issue_is_store, iq_issue_is_amo;
    logic        iq_issue_is_branch, iq_issue_is_jal, iq_issue_is_jalr;
    logic        iq_issue_is_fence, iq_issue_is_csr;
    logic        iq_issue_is_fp_op, iq_issue_is_fp_load, iq_issue_is_fp_store, iq_issue_fregwrite, iq_issue_illegal, iq_issue_err;
    logic [2:0]  iq_issue_funct3;
    logic [6:0]  iq_issue_funct7, iq_issue_opcode;
    logic [31:0] iq_issue_imm_i, iq_issue_imm_s, iq_issue_imm_b, iq_issue_imm_u, iq_issue_imm_j;
    logic [31:0] iq_issue_rs1_val, iq_issue_rs2_val;
    logic [31:0] iq_issue_frs1_val, iq_issue_frs2_val, iq_issue_frs3_val;
    logic [63:0] iq_issue_bp_meta;
    logic        iq_issue_bp_pred_taken;
    logic [2:0]  iq_issue_fence_op;
    logic [2:0]  iq_issue_fu_type;
    logic [5:0]  iq_issue_prs1, iq_issue_prs2, iq_issue_prd;
    logic [5:0]  iq_issue_rob_ptr;
    logic        ex_ctl_req_valid;
    logic [2:0]  ex_ctl_req_op;
    logic [31:0] ex_ctl_req_addr;
    // Slot 1 IQ issue output wires (ISSUE_WIDTH=2)
    logic        iq_issue1_valid;
    logic [31:0] iq_issue1_pc, iq_issue1_inst;
    logic [4:0]  iq_issue1_rd;
    logic        iq_issue1_regwrite;
    logic        iq_issue1_is_load, iq_issue1_is_store, iq_issue1_is_amo;
    logic        iq_issue1_is_branch, iq_issue1_is_jal, iq_issue1_is_jalr;
    logic        iq_issue1_is_fence, iq_issue1_is_csr;
    logic        iq_issue1_is_fp_op, iq_issue1_is_fp_load, iq_issue1_is_fp_store, iq_issue1_fregwrite, iq_issue1_illegal, iq_issue1_err;
    logic [2:0]  iq_issue1_funct3;
    logic [6:0]  iq_issue1_funct7, iq_issue1_opcode;
    logic [31:0] iq_issue1_imm_i, iq_issue1_imm_s, iq_issue1_imm_b, iq_issue1_imm_u, iq_issue1_imm_j;
    logic [31:0] iq_issue1_rs1_val, iq_issue1_rs2_val;
    logic [31:0] iq_issue1_frs1_val, iq_issue1_frs2_val, iq_issue1_frs3_val;
    logic [63:0] iq_issue1_bp_meta;
    logic        iq_issue1_bp_pred_taken;
    logic [2:0]  iq_issue1_fence_op;
    logic [5:0]  iq_issue1_prs1, iq_issue1_prs2, iq_issue1_prd;
    logic [5:0]  iq_issue1_rob_ptr;
    logic        iq_dispatch_accept_q, iq_dispatch1_accept_q;
    logic        fp_fflags_we;

    cpu_ex_stage #(
        .XLEN(XLEN),
        .ROB_TAG_W(6)
    ) u_ex (
        .pl_clk       (pl_clk),
        .pl_resetn    (pl_resetn),
        .stall_mem    (stall_mem),
        .fence_busy   (fence_busy),
        .idex_valid   (iq_issue_valid),
        .idex_pc      (iq_issue_pc),
        .idex_inst    (iq_issue_inst),
        .idex_rs1     (idex_rs1),
        .idex_rs2     (idex_rs2),
        .idex_rd      (iq_issue_rd),
        .idex_opcode  (iq_issue_opcode),
        .idex_funct3  (iq_issue_funct3),
        .idex_funct7  (iq_issue_funct7),
        .idex_imm_i   (iq_issue_imm_i),
        .idex_imm_s   (iq_issue_imm_s),
        .idex_imm_b   (iq_issue_imm_b),
        .idex_imm_u   (iq_issue_imm_u),
        .idex_imm_j   (iq_issue_imm_j),
        .idex_rs1_val (iq_issue_rs1_val),
        .idex_rs2_val (iq_issue_rs2_val),
        .idex_regwrite(iq_issue_regwrite),
        .idex_mem_read(idex_mem_read),
        .idex_mem_write(idex_mem_write),
        .idex_is_load (iq_issue_is_load),
        .idex_is_store(iq_issue_is_store),
        .idex_is_amo  (iq_issue_is_amo),
        .idex_is_branch(iq_issue_is_branch),
        .idex_is_jal  (iq_issue_is_jal),
        .idex_is_jalr (iq_issue_is_jalr),
        .idex_is_fence(iq_issue_is_fence),
        .idex_fence_op(iq_issue_fence_op),
        .idex_illegal (iq_issue_illegal),
        .idex_err     (iq_issue_err),
        .idex_is_csr  (iq_issue_is_csr),
        .idex_is_fp_load (iq_issue_is_fp_load),
        .idex_is_fp_store(iq_issue_is_fp_store),
        .idex_is_fp_op   (iq_issue_is_fp_op),
        .idex_fregwrite  (iq_issue_fregwrite),
        .idex_frs1_val   (iq_issue_frs1_val),
        .idex_frs2_val   (iq_issue_frs2_val),
        .idex_frs3_val   (iq_issue_frs3_val),
        .idex_bp_pred_taken(iq_issue_bp_pred_taken),
        .idex_bp_pred_meta (iq_issue_bp_meta),
        .idex_prs1(iq_issue_prs1),
        .idex_prs2(iq_issue_prs2),
        .idex_prd (iq_issue_prd),
        .idex_rob_ptr(iq_issue_rob_ptr),
        .idex1_valid  (iq_issue1_valid),
        .idex1_pc     (iq_issue1_valid ? iq_issue1_pc : 32'd0),
        .idex1_inst   (iq_issue1_valid ? iq_issue1_inst : 32'd0),
        .idex1_rd     (iq_issue1_valid ? iq_issue1_rd : 5'd0),
        .idex1_opcode (iq_issue1_valid ? iq_issue1_opcode : 7'd0),
        .idex1_funct3 (iq_issue1_valid ? iq_issue1_funct3 : 3'd0),
        .idex1_funct7 (iq_issue1_valid ? iq_issue1_funct7 : 7'd0),
        .idex1_rs1_val(iq_issue1_valid ? iq_issue1_rs1_val : 32'd0),
        .idex1_rs2_val(iq_issue1_valid ? iq_issue1_rs2_val : 32'd0),
        .idex1_imm_i  (iq_issue1_valid ? iq_issue1_imm_i : 32'd0),
        .idex1_imm_s  (iq_issue1_valid ? iq_issue1_imm_s : 32'd0),
        .idex1_imm_u  (iq_issue1_valid ? iq_issue1_imm_u : 32'd0),
        .idex1_imm_b  (iq_issue1_valid ? iq_issue1_imm_b : 32'd0),
        .idex1_imm_j  (iq_issue1_valid ? iq_issue1_imm_j : 32'd0),
        .idex1_bp_pred_taken(iq_issue1_valid ? iq_issue1_bp_pred_taken : 1'b0),
        .idex1_prs1   (iq_issue1_valid ? iq_issue1_prs1 : 6'd0),
        .idex1_prs2   (iq_issue1_valid ? iq_issue1_prs2 : 6'd0),
        .idex1_prd    (iq_issue1_valid ? iq_issue1_prd : 6'd0),
        .idex1_rob_ptr(iq_issue1_valid ? iq_issue1_rob_ptr : 6'd0),
        .frm_csr      (frm_q_o),
        .exmem_fregwrite_i(exmem_fregwrite),
        .memwb_is_fp_load(memwb_is_fp_load),
        .mtvec_q      (mtvec_q_o),
        .mepc_q       (mepc_q_o),
        .csr_rdata    (csr_rdata_q),
        .exmem_valid  (exmem_valid || exmem_held_valid),
        .exmem_rd     (exmem_rd),
        .exmem_regwrite(exmem_regwrite || exmem_held_regwrite),
        .exmem_is_load(exmem_is_load),
        .exmem_is_amo(exmem_is_amo),
        .exmem_alu_result(exmem_valid ? exmem_alu_result : exmem_held_alu_result),
        .exmem_prd_i  (exmem_valid ? exmem_prd : exmem_held_prd),
        .memwb_valid  (memwb_valid),
        .memwb_rd     (memwb_rd),
        .memwb_regwrite(memwb_regwrite),
        .memwb_wdata  (memwb_wdata),
        .memwb_prd_i  (memwb_prd),
        .exmem1_valid   (exmem1_valid || exmem1_held_valid),
        .exmem1_regwrite(exmem1_regwrite || exmem1_held_regwrite),
        .exmem1_alu_result(exmem1_valid ? exmem1_alu_result : exmem1_held_alu_result),
        .exmem1_prd_i   (exmem1_valid ? exmem1_prd : exmem1_held_prd),
        .i_req_valid  (i_req_valid),
        .stall_all    (stall_all),
        .fetch_inflight(fetch_inflight),
        .trap_taken   (trap_taken),
        .trap_cause_val_comb(trap_cause_val_comb),
        .mret_taken   (mret_taken),
        .redirect_valid(redirect_valid),
        .redirect_pc  (redirect_pc),
        .exmem1_redirect_valid(exmem1_redirect_valid),
        .exmem1_redirect_pc(exmem1_redirect_pc),
        .bp_if_valid  (bp_if_valid),
        .bp_if_pc     (bp_if_pc),
        .bp_upd_valid (bp_upd_valid),
        .bp_upd_pc    (bp_upd_pc),
        .bp_upd_taken (bp_upd_taken),
        .bp_upd_mispredict(bp_upd_mispredict),
        .bp_rat_cp_pop(bp_rat_cp_pop),
        .bp_rat_cp_release(bp_rat_cp_release),
        .bp_rat_cp_pop_rob_ptr(bp_rat_cp_pop_rob_ptr),
        .bp_rat_cp_release_rob_ptr(bp_rat_cp_release_rob_ptr),
        .bp_rat_cp_fixup_valid(bp_rat_cp_fixup_valid),
        .bp_rat_cp_fixup_rd(bp_rat_cp_fixup_rd),
        .bp_rat_cp_fixup_prd(bp_rat_cp_fixup_prd),
        .fu_redirect_rob_ptr(fu_redirect_rob_ptr),
        .bp_upd_meta  (bp_upd_meta),
        .bp_upd_branch_target(bp_upd_branch_target),
        .ctl_req_valid(ex_ctl_req_valid),
        .ctl_req_op   (ex_ctl_req_op),
        .ctl_req_addr (ex_ctl_req_addr),
        .if_pc_for_bp (pc_q_o),
        .exmem_valid_o(exmem_valid),
        .exmem_pc_o   (exmem_pc),
        .exmem_inst_o (exmem_inst),
        .exmem_rd_o   (exmem_rd),
        .exmem_prd_o  (exmem_prd),
        .exmem_rob_ptr_o(exmem_rob_ptr),
        .exmem_regwrite_o(exmem_regwrite),
        .exmem_is_load_o(exmem_is_load),
        .exmem_is_store_o(exmem_is_store),
        .exmem_is_amo_o(exmem_is_amo),
        .exmem_is_branch_o(exmem_is_branch),
        .exmem_is_jal_o   (exmem_is_jal),
        .exmem_is_jalr_o  (exmem_is_jalr),
        .exmem_is_fence_o (exmem_is_fence),
        .exmem_is_csr_o   (exmem_is_csr),
        .exmem_mem_read_o(exmem_mem_read),
        .exmem_alu_result_o(exmem_alu_result),
        .exmem_mem_addr_o(exmem_mem_addr),
        .exmem_mem_cmd_o(exmem_mem_cmd),
        .exmem_mem_size_o(exmem_mem_size),
        .exmem_store_wdata_o(exmem_store_wdata),
        .exmem_store_wstrb_o(exmem_store_wstrb),
        .exmem_load_funct3_o(exmem_load_funct3),
        .exmem_amo_funct_o(exmem_amo_funct),
        .exmem_amo_aq_o   (exmem_amo_aq),
        .exmem_amo_rl_o   (exmem_amo_rl),
        .exmem_fregwrite_o(exmem_fregwrite),
        .exmem_is_fp_load_o(exmem_is_fp_load),
        .exmem1_valid_o(exmem1_valid),
        .exmem1_alu_result_o(exmem1_alu_result),
        .exmem1_rd_o(exmem1_rd),
        .exmem1_prd_o(exmem1_prd),
        .exmem1_rob_ptr_o(exmem1_rob_ptr),
        .exmem1_regwrite_o(exmem1_regwrite),
        .exmem1_pc_o(exmem1_pc),
        .exmem1_inst_o(exmem1_inst),
        .exmem1_is_load_o(exmem1_is_load),
        .exmem1_is_store_o(exmem1_is_store),
        .exmem1_mem_addr_o(exmem1_mem_addr),
        .exmem1_mem_cmd_o(exmem1_mem_cmd),
        .exmem1_mem_size_o(exmem1_mem_size),
        .exmem1_store_wdata_o(exmem1_store_wdata),
        .exmem1_store_wstrb_o(exmem1_store_wstrb),
        .fp_fflags_inc(fp_fflags_inc),
        .fp_fflags_we (fp_fflags_we),
        .stall_fp     (stall_fp),
        .dbg_flags    (dbg_ex_flags),
        .csr_wr_en   (csr_wr_en),
        .csr_wr_addr (csr_wr_addr),
        .csr_wr_data (csr_wr_data)
    );

    // -----------------------------
    // MEM / MEM-WB (cpu_lsq)
    // -----------------------------
    logic        lsq_d_req_valid;
    logic [31:0] lsq_d_req_addr;
    logic [2:0]  lsq_d_req_cmd;
    logic [2:0]  lsq_d_req_size;
    logic [31:0] lsq_d_req_wdata;
    logic [3:0]  lsq_d_req_wstrb;
    logic [4:0]  lsq_d_amo_funct;
    logic        lsq_d_amo_aq, lsq_d_amo_rl;
    logic        lsq_d_req1_valid_unused;
    logic [31:0] lsq_d_req1_addr_unused;
    logic [2:0]  lsq_d_req1_cmd_unused;
    logic [2:0]  lsq_d_req1_size_unused;
    logic [31:0] lsq_d_req1_wdata_unused;
    logic [3:0]  lsq_d_req1_wstrb_unused;
    logic        lsq_mwb_valid;
    logic [31:0] lsq_mwb_pc, lsq_mwb_inst;
    logic [4:0]  lsq_mwb_rd;
    logic [5:0]  lsq_mwb_prd;
    logic [5:0]  lsq_mwb_rob_ptr;
    logic        lsq_mwb_regwrite;
    logic [31:0] lsq_mwb_wdata;
    logic [2:0]  lsq_mwb_lf3;
    logic        lsq_mwb_fpld;
    logic        lsq_stall;
    logic        lsq_empty;
    logic        lsq_idle;
    logic        lsq_full;
    logic        lsq_resp_pending;
    logic        lsq_fault;
    logic [31:0] lsq_fault_mepc;
    logic [31:0] lsq_fault_mcause;
    logic [5:0]  lsq_fault_prd;
    logic [5:0]  lsq_fault_rob_ptr;

    // LSQ: dual-slot acceptance into multi-entry FIFO (LSQ_DEPTH=16).
    wire slot0_mem_req = exmem_valid && (exmem_is_load || exmem_is_store || exmem_is_amo || exmem_is_fp_load);
    wire slot1_mem_req = exmem1_valid && (exmem1_is_load || exmem1_is_store);
    wire [5:0] lsq_snap1_rob_ptr = slot1_mem_req ? exmem1_rob_ptr : 6'd0;
    logic        lsq_replay_valid;
    logic [5:0]  lsq_replay_rob_idx;
    logic [31:0] lsq_replay_pc;

    cpu_lsq #(.LSQ_DEPTH(8)) u_lsq (
        .pl_clk(pl_clk), .pl_resetn(pl_resetn),
        // Slot 0
        .mem_req_valid(slot0_mem_req),
        .mem_req_addr(exmem_mem_addr),
        .mem_req_cmd(exmem_mem_cmd),
        .mem_req_size(exmem_mem_size),
        .mem_req_wdata(exmem_store_wdata),
        .mem_req_wstrb(exmem_store_wstrb),
        .mem_req_amo_funct(exmem_amo_funct),
        .mem_req_amo_aq(exmem_amo_aq), .mem_req_amo_rl(exmem_amo_rl),
        .mem_req_is_load(exmem_is_load),
        .mem_req_is_amo(exmem_is_amo),
        .mem_req_rd(exmem_rd),
        .mem_req_regwrite(exmem_regwrite || exmem_fregwrite),
        .mem_req_prd(exmem_prd),
        // D-port
        .d_req_valid(lsq_d_req_valid), .d_req_ready(d_req_ready),
        .d_req_addr(lsq_d_req_addr), .d_req_cmd(lsq_d_req_cmd),
        .d_req_size(lsq_d_req_size), .d_req_wdata(lsq_d_req_wdata),
        .d_req_wstrb(lsq_d_req_wstrb), .d_req_amo_funct(lsq_d_amo_funct),
        .d_req_amo_aq(lsq_d_amo_aq), .d_req_amo_rl(lsq_d_amo_rl),
        .d_resp_valid(d_resp_valid), .d_resp_rdata(d_resp_rdata),
        .d_resp_err(d_resp_err),
        // WB
        .memwb_valid(lsq_mwb_valid), .memwb_pc(lsq_mwb_pc),
        .memwb_inst(lsq_mwb_inst), .memwb_rd(lsq_mwb_rd),
        .memwb_prd(lsq_mwb_prd),
        .memwb_rob_ptr(lsq_mwb_rob_ptr),
        .memwb_regwrite(lsq_mwb_regwrite), .memwb_wdata(lsq_mwb_wdata),
        .memwb_load_funct3(lsq_mwb_lf3), .memwb_is_fp_load(lsq_mwb_fpld),
        .memwb_is_amo(),
        // Slot 0 snapshot
        .snap_pc(exmem_pc),
        .snap_inst(exmem_inst),
        .snap_load_funct3(exmem_load_funct3),
        .snap_is_fp_load(exmem_is_fp_load),
        .snap_rob_ptr(exmem_rob_ptr),
        // Slot 1 memory request
        .mem_req1_valid(slot1_mem_req),
        .mem_req1_addr(exmem1_mem_addr),
        .mem_req1_cmd(exmem1_mem_cmd),
        .mem_req1_size(exmem1_mem_size),
        .mem_req1_wdata(exmem1_store_wdata),
        .mem_req1_wstrb(exmem1_store_wstrb),
        .mem_req1_is_load(exmem1_is_load),
        .mem_req1_is_store(exmem1_is_store),
        .mem_req1_rd(exmem1_rd),
        .mem_req1_regwrite(exmem1_regwrite),
        .mem_req1_prd(exmem1_prd),
        .d_req1_valid(lsq_d_req1_valid_unused),
        .d_req1_ready(1'b0),
        .d_req1_addr(lsq_d_req1_addr_unused),
        .d_req1_cmd(lsq_d_req1_cmd_unused),
        .d_req1_size(lsq_d_req1_size_unused),
        .d_req1_wdata(lsq_d_req1_wdata_unused),
        .d_req1_wstrb(lsq_d_req1_wstrb_unused),
        .d_resp1_valid(1'b0),
        .d_resp1_rdata(32'b0),
        .d_resp1_err(1'b0),
        // Slot 1 snapshot
        .snap1_pc(exmem1_pc),
        .snap1_inst(exmem1_inst),
        .snap1_load_funct3(exmem1_inst[14:12]),
        .snap1_is_fp_load(1'b0),
        .snap1_rob_ptr(lsq_snap1_rob_ptr),
        .alloc_rob_idx(6'b0),
        // ---- outputs ----
        .lsq_empty_o(lsq_empty), .lsq_idle_o(lsq_idle),
        .lsq_full_o(lsq_full), .lsq_resp_pending_o(lsq_resp_pending),
        .stall_mem(lsq_stall), .mem_fault_redirect(lsq_fault),
        .mem_fault_mepc(lsq_fault_mepc), .mem_fault_mcause(lsq_fault_mcause),
        .mem_fault_prd(lsq_fault_prd), .mem_fault_rob_ptr(lsq_fault_rob_ptr),
        .replay_valid(lsq_replay_valid), .replay_rob_idx(lsq_replay_rob_idx),
        .replay_pc(lsq_replay_pc)
    );

    assign d_req_valid      = lsq_d_req_valid;
    assign d_req_addr       = lsq_d_req_addr;
    assign d_req_cmd        = lsq_d_req_cmd;
    assign d_req_size       = lsq_d_req_size;
    assign d_req_wdata      = lsq_d_req_wdata;
    assign d_req_wstrb      = lsq_d_req_wstrb;
    assign d_req_amo_funct  = lsq_d_amo_funct;
    assign d_req_amo_aq     = lsq_d_amo_aq;
    assign d_req_amo_rl     = lsq_d_amo_rl;
    assign memwb_valid      = lsq_mwb_valid;
    assign memwb_pc         = lsq_mwb_pc;
    assign memwb_inst       = lsq_mwb_inst;
    assign memwb_rd         = lsq_mwb_rd;
    assign memwb_prd        = lsq_mwb_prd;
    assign memwb_rob_ptr    = lsq_mwb_rob_ptr;
    assign memwb_regwrite   = lsq_mwb_regwrite;
    assign memwb_wdata      = lsq_mwb_wdata;
    assign memwb_load_funct3= lsq_mwb_lf3;
    assign memwb_is_fp_load = lsq_mwb_fpld;
    assign stall_mem        = lsq_stall;
    assign mem_fault_redirect = lsq_fault;
    assign mem_fault_mepc   = lsq_fault_mepc;
    assign mem_fault_mcause = lsq_fault_mcause;
    assign mem_fault_prd    = lsq_fault_prd;
    assign mem_fault_rob_ptr= lsq_fault_rob_ptr;

    // -----------------------------
    // WB
    // -----------------------------
    logic        wb_commit_valid;
    logic [31:0] wb_commit_pc;
    logic [31:0] wb_commit_inst;
    logic        wb_commit_regwrite;
    logic [4:0]  wb_commit_waddr;
    logic [31:0] wb_commit_wdata;
    logic        wb_commit_from_memwb;
    logic        wb_commit_from_exmem;
    logic        wb_commit_defer_exmem;
    logic        exmem_advance;
    logic        exmem_rob_fire;
    logic        fence_pending_valid;
    logic [5:0]  fence_pending_prd;
    logic [5:0]  fence_pending_rob_ptr;
    logic        rob_empty;
    logic [5:0]  rob_tail_tag;
    logic [5:0]  rob_head_tag;
    logic        rob_wb_accept, rob_wb2_accept, rob_wb3_accept;
    logic        rob_trap_redirect;
    logic [31:0] rob_trap_redirect_pc;
    logic [31:0] rob_trap_redirect_cause;
    typedef enum logic [1:0] {
        FENCE_IDLE,
        FENCE_DRAIN,
        FENCE_WAIT_DONE
    } fence_state_e;
    fence_state_e fence_state_q;
    logic [2:0]  fence_pending_op;
    logic [31:0] fence_pending_addr;
    wire fence_issue_fire = !fence_busy && iq_issue_valid && iq_issue_is_fence;
    wire fence_drain_done = (fence_state_q == FENCE_DRAIN) && lsq_idle;

    assign exmem_advance  = !stall_mem && !fence_busy && !stall_fp;
    assign exmem_rob_fire = !stall_fp;
    assign ctl_req_valid = fence_drain_done;
    assign ctl_req_op    = fence_pending_op;
    assign ctl_req_addr  = fence_pending_addr;

    wire exmem_nop_rob = exmem_rob_fire && exmem_valid && !exmem_is_load && !exmem_is_store
        && !exmem_is_amo && !exmem_is_branch && !exmem_is_jal && !exmem_is_jalr
        && !exmem_is_fence && !exmem_is_csr && !exmem_regwrite;
    wire exmem_gpr_rob = exmem_rob_fire && exmem_valid && exmem_regwrite
        && !exmem_is_load && !exmem_is_store && !exmem_is_amo;
    wire exmem_fp_rob = exmem_rob_fire && exmem_valid && exmem_fregwrite
        && !exmem_is_load && !exmem_is_store && !exmem_is_amo;
    wire exmem_branch_rob = exmem_rob_fire && exmem_valid && exmem_is_branch
        && !exmem_is_load && !exmem_is_store && !exmem_is_amo;
    wire exmem_store_rob = exmem_rob_fire && exmem_valid && exmem_is_store;
    wire exmem_amo_rob   = exmem_rob_fire && exmem_valid && exmem_is_amo;
    wire exmem_jal_rob   = exmem_rob_fire && exmem_valid && exmem_is_jal;
    wire exmem_jalr_rob  = exmem_rob_fire && exmem_valid && exmem_is_jalr;
    wire exmem_fence_rob = 1'b0;
    wire exmem_csr_rob   = exmem_rob_fire && exmem_valid && exmem_is_csr;
    wire exmem_slot_rob = exmem_gpr_rob || exmem_fp_rob || exmem_nop_rob || exmem_branch_rob
        || exmem_jal_rob || exmem_jalr_rob || exmem_fence_rob || exmem_csr_rob;
    wire exmem_rob_done = exmem_slot_rob && (exmem_prd != 6'd0);

    wire [6:0] exmem1_opcode = exmem1_inst[6:0];
    wire exmem1_is_branch_rob = (exmem1_opcode == 7'b1100011);
    wire exmem1_is_jal_rob    = (exmem1_opcode == 7'b1101111);
    wire exmem1_is_jalr_rob   = (exmem1_opcode == 7'b1100111);
    wire exmem1_is_fence_rob  = (exmem1_opcode == 7'b0001111);
    wire exmem1_is_csr_rob    = (exmem1_opcode == 7'b1110011);
    wire exmem1_slot_rob = exmem_rob_fire && exmem1_valid && (
        ((exmem1_regwrite && !exmem1_is_load && !exmem1_is_store)
         || (!exmem1_regwrite && !exmem1_is_load && !exmem1_is_store
             && !exmem1_is_branch_rob && !exmem1_is_jal_rob
             && !exmem1_is_jalr_rob && !exmem1_is_fence_rob && !exmem1_is_csr_rob))
        || exmem1_is_branch_rob || exmem1_is_jal_rob || exmem1_is_jalr_rob
        || exmem1_is_fence_rob || exmem1_is_csr_rob);
    wire exmem1_rob_done = exmem1_slot_rob && (exmem1_prd != 6'd0);
    wire exmem_ctrl_resolve = exmem_valid && (exmem_is_branch || exmem_is_jal || exmem_is_jalr);
    wire exmem1_ctrl_resolve = exmem1_valid && (exmem1_is_branch_rob || exmem1_is_jal_rob || exmem1_is_jalr_rob);
    // Redirect/mispredict: raw request vs ROB squash (must not squash an already-empty ROB with a stale tag).
    wire ex_redirect_valid = redirect_valid && !trap_taken;
    wire slot1_static_redirect = ifid_pending_slot1_redir && !ex_redirect_valid && !exmem1_redirect_valid;
    wire younger_squash_raw   = ex_redirect_valid || exmem1_redirect_valid || slot1_static_redirect || lsq_replay_valid;
    wire [5:0] younger_squash_ptr = ex_redirect_valid ? fu_redirect_rob_ptr
        : (exmem1_redirect_valid ? exmem1_rob_ptr
        : (lsq_replay_valid ? lsq_replay_rob_idx : ifid_slot1_redir_rob_ptr));
    wire younger_squash_to_rob;  // younger_squash_raw && !rob_empty (see assign near u_rob)
    logic younger_squash_pending_q;
    logic [5:0] younger_squash_ptr_q;
    logic rob_squash_busy;
    wire younger_squash_accept = younger_squash_pending_q && !rob_squash_busy;
    wire younger_squash_active = younger_squash_raw || younger_squash_pending_q || rob_squash_busy;

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            younger_squash_pending_q <= 1'b0;
            younger_squash_ptr_q     <= '0;
        end else begin
            if (younger_squash_raw) begin
                younger_squash_pending_q <= 1'b1;
                younger_squash_ptr_q <= younger_squash_ptr;
            end else if (younger_squash_accept) begin
                younger_squash_pending_q <= 1'b0;
            end
        end
    end

    wire [31:0] memwb_wdata_rob_sext =
        (memwb_load_funct3 == 3'b000) ? {{24{memwb_wdata[7]}},  memwb_wdata[7:0]} :
        (memwb_load_funct3 == 3'b100) ? {24'b0,                 memwb_wdata[7:0]} :
        (memwb_load_funct3 == 3'b001) ? {{16{memwb_wdata[15]}}, memwb_wdata[15:0]} :
        (memwb_load_funct3 == 3'b101) ? {16'b0,                 memwb_wdata[15:0]} :
        memwb_wdata;

    wire        rob_v_mem = memwb_rob_done;
    wire        rob_v_fence = fence_pending_valid && ctl_done && !ctl_err;
    wire        rob_v_ex0 = exmem_rob_done;
    wire        rob_v_ex1 = exmem1_rob_done;
    wire        rob_wb_en = rob_v_mem || rob_v_fence || rob_v_ex0 || rob_v_ex1;
    wire [5:0]  rob_wb_prd = rob_v_mem ? memwb_prd
        : (rob_v_fence ? fence_pending_prd : (rob_v_ex0 ? exmem_prd : exmem1_prd));
    wire [5:0]  rob_wb_rob_ptr = rob_v_mem ? memwb_rob_ptr
        : (rob_v_fence ? fence_pending_rob_ptr : (rob_v_ex0 ? exmem_rob_ptr : exmem1_rob_ptr));
    wire [31:0] rob_wb_wdata = rob_v_mem ? memwb_wdata_rob_sext
        : (rob_v_fence ? 32'b0 : (rob_v_ex0 ? exmem_alu_result : exmem1_alu_result));
    wire        rob_wb_regwrite = rob_v_mem ? memwb_prf_we
        : (rob_v_fence ? 1'b0
        : (rob_v_ex0 ? (exmem_regwrite && !exmem_is_load && !exmem_is_store && !exmem_is_amo)
                     : (exmem1_regwrite && !exmem1_is_load && !exmem1_is_store)));

`ifndef SYNTHESIS
    always_ff @(posedge pl_clk) begin
        if (pl_resetn && $test$plusargs("CSR_DBG") && rob_v_ex0 && exmem_is_csr) begin
            $display("[CORE_CSR_DBG] %m t=%0t wb pc=0x%08x inst=0x%08x prd=%0d rob=%0d wdata=0x%08x regwrite=%0b",
                     $time, exmem_pc, exmem_inst, exmem_prd, exmem_rob_ptr,
                     rob_wb_wdata, rob_wb_regwrite);
        end
    end
`endif

    wire        rob_wb2_en = !rob_v_fence
        && ((rob_v_mem && rob_v_ex0) || (rob_v_mem && rob_v_ex1) || (rob_v_ex0 && rob_v_ex1));
    wire [5:0]  rob_wb2_prd = (!rob_v_mem && rob_v_ex0 && rob_v_ex1) ? exmem1_prd
        : ((rob_v_mem && rob_v_ex0) ? exmem_prd : exmem1_prd);
    wire [5:0]  rob_wb2_rob_ptr = (!rob_v_mem && rob_v_ex0 && rob_v_ex1) ? exmem1_rob_ptr
        : ((rob_v_mem && rob_v_ex0) ? exmem_rob_ptr : exmem1_rob_ptr);
    wire [31:0] rob_wb2_wdata = (!rob_v_mem && rob_v_ex0 && rob_v_ex1) ? exmem1_alu_result
        : ((rob_v_mem && rob_v_ex0) ? exmem_alu_result : exmem1_alu_result);
    wire        rob_wb2_regwrite = (!rob_v_mem && rob_v_ex0 && rob_v_ex1)
        ? (exmem1_regwrite && !exmem1_is_load && !exmem1_is_store)
        : ((rob_v_mem && rob_v_ex0)
            ? (exmem_regwrite && !exmem_is_load && !exmem_is_store && !exmem_is_amo)
            : (exmem1_regwrite && !exmem1_is_load && !exmem1_is_store));
    wire        rob_wb3_en = !rob_v_fence && rob_v_mem && rob_v_ex0 && rob_v_ex1;
    wire [5:0]  rob_wb3_prd = exmem1_prd;
    wire [5:0]  rob_wb3_rob_ptr = exmem1_rob_ptr;
    wire [31:0] rob_wb3_wdata = exmem1_alu_result;
    wire        rob_wb3_regwrite = exmem1_regwrite && !exmem1_is_load && !exmem1_is_store;
    wire        rob_wb_cdb_valid  = rob_wb_accept  && rob_wb_regwrite;
    wire        rob_wb2_cdb_valid = rob_wb2_accept && rob_wb2_regwrite;
    wire        rob_wb3_cdb_valid = rob_wb3_accept && rob_wb3_regwrite;

    cpu_wb_stage u_wb (
        .pl_clk       (pl_clk),
        .pl_resetn    (pl_resetn),
        .exmem_valid  (exmem_valid),
        .exmem_advance(exmem_advance),
        .exmem_rd     (exmem_rd),
        .exmem_regwrite(exmem_regwrite),
        .exmem_fregwrite(exmem_fregwrite),
        .exmem_is_load(exmem_is_load),
        .exmem_is_store(exmem_is_store),
        .exmem_is_amo(exmem_is_amo),
        .exmem_is_branch(exmem_is_branch),
        .exmem_is_jal   (exmem_is_jal),
        .exmem_is_jalr  (exmem_is_jalr),
        .exmem_is_fence (exmem_is_fence),
        .exmem_is_csr   (exmem_is_csr),
        .exmem_alu_result(exmem_alu_result),
        .exmem_pc     (exmem_pc),
        .exmem_inst   (exmem_inst),
        .memwb_valid  (memwb_valid),
        .memwb_pc     (memwb_pc),
        .memwb_inst   (memwb_inst),
        .memwb_rd     (memwb_rd),
        .memwb_regwrite(memwb_regwrite),
        .memwb_wdata  (memwb_wdata),
        .memwb_load_funct3(memwb_load_funct3),
        .memwb_is_fp_load(memwb_is_fp_load),
        .rf_we        (rf_we),
        .rf_waddr     (rf_waddr),
        .rf_wdata     (rf_wdata),
        .rf_we_combo  (rf_we_combo),
        .rf_waddr_combo(rf_waddr_combo),
        .rf_wdata_combo(rf_wdata_combo),
        .frf_we       (frf_we),
        .frf_waddr    (frf_waddr),
        .frf_wdata    (frf_wdata),
        .frf_we_b     (frf_we_b),
        .frf_waddr_b  (frf_waddr_b),
        .frf_wdata_b  (frf_wdata_b),
        .commit_valid   (wb_commit_valid),
        .commit_pc      (wb_commit_pc),
        .commit_inst    (wb_commit_inst),
        .commit_regwrite(wb_commit_regwrite),
        .commit_waddr   (wb_commit_waddr),
        .commit_wdata   (wb_commit_wdata),
        .mon_commit_from_memwb (wb_commit_from_memwb),
        .mon_commit_from_exmem (wb_commit_from_exmem),
        .mon_commit_defer_exmem(wb_commit_defer_exmem),
        .rob_empty      (rob_empty)
    );

    // ──── Phase O1: PRF / RAT / ROB ────────────────────────────────────
    logic [5:0]  prs1, prs2, old_prd, wb_prd;
    logic [5:0]  prs1_1, prs2_1, old1_prd; // unused in O1, WB writes arch regs directly
    logic [31:0] prf_rdata1, prf_rdata2, prf_rdata3, prf_rdata4;
    logic        prf_we0, prf_we1;
    logic [5:0]  prf_waddr0, prf_waddr1;
    logic [31:0] prf_wdata0, prf_wdata1;

    // prd is 6-bit globally (0..63). Keep PRF size within addressable range.
    localparam int unsigned CORE_PRF_SIZE = 64;
    assign prf_we0    = rob_wb_cdb_valid;
    assign prf_waddr0 = rob_wb_prd;
    assign prf_wdata0 = rob_wb_wdata;
    assign prf_we1    = rob_wb2_cdb_valid;
    assign prf_waddr1 = rob_wb2_prd;
    assign prf_wdata1 = rob_wb2_wdata;
    assign stall_prf  = ifid_usable && (allocate_prd == 6'd0);
    // Never allocate ROB/PRF entries on redirect cycles; IF/ID payload may be transient.
    wire alloc0_fire = consume_ifid && ifid_usable && !rob_full_q && !stall_iq
        && !redirect_valid_any && !younger_squash_pending_q && !rob_squash_busy;
    wire alloc1_fire = alloc0_fire && ifid_dual_alloc_ready;
    wire split_slot1_refetch = alloc0_fire && ifid_effective_dual && !alloc1_fire;

    logic consume_ifid_d1;
    logic alloc0_fire_d1, alloc1_fire_d1;
    always_ff @(posedge pl_clk or negedge pl_resetn)
        if (!pl_resetn) begin
            consume_ifid_d1 <= 1'b0;
            alloc0_fire_d1  <= 1'b0;
            alloc1_fire_d1  <= 1'b0;
        end else begin
            consume_ifid_d1 <= alloc0_fire;
            alloc0_fire_d1  <= alloc0_fire;
            alloc1_fire_d1  <= alloc1_fire;
        end

    logic [31:0] ifid_pc_d1, ifid_inst_d1;
    logic [31:0] ifid1_inst_d1;
    logic [5:0] prs1_d1, prs2_d1, allocate_prd_d1;
    logic [5:0] prs1_1_d1, prs2_1_d1, allocate1_prd_d1;
    logic [5:0] old_prd_d1, old1_prd_d1;
    logic [5:0] alloc0_rob_ptr, alloc1_rob_ptr;
    logic [5:0] alloc0_rob_ptr_d1, alloc1_rob_ptr_d1;
    logic       id_regwrite_d1, id1_regwrite_d1, ifid1_valid_d1;

    always_ff @(posedge pl_clk) begin
        if (alloc0_fire) begin
            prs1_d1  <= prs1;   prs2_d1  <= prs2;   allocate_prd_d1  <= allocate_prd;
            alloc0_rob_ptr_d1 <= alloc0_rob_ptr;
            old_prd_d1 <= old_prd;
            id_regwrite_d1 <= id_regwrite;
            ifid_pc_d1 <= ifid_pc;
            ifid_inst_d1 <= ifid_inst;
            if (alloc1_fire) begin
                prs1_1_d1 <= prs1_1; prs2_1_d1 <= prs2_1; allocate1_prd_d1 <= allocate1_prd;
                alloc1_rob_ptr_d1 <= alloc1_rob_ptr;
                old1_prd_d1 <= old1_prd;
                id1_regwrite_d1 <= id1_regwrite;
                ifid1_inst_d1 <= ifid1_inst;
                ifid1_valid_d1 <= 1'b1;
            end else begin
                ifid1_valid_d1 <= 1'b0;
            end
        end
    end

    // Dispatch / retract (needs d1 state; must precede PRF/RAT instances).
    wire dispatch_valid_g  = alloc0_fire_d1 && !redirect_blocks_dispatch;
    wire dispatch1_is_ctl_class = (idex1_opcode == 7'b0001111) || (idex1_opcode == 7'b1110011);
    wire dispatch1_valid_g = alloc1_fire_d1 && !redirect_blocks_dispatch && !dispatch1_is_ctl_class;
    logic        rob_retract_ack0, rob_retract_ack1;
    // Checkpoint push must align with rename/alloc (not delayed dispatch/issue signals),
    // otherwise cp_pop may restore a stale RAT snapshot and create duplicate live PRDs.
    // Checkpoint when either slot allocates a control-flow op (slot1-only branch needs RAT pop on mispredict).
    wire rat_cp_push = (alloc0_fire && ifid0_is_ctrl) || (alloc1_fire && ifid1_is_ctrl);
    wire [5:0] rat_cp_push_tag = (alloc0_fire && ifid0_is_ctrl) ? alloc0_rob_ptr : alloc1_rob_ptr;
    // Fixup: when only slot1 is ctrl, cp_pop must preserve slot0's rename (which precedes the branch).
    wire cp_slot0_nonctrl = alloc0_fire && !ifid0_is_ctrl && id_regwrite && (ifid_inst[11:7] != 5'd0);
    wire cp_slot1_ctrl_only = alloc1_fire && ifid1_is_ctrl && !ifid0_is_ctrl;
    logic        cp_fixup_valid;
    logic [4:0]  cp_fixup_rd;
    logic [5:0]  cp_fixup_prd;
    always_ff @(posedge pl_clk or negedge pl_resetn)
        if (!pl_resetn) begin
            cp_fixup_valid <= 1'b0;
            cp_fixup_rd    <= '0;
            cp_fixup_prd   <= '0;
        end else begin
            if (rat_cp_push && cp_slot0_nonctrl && cp_slot1_ctrl_only) begin
                cp_fixup_valid <= 1'b1;
                cp_fixup_rd    <= ifid_inst[11:7];
                cp_fixup_prd   <= allocate_prd;
            end else if (bp_rat_cp_pop || bp_rat_cp_release || rob_retract_ack0) begin
                cp_fixup_valid <= 1'b0;
            end
        end
    // Slot-wise retract: if a consumed slot fails to dispatch, return its tail alloc.
    wire retract_slot0_pop = alloc0_fire_d1 && !iq_dispatch_accept_q && !younger_squash_active;
    wire retract_slot1_pop = alloc1_fire_d1 && !iq_dispatch1_accept_q && !younger_squash_active;
    assign rob_retract_en  = retract_slot0_pop || retract_slot1_pop;
    wire rob_retract_dual  = retract_slot0_pop && retract_slot1_pop;

    logic        rob_retire_valid;
    logic        rob_retire_arch_valid;
    logic [63:0] rob_squash_release_mask;
    logic [63:0] rob_squash_release_mask_d1;
    logic [63:0] rob_prd_inuse_mask;
    logic [63:0] rat_mapped_prd_mask;
    wire  [63:0] prf_inuse_prd_mask = rob_prd_inuse_mask | rat_mapped_prd_mask;
    logic [31:0] rob_retire_pc;
    logic [31:0] rob_retire_inst;
    logic        rob_retire_regwrite;
    logic [4:0]  rob_retire_waddr;
    logic [31:0] rob_retire_wdata;
    logic        rob_pop;
    logic        rob_retire1_valid;
    logic        rob_retire1_arch_valid;
    logic [31:0] rob_retire1_pc, rob_retire1_inst;
    logic        rob_retire1_regwrite;
    logic [4:0]  rob_retire1_waddr;
    logic [31:0] rob_retire1_wdata;

    assign rob_pop = rob_retire_valid;
    assign younger_squash_to_rob = younger_squash_pending_q && !rob_empty && !rob_squash_busy;
    wire        rob_exception_from_ex = trap_taken && !stall_fp && !stall_mem && !fence_busy;
    wire        rob_exception_en = rob_exception_from_ex || mem_fault_redirect;
    wire [3:0]  rob_exception_cause = mem_fault_redirect ? mem_fault_mcause[3:0]
                                                          : trap_cause_val_comb[3:0];
    wire [5:0]  rob_exception_prd = mem_fault_redirect ? mem_fault_prd : iq_issue_prd;
    wire [5:0]  rob_exception_rob_ptr = mem_fault_redirect ? mem_fault_rob_ptr : iq_issue_rob_ptr;

    cpu_rob #(.ROB_DEPTH(16)) u_rob (
        .pl_clk(pl_clk), .pl_resetn(pl_resetn),
        .alloc_en          (alloc0_fire),
        .alloc_pc          (ifid_pc),
        .alloc_inst        (ifid_inst),
        .alloc_regwrite    (id_regwrite),
        .alloc_rd          (ifid_inst[11:7]),
        .alloc_old_prd     (old_prd),
        .alloc_prd         (allocate_prd),
        .alloc_rob_ptr     (alloc0_rob_ptr),
        .alloc1_en         (alloc1_fire),
        .alloc1_pc         (ifid1_pc), .alloc1_inst(ifid1_inst),
        .alloc1_regwrite   (id1_regwrite), .alloc1_rd(ifid1_inst[11:7]),
        .alloc1_prd        (allocate1_prd),
        .alloc1_old_prd    (old1_prd),
        .alloc1_rob_ptr    (alloc1_rob_ptr),
        .retract_en        (rob_retract_en),
        .retract_dual      (rob_retract_dual),
        .retract0_req      (retract_slot0_pop),
        .retract1_req      (retract_slot1_pop),
        .retract_ack0      (rob_retract_ack0),
        .retract_ack1      (rob_retract_ack1),
        .squash_en         (younger_squash_to_rob),
        .squash_rob_ptr    (younger_squash_ptr_q),
        .squash_busy       (rob_squash_busy),
        .wb_en             (rob_wb_en),
        .wb_wdata          (rob_wb_wdata),
        .wb_prd            (rob_wb_prd),
        .wb_rob_ptr        (rob_wb_rob_ptr),
        .wb2_en            (rob_wb2_en),
        .wb2_wdata         (rob_wb2_wdata),
        .wb2_prd           (rob_wb2_prd),
        .wb2_rob_ptr       (rob_wb2_rob_ptr),
        .wb3_en            (rob_wb3_en),
        .wb3_wdata         (rob_wb3_wdata),
        .wb3_prd           (rob_wb3_prd),
        .wb3_rob_ptr       (rob_wb3_rob_ptr),
        .wb_accept         (rob_wb_accept),
        .wb2_accept        (rob_wb2_accept),
        .wb3_accept        (rob_wb3_accept),
        .pop_en            (rob_pop),
        .rob_retire_valid  (rob_retire_valid),
        .rob_retire_arch_valid (rob_retire_arch_valid),
        .rob_retire_pc     (rob_retire_pc),
        .rob_retire_inst   (rob_retire_inst),
        .rob_retire_regwrite(rob_retire_regwrite),
        .rob_retire_waddr  (rob_retire_waddr),
        .rob_retire_wdata  (rob_retire_wdata),
        .rob_empty         (rob_empty),
        .rob_full          (rob_full_q),
        .rob_full_dual     (rob_full_dual_q),
        .rob_tail_tag      (rob_tail_tag),
        .rob_head_tag      (rob_head_tag),
        .retire_release_en (rob_release_en),
        .retire_release_prd(rob_release_prd),
        .rob_retire1_valid  (rob_retire1_valid),
        .rob_retire1_arch_valid (rob_retire1_arch_valid),
        .rob_retire1_pc     (rob_retire1_pc),
        .rob_retire1_inst   (rob_retire1_inst),
        .rob_retire1_regwrite(rob_retire1_regwrite),
        .rob_retire1_waddr  (rob_retire1_waddr),
        .rob_retire1_wdata  (rob_retire1_wdata),
        .retire1_release_en (rob_release1_en),
        .retire1_release_prd(rob_release1_prd),
        .exception_en      (rob_exception_en),
        .exception_cause   (rob_exception_cause),
        .exception_prd     (rob_exception_prd),
        .exception_rob_ptr (rob_exception_rob_ptr),
        .trap_redirect     (rob_trap_redirect),
        .trap_redirect_pc  (rob_trap_redirect_pc),
        .trap_redirect_cause(rob_trap_redirect_cause),
        .squash_release_mask(rob_squash_release_mask),
        .rob_prd_inuse_mask(rob_prd_inuse_mask)
    );

    // IQ squash must track ROB: when squash_rob_ptr is outside [head,tail), ROB skips squash but IQ
    // would still apply tag comparisons and can wipe valid RS entries (branch_stress / mispredict).
    wire iq_younger_squash = younger_squash_to_rob && u_rob.squash_rob_ptr_in_window;

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn)
            rob_squash_release_mask_d1 <= '0;
        else
            rob_squash_release_mask_d1 <= rob_squash_release_mask;
    end

    assign retire_valid    = rob_retire_arch_valid;
    assign retire_pc       = rob_retire_pc;
    assign retire_inst     = rob_retire_inst;
    assign retire_regwrite = rob_retire_regwrite;
    assign retire_waddr    = rob_retire_waddr;
    assign retire_wdata    = rob_retire_wdata;
    assign retire1_valid   = rob_retire1_arch_valid;
    assign retire1_pc       = rob_retire1_pc;
    assign retire1_inst     = rob_retire1_inst;
    assign retire1_regwrite = rob_retire1_regwrite;
    assign retire1_waddr    = rob_retire1_waddr;
    assign retire1_wdata    = rob_retire1_wdata;

    cpu_prf #(.PRF_SIZE(CORE_PRF_SIZE)) u_prf (
        .pl_clk(pl_clk), .pl_resetn(pl_resetn),
        .allocate_en   (alloc0_fire),
        .allocate_arch (ifid_inst[11:7]),
        .allocate_prd  (allocate_prd),
        .allocate1_en  (alloc1_fire),
        .allocate1_arch(ifid1_inst[11:7]),
        .allocate1_prd (allocate1_prd),
        .release_en    (rob_release_en),
        .release_prd   (rob_release_prd),
        .release1_en   (rob_release1_en),
        .release1_prd  (rob_release1_prd),
        .retract_en    (rob_retract_ack0 && (allocate_prd_d1 != 6'd0)),
        .retract_prd   (allocate_prd_d1),
        .retract1_en   (rob_retract_ack1 && (allocate1_prd_d1 != 6'd0)),
        .retract1_prd  (allocate1_prd_d1),
        .we            (prf_we0),
        .waddr         (prf_waddr0),
        .wdata         (prf_wdata0),
        .we1           (prf_we1),
        .waddr1        (prf_waddr1),
        .wdata1        (prf_wdata1),
        .squash_release_mask(rob_squash_release_mask),
        .squash_release_mask_d1(rob_squash_release_mask_d1),
        .inuse_prd_mask(prf_inuse_prd_mask),
        .raddr1        (prs1),
        .raddr2        (prs2),
        .rdata1        (prf_rdata1),
        .rdata2        (prf_rdata2),
        .raddr3        (prs1_1),
        .raddr4        (prs2_1),
        .rdata3        (prf_rdata3),
        .rdata4        (prf_rdata4)
    );

    assign rf_rs1_val = prf_rdata1;
    assign rf_rs2_val = prf_rdata2;
    assign rf_rs1_val_1 = prf_rdata3;
    assign rf_rs2_val_1 = prf_rdata4;

    cpu_rat u_rat (
        .pl_clk(pl_clk), .pl_resetn(pl_resetn),
        .rename_en       (alloc0_fire),
        .rename_rs1      (ifid_inst[19:15]),
        .rename_rs2      (ifid_inst[24:20]),
        .rename_rd       (ifid_inst[11:7]),
        .rename_regwrite (id_regwrite),
        .new_prd         (allocate_prd),
        .prs1            (prs1),
        .prs2            (prs2),
        .old_prd         (old_prd),
        .wb_arch         (wb_commit_waddr),
        .wb_prd          (wb_prd),
        .commit_en       (1'b0),
        .commit_rd       (5'd0),
        .commit_prd      (6'd0),
        .retract1_en     (rob_retract_ack1 && id1_regwrite_d1 && (ifid1_inst_d1[11:7] != 5'd0)),
        .retract1_rd     (ifid1_inst_d1[11:7]),
        .retract1_old_prd(old1_prd_d1),
        .retract0_en     (rob_retract_ack0 && id_regwrite_d1 && (ifid_inst_d1[11:7] != 5'd0)),
        .retract0_rd     (ifid_inst_d1[11:7]),
        .retract0_old_prd(old_prd_d1),
        .flush_en        (1'b0),
        // Checkpoint: push on slot0 control-flow rename/alloc; pop on mispredict.
        .cp_push         (rat_cp_push),
        .cp_pop          (bp_rat_cp_pop),
        .cp_release      (bp_rat_cp_release),
        .cp_push_tag     (rat_cp_push_tag),
        .cp_pop_tag      (bp_rat_cp_pop_rob_ptr),
        .cp_release_tag  (bp_rat_cp_release_rob_ptr),
        .cp_empty        (rat_cp_empty),
        .cp_fixup_valid  (cp_fixup_valid),
        .cp_fixup_rd     (cp_fixup_rd),
        .cp_fixup_prd    (cp_fixup_prd),
        .cp_fixup2_valid (bp_rat_cp_fixup_valid),
        .cp_fixup2_rd    (bp_rat_cp_fixup_rd),
        .cp_fixup2_prd   (bp_rat_cp_fixup_prd),
        .mapped_prd_mask (rat_mapped_prd_mask),
        .rename1_en      (alloc1_fire),
        .rename1_rs1     (ifid1_inst[19:15]), .rename1_rs2(ifid1_inst[24:20]),
        .rename1_rd      (ifid1_inst[11:7]),
        .rename1_regwrite(id1_regwrite),
        .new1_prd        (allocate1_prd),
        .prs1_1          (prs1_1), .prs2_1(prs2_1), .old1_prd(old1_prd)
    );

    // Replace regfile read ports with PRF reads
    // (rf_rs1_val / rf_rs2_val currently come from cpu_regfile)
    // For O1: PRF duplicates regfile storage, so reads are consistent.
    // In O2+: regfile becomes commit-only; PRF is the working storage.
    // For now, keep the existing regfile reads as primary, PRF is shadow.

    // -----------------------------
    // CSR file + fence busy
    // -----------------------------
    wire irq_take;
    cpu_csr_file #(
        .P_RESET_MTVEC(RESET_PC),
        .P_MHARTID(P_MHARTID)
    ) u_csr (
        .pl_clk           (pl_clk),
        .pl_resetn        (pl_resetn),
        .csr_raddr        (idex_inst[31:20]),
        .csr_rdata        (csr_rdata),
        .csr_wr_en        (csr_wr_en),
        .csr_wr_addr      (csr_wr_addr),
        .csr_wr_data      (csr_wr_data),
        .trap_mem         (rob_trap_redirect),
        .trap_mem_mepc    (rob_trap_redirect_pc),
        .trap_mem_mcause  (rob_trap_redirect_cause),
        .trap_ctl         (ctl_fault_redirect),
        .trap_ctl_mepc    (idex_pc),
        .trap_insn        (1'b0),
        .trap_insn_mepc   (32'd0),
        .trap_insn_mcause (32'd0),
        .irq_take         (irq_take),
        .irq_mepc         (ifid_valid ? ifid_pc : pc_q_o),
        .irq_mcause_val   (irq_mcause_sel),
        .mret_taken       (mret_taken),
        .irq_m_soft_i     (irq_m_soft_i),
        .irq_m_timer_i    (irq_m_timer_i),
        .irq_m_ext_i      (irq_m_ext_i),
        // RISC-V minstret counts retired instructions; tie to WB commit (not IF consume).
        .minstret_inc     (wb_commit_valid),
        .fp_fflags_we     (fp_fflags_we),
        .fp_fflags_inc    (fp_fflags_inc),
        .fp_fs_dirty_evt  (fp_fs_dirty_evt),
        .mtvec_q_o        (mtvec_q_o),
        .mepc_q_o         (mepc_q_o),
        .mstatus_q_o      (mstatus_q_o),
        .mie_q_o          (mie_q_o),
        .mip_live_o       (mip_live_o),
        .frm_q_o          (frm_q_o)
    );

    assign irq_take = mstatus_q_o[3] && irq_pe && rob_empty && !trap_taken && !ex_redirect_valid && !rob_trap_redirect && !stall_mem
        && !fence_busy && !mem_fault_redirect && !ctl_fault_redirect;
    wire slot1_static_dispatch_ok = ifid_pending_slot1_redir && !ex_redirect_valid && !exmem1_redirect_valid
        && !rob_trap_redirect && !ctl_fault_redirect && !irq_take;

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            ifid_pending_slot1_redir <= 1'b0;
            ifid_slot1_redir_pc    <= '0;
            ifid_slot1_redir_rob_ptr <= '0;
        end else begin
            if (alloc0_fire && (ifid0_opc == 7'b0001111) && ifid1_pair_ok) begin
                ifid_pending_slot1_redir <= 1'b1;
                ifid_slot1_redir_pc    <= ifid_pc + 32'd4;
                ifid_slot1_redir_rob_ptr <= alloc0_rob_ptr;
            end else if (split_slot1_refetch) begin
                ifid_pending_slot1_redir <= 1'b1;
                ifid_slot1_redir_pc    <= ifid_pc + 32'd4;
                ifid_slot1_redir_rob_ptr <= alloc0_rob_ptr;
            end else if (alloc1_fire && ifid1_redirect_static_d) begin
                ifid_pending_slot1_redir <= 1'b1;
                ifid_slot1_redir_pc    <= ifid1_redirect_target_d;
                ifid_slot1_redir_rob_ptr <= alloc1_rob_ptr;
            end else if (ifid_pending_slot1_redir)
                ifid_pending_slot1_redir <= 1'b0;
        end
    end

    assign redirect_valid_any = ex_redirect_valid | exmem1_redirect_valid | rob_trap_redirect | ctl_fault_redirect | irq_take
        | lsq_replay_valid | ifid_pending_slot1_redir;
    assign redirect_blocks_dispatch = (redirect_valid_any || younger_squash_pending_q || rob_squash_busy)
        && !slot1_static_dispatch_ok;
    assign iq_global_flush = rob_trap_redirect | ctl_fault_redirect | irq_take;
    assign redirect_pc_any    = rob_trap_redirect ? csr_trap_entry_pc(mtvec_q_o, rob_trap_redirect_cause)
        : (ctl_fault_redirect ? csr_trap_entry_pc(mtvec_q_o, 32'd2)
        : (irq_take ? csr_trap_entry_pc(mtvec_q_o, irq_mcause_sel)
        : (lsq_replay_valid ? lsq_replay_pc
        : (ex_redirect_valid ? redirect_pc
        : (exmem1_redirect_valid ? exmem1_redirect_pc
        : (ifid_pending_slot1_redir ? ifid_slot1_redir_pc : redirect_pc))))));

    // Scoreboard (declared here for forward-reference in SYNTHESIS debug block)
    logic [CORE_PRF_SIZE-1:0] pr_busy;
    logic [CORE_PRF_SIZE-1:0] pr_busy_set, pr_busy_clear;

    wire [5:0] dispatch_prs1_g  = (idex_rs1  == 5'd0) ? 6'd0 : prs1_d1;
    wire [5:0] dispatch_prs2_g  = (idex_rs2  == 5'd0) ? 6'd0 : prs2_d1;
    wire [5:0] dispatch1_prs1_g = (idex1_rs1 == 5'd0) ? 6'd0 : prs1_1_d1;
    wire [5:0] dispatch1_prs2_g = (idex1_rs2 == 5'd0) ? 6'd0 : prs2_1_d1;

    // Source-operand usage (avoid false rs2 dependency on I/U/J/Load/JALR classes).
    wire dispatch_use_rs1 = (idex_opcode == 7'b0010011) || (idex_opcode == 7'b0110011)
        || (idex_opcode == 7'b0000011) || (idex_opcode == 7'b0100011)
        || (idex_opcode == 7'b1100011) || (idex_opcode == 7'b1100111)
        || (idex_opcode == 7'b0101111) || (idex_opcode == 7'b1110011);
    wire dispatch_use_rs2 = (idex_opcode == 7'b0110011) || (idex_opcode == 7'b0100011)
        || (idex_opcode == 7'b1100011) || (idex_opcode == 7'b0101111);
    wire dispatch1_use_rs1 = dispatch1_valid_g && ((idex1_opcode == 7'b0010011) || (idex1_opcode == 7'b0110011)
        || (idex1_opcode == 7'b0000011) || (idex1_opcode == 7'b0100011)
        || (idex1_opcode == 7'b1100011) || (idex1_opcode == 7'b1100111)
        || (idex1_opcode == 7'b0101111) || (idex1_opcode == 7'b1110011));
    wire dispatch1_use_rs2 = dispatch1_valid_g && ((idex1_opcode == 7'b0110011) || (idex1_opcode == 7'b0100011)
        || (idex1_opcode == 7'b1100011) || (idex1_opcode == 7'b0101111));
    wire dispatch1_rs1_from_slot0 = dispatch1_use_rs1 && id_regwrite_d1 && (idex_rd != 5'd0)
        && (idex1_rs1 == idex_rd);
    wire dispatch1_rs2_from_slot0 = dispatch1_use_rs2 && id_regwrite_d1 && (idex_rd != 5'd0)
        && (idex1_rs2 == idex_rd);
    wire dispatch_rs1_rdy_g  = !dispatch_use_rs1  || !pr_busy[dispatch_prs1_g];
    wire dispatch_rs2_rdy_g  = !dispatch_use_rs2  || !pr_busy[dispatch_prs2_g];
    wire dispatch1_rs1_rdy_g = !dispatch1_use_rs1
        || (!dispatch1_rs1_from_slot0 && !pr_busy[dispatch1_prs1_g]);
    wire dispatch1_rs2_rdy_g = !dispatch1_use_rs2
        || (!dispatch1_rs2_from_slot0 && !pr_busy[dispatch1_prs2_g]);

`ifndef SYNTHESIS
    localparam logic [5:0] DBG_PRD = 6'd34;
    int unsigned dbg_mem_redirect_cnt;
    int unsigned dbg_stall_mem_rise_cnt;
    int unsigned dbg_stall_mem_streak;
    int unsigned dbg_redirect_streak;
    int unsigned dbg_redirect_ex_cnt, dbg_redirect_mem_cnt, dbg_redirect_ctl_cnt, dbg_redirect_irq_cnt;
    int unsigned dbg_no_retire_streak;
    int unsigned dbg_wb_done_cnt, dbg_rob_retire_cnt, dbg_arch_retire_cnt;
    int unsigned dbg_wb_no_retire_streak;
    int unsigned dbg_ifid_consume_cnt, dbg_id_dispatch_cnt, dbg_iq_issue_cnt;
    int unsigned dbg_exmem_adv_cnt, dbg_wb_commit_cnt;
    int unsigned dbg_issue_no_exmem_streak, dbg_exmem_no_wb_streak;
    int unsigned dbg_wb_no_robret_streak;
    int unsigned dbg_issue_uncat_cnt, dbg_ex_uncat_cnt;
    int unsigned dbg_ex_gpr_cnt, dbg_ex_branch_cnt, dbg_ex_store_cnt, dbg_ex_amo_cnt;
    int unsigned dbg_ex_jal_cnt, dbg_ex_jalr_cnt, dbg_ex_fence_cnt, dbg_ex_csr_cnt;
    int unsigned dbg_exslot_prd0_cnt;
    int unsigned dbg_prd_trace_cnt;
    logic dbg_stall_mem_q;
    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            dbg_mem_redirect_cnt <= 0;
            dbg_stall_mem_rise_cnt <= 0;
            dbg_stall_mem_streak <= 0;
            dbg_redirect_streak <= 0;
            dbg_redirect_ex_cnt <= 0;
            dbg_redirect_mem_cnt <= 0;
            dbg_redirect_ctl_cnt <= 0;
            dbg_redirect_irq_cnt <= 0;
            dbg_no_retire_streak <= 0;
            dbg_wb_done_cnt <= 0;
            dbg_rob_retire_cnt <= 0;
            dbg_arch_retire_cnt <= 0;
            dbg_wb_no_retire_streak <= 0;
            dbg_ifid_consume_cnt <= 0;
            dbg_id_dispatch_cnt <= 0;
            dbg_iq_issue_cnt <= 0;
            dbg_exmem_adv_cnt <= 0;
            dbg_wb_commit_cnt <= 0;
            dbg_issue_no_exmem_streak <= 0;
            dbg_exmem_no_wb_streak <= 0;
            dbg_wb_no_robret_streak <= 0;
            dbg_issue_uncat_cnt <= 0;
            dbg_ex_uncat_cnt <= 0;
            dbg_ex_gpr_cnt <= 0;
            dbg_ex_branch_cnt <= 0;
            dbg_ex_store_cnt <= 0;
            dbg_ex_amo_cnt <= 0;
            dbg_ex_jal_cnt <= 0;
            dbg_ex_jalr_cnt <= 0;
            dbg_ex_fence_cnt <= 0;
            dbg_ex_csr_cnt <= 0;
            dbg_exslot_prd0_cnt <= 0;
            dbg_prd_trace_cnt <= 0;
            dbg_stall_mem_q <= 1'b0;
        end else begin
            dbg_stall_mem_q <= stall_mem;
            dbg_stall_mem_streak <= stall_mem ? (dbg_stall_mem_streak + 1) : 0;
            dbg_redirect_streak <= redirect_valid_any ? (dbg_redirect_streak + 1) : 0;
            dbg_no_retire_streak <= (retire_valid || retire1_valid) ? 0 : (dbg_no_retire_streak + 1);
            if (redirect_valid)      dbg_redirect_ex_cnt  <= dbg_redirect_ex_cnt + 1;
            if (mem_fault_redirect)  dbg_redirect_mem_cnt <= dbg_redirect_mem_cnt + 1;
            if (ctl_fault_redirect)  dbg_redirect_ctl_cnt <= dbg_redirect_ctl_cnt + 1;
            if (irq_take)            dbg_redirect_irq_cnt <= dbg_redirect_irq_cnt + 1;
            if (consume_ifid) dbg_ifid_consume_cnt <= dbg_ifid_consume_cnt + 1;
            if (consume_ifid) dbg_id_dispatch_cnt <= dbg_id_dispatch_cnt + (ifid1_valid ? 2 : 1);
            if (iq_issue_valid) dbg_iq_issue_cnt <= dbg_iq_issue_cnt + (iq_issue1_valid ? 2 : 1);
            if (exmem_advance && (exmem_valid || exmem1_valid)) dbg_exmem_adv_cnt <= dbg_exmem_adv_cnt + (exmem1_valid ? 2 : 1);
            if (wb_commit_valid) dbg_wb_commit_cnt <= dbg_wb_commit_cnt + 1;
            if (iq_issue_valid && !(iq_issue_regwrite || iq_issue_is_branch || iq_issue_is_store
                                    || iq_issue_is_amo || iq_issue_is_jal || iq_issue_is_jalr
                                    || iq_issue_is_fence || iq_issue_is_csr || iq_issue_is_load))
                dbg_issue_uncat_cnt <= dbg_issue_uncat_cnt + 1;
            if (rob_wb_en || rob_wb2_en || rob_wb3_en) begin
                dbg_wb_done_cnt <= dbg_wb_done_cnt
                    + (rob_wb_en  ? 1 : 0)
                    + (rob_wb2_en ? 1 : 0)
                    + (rob_wb3_en ? 1 : 0);
            end
            if (rob_retire_valid)
                dbg_rob_retire_cnt <= dbg_rob_retire_cnt + (rob_retire1_valid ? 2 : 1);
            if (retire_valid)
                dbg_arch_retire_cnt <= dbg_arch_retire_cnt + (retire1_valid ? 2 : 1);
            if ((rob_wb_en || rob_wb2_en || rob_wb3_en) && !retire_valid)
                dbg_wb_no_retire_streak <= dbg_wb_no_retire_streak + 1;
            else if (retire_valid)
                dbg_wb_no_retire_streak <= 0;
            if ((iq_issue_valid || iq_issue1_valid) && !(exmem_valid || exmem1_valid))
                dbg_issue_no_exmem_streak <= dbg_issue_no_exmem_streak + 1;
            else if (exmem_valid || exmem1_valid)
                dbg_issue_no_exmem_streak <= 0;
            if ((exmem_valid || exmem1_valid) && !(rob_wb_en || rob_wb2_en || rob_wb3_en || wb_commit_valid))
                dbg_exmem_no_wb_streak <= dbg_exmem_no_wb_streak + 1;
            else if (rob_wb_en || rob_wb2_en || rob_wb3_en || wb_commit_valid)
                dbg_exmem_no_wb_streak <= 0;
            if ((rob_wb_en || rob_wb2_en || rob_wb3_en) && !rob_retire_valid)
                dbg_wb_no_robret_streak <= dbg_wb_no_robret_streak + 1;
            else if (rob_retire_valid)
                dbg_wb_no_robret_streak <= 0;
            if (exmem_gpr_rob)    dbg_ex_gpr_cnt <= dbg_ex_gpr_cnt + 1;
            if (exmem_branch_rob) dbg_ex_branch_cnt <= dbg_ex_branch_cnt + 1;
            if (exmem_store_rob)  dbg_ex_store_cnt <= dbg_ex_store_cnt + 1;
            if (exmem_amo_rob)    dbg_ex_amo_cnt <= dbg_ex_amo_cnt + 1;
            if (exmem_jal_rob)    dbg_ex_jal_cnt <= dbg_ex_jal_cnt + 1;
            if (exmem_jalr_rob)   dbg_ex_jalr_cnt <= dbg_ex_jalr_cnt + 1;
            if (exmem_fence_rob)  dbg_ex_fence_cnt <= dbg_ex_fence_cnt + 1;
            if (exmem_csr_rob)    dbg_ex_csr_cnt <= dbg_ex_csr_cnt + 1;
            if (exmem_slot_rob && exmem_prd == 6'd0)
                dbg_exslot_prd0_cnt <= dbg_exslot_prd0_cnt + 1;
            if ($test$plusargs("PIPE_DBG") && exmem_valid && !exmem_slot_rob && !exmem_is_load && (dbg_ex_uncat_cnt < 256)) begin
                dbg_ex_uncat_cnt <= dbg_ex_uncat_cnt + 1;
                $display("[PIPE_DBG] ex_uncat pc=0x%08x inst=0x%08x prd=%0d rgw=%0b ld=%0b st=%0b amo=%0b br=%0b jal=%0b jalr=%0b fe=%0b csr=%0b",
                         exmem_pc, exmem_inst, exmem_prd, exmem_regwrite, exmem_is_load, exmem_is_store, exmem_is_amo,
                         exmem_is_branch, exmem_is_jal, exmem_is_jalr, exmem_is_fence, exmem_is_csr);
            end
            if ((rob_wb_en && (rob_wb_prd == 6'd0)) || (rob_wb2_en && (rob_wb2_prd == 6'd0)) || (rob_wb3_en && (rob_wb3_prd == 6'd0)))
                $error("[PIPE_ASSERT] rob_wb_en* with prd=0");
            if (!dbg_stall_mem_q && stall_mem) begin
                dbg_stall_mem_rise_cnt <= dbg_stall_mem_rise_cnt + 1;
                if ($test$plusargs("CORE_DBG") && dbg_stall_mem_rise_cnt < 64) begin
                    $display("[CORE_DBG] stall_mem_rise pc=0x%08x ex_pc=0x%08x ex_inst=0x%08x lsq_fault=%0b",
                             pc_q_o, exmem_pc, exmem_inst, mem_fault_redirect);
                end
            end
            if (mem_fault_redirect) begin
                dbg_mem_redirect_cnt <= dbg_mem_redirect_cnt + 1;
                if ($test$plusargs("CORE_DBG") && dbg_mem_redirect_cnt < 128) begin
                    $display("[CORE_DBG] mem_redirect mepc=0x%08x mcause=%0d redir_pc=0x%08x stall_mem=%0b",
                             mem_fault_mepc, mem_fault_mcause,
                             csr_trap_entry_pc(mtvec_q_o, mem_fault_mcause), stall_mem);
                end
            end
            if (dbg_stall_mem_streak == 32'd10000)
                $error("[CORE_ASSERT] stall_mem stuck high for >10000 cycles");
            if (dbg_redirect_streak == 32'd10000)
                $error("[CORE_ASSERT] redirect_valid_any stuck high for >10000 cycles");
            if (dbg_no_retire_streak == 32'd10000) begin
                $error("[CORE_ASSERT] no retire for >10000 cycles ex/mem/ctl/irq redirects=%0d/%0d/%0d/%0d",
                       dbg_redirect_ex_cnt, dbg_redirect_mem_cnt, dbg_redirect_ctl_cnt, dbg_redirect_irq_cnt);
                if ($test$plusargs("PIPE_DBG")) begin
                    $display("[PIPE_ASSERT_SNAPSHOT] ifid(v/use/consume/pc/inst)=%0b/%0b/%0b/0x%08x/0x%08x idex(v/v1/next/next1)=%0b/%0b/%0b/%0b redirect=%0b alloc0=%0b",
                             ifid_valid, ifid_usable, consume_ifid, ifid_pc, ifid_inst,
                             idex_valid, idex1_valid, idex_next_valid, idex1_next_valid,
                             redirect_valid_any, alloc0_fire);
                    $display("[PIPE_ASSERT_ID] pipe_adv=%0b fp_busy_stall=%0b fp_load_stall=%0b load_stall=%0b fp_busy=0x%08x frf_we=%0b/%0b faddr=%0d/%0d",
                             u_id.pipeline_advance, u_id.stall_fp_busy, u_id.stall_fp_load_use,
                             stall_load_use, u_id.fp_busy_q, frf_we, frf_we_b, frf_waddr, frf_waddr_b);
                end
            end
            if (dbg_wb_no_retire_streak == 32'd10000) begin
                $error("[CORE_ASSERT] wb_done without retire >10000 cycles wb/rob_retire/arch_retire=%0d/%0d/%0d rob_empty=%0b",
                       dbg_wb_done_cnt, dbg_rob_retire_cnt, dbg_arch_retire_cnt, rob_empty);
            end
            if (dbg_issue_no_exmem_streak == 32'd10000)
                $error("[PIPE_ASSERT] issue without exmem >10000 cycles ifid/id/iq/ex=%0d/%0d/%0d/%0d",
                       dbg_ifid_consume_cnt, dbg_id_dispatch_cnt, dbg_iq_issue_cnt, dbg_exmem_adv_cnt);
            if (dbg_exmem_no_wb_streak == 32'd10000)
                $error("[PIPE_ASSERT] exmem without wb >10000 cycles ex_adv/wb_commit/rob_wb=%0d/%0d/%0d",
                       dbg_exmem_adv_cnt, dbg_wb_commit_cnt, dbg_wb_done_cnt);
            if (dbg_wb_no_robret_streak == 32'd10000)
                $error("[PIPE_ASSERT] wb_done without rob_retire >10000 cycles wb/rob_retire/arch_retire=%0d/%0d/%0d",
                       dbg_wb_done_cnt, dbg_rob_retire_cnt, dbg_arch_retire_cnt);
            if ($test$plusargs("PIPE_DBG") && (exmem_valid || exmem1_valid) && !(rob_wb_en || rob_wb2_en || rob_wb3_en)
                && (dbg_exmem_no_wb_streak < 64)) begin
                $display("[PIPE_DBG] ex_no_wb exv=%0b exld=%0b exslot=%0b exprd=%0d ex1v=%0b ex1ld=%0b ex1slot=%0b ex1prd=%0d memwb=%0b reason(ld/prd/cls)=%0b/%0b/%0b",
                         exmem_valid, exmem_is_load, exmem_slot_rob, exmem_prd,
                         exmem1_valid, exmem1_is_load, exmem1_slot_rob, exmem1_prd, memwb_rob_done,
                         (exmem_valid && exmem_is_load) || (exmem1_valid && exmem1_is_load),
                         ((exmem_slot_rob && exmem_prd == 6'd0) || (exmem1_slot_rob && exmem1_prd == 6'd0)),
                         ((exmem_valid && !exmem_slot_rob && !exmem_is_load) || (exmem1_valid && !exmem1_slot_rob && !exmem1_is_load)));
            end
            if ($test$plusargs("PIPE_DBG") && (dbg_no_retire_streak % 100000) == 0 && dbg_no_retire_streak != 0) begin
                $display("[PIPE_SNAPSHOT] no_retire=%0d ifid=%0d id=%0d iq=%0d ex=%0d wb_commit=%0d rob_wb=%0d rob_retire=%0d arch_retire=%0d redirects ex/mem/ctl/irq=%0d/%0d/%0d/%0d",
                         dbg_no_retire_streak, dbg_ifid_consume_cnt, dbg_id_dispatch_cnt, dbg_iq_issue_cnt,
                         dbg_exmem_adv_cnt, dbg_wb_commit_cnt, dbg_wb_done_cnt, dbg_rob_retire_cnt, dbg_arch_retire_cnt,
                         dbg_redirect_ex_cnt, dbg_redirect_mem_cnt, dbg_redirect_ctl_cnt, dbg_redirect_irq_cnt);
                $display("[PIPE_STAGEC] ex_class gpr/br/st/amo/jal/jalr/fe/csr=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d issue_uncat=%0d ex_uncat=%0d",
                         dbg_ex_gpr_cnt, dbg_ex_branch_cnt, dbg_ex_store_cnt, dbg_ex_amo_cnt,
                         dbg_ex_jal_cnt, dbg_ex_jalr_cnt, dbg_ex_fence_cnt, dbg_ex_csr_cnt,
                         dbg_issue_uncat_cnt, dbg_ex_uncat_cnt);
                $display("[PIPE_STAGED] exslot_prd0=%0d", dbg_exslot_prd0_cnt);
                $display("[PIPE_STALL] stall mem/fence/load/fp/csr/iq/prf/rob/retract=%0b/%0b/%0b/%0b/%0b/%0b/%0b/%0b/%0b ifid(v/pc/inst)=%0b/0x%08x/0x%08x dual=%0b alloc=%0d/%0d rob(empty/full/dual/head/tail)=%0b/%0b/%0b/%0d/%0d iq(full/dual)=%0b/%0b",
                         stall_mem, fence_busy, stall_load_use, stall_fp, stall_csr,
                         stall_iq, stall_prf, stall_rob, rob_retract_en,
                         ifid_valid, ifid_pc, ifid_inst, ifid_effective_dual,
                         allocate_prd, allocate1_prd,
                         rob_empty, rob_full_q, rob_full_dual_q, rob_head_tag, rob_tail_tag,
                         iq_full_q, iq_full_dual_q);
                $display("[PIPE_PRF] busy=0x%016x inuse=0x%016x rat=0x%016x rob=0x%016x",
                         pr_busy, prf_inuse_prd_mask, rat_mapped_prd_mask, rob_prd_inuse_mask);
            end
            if ($test$plusargs("PRDTRACE") && (dbg_prd_trace_cnt < 256)) begin
                if (alloc0_fire && allocate_prd == DBG_PRD) begin
                    dbg_prd_trace_cnt <= dbg_prd_trace_cnt + 1;
                    $display("[PRD%0d] alloc0 t=%0t pc=0x%08x inst=0x%08x ifid1=%0b", DBG_PRD, $time, ifid_pc, ifid_inst, ifid1_valid);
                end
                if (alloc1_fire && allocate1_prd == DBG_PRD) begin
                    dbg_prd_trace_cnt <= dbg_prd_trace_cnt + 1;
                    $display("[PRD%0d] alloc1 t=%0t pc=0x%08x inst=0x%08x", DBG_PRD, $time, ifid1_pc, ifid1_inst);
                end
                if ((alloc0_fire_d1 && allocate_prd_d1 == DBG_PRD) || (alloc1_fire_d1 && allocate1_prd_d1 == DBG_PRD)) begin
                    dbg_prd_trace_cnt <= dbg_prd_trace_cnt + 1;
                    $display("[PRD%0d] dispatch t=%0t d0=%0b prd0=%0d pc0=0x%08x inst0=0x%08x prs0=%0d/%0d rdy0=%0b/%0b d1=%0b prd1=%0d pc1=0x%08x inst1=0x%08x redir=%0b",
                             DBG_PRD, $time,
                             dispatch_valid_g, allocate_prd_d1, idex_pc, idex_inst,
                             dispatch_prs1_g, dispatch_prs2_g,
                             dispatch_rs1_rdy_g, dispatch_rs2_rdy_g,
                             dispatch1_valid_g,
                             (dispatch1_valid_g ? allocate1_prd_d1 : 6'd0),
                             (dispatch1_valid_g ? idex1_pc : 32'd0),
                             (dispatch1_valid_g ? idex1_inst : 32'd0),
                             redirect_valid_any);
                end
                if (rob_release_en && rob_release_prd == DBG_PRD) begin
                    dbg_prd_trace_cnt <= dbg_prd_trace_cnt + 1;
                    $display("[PRD%0d] release0 t=%0t retire_pc=0x%08x retire_inst=0x%08x", DBG_PRD, $time, rob_retire_pc, rob_retire_inst);
                end
                if (rob_release1_en && rob_release1_prd == DBG_PRD) begin
                    dbg_prd_trace_cnt <= dbg_prd_trace_cnt + 1;
                    $display("[PRD%0d] release1 t=%0t retire1_pc=0x%08x retire1_inst=0x%08x", DBG_PRD, $time, rob_retire1_pc, rob_retire1_inst);
                end
                if (retract_slot0_pop && allocate_prd_d1 == DBG_PRD) begin
                    dbg_prd_trace_cnt <= dbg_prd_trace_cnt + 1;
                    $display("[PRD%0d] retract0 t=%0t", DBG_PRD, $time);
                end
                if (retract_slot1_pop && allocate1_prd_d1 == DBG_PRD) begin
                    dbg_prd_trace_cnt <= dbg_prd_trace_cnt + 1;
                    $display("[PRD%0d] retract1 t=%0t", DBG_PRD, $time);
                end
                if ((rob_wb_en && rob_wb_prd == DBG_PRD) || (rob_wb2_en && rob_wb2_prd == DBG_PRD)
                    || (rob_wb3_en && rob_wb3_prd == DBG_PRD)) begin
                    dbg_prd_trace_cnt <= dbg_prd_trace_cnt + 1;
                    $display("[PRD%0d] wb t=%0t wb0=%0b/%0d wb1=%0b/%0d wb2=%0b/%0d memwb(v/d/prd)=%0b/%0b/%0d",
                             DBG_PRD, $time, rob_wb_en, rob_wb_prd, rob_wb2_en, rob_wb2_prd, rob_wb3_en, rob_wb3_prd,
                             memwb_valid, memwb_rob_done, memwb_prd);
                end
                if ((iq_issue_valid && iq_issue_prd == DBG_PRD) || (iq_issue1_valid && iq_issue1_prd == DBG_PRD)) begin
                    dbg_prd_trace_cnt <= dbg_prd_trace_cnt + 1;
                    $display("[PRD%0d] iq_issue t=%0t i0(v/prd/pc/op)= %0b/%0d/0x%08x/0x%02x i1(v/prd/pc/op)= %0b/%0d/0x%08x/0x%02x",
                             DBG_PRD, $time,
                             iq_issue_valid, iq_issue_prd, iq_issue_pc, iq_issue_opcode,
                             iq_issue1_valid,
                             (iq_issue1_valid ? iq_issue1_prd : 6'd0),
                             (iq_issue1_valid ? iq_issue1_pc : 32'd0),
                             (iq_issue1_valid ? iq_issue1_opcode : 7'd0));
                end
                if ((exmem_valid && exmem_prd == DBG_PRD) || (exmem1_valid && exmem1_prd == DBG_PRD)) begin
                    dbg_prd_trace_cnt <= dbg_prd_trace_cnt + 1;
                    $display("[PRD%0d] exmem t=%0t adv=%0b ex0(v/prd/br/j/jr/st/ld/rgw/slot/done)= %0b/%0d/%0b/%0b/%0b/%0b/%0b/%0b/%0b/%0b ex1(v/prd/br/st/ld/rgw/slot/done)= %0b/%0d/%0b/%0b/%0b/%0b/%0b/%0b",
                             DBG_PRD, $time, exmem_advance,
                             exmem_valid, exmem_prd, exmem_is_branch, exmem_is_jal, exmem_is_jalr,
                             exmem_is_store, exmem_is_load, exmem_regwrite, exmem_slot_rob, exmem_rob_done,
                             exmem1_valid, exmem1_prd, exmem1_is_branch_rob, exmem1_is_store, exmem1_is_load,
                             exmem1_regwrite, exmem1_slot_rob, exmem1_rob_done);
                end
                if (stall_prf && ifid_valid && allocate_prd == DBG_PRD) begin
                    dbg_prd_trace_cnt <= dbg_prd_trace_cnt + 1;
                    $display("[PRD%0d] stall_prf t=%0t ifid=0x%08x alloc0=%0d alloc1=%0d rob_empty=%0b head/tail=%0d/%0d",
                             DBG_PRD, $time, ifid_inst, allocate_prd, allocate1_prd, rob_empty, rob_head_tag, rob_tail_tag);
                end
            end
            if ($test$plusargs("REDIRTRACE")) begin
                if (alloc0_fire || redirect_valid_any || younger_squash_to_rob) begin
                    $display("[REDIRTRACE] t=%0t alloc=%0b/%0b ifid=0x%08x/0x%08x inst=0x%08x/0x%08x slot1(v/pair/eff/ready)=%0b/%0b/%0b/%0b prd=%0d/%0d full(rob/iq)=%0b/%0b slot1_static=%0b pend=%0b redir_any=%0b pc=0x%08x ex=%0b ex1=%0b squash=%0b ptr=%0d head/tail=%0d/%0d",
                             $time, alloc0_fire, alloc1_fire,
                             ifid_pc, ifid1_pc, ifid_inst, ifid1_inst,
                             ifid1_present, ifid1_pair_ok, ifid_effective_dual, ifid_dual_alloc_ready,
                             allocate_prd, allocate1_prd, rob_full_dual_q, iq_full_dual_q,
                             ifid1_redirect_static_d, ifid_pending_slot1_redir,
                             redirect_valid_any, redirect_pc_any,
                             ex_redirect_valid, exmem1_redirect_valid,
                             younger_squash_to_rob, younger_squash_ptr,
                             rob_head_tag, rob_tail_tag);
                end
            end
        end
    end
`endif


    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            fence_busy <= 1'b0;
            fence_pending_valid <= 1'b0;
            fence_pending_prd <= '0;
            fence_pending_rob_ptr <= '0;
            fence_pending_op <= '0;
            fence_pending_addr <= '0;
            fence_state_q <= FENCE_IDLE;
        end else begin
            if (fence_issue_fire) begin
                fence_busy <= 1'b1;
                fence_pending_valid <= 1'b1;
                fence_pending_prd <= iq_issue_prd;
                fence_pending_rob_ptr <= iq_issue_rob_ptr;
                fence_pending_op <= iq_issue_fence_op;
                fence_pending_addr <= iq_issue_pc;
                fence_state_q <= FENCE_DRAIN;
            end else begin
                unique case (fence_state_q)
                    FENCE_IDLE: begin
                        fence_busy <= 1'b0;
                    end
                    FENCE_DRAIN: begin
                        if (lsq_idle)
                            fence_state_q <= FENCE_WAIT_DONE;
                    end
                    FENCE_WAIT_DONE: begin
                        if (ctl_done) begin
                            fence_busy <= 1'b0;
                            fence_pending_valid <= 1'b0;
                            fence_state_q <= FENCE_IDLE;
                        end
                    end
                    default: begin
                        fence_busy <= 1'b0;
                        fence_pending_valid <= 1'b0;
                        fence_state_q <= FENCE_IDLE;
                    end
                endcase
            end
        end
    end

    // Scoreboard: tracks in-flight physical register writes (allocate every ROB entry)
    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            pr_busy <= '0;
        end else begin
            pr_busy_set   = '0;
            pr_busy_clear = rob_squash_release_mask_d1;
            if (alloc0_fire) begin
                if (allocate_prd != 6'd0)
                    pr_busy_set[allocate_prd] = 1'b1;
                if (alloc1_fire && (allocate1_prd != 6'd0))
                    pr_busy_set[allocate1_prd] = 1'b1;
            end
            if (rob_retract_ack1 && (allocate1_prd_d1 != 6'd0))
                pr_busy_clear[allocate1_prd_d1] = 1'b1;
            if (rob_retract_ack0 && (allocate_prd_d1 != 6'd0))
                pr_busy_clear[allocate_prd_d1] = 1'b1;
            if (rob_wb_accept && rob_wb_prd != 6'd0)
                pr_busy_clear[rob_wb_prd] = 1'b1;
            if (rob_wb2_accept && rob_wb2_prd != 6'd0)
                pr_busy_clear[rob_wb2_prd] = 1'b1;
            if (rob_wb3_accept && rob_wb3_prd != 6'd0)
                pr_busy_clear[rob_wb3_prd] = 1'b1;
            pr_busy <= (pr_busy | pr_busy_set) & ~pr_busy_clear;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge pl_clk) begin
        if (pl_resetn && !dispatch1_valid_g && (dispatch1_use_rs1 || dispatch1_use_rs2))
            $error("[PIPE_ASSERT] slot1 use_rs asserted when dispatch1 is invalid");
    end
`endif
    // Kept as a perf/debug flag. Memory ops are allowed to enqueue into LSQ while
    // the next ready op issues, unless the LSQ itself backpressures through stall_mem.
    wire iq_issue_hold_mem = exmem_valid && (exmem_is_load || exmem_is_store || exmem_is_amo || exmem_is_fp_load);
    assign perf_backend_flags = {
        (lsq_d_req_valid && !d_req_ready),
        rob_retire1_valid,
        (!rob_empty && !rob_retire_valid),
        iq_issue_hold_mem,
        lsq_full,
        lsq_resp_pending,
        iq_issue_hold_mem,
        stall_mem
    };

    // ── IQ (in-core, drives EX stage) ─────────────────────────────
    cpu_issue_queue #(.IQ_DEPTH(8), .ROB_TAG_W(6)) u_iq_core (
        .pl_clk(pl_clk), .pl_resetn(pl_resetn),
        // Dispatch as pulse to avoid re-enqueueing held ID/EX entries.
        .dispatch_valid(dispatch_valid_g), .dispatch_pc(idex_pc),
        .dispatch_inst(idex_inst), .dispatch_rd(idex_rd),
        .dispatch_regwrite(idex_regwrite),
        .dispatch_is_load(idex_is_load), .dispatch_is_store(idex_is_store), .dispatch_is_amo(idex_is_amo),
        .dispatch_is_branch(idex_is_branch), .dispatch_is_jal(idex_is_jal), .dispatch_is_jalr(idex_is_jalr),
        .dispatch_is_fence(idex_is_fence), .dispatch_is_csr(idex_is_csr),
        .dispatch_is_fp_op(idex_is_fp_op), .dispatch_is_fp_load(idex_is_fp_load), .dispatch_is_fp_store(idex_is_fp_store), .dispatch_fregwrite(idex_fregwrite),
        .dispatch_illegal(idex_illegal), .dispatch_err(idex_err),
        .dispatch_funct3(idex_funct3), .dispatch_funct7(idex_funct7), .dispatch_opcode(idex_opcode),
        .dispatch_imm_i(idex_imm_i), .dispatch_imm_s(idex_imm_s), .dispatch_imm_b(idex_imm_b),
        .dispatch_imm_u(idex_imm_u), .dispatch_imm_j(idex_imm_j),
        .dispatch_rs1_val(idex_rs1_val), .dispatch_rs2_val(idex_rs2_val),
        .dispatch_frs1_val(idex_frs1_val), .dispatch_frs2_val(idex_frs2_val), .dispatch_frs3_val(idex_frs3_val),
        .dispatch_bp_meta(idex_bp_pred_meta), .dispatch_bp_pred_taken(idex_bp_pred_taken),
        .dispatch_fence_op(idex_fence_op),
        .dispatch_prs1(dispatch_prs1_g), .dispatch_prs2(dispatch_prs2_g), .dispatch_prd(allocate_prd_d1),
        .dispatch_rob_ptr(alloc0_rob_ptr_d1),
        .dispatch_rs1_rdy(dispatch_rs1_rdy_g), .dispatch_rs2_rdy(dispatch_rs2_rdy_g),
        .stall_fp(stall_fp), .frm_csr(frm_q_o),
        .stall(stall_mem || stall_fp || fence_busy || redirect_blocks_dispatch),
        .flush_en(iq_global_flush),
        .squash_en(iq_younger_squash),
        .squash_rob_ptr(younger_squash_ptr_q),
        .rob_tail_tag(rob_tail_tag),
        .rob_head_tag(rob_head_tag),
        .dispatch_accept(iq_dispatch_accept_q),
        .dispatch1_accept(iq_dispatch1_accept_q),
        // Slot 1 dispatch
        .dispatch1_valid(dispatch1_valid_g),
        .dispatch1_pc(dispatch1_valid_g ? idex1_pc : 32'd0), .dispatch1_inst(dispatch1_valid_g ? idex1_inst : 32'd0),
        .dispatch1_rd(dispatch1_valid_g ? idex1_rd : 5'd0), .dispatch1_regwrite(dispatch1_valid_g ? idex1_regwrite : 1'b0),
        .dispatch1_is_load(dispatch1_valid_g ? idex1_is_load : 1'b0), .dispatch1_is_store(dispatch1_valid_g ? idex1_is_store : 1'b0), .dispatch1_is_amo(dispatch1_valid_g ? idex1_is_amo : 1'b0),
        .dispatch1_is_branch(dispatch1_valid_g ? idex1_is_branch : 1'b0), .dispatch1_is_jal(dispatch1_valid_g ? idex1_is_jal : 1'b0), .dispatch1_is_jalr(dispatch1_valid_g ? idex1_is_jalr : 1'b0),
        .dispatch1_is_fence(dispatch1_valid_g ? idex1_is_fence : 1'b0), .dispatch1_is_csr(dispatch1_valid_g ? idex1_is_csr : 1'b0),
        .dispatch1_is_fp_op(dispatch1_valid_g ? idex1_is_fp_op : 1'b0), .dispatch1_is_fp_load(dispatch1_valid_g ? idex1_is_fp_load : 1'b0), .dispatch1_is_fp_store(dispatch1_valid_g ? idex1_is_fp_store : 1'b0),
        .dispatch1_fregwrite(dispatch1_valid_g ? idex1_fregwrite : 1'b0), .dispatch1_illegal(1'b0), .dispatch1_err(1'b0),
        .dispatch1_funct3(dispatch1_valid_g ? idex1_funct3 : 3'd0), .dispatch1_funct7(dispatch1_valid_g ? idex1_funct7 : 7'd0), .dispatch1_opcode(dispatch1_valid_g ? idex1_opcode : 7'd0),
        .dispatch1_imm_i(dispatch1_valid_g ? idex1_imm_i : 32'd0), .dispatch1_imm_s(dispatch1_valid_g ? idex1_imm_s : 32'd0), .dispatch1_imm_b(dispatch1_valid_g ? idex1_imm_b : 32'd0), .dispatch1_imm_u(dispatch1_valid_g ? idex1_imm_u : 32'd0), .dispatch1_imm_j(dispatch1_valid_g ? idex1_imm_j : 32'd0),
        .dispatch1_rs1_val(dispatch1_valid_g ? idex1_rs1_val : 32'd0), .dispatch1_rs2_val(dispatch1_valid_g ? idex1_rs2_val : 32'd0),
        .dispatch1_frs1_val(dispatch1_valid_g ? idex1_frs1_val : 32'd0), .dispatch1_frs2_val(dispatch1_valid_g ? idex1_frs2_val : 32'd0), .dispatch1_frs3_val(dispatch1_valid_g ? idex1_frs3_val : 32'd0),
        .dispatch1_bp_meta(dispatch1_valid_g ? idex1_bp_pred_meta : '0), .dispatch1_bp_pred_taken(dispatch1_valid_g ? idex1_bp_pred_taken : 1'b0),
        .dispatch1_fence_op('0),
        .dispatch1_prs1(dispatch1_valid_g ? dispatch1_prs1_g : 6'd0), .dispatch1_prs2(dispatch1_valid_g ? dispatch1_prs2_g : 6'd0), .dispatch1_prd(dispatch1_valid_g ? allocate1_prd_d1 : 6'd0),
        .dispatch1_rob_ptr(dispatch1_valid_g ? alloc1_rob_ptr_d1 : 6'd0),
        .dispatch1_rs1_rdy(dispatch1_valid_g ? dispatch1_rs1_rdy_g : 1'b0), .dispatch1_rs2_rdy(dispatch1_valid_g ? dispatch1_rs2_rdy_g : 1'b0),
        .cdb_valid(rob_wb_cdb_valid),
        .cdb_prd(rob_wb_prd),
        .cdb_wdata(rob_wb_wdata),
        .cdb2_valid(rob_wb2_cdb_valid),
        .cdb2_prd(rob_wb2_prd),
        .cdb2_wdata(rob_wb2_wdata),
        .cdb3_valid(rob_wb3_cdb_valid),
        .cdb3_prd(rob_wb3_prd),
        .cdb3_wdata(rob_wb3_wdata),
        .issue_valid(iq_issue_valid), .issue_pc(iq_issue_pc), .issue_inst(iq_issue_inst),
        .issue_rd(iq_issue_rd), .issue_regwrite(iq_issue_regwrite),
        .issue_is_load(iq_issue_is_load), .issue_is_store(iq_issue_is_store), .issue_is_amo(iq_issue_is_amo),
        .issue_is_branch(iq_issue_is_branch), .issue_is_jal(iq_issue_is_jal), .issue_is_jalr(iq_issue_is_jalr),
        .issue_is_fence(iq_issue_is_fence), .issue_is_csr(iq_issue_is_csr),
        .issue_is_fp_op(iq_issue_is_fp_op), .issue_is_fp_load(iq_issue_is_fp_load), .issue_is_fp_store(iq_issue_is_fp_store), .issue_fregwrite(iq_issue_fregwrite), .issue_illegal(iq_issue_illegal), .issue_err(iq_issue_err),
        .issue_funct3(iq_issue_funct3), .issue_funct7(iq_issue_funct7), .issue_opcode(iq_issue_opcode),
        .issue_imm_i(iq_issue_imm_i), .issue_imm_s(iq_issue_imm_s), .issue_imm_b(iq_issue_imm_b), .issue_imm_u(iq_issue_imm_u), .issue_imm_j(iq_issue_imm_j),
        .issue_rs1_val(iq_issue_rs1_val), .issue_rs2_val(iq_issue_rs2_val), .issue_frs1_val(iq_issue_frs1_val), .issue_frs2_val(iq_issue_frs2_val), .issue_frs3_val(iq_issue_frs3_val),
        .issue_bp_meta(iq_issue_bp_meta), .issue_bp_pred_taken(iq_issue_bp_pred_taken),         .issue_fence_op(iq_issue_fence_op),
        .issue_fu_type(iq_issue_fu_type),
        .issue_prs1(iq_issue_prs1), .issue_prs2(iq_issue_prs2), .issue_prd(iq_issue_prd), .issue_rob_ptr(iq_issue_rob_ptr),
        // Slot 1 issue
        .issue1_valid(iq_issue1_valid),
        .issue1_pc(iq_issue1_pc), .issue1_inst(iq_issue1_inst),
        .issue1_rd(iq_issue1_rd), .issue1_regwrite(iq_issue1_regwrite),
        .issue1_is_load(iq_issue1_is_load), .issue1_is_store(iq_issue1_is_store), .issue1_is_amo(iq_issue1_is_amo),
        .issue1_is_branch(iq_issue1_is_branch), .issue1_is_jal(iq_issue1_is_jal), .issue1_is_jalr(iq_issue1_is_jalr),
        .issue1_is_fence(iq_issue1_is_fence), .issue1_is_csr(iq_issue1_is_csr),
        .issue1_is_fp_op(iq_issue1_is_fp_op), .issue1_is_fp_load(iq_issue1_is_fp_load), .issue1_is_fp_store(iq_issue1_is_fp_store),
        .issue1_fregwrite(iq_issue1_fregwrite), .issue1_illegal(iq_issue1_illegal), .issue1_err(iq_issue1_err),
        .issue1_funct3(iq_issue1_funct3), .issue1_funct7(iq_issue1_funct7), .issue1_opcode(iq_issue1_opcode),
        .issue1_imm_i(iq_issue1_imm_i), .issue1_imm_s(iq_issue1_imm_s), .issue1_imm_b(iq_issue1_imm_b), .issue1_imm_u(iq_issue1_imm_u), .issue1_imm_j(iq_issue1_imm_j),
        .issue1_rs1_val(iq_issue1_rs1_val), .issue1_rs2_val(iq_issue1_rs2_val),
        .issue1_frs1_val(iq_issue1_frs1_val), .issue1_frs2_val(iq_issue1_frs2_val), .issue1_frs3_val(iq_issue1_frs3_val),
        .issue1_bp_meta(iq_issue1_bp_meta), .issue1_bp_pred_taken(iq_issue1_bp_pred_taken),
        .issue1_fence_op(iq_issue1_fence_op),
        .issue1_prs1(iq_issue1_prs1), .issue1_prs2(iq_issue1_prs2), .issue1_prd(iq_issue1_prd), .issue1_rob_ptr(iq_issue1_rob_ptr),
        .iq_full(iq_full_q), .iq_full_dual(iq_full_dual_q)
    );

    assign mon_trap_occurred = rob_trap_redirect;

endmodule
