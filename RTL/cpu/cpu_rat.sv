// Register Alias Table: arch → phys reg mapping.
// Phase O1: identity mapping (arch_n → phys_n). No speculative remapping.
// In O2+ : speculative writes update the rat_tbl; checkpoints save/restore.

module cpu_rat #(
    parameter int unsigned CP_DEPTH = 8
) (
    input  logic        pl_clk,
    input  logic        pl_resetn,

    // === rename (from ID stage) ===
    input  logic        rename_en,           // rename valid this cycle
    input  logic [4:0]  rename_rs1,          // arch src1
    input  logic [4:0]  rename_rs2,          // arch src2
    input  logic [4:0]  rename_rd,           // arch dst
    input  logic        rename_regwrite,     // does this instruction write a reg?
    input  logic [5:0]  new_prd,             // allocated phys reg from PRF

    output logic [5:0]  prs1,                // phys src1
    output logic [5:0]  prs2,                // phys src2
    output logic [5:0]  old_prd,
    // Slot 1 rename (ISSUE_WIDTH=2)
    input  logic        rename1_en,
    input  logic [4:0]  rename1_rs1, rename1_rs2, rename1_rd,
    input  logic        rename1_regwrite,
    input  logic [5:0]  new1_prd,
    output logic [5:0]  prs1_1, prs2_1, old1_prd,             // old phys reg for dst (for ROB, to release later)

    // === writeback lookup (returns current phys mapping for arch reg) ===
    input  logic [4:0]  wb_arch,
    output       [5:0]  wb_prd,

    // === commit (from ROB/COMMIT) ===
    input  logic        commit_en,
    input  logic [4:0]  commit_rd,
    input  logic [5:0]  commit_prd,

    // Speculative rename undo (ROB tail retract): revert before same-cycle rename.
    input  logic        retract1_en,
    input  logic [4:0]  retract1_rd,
    input  logic [5:0]  retract1_old_prd,
    input  logic        retract0_en,
    input  logic [4:0]  retract0_rd,
    input  logic [5:0]  retract0_old_prd,

    // === flush (from mispredict / trap) ===
    input  logic        flush_en,
    // Checkpoint for branch speculation
    input  logic        cp_push, cp_pop, cp_release,
    input  logic [5:0]  cp_push_tag,
    input  logic [5:0]  cp_pop_tag,
    input  logic [5:0]  cp_release_tag,
    output        cp_empty,  // wire-driven
    // Fixup: when only slot1 is ctrl, cp_pop must preserve slot0's rename
    input  logic        cp_fixup_valid,
    input  logic [4:0]  cp_fixup_rd,
    input  logic [5:0]  cp_fixup_prd,
    // Fixup for the redirecting control-flow instruction itself (JAL/JALR link rd).
    input  logic        cp_fixup2_valid,
    input  logic [4:0]  cp_fixup2_rd,
    input  logic [5:0]  cp_fixup2_prd,

    output logic [63:0] mapped_prd_mask
);

    logic [5:0] rat_tbl [0:31];
    logic [5:0] cp_stack [0:CP_DEPTH-1][0:31];
    logic [5:0] cp_tag [0:CP_DEPTH-1];
    logic [5:0] cp_push_shadow [0:31];
    logic [5:0] cp_push_tag_q;
    logic       cp_push_q;
    logic [$clog2(CP_DEPTH+1)-1:0] cp_wptr;
    logic [$clog2(CP_DEPTH+1)-1:0] cp_next_wptr;
    assign cp_empty = (cp_wptr == 0);

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        int pop_idx;
        int rel_idx;
        logic pop_found;
        logic rel_found;
        if (!pl_resetn) begin
            for (int i = 0; i < 32; i++)
                rat_tbl[i] <= {1'b0, 5'(i)};
            for (int s = 0; s < CP_DEPTH; s++)
                cp_tag[s] <= 6'd0;
            for (int i = 0; i < 32; i++)
                cp_push_shadow[i] <= {1'b0, 5'(i)};
            cp_push_tag_q <= 6'd0;
            cp_push_q <= 1'b0;
            cp_wptr <= 0;
        end else begin
            cp_next_wptr = cp_wptr;
            pop_idx = 0;
            rel_idx = 0;
            pop_found = 1'b0;
            rel_found = 1'b0;
            if (flush_en) begin
                for (int i = 0; i < 32; i++)
                    rat_tbl[i] <= {1'b0, 5'(i)};
                for (int s = 0; s < CP_DEPTH; s++)
                    cp_tag[s] <= 6'd0;
                cp_push_q <= 1'b0;
                cp_wptr <= 0;
            end else if (cp_pop && cp_wptr > 0) begin
                cp_push_q <= 1'b0;
                for (int s = 0; s < CP_DEPTH; s++) begin
                    if ((s < cp_wptr) && (cp_tag[s] == cp_pop_tag)) begin
                        pop_idx = s;
                        pop_found = 1'b1;
                    end
                end
                if (!pop_found)
                    pop_idx = cp_wptr - 1;
                for (int i = 0; i < 32; i++)
                    rat_tbl[i] <= cp_stack[pop_idx][i];
                if (cp_fixup2_valid && (cp_fixup2_rd != 5'd0))
                    rat_tbl[cp_fixup2_rd] <= cp_fixup2_prd;
                cp_wptr <= pop_idx[$clog2(CP_DEPTH+1)-1:0];
            end else begin
                // Capture checkpoint contents behind a register; the wide cp_stack write happens
                // one cycle later from this local snapshot, not directly from rename control.
                if (cp_push && (cp_wptr < CP_DEPTH)) begin
                    for (int i = 0; i < 32; i++)
                        cp_push_shadow[i] <= rat_tbl[i];
                    if (cp_fixup_valid && (cp_fixup_rd != 5'd0))
                        cp_push_shadow[cp_fixup_rd] <= cp_fixup_prd;
                    cp_push_tag_q <= cp_push_tag;
                    cp_push_q <= 1'b1;
                end else begin
                    cp_push_q <= 1'b0;
                end
                // Undo younger slot first (matches ROB tail pop order).
                if (retract1_en && (retract1_rd != 5'd0))
                    rat_tbl[retract1_rd] <= retract1_old_prd;
                if (retract0_en && (retract0_rd != 5'd0))
                    rat_tbl[retract0_rd] <= retract0_old_prd;
                if (rename_en && rename_regwrite && (rename_rd != 5'd0))
                    rat_tbl[rename_rd] <= new_prd;
                if (rename1_en && rename1_regwrite && (rename1_rd != 5'd0))
                    rat_tbl[rename1_rd] <= new1_prd;
                if (cp_release && cp_next_wptr > 0) begin
                    for (int s = 0; s < CP_DEPTH; s++) begin
                        if ((s < cp_next_wptr) && (cp_tag[s] == cp_release_tag) && !rel_found) begin
                            rel_idx = s;
                            rel_found = 1'b1;
                        end
                    end
                    if (rel_found) begin
                        for (int s = 0; s < CP_DEPTH-1; s++) begin
                            if ((s >= rel_idx) && (s < (cp_next_wptr - 1))) begin
                                cp_tag[s] <= cp_tag[s+1];
                                for (int i = 0; i < 32; i++)
                                    cp_stack[s][i] <= cp_stack[s+1][i];
                            end
                        end
                        cp_next_wptr = cp_next_wptr - 1;
                    end
                end
                if (cp_push_q && cp_next_wptr < CP_DEPTH) begin
                    for (int i = 0; i < 32; i++)
                        cp_stack[cp_next_wptr][i] <= cp_push_shadow[i];
                    cp_tag[cp_next_wptr] <= cp_push_tag_q;
                    cp_wptr <= cp_next_wptr + 1;
                end else begin
                    cp_wptr <= cp_next_wptr;
                end
            end
        end
    end

    assign prs1   = rat_tbl[rename_rs1];
    assign prs2   = (rename_rs1 == rename_rs2) ? prs1 : rat_tbl[rename_rs2];
    assign old_prd = rat_tbl[rename_rd];
    // Slot 1: WAW-aware — if both slots write same arch reg, slot1.old = slot0.new
    // Slot 1 source rename must see slot 0 same-cycle rename (RAW in bundle).
    assign prs1_1  = (rename_en && rename_regwrite && (rename_rd != 5'd0) && (rename1_rs1 == rename_rd))
        ? new_prd : rat_tbl[rename1_rs1];
    assign prs2_1  = (rename1_rs1 == rename1_rs2) ? prs1_1 :
        ((rename_en && rename_regwrite && (rename_rd != 5'd0) && (rename1_rs2 == rename_rd))
            ? new_prd : rat_tbl[rename1_rs2]);
    assign old1_prd = (rename1_rd == rename_rd && rename_en && rename_regwrite) ? new_prd : rat_tbl[rename1_rd];

    assign wb_prd = rat_tbl[wb_arch];

    always_comb begin
        mapped_prd_mask = '0;
        for (int i = 0; i < 32; i++) begin
            if (rat_tbl[i] != 6'd0)
                mapped_prd_mask[rat_tbl[i]] = 1'b1;
        end
    end

endmodule
