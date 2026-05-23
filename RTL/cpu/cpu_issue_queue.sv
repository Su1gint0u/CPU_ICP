// Issue Queue / Reservation Station. Phase R6: 8-deep RS + CDB wakeup interface.
module cpu_issue_queue #(
    parameter int unsigned IQ_DEPTH = 8,
    parameter int unsigned ROB_TAG_W = 5
) (
    input  logic pl_clk, input  logic pl_resetn,
    input  logic dispatch_valid, input  logic [31:0] dispatch_pc, dispatch_inst,
    input  logic [4:0] dispatch_rd, input  logic dispatch_regwrite,
    input  logic dispatch_is_load, dispatch_is_store, dispatch_is_amo,
    input  logic dispatch_is_branch, dispatch_is_jal, dispatch_is_jalr,
    input  logic dispatch_is_fence, dispatch_is_csr,
    input  logic dispatch_is_fp_op, dispatch_is_fp_load, dispatch_is_fp_store, dispatch_fregwrite,
    input  logic dispatch_illegal, dispatch_err,
    input  logic [2:0] dispatch_funct3, input  logic [6:0] dispatch_funct7, dispatch_opcode,
    input  logic [31:0] dispatch_imm_i, dispatch_imm_s, dispatch_imm_b, dispatch_imm_u, dispatch_imm_j,
    input  logic [31:0] dispatch_rs1_val, dispatch_rs2_val,
    input  logic [31:0] dispatch_frs1_val, dispatch_frs2_val, dispatch_frs3_val,
    input  logic [63:0] dispatch_bp_meta, input  logic dispatch_bp_pred_taken,
    input  logic [2:0] dispatch_fence_op,
    input  logic [5:0]  dispatch_prs1, dispatch_prs2, dispatch_prd,
    input  logic [ROB_TAG_W-1:0] dispatch_rob_ptr,
    input  logic        dispatch_rs1_rdy, dispatch_rs2_rdy,
    input  logic stall_fp, input  logic [2:0] frm_csr,
    input  logic stall,
    input  logic flush_en,
    input  logic squash_en,
    input  logic [ROB_TAG_W-1:0] squash_rob_ptr,
    // Pre-squash ROB tail (must match cpu_rob in the squash cycle).
    input  logic [ROB_TAG_W-1:0] rob_tail_tag,
    // ROB head tag: pick oldest ready RS entry by min (rob_ptr - rob_head) in tag space (not rptr ring order).
    input  logic [ROB_TAG_W-1:0] rob_head_tag,
    output logic dispatch_accept,
    output logic dispatch1_accept,
    // CDB wakeup (up to 3 producers / cycle)
    input  logic        cdb_valid,
    input  logic [5:0]  cdb_prd,
    input  logic [31:0] cdb_wdata,
    input  logic        cdb2_valid,
    input  logic [5:0]  cdb2_prd,
    input  logic [31:0] cdb2_wdata,
    input  logic        cdb3_valid,
    input  logic [5:0]  cdb3_prd,
    input  logic [31:0] cdb3_wdata,
    // issue
    output logic issue_valid, output logic [31:0] issue_pc, issue_inst,
    output logic [4:0] issue_rd, output logic issue_regwrite,
    output logic issue_is_load, issue_is_store, issue_is_amo,
    output logic issue_is_branch, issue_is_jal, issue_is_jalr, issue_is_fence, issue_is_csr,
    output logic issue_is_fp_op, issue_is_fp_load, issue_is_fp_store, issue_fregwrite, issue_illegal, issue_err,
    output logic [2:0] issue_funct3, output logic [6:0] issue_funct7, issue_opcode,
    output logic [31:0] issue_imm_i, issue_imm_s, issue_imm_b, issue_imm_u, issue_imm_j,
    output logic [31:0] issue_rs1_val, issue_rs2_val, issue_frs1_val, issue_frs2_val, issue_frs3_val,
    output logic [63:0] issue_bp_meta, output logic issue_bp_pred_taken,
    output logic [2:0] issue_fence_op,
    output logic [5:0] issue_prs1, issue_prs2, issue_prd,
    output logic [ROB_TAG_W-1:0] issue_rob_ptr,
    // FU classification
    output logic [2:0] issue_fu_type,     // 0=ALU, 1=MUL, 2=LSU, 3=BRU
    // Slot 1 dispatch / issue (ISSUE_WIDTH=2)
    input  logic            dispatch1_valid,
    input  logic [31:0]     dispatch1_pc, dispatch1_inst,
    input  logic [4:0]      dispatch1_rd,
    input  logic            dispatch1_regwrite,
    input  logic            dispatch1_is_load, dispatch1_is_store, dispatch1_is_amo,
    input  logic            dispatch1_is_branch, dispatch1_is_jal, dispatch1_is_jalr,
    input  logic            dispatch1_is_fence, dispatch1_is_csr,
    input  logic            dispatch1_is_fp_op, dispatch1_is_fp_load, dispatch1_is_fp_store,
    input  logic            dispatch1_fregwrite, dispatch1_illegal, dispatch1_err,
    input  logic [2:0]      dispatch1_funct3,
    input  logic [6:0]      dispatch1_funct7, dispatch1_opcode,
    input  logic [31:0]     dispatch1_imm_i, dispatch1_imm_s, dispatch1_imm_b, dispatch1_imm_u, dispatch1_imm_j,
    input  logic [31:0]     dispatch1_rs1_val, dispatch1_rs2_val,
    input  logic [31:0]     dispatch1_frs1_val, dispatch1_frs2_val, dispatch1_frs3_val,
    input  logic [63:0]     dispatch1_bp_meta,
    input  logic            dispatch1_bp_pred_taken,
    input  logic [2:0]      dispatch1_fence_op,
    input  logic [5:0]      dispatch1_prs1, dispatch1_prs2, dispatch1_prd,
    input  logic [ROB_TAG_W-1:0] dispatch1_rob_ptr,
    input  logic            dispatch1_rs1_rdy, dispatch1_rs2_rdy,
    output logic            issue1_valid,
    output logic [31:0]     issue1_pc, issue1_inst,
    output logic [4:0]      issue1_rd,
    output logic            issue1_regwrite,
    output logic            issue1_is_load, issue1_is_store, issue1_is_amo,
    output logic            issue1_is_branch, issue1_is_jal, issue1_is_jalr,
    output logic            issue1_is_fence, issue1_is_csr,
    output logic            issue1_is_fp_op, issue1_is_fp_load, issue1_is_fp_store,
    output logic            issue1_fregwrite, issue1_illegal, issue1_err,
    output logic [2:0]      issue1_funct3,
    output logic [6:0]      issue1_funct7, issue1_opcode,
    output logic [31:0]     issue1_imm_i, issue1_imm_s, issue1_imm_b, issue1_imm_u, issue1_imm_j,
    output logic [31:0]     issue1_rs1_val, issue1_rs2_val,
    output logic [31:0]     issue1_frs1_val, issue1_frs2_val, issue1_frs3_val,
    output logic [63:0]     issue1_bp_meta,
    output logic            issue1_bp_pred_taken,
    output logic [2:0]      issue1_fence_op,
    output logic [5:0]      issue1_prs1, issue1_prs2, issue1_prd,
    output logic [ROB_TAG_W-1:0] issue1_rob_ptr,
    output logic            iq_full,
    output logic            iq_full_dual
);
    localparam int unsigned IQ_DEPTH_M1 = (IQ_DEPTH > 0) ? (IQ_DEPTH - 1) : 0;
`ifndef SYNTHESIS
    localparam logic [5:0] DBG_PRD = 6'd34;
    int unsigned dbg_prd_state_cnt;
`endif

    typedef struct packed {
        logic        valid;
        logic        rs1_rdy, rs2_rdy;
        logic [5:0]  prs1, prs2, prd;  // physical regs for wakeup + destination
        logic [31:0] pc, inst;
        logic [4:0]  rd; logic regwrite;
        logic        is_load, is_store, is_amo;
        logic        is_branch, is_jal, is_jalr, is_fence, is_csr;
        logic        is_fp_op, is_fp_load, is_fp_store, fregwrite, illegal, err;
        logic [2:0]  funct3; logic [6:0] funct7, opcode;
        logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
        logic [31:0] rs1_val, rs2_val, frs1_val, frs2_val, frs3_val;
        logic [63:0] bp_meta; logic bp_pred_taken;
        logic [2:0]  fence_op;
        logic [ROB_TAG_W-1:0] rob_ptr;
    } rs_entry_t;

    rs_entry_t e [0:IQ_DEPTH-1];
    logic [$clog2(IQ_DEPTH):0] wptr, rptr;
    logic [$clog2(IQ_DEPTH):0] used_slots;
    logic can_push0, can_push1;
    logic free0_found, free1_found;
    logic [$clog2(IQ_DEPTH)-1:0] free_idx0, free_idx1;
    logic iq_full_next, iq_full_dual_next;
    // Timing mode: keep dispatch acceptance independent from the issue-select scan.
    // All dispatched ops enter the RS; this avoids a long e[] -> passthrough/accept
    // -> frontend stall path.
    logic iq_passthrough0;
    always_comb begin
        automatic int unsigned free_slots_cur = 0;
        automatic int unsigned pending_push_guard = 0;
        automatic int unsigned guarded_free_slots = 0;
        used_slots = '0;
        free0_found = 1'b0;
        free1_found = 1'b0;
        free_idx0 = '0;
        free_idx1 = '0;
        iq_full_next = 1'b0;
        iq_full_dual_next = 1'b0;
        for (int i = 0; i < IQ_DEPTH; i++) begin
            if (e[i].valid) begin
                used_slots = used_slots + 1'b1;
            end else if (!free0_found) begin
                free0_found = 1'b1;
                free_idx0 = i[$clog2(IQ_DEPTH)-1:0];
            end else if (!free1_found) begin
                free1_found = 1'b1;
                free_idx1 = i[$clog2(IQ_DEPTH)-1:0];
            end
        end
        free_slots_cur = IQ_DEPTH - used_slots;
        can_push0 = free0_found;
        can_push1 = free1_found;
        iq_passthrough0  = 1'b0;
        dispatch_accept  = dispatch_valid && can_push0;
        dispatch1_accept = dispatch1_valid && can_push1;
        // Frontend allocation is one cycle ahead of IQ dispatch. Register a conservative
        // capacity hint and reserve room for the already-pending dispatch plus a new one.
        pending_push_guard = (dispatch_valid ? 1 : 0) + (dispatch1_valid ? 1 : 0);
        if (free_slots_cur > pending_push_guard)
            guarded_free_slots = free_slots_cur - pending_push_guard;
        else
            guarded_free_slots = 0;
        iq_full_next      = (guarded_free_slots < 3);
        iq_full_dual_next = (guarded_free_slots < 4);
    end

    // FU type decode (combinational from opcode/funct7)
    function automatic logic [2:0] get_fu_type(logic [6:0] opc, logic [6:0] f7);
        get_fu_type = 3'd0; // ALU default
        if (opc == 7'b0110011 && f7 == 7'h01)
            get_fu_type = 3'd1; // MUL
        else if (opc == 7'b1100011 || opc == 7'b1101111 || opc == 7'b1100111 || opc == 7'b0001111)
            get_fu_type = 3'd3; // BRU (branch/jal/jalr/fence)
        else if (opc == 7'b0000011 || opc == 7'b0100011 || opc == 7'b0101111
              || opc == 7'b0000111 || opc == 7'b0100111)
            get_fu_type = 3'd2; // LSU (load/store/amo/fp-ld/st)
        else if (opc == 7'b1010011 || opc == 7'h43 || opc == 7'h47 || opc == 7'h4b || opc == 7'h4f)
            get_fu_type = 3'd4; // FPU (slot0 only)
        // else ALU (OP, OP-IMM, LUI, AUIPC, CSR, etc.)
    endfunction

    function automatic logic issue_ready_idx(input int idx);
        automatic logic [2:0] ft;
        automatic logic       plain_load_ooo_ok;
        ft = get_fu_type(e[idx].opcode, e[idx].funct7);
        // Timing mode: keep loads ordered at the ROB head. This removes the
        // nested older-entry scan from the issue-ready path.
        plain_load_ooo_ok = 1'b0;
        issue_ready_idx = e[idx].valid && e[idx].rs1_rdy && e[idx].rs2_rdy
            && ((ft != 3'd2 && ft != 3'd3 && ft != 3'd4 && !e[idx].is_fence && !e[idx].is_csr)
                || (e[idx].rob_ptr == rob_head_tag)
                || plain_load_ooo_ok);
    endfunction

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            wptr <= 0; rptr <= 0;
            for (int i = 0; i < IQ_DEPTH; i++) e[i] <= '0;
            iq_full <= 1'b0;
            iq_full_dual <= 1'b0;
            issue_valid <= 1'b0; issue_pc <= '0; issue_inst <= '0;
            issue_rd <= '0; issue_regwrite <= 1'b0;
            issue_is_load <= 1'b0; issue_is_store <= 1'b0; issue_is_amo <= 1'b0;
            issue_is_branch<=1'b0; issue_is_jal<=1'b0; issue_is_jalr<=1'b0;
            issue_is_fence<=1'b0; issue_is_csr<=1'b0;
            issue_is_fp_op<=1'b0; issue_is_fp_load<=1'b0; issue_is_fp_store<=1'b0; issue_fregwrite<=1'b0;
            issue_illegal<=1'b0; issue_err<=1'b0;
            issue_funct3<='0; issue_funct7<='0; issue_opcode<='0;
            issue_imm_i<='0; issue_imm_s<='0; issue_imm_b<='0; issue_imm_u<='0; issue_imm_j<='0;
            issue_rs1_val<='0; issue_rs2_val<='0; issue_frs1_val<='0; issue_frs2_val<='0; issue_frs3_val<='0;
            issue_bp_meta<='0; issue_bp_pred_taken<=1'b0; issue_fence_op<='0;
            issue_fu_type <= '0;
            issue_prs1 <= '0; issue_prs2 <= '0; issue_prd <= '0; issue_rob_ptr <= '0;
            // Slot 1 reset
            issue1_valid <= 1'b0;
            issue1_pc <= '0; issue1_inst <= '0; issue1_rd <= '0; issue1_regwrite <= 1'b0;
            issue1_is_load <= 1'b0; issue1_is_store <= 1'b0; issue1_is_amo <= 1'b0;
            issue1_is_branch<=1'b0; issue1_is_jal<=1'b0; issue1_is_jalr<=1'b0;
            issue1_is_fence<=1'b0; issue1_is_csr<=1'b0;
            issue1_is_fp_op<=1'b0; issue1_is_fp_load<=1'b0; issue1_is_fp_store<=1'b0;
            issue1_fregwrite<=1'b0; issue1_illegal<=1'b0; issue1_err<=1'b0;
            issue1_funct3<='0; issue1_funct7<='0; issue1_opcode<='0;
            issue1_imm_i<='0; issue1_imm_s<='0; issue1_imm_b<='0; issue1_imm_u<='0; issue1_imm_j<='0;
            issue1_rs1_val<='0; issue1_rs2_val<='0; issue1_frs1_val<='0; issue1_frs2_val<='0; issue1_frs3_val<='0;
            issue1_bp_meta<='0; issue1_bp_pred_taken<=1'b0; issue1_fence_op<='0;
            issue1_prs1<='0; issue1_prs2<='0; issue1_prd<='0; issue1_rob_ptr<='0;
`ifndef SYNTHESIS
            dbg_prd_state_cnt <= 0;
`endif
        end else if (flush_en) begin
            wptr <= 0;
            rptr <= 0;
            for (int i = 0; i < IQ_DEPTH; i++) e[i] <= '0;
            iq_full <= 1'b0;
            iq_full_dual <= 1'b0;
            issue_valid <= 1'b0;
            issue1_valid <= 1'b0;
`ifndef SYNTHESIS
            dbg_prd_state_cnt <= 0;
`endif
        end else begin
            iq_full <= iq_full_next;
            iq_full_dual <= iq_full_dual_next;
            if (!stall_fp) begin
                issue_valid <= 1'b0;
                issue1_valid <= 1'b0;
            end
            if (squash_en) begin
                // Kill RS entries strictly younger than redirect: rob_ptr in (squash_rob_ptr, rob_tail_tag)
                // in ROB tag space (mod 2^ROB_TAG_W), matching cpu_rob walk from squash_rob_ptr+1 while p!=tail.
                // When rob_tail_tag == squash_rob_ptr, ROB has no entries younger than the redirect; tail-squash-1
                // would wrap to 2^W-1 and wrongly kill in-flight entries (e.g. ROB head still in IQ).
                automatic logic [ROB_TAG_W-1:0] squash_span =
                    (rob_tail_tag == squash_rob_ptr) ? '0
                    : (rob_tail_tag - squash_rob_ptr - 1'b1);
                for (int i = 0; i < IQ_DEPTH; i++) begin
                    if (e[i].valid && (squash_span != 0)) begin
                        automatic logic [ROB_TAG_W-1:0] rel =
                            e[i].rob_ptr - squash_rob_ptr - 1'b1;
                        if (rel < squash_span)
                            e[i].valid <= 1'b0;
                    end
                end
            end
            // R2: RS selection — issue oldest ready entry.
            // During global stall/redirect, suppress issue to avoid re-issuing same entry every cycle.
            if (!stall) begin
                automatic int sel0 = -1;
                automatic logic [ROB_TAG_W-1:0] best_age0 = {ROB_TAG_W{1'b1}};
                for (int i = 0; i < IQ_DEPTH; i++) begin
                    if (issue_ready_idx(i)) begin
                        automatic logic [ROB_TAG_W-1:0] age = e[i].rob_ptr - rob_head_tag;
                        if (age < best_age0) begin
                            best_age0 = age;
                            sel0      = i;
                        end
                    end
                end
                if (sel0 >= 0) begin
                    issue_valid    <= 1'b1;
                    issue_pc       <= e[sel0].pc;       issue_inst <= e[sel0].inst;
                    issue_rd       <= e[sel0].rd;       issue_regwrite <= e[sel0].regwrite;
                    issue_is_load  <= e[sel0].is_load;  issue_is_store <= e[sel0].is_store;
                    issue_is_amo   <= e[sel0].is_amo;   issue_is_branch <= e[sel0].is_branch;
                    issue_is_jal   <= e[sel0].is_jal;   issue_is_jalr <= e[sel0].is_jalr;
                    issue_is_fence <= e[sel0].is_fence; issue_is_csr <= e[sel0].is_csr;
                    issue_is_fp_op<= e[sel0].is_fp_op;  issue_is_fp_load<=e[sel0].is_fp_load; issue_is_fp_store<=e[sel0].is_fp_store;
                    issue_fregwrite <= e[sel0].fregwrite;
                    issue_illegal  <= e[sel0].illegal;  issue_err <= e[sel0].err;
                    issue_funct3   <= e[sel0].funct3;   issue_funct7 <= e[sel0].funct7;
                    issue_opcode   <= e[sel0].opcode;
                    issue_imm_i    <= e[sel0].imm_i;    issue_imm_s <= e[sel0].imm_s;
                    issue_imm_b    <= e[sel0].imm_b;    issue_imm_u <= e[sel0].imm_u;
                    issue_imm_j    <= e[sel0].imm_j;
                    issue_rs1_val  <= e[sel0].rs1_val;  issue_rs2_val <= e[sel0].rs2_val;
                    issue_frs1_val <= e[sel0].frs1_val; issue_frs2_val <= e[sel0].frs2_val;
                    issue_frs3_val <= e[sel0].frs3_val;
                    issue_bp_meta  <= e[sel0].bp_meta;  issue_bp_pred_taken <= e[sel0].bp_pred_taken;
                    issue_fence_op <= e[sel0].fence_op;
                    issue_fu_type  <= get_fu_type(e[sel0].opcode, e[sel0].funct7);
                    issue_prs1 <= e[sel0].prs1; issue_prs2 <= e[sel0].prs2; issue_prd <= e[sel0].prd; issue_rob_ptr <= e[sel0].rob_ptr;
`ifndef SYNTHESIS
                    if ($test$plusargs("PRDTRACE") && e[sel0].prd == DBG_PRD)
                        $display("[IQ40] issue0 t=%0t pc=0x%08x inst=0x%08x", $time, e[sel0].pc, e[sel0].inst);
`endif
                end
                if (sel0 >= 0) begin
                    e[sel0].valid <= 1'b0;
                    // Maintain rptr as the oldest valid entry after this cycle's pops.
                    begin
                        automatic logic [$clog2(IQ_DEPTH)-1:0] rcur;
                        automatic logic [$clog2(IQ_DEPTH)-1:0] rnext;
                        automatic logic found_valid;
                        rcur = rptr[$clog2(IQ_DEPTH)-1:0];
                        rnext = rcur;
                        found_valid = 1'b0;
                        for (int j = 0; j < IQ_DEPTH; j++) begin
                            automatic logic [$clog2(IQ_DEPTH)-1:0] idx_scan;
                            automatic logic issuing_idx;
                            idx_scan = (rcur + j + 1) % IQ_DEPTH;
                            issuing_idx = ((sel0 >= 0) && (idx_scan == sel0[$clog2(IQ_DEPTH)-1:0]));
                            if (e[idx_scan].valid && !issuing_idx && !found_valid) begin
                                rnext = idx_scan;
                                found_valid = 1'b1;
                            end
                        end
                        if (found_valid)
                            rptr <= rnext;
                        else
                            rptr <= rcur + 1'b1;
                    end
                end else begin
                    // Fallback: 仅非访存/非控制类可旁路；否则本拍不入队则 issue 保持 0，仅靠下方 push。
                    if (iq_passthrough0) begin
                        issue_valid <= dispatch_valid;
                        issue_pc <= dispatch_pc; issue_inst <= dispatch_inst;
                        issue_rd <= dispatch_rd; issue_regwrite <= dispatch_regwrite;
                        issue_is_load <= dispatch_is_load; issue_is_store <= dispatch_is_store;
                        issue_is_amo <= dispatch_is_amo; issue_is_branch <= dispatch_is_branch;
                        issue_is_jal <= dispatch_is_jal; issue_is_jalr <= dispatch_is_jalr;
                        issue_is_fence <= dispatch_is_fence; issue_is_csr <= dispatch_is_csr;
                        issue_is_fp_op <= dispatch_is_fp_op; issue_is_fp_load <= dispatch_is_fp_load; issue_is_fp_store <= dispatch_is_fp_store;
                        issue_fregwrite <= dispatch_fregwrite;
                        issue_illegal <= dispatch_illegal; issue_err <= dispatch_err;
                        issue_funct3 <= dispatch_funct3; issue_funct7 <= dispatch_funct7;
                        issue_opcode <= dispatch_opcode;
                        issue_imm_i <= dispatch_imm_i; issue_imm_s <= dispatch_imm_s;
                        issue_imm_b <= dispatch_imm_b; issue_imm_u <= dispatch_imm_u; issue_imm_j <= dispatch_imm_j;
                        issue_rs1_val <= dispatch_rs1_val; issue_rs2_val <= dispatch_rs2_val;
                        issue_frs1_val <= dispatch_frs1_val; issue_frs2_val <= dispatch_frs2_val;
                        issue_frs3_val <= dispatch_frs3_val;
                        issue_bp_meta <= dispatch_bp_meta; issue_bp_pred_taken <= dispatch_bp_pred_taken;
                        issue_fence_op <= dispatch_fence_op;
                        issue_fu_type  <= get_fu_type(dispatch_opcode, dispatch_funct7);
                        issue_prs1 <= dispatch_prs1; issue_prs2 <= dispatch_prs2; issue_prd <= dispatch_prd; issue_rob_ptr <= dispatch_rob_ptr;
                    end
                end
            end

            // Store into RS — ALU 旁路同拍已发射则勿再 push slot0；访存类从不旁路，始终可 push。
            if (dispatch_valid && can_push0 && !iq_passthrough0) begin
                e[free_idx0] <= '{
                    valid: 1'b1,
                    // Include same-cycle CDB hits so new entries don't miss wakeup.
                    rs1_rdy: dispatch_rs1_rdy
                        || (cdb_valid  && (cdb_prd  != 6'd0) && (dispatch_prs1 == cdb_prd))
                        || (cdb2_valid && (cdb2_prd != 6'd0) && (dispatch_prs1 == cdb2_prd))
                        || (cdb3_valid && (cdb3_prd != 6'd0) && (dispatch_prs1 == cdb3_prd)),
                    rs2_rdy: dispatch_rs2_rdy
                        || (cdb_valid  && (cdb_prd  != 6'd0) && (dispatch_prs2 == cdb_prd))
                        || (cdb2_valid && (cdb2_prd != 6'd0) && (dispatch_prs2 == cdb2_prd))
                        || (cdb3_valid && (cdb3_prd != 6'd0) && (dispatch_prs2 == cdb3_prd)),
                    prs1: dispatch_prs1, prs2: dispatch_prs2, prd: dispatch_prd,
                    pc: dispatch_pc, inst: dispatch_inst,
                    rd: dispatch_rd, regwrite: dispatch_regwrite,
                    is_load: dispatch_is_load, is_store: dispatch_is_store,
                    is_amo: dispatch_is_amo, is_branch: dispatch_is_branch,
                    is_jal: dispatch_is_jal, is_jalr: dispatch_is_jalr,
                    is_fence: dispatch_is_fence, is_csr: dispatch_is_csr,
                    is_fp_op: dispatch_is_fp_op, is_fp_load: dispatch_is_fp_load, is_fp_store: dispatch_is_fp_store,
                    fregwrite: dispatch_fregwrite,
                    illegal: dispatch_illegal, err: dispatch_err,
                    funct3: dispatch_funct3, funct7: dispatch_funct7, opcode: dispatch_opcode,
                    imm_i: dispatch_imm_i, imm_s: dispatch_imm_s,
                    imm_b: dispatch_imm_b, imm_u: dispatch_imm_u, imm_j: dispatch_imm_j,
                    rs1_val: (cdb_valid  && (cdb_prd  != 6'd0) && (dispatch_prs1 == cdb_prd))  ? cdb_wdata  :
                             (cdb2_valid && (cdb2_prd != 6'd0) && (dispatch_prs1 == cdb2_prd)) ? cdb2_wdata :
                             (cdb3_valid && (cdb3_prd != 6'd0) && (dispatch_prs1 == cdb3_prd)) ? cdb3_wdata :
                             dispatch_rs1_val,
                    rs2_val: (cdb_valid  && (cdb_prd  != 6'd0) && (dispatch_prs2 == cdb_prd))  ? cdb_wdata  :
                             (cdb2_valid && (cdb2_prd != 6'd0) && (dispatch_prs2 == cdb2_prd)) ? cdb2_wdata :
                             (cdb3_valid && (cdb3_prd != 6'd0) && (dispatch_prs2 == cdb3_prd)) ? cdb3_wdata :
                             dispatch_rs2_val,
                    frs1_val: dispatch_frs1_val, frs2_val: dispatch_frs2_val, frs3_val: dispatch_frs3_val,
                    bp_meta: dispatch_bp_meta, bp_pred_taken: dispatch_bp_pred_taken,
                    fence_op: dispatch_fence_op,
                    rob_ptr: dispatch_rob_ptr
                };
`ifndef SYNTHESIS
                if ($test$plusargs("PRDTRACE") && dispatch_prd == DBG_PRD) begin
                    $display("[IQ40] push0 t=%0t pc=0x%08x rs_rdy=%0b/%0b prs=%0d/%0d",
                             $time, dispatch_pc,
                             dispatch_rs1_rdy
                                || (cdb_valid  && (cdb_prd  != 6'd0) && (dispatch_prs1 == cdb_prd))
                                || (cdb2_valid && (cdb2_prd != 6'd0) && (dispatch_prs1 == cdb2_prd))
                                || (cdb3_valid && (cdb3_prd != 6'd0) && (dispatch_prs1 == cdb3_prd)),
                             dispatch_rs2_rdy
                                || (cdb_valid  && (cdb_prd  != 6'd0) && (dispatch_prs2 == cdb_prd))
                                || (cdb2_valid && (cdb2_prd != 6'd0) && (dispatch_prs2 == cdb2_prd))
                                || (cdb3_valid && (cdb3_prd != 6'd0) && (dispatch_prs2 == cdb3_prd)),
                             dispatch_prs1, dispatch_prs2);
                end
`endif
                wptr <= wptr + 1'b1;
            end
            // Slot 1: after slot0 push uses wptr+1 / +2; if slot0 was passthrough, only slot1 at wptr.
            if (dispatch1_valid) begin
                if (iq_passthrough0) begin
	                    if (can_push0) begin
	                        e[free_idx0] <= '{
                    valid: 1'b1,
                    rs1_rdy: dispatch1_rs1_rdy
                        || (cdb_valid  && (cdb_prd  != 6'd0) && (dispatch1_prs1 == cdb_prd))
                        || (cdb2_valid && (cdb2_prd != 6'd0) && (dispatch1_prs1 == cdb2_prd))
                        || (cdb3_valid && (cdb3_prd != 6'd0) && (dispatch1_prs1 == cdb3_prd)),
                    rs2_rdy: dispatch1_rs2_rdy
                        || (cdb_valid  && (cdb_prd  != 6'd0) && (dispatch1_prs2 == cdb_prd))
                        || (cdb2_valid && (cdb2_prd != 6'd0) && (dispatch1_prs2 == cdb2_prd))
                        || (cdb3_valid && (cdb3_prd != 6'd0) && (dispatch1_prs2 == cdb3_prd)),
                        prs1: dispatch1_prs1, prs2: dispatch1_prs2, prd: dispatch1_prd,
                        pc: dispatch1_pc, inst: dispatch1_inst,
                        rd: dispatch1_rd, regwrite: dispatch1_regwrite,
                        is_load: dispatch1_is_load, is_store: dispatch1_is_store,
                        is_amo: dispatch1_is_amo, is_branch: dispatch1_is_branch,
                        is_jal: dispatch1_is_jal, is_jalr: dispatch1_is_jalr,
                        is_fence: dispatch1_is_fence, is_csr: dispatch1_is_csr,
                        is_fp_op: dispatch1_is_fp_op, is_fp_load: dispatch1_is_fp_load, is_fp_store: dispatch1_is_fp_store,
                        fregwrite: dispatch1_fregwrite,
                        illegal: dispatch1_illegal, err: dispatch1_err,
                        funct3: dispatch1_funct3, funct7: dispatch1_funct7, opcode: dispatch1_opcode,
                        imm_i: dispatch1_imm_i, imm_s: dispatch1_imm_s,
                        imm_b: dispatch1_imm_b, imm_u: dispatch1_imm_u, imm_j: dispatch1_imm_j,
                    rs1_val: (cdb_valid  && (cdb_prd  != 6'd0) && (dispatch1_prs1 == cdb_prd))  ? cdb_wdata  :
                             (cdb2_valid && (cdb2_prd != 6'd0) && (dispatch1_prs1 == cdb2_prd)) ? cdb2_wdata :
                             (cdb3_valid && (cdb3_prd != 6'd0) && (dispatch1_prs1 == cdb3_prd)) ? cdb3_wdata :
                             dispatch1_rs1_val,
                    rs2_val: (cdb_valid  && (cdb_prd  != 6'd0) && (dispatch1_prs2 == cdb_prd))  ? cdb_wdata  :
                             (cdb2_valid && (cdb2_prd != 6'd0) && (dispatch1_prs2 == cdb2_prd)) ? cdb2_wdata :
                             (cdb3_valid && (cdb3_prd != 6'd0) && (dispatch1_prs2 == cdb3_prd)) ? cdb3_wdata :
                             dispatch1_rs2_val,
                        frs1_val: dispatch1_frs1_val, frs2_val: dispatch1_frs2_val, frs3_val: dispatch1_frs3_val,
                        bp_meta: dispatch1_bp_meta, bp_pred_taken: dispatch1_bp_pred_taken,
                        fence_op: dispatch1_fence_op,
                        rob_ptr: dispatch1_rob_ptr
                        };
                        wptr <= wptr + 1'b1;
                    end
`ifndef SYNTHESIS
                    else if ($test$plusargs("PRDTRACE") && dispatch1_prd == DBG_PRD) begin
                        $error("[IQ_ASSERT] dispatch1 dropped (passthrough0 path) prd=%0d wptr=%0d rptr=%0d",
                               dispatch1_prd, wptr, rptr);
                    end
`endif
                end else begin
	                if (can_push1) begin
                    e[free_idx1] <= '{
                    valid: 1'b1,
                    // Include same-cycle CDB hits so new entries don't miss wakeup.
                    rs1_rdy: dispatch1_rs1_rdy
                        || (cdb_valid  && (cdb_prd  != 6'd0) && (dispatch1_prs1 == cdb_prd))
                        || (cdb2_valid && (cdb2_prd != 6'd0) && (dispatch1_prs1 == cdb2_prd))
                        || (cdb3_valid && (cdb3_prd != 6'd0) && (dispatch1_prs1 == cdb3_prd)),
                    rs2_rdy: dispatch1_rs2_rdy
                        || (cdb_valid  && (cdb_prd  != 6'd0) && (dispatch1_prs2 == cdb_prd))
                        || (cdb2_valid && (cdb2_prd != 6'd0) && (dispatch1_prs2 == cdb2_prd))
                        || (cdb3_valid && (cdb3_prd != 6'd0) && (dispatch1_prs2 == cdb3_prd)),
                        prs1: dispatch1_prs1, prs2: dispatch1_prs2, prd: dispatch1_prd,
                        pc: dispatch1_pc, inst: dispatch1_inst,
                        rd: dispatch1_rd, regwrite: dispatch1_regwrite,
                        is_load: dispatch1_is_load, is_store: dispatch1_is_store,
                        is_amo: dispatch1_is_amo, is_branch: dispatch1_is_branch,
                        is_jal: dispatch1_is_jal, is_jalr: dispatch1_is_jalr,
                        is_fence: dispatch1_is_fence, is_csr: dispatch1_is_csr,
                        is_fp_op: dispatch1_is_fp_op, is_fp_load: dispatch1_is_fp_load, is_fp_store: dispatch1_is_fp_store,
                        fregwrite: dispatch1_fregwrite,
                        illegal: dispatch1_illegal, err: dispatch1_err,
                        funct3: dispatch1_funct3, funct7: dispatch1_funct7, opcode: dispatch1_opcode,
                        imm_i: dispatch1_imm_i, imm_s: dispatch1_imm_s,
                        imm_b: dispatch1_imm_b, imm_u: dispatch1_imm_u, imm_j: dispatch1_imm_j,
                    rs1_val: (cdb_valid  && (cdb_prd  != 6'd0) && (dispatch1_prs1 == cdb_prd))  ? cdb_wdata  :
                             (cdb2_valid && (cdb2_prd != 6'd0) && (dispatch1_prs1 == cdb2_prd)) ? cdb2_wdata :
                             (cdb3_valid && (cdb3_prd != 6'd0) && (dispatch1_prs1 == cdb3_prd)) ? cdb3_wdata :
                             dispatch1_rs1_val,
                    rs2_val: (cdb_valid  && (cdb_prd  != 6'd0) && (dispatch1_prs2 == cdb_prd))  ? cdb_wdata  :
                             (cdb2_valid && (cdb2_prd != 6'd0) && (dispatch1_prs2 == cdb2_prd)) ? cdb2_wdata :
                             (cdb3_valid && (cdb3_prd != 6'd0) && (dispatch1_prs2 == cdb3_prd)) ? cdb3_wdata :
                             dispatch1_rs2_val,
                        frs1_val: dispatch1_frs1_val, frs2_val: dispatch1_frs2_val, frs3_val: dispatch1_frs3_val,
                        bp_meta: dispatch1_bp_meta, bp_pred_taken: dispatch1_bp_pred_taken,
                        fence_op: dispatch1_fence_op,
                        rob_ptr: dispatch1_rob_ptr
                    };
`ifndef SYNTHESIS
                    if ($test$plusargs("PRDTRACE") && dispatch1_prd == DBG_PRD) begin
                        $display("[IQ40] push1 t=%0t pc=0x%08x rs_rdy=%0b/%0b prs=%0d/%0d",
                                 $time, dispatch1_pc,
                                 dispatch1_rs1_rdy
                                    || (cdb_valid  && (cdb_prd  != 6'd0) && (dispatch1_prs1 == cdb_prd))
                                    || (cdb2_valid && (cdb2_prd != 6'd0) && (dispatch1_prs1 == cdb2_prd))
                                    || (cdb3_valid && (cdb3_prd != 6'd0) && (dispatch1_prs1 == cdb3_prd)),
                                 dispatch1_rs2_rdy
                                    || (cdb_valid  && (cdb_prd  != 6'd0) && (dispatch1_prs2 == cdb_prd))
                                    || (cdb2_valid && (cdb2_prd != 6'd0) && (dispatch1_prs2 == cdb2_prd))
                                    || (cdb3_valid && (cdb3_prd != 6'd0) && (dispatch1_prs2 == cdb3_prd)),
                                 dispatch1_prs1, dispatch1_prs2);
                    end
`endif
                    wptr <= wptr + 2;
                end
`ifndef SYNTHESIS
                else if ($test$plusargs("PRDTRACE") && dispatch1_prd == DBG_PRD) begin
                    $error("[IQ_ASSERT] dispatch1 dropped due IQ full prd=%0d wptr=%0d rptr=%0d",
                           dispatch1_prd, wptr, rptr);
                end
`endif
                end
            end
            // CDB wakeup: set rs*_rdy when phys reg matches
            if (cdb_valid && cdb_prd != 6'd0) begin
                for (int i = 0; i < IQ_DEPTH; i++) begin
                    if (e[i].valid) begin
                        if (e[i].prs1 == cdb_prd) begin
                            e[i].rs1_rdy <= 1'b1;
                            e[i].rs1_val <= cdb_wdata;
`ifndef SYNTHESIS
                            if ($test$plusargs("PRDTRACE") && e[i].prd == DBG_PRD)
                                $display("[IQ40] wake_rs1 cdb0 t=%0t cdb_prd=%0d", $time, cdb_prd);
`endif
                        end
                        if (e[i].prs2 == cdb_prd) begin
                            e[i].rs2_rdy <= 1'b1;
                            e[i].rs2_val <= cdb_wdata;
`ifndef SYNTHESIS
                            if ($test$plusargs("PRDTRACE") && e[i].prd == DBG_PRD)
                                $display("[IQ40] wake_rs2 cdb0 t=%0t cdb_prd=%0d", $time, cdb_prd);
`endif
                        end
                    end
                end
            end
            if (cdb2_valid && cdb2_prd != 6'd0) begin
                for (int i = 0; i < IQ_DEPTH; i++) begin
                    if (e[i].valid) begin
                        if (e[i].prs1 == cdb2_prd) begin
                            e[i].rs1_rdy <= 1'b1;
                            e[i].rs1_val <= cdb2_wdata;
                        end
                        if (e[i].prs2 == cdb2_prd) begin
                            e[i].rs2_rdy <= 1'b1;
                            e[i].rs2_val <= cdb2_wdata;
                        end
                    end
                end
            end
            if (cdb3_valid && cdb3_prd != 6'd0) begin
                for (int i = 0; i < IQ_DEPTH; i++) begin
                    if (e[i].valid) begin
                        if (e[i].prs1 == cdb3_prd) begin
                            e[i].rs1_rdy <= 1'b1;
                            e[i].rs1_val <= cdb3_wdata;
                        end
                        if (e[i].prs2 == cdb3_prd) begin
                            e[i].rs2_rdy <= 1'b1;
                            e[i].rs2_val <= cdb3_wdata;
                        end
                    end
                end
            end
`ifndef SYNTHESIS
            if ($test$plusargs("PRDTRACE") && (dbg_prd_state_cnt < 64)) begin
                for (int i = 0; i < IQ_DEPTH; i++) begin
                    if (e[i].valid && (e[i].prd == DBG_PRD)) begin
                        dbg_prd_state_cnt <= dbg_prd_state_cnt + 1;
                        $display("[IQ%0d] state t=%0t idx=%0d v=%0b pc=0x%08x inst=0x%08x prs=%0d/%0d rdy=%0b/%0b rob=%0d head=%0d stall=%0b ft=%0d ready=%0b",
                                 DBG_PRD, $time, i, e[i].valid, e[i].pc, e[i].inst,
                                 e[i].prs1, e[i].prs2, e[i].rs1_rdy, e[i].rs2_rdy,
                                 e[i].rob_ptr, rob_head_tag, stall,
                                 get_fu_type(e[i].opcode, e[i].funct7), issue_ready_idx(i));
                    end
                end
            end
`endif
        end
    end

endmodule
