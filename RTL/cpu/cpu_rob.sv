// ReOrder Buffer: FIFO + per-instruction alloc + exact ROB-tagged completion + retire mux.
// Completion: wb/wb2/wb3 must match both ROB tag and PRD. Head retires when done.

module cpu_rob #(
    parameter int unsigned ROB_DEPTH = 16
) (
    input  logic        pl_clk,
    input  logic        pl_resetn,

    // === alloc (from consume_ifid — creates entry for every instruction) ===
    input  logic        alloc_en,
    input  logic [31:0] alloc_pc,
    input  logic [31:0] alloc_inst,
    input  logic        alloc_regwrite,
    input  logic [4:0]  alloc_rd,
    input  logic [5:0]  alloc_old_prd,
    input  logic [5:0]  alloc_prd,       // phys dest for slot0
    output logic [$clog2(ROB_DEPTH):0] alloc_rob_ptr,
    // Slot 1 alloc (ISSUE_WIDTH=2)
    input  logic        alloc1_en,
    input  logic [31:0] alloc1_pc, alloc1_inst,
    input  logic        alloc1_regwrite,
    input  logic [4:0]  alloc1_rd,
    input  logic [5:0]  alloc1_prd,    // phys dest for slot1
    input  logic [5:0]  alloc1_old_prd,// old phys reg to release at commit
    output logic [$clog2(ROB_DEPTH):0] alloc1_rob_ptr,
    // Undo last speculative alloc(s) when IF/ID was consumed but ID/EX flushed before IQ dispatch (redirect bubble).
    input  logic        retract_en,
    input  logic        retract_dual, // match prior dual consume_ifid (two tail slots)
    input  logic        retract0_req,  // slot0 requests tail undo (same as core retract_slot0_pop)
    input  logic        retract1_req,
    output logic        retract_ack0, // ROB actually invalidated slot0's tail entry this cycle
    output logic        retract_ack1,
    // Younger squash on redirect: keep <= squash_rob_ptr, drop strictly younger tail entries.
    input  logic        squash_en,
    input  logic [$clog2(ROB_DEPTH):0] squash_rob_ptr,
    output logic        squash_busy,

    // === writeback (match by prd — up to 3 completions/cycle) ===
    input  logic        wb_en,
    input  logic [31:0] wb_wdata,
    input  logic [5:0]  wb_prd,
    input  logic [$clog2(ROB_DEPTH):0] wb_rob_ptr,
    input  logic        wb2_en,
    input  logic [31:0] wb2_wdata,
    input  logic [5:0]  wb2_prd,
    input  logic [$clog2(ROB_DEPTH):0] wb2_rob_ptr,
    input  logic        wb3_en,
    input  logic [31:0] wb3_wdata,
    input  logic [5:0]  wb3_prd,
    input  logic [$clog2(ROB_DEPTH):0] wb3_rob_ptr,
    output logic        wb_accept,
    output logic        wb2_accept,
    output logic        wb3_accept,

    // === pop ===
    input  logic        pop_en,

    // === retire output ===
    output logic        rob_retire_valid,
    // Architectural retire (difftest): suppressed when head has precise exception — trap handled separately.
    output logic        rob_retire_arch_valid,
    output logic [31:0] rob_retire_pc,
    output logic [31:0] rob_retire_inst,
    output logic        rob_retire_regwrite,
    output logic [4:0]  rob_retire_waddr,
    output logic [31:0] rob_retire_wdata,

    output logic        rob_empty,
    output logic        rob_full,
    // True when tail cannot accept two new entries (dual consume_ifid must stall).
    output logic        rob_full_dual,
    // Tail tag for IQ squash boundary (same cycle as squash_en, pre-update).
    output logic [$clog2(ROB_DEPTH):0] rob_tail_tag,
    output logic [$clog2(ROB_DEPTH):0] rob_head_tag,
    output logic        retire_release_en,
    output logic [5:0]  retire_release_prd,
    output logic        rob_retire1_valid,
    output logic        rob_retire1_arch_valid,
    output logic [31:0] rob_retire1_pc,
    output logic [31:0] rob_retire1_inst,
    output logic        rob_retire1_regwrite,
    output logic [4:0]  rob_retire1_waddr,
    output logic [31:0] rob_retire1_wdata,
    output logic        retire1_release_en,
    output logic [5:0]  retire1_release_prd,
    // Precise exception: ROB head has exception → redirect to mtvec
    output logic        trap_redirect,
    output logic [31:0] trap_redirect_pc,
    output logic [31:0] trap_redirect_cause,
    // Squash release: one-hot mask of prds freed by younger squash (for PRF free-list return)
    output logic [63:0] squash_release_mask,
    // Conservative in-use mask for PRF allocation. Keep allocated destinations
    // and old mappings live while the owning ROB entry is still precise state.
    output logic [63:0] rob_prd_inuse_mask,
    // Exception writeback (from EX stage)
    input  logic        exception_en,
    input  logic [3:0]  exception_cause,
    input  logic [5:0]  exception_prd,
    input  logic [$clog2(ROB_DEPTH):0] exception_rob_ptr
);

    localparam int unsigned PTR_W = $clog2(ROB_DEPTH);

    typedef struct packed {
        logic        valid;
        logic        done;
        logic [31:0] pc;
        logic [31:0] inst;
        logic        regwrite;
        logic [4:0]  rd;
        logic [31:0] wdata;
        logic [5:0]  old_prd;  // old phys reg to release at commit
        logic [5:0]  prd;      // phys destination reg (for OoO wb match)
        logic [3:0]  exception;
    } rob_e_t;

    // Exception writeback is handled in the always_ff via exception_en port.

    rob_e_t q [0:ROB_DEPTH-1];
    logic [PTR_W:0] head, tail;
    logic                       release_scan_active;
    logic [PTR_W:0] release_scan_cur;
    logic [PTR_W:0] release_scan_tail;
`ifndef SYNTHESIS
    localparam logic [5:0] DBG_PRD = 6'd40;
`endif

    wire [PTR_W-1:0] h_idx = head[PTR_W-1:0];
    wire [PTR_W-1:0] t_idx = tail[PTR_W-1:0];
    wire [PTR_W-1:0] release_scan_idx = release_scan_cur[PTR_W-1:0];
    wire [PTR_W:0] release_scan_next = release_scan_cur + 1'b1;
    assign squash_busy = release_scan_active;
    // Occupancy in tag space; redirect must lie in [head, tail) or squash would move tail past the real frontier.
    wire [PTR_W:0] rob_occ = tail - head;
    wire squash_rob_ptr_in_window = (squash_rob_ptr - head) < rob_occ;
    assign alloc_rob_ptr = tail;
    assign alloc1_rob_ptr = tail + 1'b1;
    assign rob_tail_tag = tail;
    assign rob_head_tag = head;
    assign rob_empty = (head == tail);
    assign rob_full  = (tail[$clog2(ROB_DEPTH)] ^ head[$clog2(ROB_DEPTH)])
                    && (t_idx == h_idx);
    assign rob_full_dual = rob_full
        || (tail[$clog2(ROB_DEPTH)] == head[$clog2(ROB_DEPTH)]
            && ((t_idx + 1) % ROB_DEPTH == h_idx));

    wire wb_ptr_in_window  = ((wb_rob_ptr  - head) < rob_occ);
    wire wb2_ptr_in_window = ((wb2_rob_ptr - head) < rob_occ);
    wire wb3_ptr_in_window = ((wb3_rob_ptr - head) < rob_occ);
    wire exception_ptr_in_window = ((exception_rob_ptr - head) < rob_occ);
    wire [PTR_W-1:0] wb_idx  = wb_rob_ptr[PTR_W-1:0];
    wire [PTR_W-1:0] wb2_idx = wb2_rob_ptr[PTR_W-1:0];
    wire [PTR_W-1:0] wb3_idx = wb3_rob_ptr[PTR_W-1:0];
    wire [PTR_W-1:0] exception_idx = exception_rob_ptr[PTR_W-1:0];

    assign wb_accept  = wb_en  && (wb_prd  != 6'd0) && wb_ptr_in_window
        && q[wb_idx].valid  && !q[wb_idx].done  && (q[wb_idx].prd  == wb_prd);
    assign wb2_accept = wb2_en && (wb2_prd != 6'd0) && wb2_ptr_in_window
        && q[wb2_idx].valid && !q[wb2_idx].done && (q[wb2_idx].prd == wb2_prd);
    assign wb3_accept = wb3_en && (wb3_prd != 6'd0) && wb3_ptr_in_window
        && q[wb3_idx].valid && !q[wb3_idx].done && (q[wb3_idx].prd == wb3_prd);

    always_comb begin
        rob_prd_inuse_mask = '0;
        for (int i = 0; i < ROB_DEPTH; i++) begin
            if (q[i].valid) begin
                if (q[i].prd != 6'd0)
                    rob_prd_inuse_mask[q[i].prd] = 1'b1;
                if (q[i].old_prd != 6'd0)
                    rob_prd_inuse_mask[q[i].old_prd] = 1'b1;
            end
        end
    end

    // PRF/RAT must only free mappings when ROB drops the matching tail entry(s). A dual retract
    // request can fall back to a single pop (youngest only), in which case only that slot's prd
    // may be retracted.
    always_comb begin
        retract_ack0 = 1'b0;
        retract_ack1 = 1'b0;
        if (retract_en && (tail != head)) begin
            automatic logic [$clog2(ROB_DEPTH)-1:0] t_m1 = (t_idx + ROB_DEPTH - 1) % ROB_DEPTH;
            automatic logic [$clog2(ROB_DEPTH)-1:0] t_m2 = (t_idx + ROB_DEPTH - 2) % ROB_DEPTH;
            if (retract_dual
                && (t_m1 != h_idx) && (t_m2 != h_idx)
                && q[t_m1].valid && !q[t_m1].done
                && q[t_m2].valid && !q[t_m2].done) begin
                retract_ack0 = retract0_req;
                retract_ack1 = retract1_req;
            end else if (retract_dual && (t_m1 != h_idx) && q[t_m1].valid && !q[t_m1].done
                       && (t_m2 == h_idx)) begin
                // slot0 at head protected, only ack slot1
                retract_ack1 = retract1_req;
            end else if ((t_m1 != h_idx) && q[t_m1].valid && !q[t_m1].done) begin
                if (retract_dual) begin
                    retract_ack1 = retract1_req;
                end else if (retract1_req && !retract0_req) begin
                    retract_ack1 = 1'b1;
                end else if (retract0_req && !retract1_req) begin
                    retract_ack0 = 1'b1;
                end
            end
        end
    end

    assign rob_retire_valid    = !rob_empty && q[h_idx].valid && q[h_idx].done;
    assign rob_retire_arch_valid = rob_retire_valid && (q[h_idx].exception == 4'd0);
    assign rob_retire_pc       = q[h_idx].pc;
    assign rob_retire_inst     = q[h_idx].inst;
    assign rob_retire_regwrite = q[h_idx].regwrite;
    assign rob_retire_waddr    = q[h_idx].rd;
    assign rob_retire_wdata    = q[h_idx].wdata;

    wire [$clog2(ROB_DEPTH)-1:0] h1_idx = (h_idx + 1) % ROB_DEPTH;
    wire squash_head_same_cycle = squash_en && squash_rob_ptr_in_window
        && (squash_rob_ptr == head)
        && pop_en && !rob_empty && q[h_idx].valid && q[h_idx].done;
    wire retire1_can_pop = !squash_head_same_cycle
        && !rob_empty && q[h_idx].valid && q[h_idx].done
        && (q[h_idx].exception == 4'd0)
        && q[h1_idx].valid && q[h1_idx].done
        && (q[h1_idx].exception == 4'd0);
    assign rob_retire1_valid    = retire1_can_pop;
    assign rob_retire1_arch_valid = rob_retire1_valid
        && (q[h_idx].exception == 4'd0) && (q[h1_idx].exception == 4'd0);
    assign rob_retire1_pc       = q[h1_idx].pc;
    assign rob_retire1_inst     = q[h1_idx].inst;
    assign rob_retire1_regwrite = q[h1_idx].regwrite;
    assign rob_retire1_waddr    = q[h1_idx].rd;
    assign rob_retire1_wdata    = q[h1_idx].wdata;
    wire exception_flush_now = pop_en && !rob_empty && q[h_idx].valid && q[h_idx].done
        && (q[h_idx].exception != 4'd0);

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            head <= '0;
            tail <= '0;
            retire_release_en <= 1'b0;
            retire_release_prd <= '0;
            retire1_release_en <= 1'b0;
            retire1_release_prd <= '0;
            trap_redirect <= 1'b0;
            trap_redirect_pc <= '0;
            trap_redirect_cause <= '0;
            squash_release_mask <= '0;
            release_scan_active <= 1'b0;
            release_scan_cur <= '0;
            release_scan_tail <= '0;
            for (int i = 0; i < ROB_DEPTH; i++)
                q[i] <= '0;
        end else begin
            retire_release_en <= 1'b0;
            retire1_release_en <= 1'b0;
            trap_redirect <= 1'b0;
            trap_redirect_cause <= '0;
            squash_release_mask <= '0;

            if (release_scan_active) begin
                if (q[release_scan_idx].valid && (q[release_scan_idx].prd != 6'd0))
                    squash_release_mask[q[release_scan_idx].prd] <= 1'b1;
                q[release_scan_idx].valid <= 1'b0;
                if (release_scan_next == release_scan_tail) begin
                    release_scan_active <= 1'b0;
                end else begin
                    release_scan_cur <= release_scan_next;
                end
            end

            // Pop head when it was valid, done, and retiring
            if (pop_en && !rob_empty && q[h_idx].valid && q[h_idx].done) begin
                if (q[h_idx].exception != 0) begin
                    // Precise exception: redirect to mtvec, flush ROB
`ifndef SYNTHESIS
                    if ($test$plusargs("ROB_DBG"))
                        $display("[ROB_FLUSH] exception_flush t=%0t head=%0d tail=%0d h(pc/inst/prd/exc)=%08x/%08x/%0d/%0d",
                                 $time, head, tail, q[h_idx].pc, q[h_idx].inst, q[h_idx].prd, q[h_idx].exception);
`endif
                    trap_redirect <= 1'b1;
                    trap_redirect_pc <= q[h_idx].pc;
                    trap_redirect_cause <= {28'd0, q[h_idx].exception};
                    release_scan_active <= (tail != head);
                    release_scan_cur    <= head;
                    release_scan_tail   <= tail;
                    head <= 0; tail <= 0;
                end else begin
                    retire_release_en  <= 1'b1;
                    // Regwrite + arch rd!=0: release superseded old mapping; otherwise release completion tag (prd).
                    // jal/lw with rd=x0 still allocates a phys tag — old_prd comes from table[0]==0, so must release prd.
                    retire_release_prd <= (q[h_idx].regwrite && (q[h_idx].rd != 5'd0)) ? q[h_idx].old_prd
                                                                                         : q[h_idx].prd;
                    q[h_idx].valid <= 1'b0;
                    if (retire1_can_pop) begin
                        retire1_release_en  <= 1'b1;
                        retire1_release_prd <= (q[h1_idx].regwrite && (q[h1_idx].rd != 5'd0))
                             ? q[h1_idx].old_prd
                             : q[h1_idx].prd;
                        q[h1_idx].valid <= 1'b0;
                        head <= head + 2;
                    end else begin
                        head <= head + 1'b1;
                    end
                end
            end

            if (!exception_flush_now) begin
            // Retract speculative tail (no matching IQ entry) — must run before alloc in same cycle
            if (retract_en && (tail != head)) begin
                automatic logic [$clog2(ROB_DEPTH)-1:0] t_m1 = (t_idx + ROB_DEPTH - 1) % ROB_DEPTH;
                automatic logic [$clog2(ROB_DEPTH)-1:0] t_m2 = (t_idx + ROB_DEPTH - 2) % ROB_DEPTH;
                // Conservative retract: only reclaim entries that are still speculative
                // (valid && !done), so we don't punch holes into committed/older entries.
                if (retract_dual
                    && (t_m1 != h_idx) && (t_m2 != h_idx)
                    && q[t_m1].valid && !q[t_m1].done
                    && q[t_m2].valid && !q[t_m2].done) begin
                    q[t_m1].valid <= 1'b0;
                    q[t_m2].valid <= 1'b0;
                    tail <= tail - 2;
                end else if (retract_dual && (t_m1 != h_idx) && q[t_m1].valid && !q[t_m1].done
                           && (t_m2 == h_idx)) begin
                    // slot0 is at head (protected), slot1 is at head+1: reclaim slot1 only.
                    // Head entry will be handled by pop or self-heal. Only ack slot1 for PRF/RAT.
                    q[t_m1].valid <= 1'b0;
                    tail <= tail - 1'b1;
                end else if ((t_m1 != h_idx) && q[t_m1].valid && !q[t_m1].done) begin
                    q[t_m1].valid <= 1'b0;
                    tail <= tail - 1'b1;
                end
            end

            // Younger squash on redirect/mispredict: remove entries after redirecting instruction.
            if (squash_en && (tail != head) && squash_rob_ptr_in_window) begin
                automatic logic [PTR_W:0] first_young;
                automatic logic [PTR_W:0] young_count;
                first_young = squash_rob_ptr + 1'b1;
                young_count = tail - first_young;

                // Clear younger entries immediately. The older release-scan
                // approach could leave tail moved behind head while it was
                // still invalidating stale entries, creating ROB head holes
                // on tight taken-branch loops.
                release_scan_active <= 1'b0;
                release_scan_cur    <= '0;
                release_scan_tail   <= '0;
                for (int off = 0; off < ROB_DEPTH; off++) begin
                    if (off[PTR_W:0] < young_count) begin
                        automatic logic [PTR_W:0] drop_tag;
                        automatic logic [PTR_W-1:0] drop_idx;
                        drop_tag = first_young + off[PTR_W:0];
                        drop_idx = drop_tag[PTR_W-1:0];
                        if (q[drop_idx].valid && (q[drop_idx].prd != 6'd0))
                            squash_release_mask[q[drop_idx].prd] <= 1'b1;
                        q[drop_idx].valid <= 1'b0;
                    end
                end
                tail <= first_young;
            end

            // Alloc: 1 or 2 entries at tail
            if (alloc_en && !rob_full) begin
                q[t_idx].valid    <= 1'b1;
                q[t_idx].done     <= 1'b0;
                q[t_idx].pc       <= alloc_pc;
                q[t_idx].inst     <= alloc_inst;
                q[t_idx].regwrite <= alloc_regwrite;
                q[t_idx].rd       <= alloc_rd;
                q[t_idx].wdata    <= '0;
                q[t_idx].old_prd  <= alloc_old_prd;
                q[t_idx].prd      <= alloc_prd;
                q[t_idx].exception <= '0;
                if (alloc1_en && !rob_full_dual) begin
                    automatic logic [$clog2(ROB_DEPTH)-1:0] t1 = (t_idx + 1) % ROB_DEPTH;
                    q[t1].valid    <= 1'b1;
                    q[t1].done     <= 1'b0;
                    q[t1].pc       <= alloc1_pc;
                    q[t1].inst     <= alloc1_inst;
                    q[t1].regwrite <= alloc1_regwrite;
                    q[t1].rd       <= alloc1_rd;
                    q[t1].wdata    <= '0;
                    q[t1].old_prd  <= alloc1_old_prd;
                    q[t1].prd      <= alloc1_prd;
                    q[t1].exception <= '0;
                    tail <= tail + 2;
                end else begin
                    tail <= tail + 1'b1;
                end
            end

            // Writeback: complete only the exact ROB entry that produced this result.
            if (wb_accept) begin
                q[wb_idx].done  <= 1'b1;
                q[wb_idx].wdata <= wb_wdata;
`ifndef SYNTHESIS
                if ($test$plusargs("PRDTRACE") && wb_prd == DBG_PRD)
                    $display("[ROB%0d] wb0_hit t=%0t idx=%0d pc=0x%08x inst=0x%08x",
                             DBG_PRD, $time, wb_idx, q[wb_idx].pc, q[wb_idx].inst);
`endif
            end
`ifndef SYNTHESIS
            else if ($test$plusargs("PRDTRACE") && wb_en && wb_prd == DBG_PRD) begin
                $display("[ROB%0d] wb0_stale t=%0t ptr=%0d head/tail=%0d/%0d",
                         DBG_PRD, $time, wb_rob_ptr, head, tail);
            end
`endif
            if (wb2_accept) begin
                q[wb2_idx].done  <= 1'b1;
                q[wb2_idx].wdata <= wb2_wdata;
`ifndef SYNTHESIS
                if ($test$plusargs("PRDTRACE") && wb2_prd == DBG_PRD)
                    $display("[ROB%0d] wb1_hit t=%0t idx=%0d pc=0x%08x inst=0x%08x",
                             DBG_PRD, $time, wb2_idx, q[wb2_idx].pc, q[wb2_idx].inst);
`endif
            end
`ifndef SYNTHESIS
            else if ($test$plusargs("PRDTRACE") && wb2_en && wb2_prd == DBG_PRD) begin
                $display("[ROB%0d] wb1_stale t=%0t ptr=%0d head/tail=%0d/%0d",
                         DBG_PRD, $time, wb2_rob_ptr, head, tail);
            end
`endif
            if (wb3_accept) begin
                q[wb3_idx].done  <= 1'b1;
                q[wb3_idx].wdata <= wb3_wdata;
`ifndef SYNTHESIS
                if ($test$plusargs("PRDTRACE") && wb3_prd == DBG_PRD)
                    $display("[ROB%0d] wb2_hit t=%0t idx=%0d pc=0x%08x inst=0x%08x",
                             DBG_PRD, $time, wb3_idx, q[wb3_idx].pc, q[wb3_idx].inst);
`endif
            end
`ifndef SYNTHESIS
            else if ($test$plusargs("PRDTRACE") && wb3_en && wb3_prd == DBG_PRD) begin
                $display("[ROB%0d] wb2_stale t=%0t ptr=%0d head/tail=%0d/%0d",
                         DBG_PRD, $time, wb3_rob_ptr, head, tail);
            end
`endif

            // Exception: mark only the exact producer entry; stale wrong-path exceptions are ignored.
            if (exception_en) begin
                logic exc_marked;
                exc_marked = 1'b0;
                if (exception_prd != 6'd0 && exception_ptr_in_window
                    && q[exception_idx].valid && !q[exception_idx].done
                    && (q[exception_idx].prd == exception_prd)) begin
                    q[exception_idx].exception <= exception_cause;
                    q[exception_idx].done      <= 1'b1;
                    q[exception_idx].wdata     <= '0;
                    exc_marked = 1'b1;
                end
`ifndef SYNTHESIS
                if (!exc_marked)
                    $error("cpu_rob: exception_en unmatched ptr=%0d prd=%0d cause=%0d head=%0d tail=%0d",
                           exception_rob_ptr, exception_prd, exception_cause, head, tail);
`endif
            end
            end
        end
    end

`ifndef SYNTHESIS
    int unsigned dbg_head_done_streak;
    int unsigned dbg_wb_match_cnt;
    int unsigned dbg_pop_cnt;
    int unsigned dbg_wb_nomatch_streak;
    int unsigned dbg_head_wait_streak;
    int unsigned dbg_prd37_trace_cnt;
    int unsigned dbg_head_hole_cnt;
    // Head-hole check: main FSM may heal head same cycle; one-shot invalid@head is often transient.
    // Flag persistent hole (invalid head while non-empty for 2+ consecutive sampled cycles) as hard fail.
    logic        dbg_head_hole_prev;
    logic wb_hit, wb2_hit, wb3_hit;
    always_comb begin
        wb_hit  = wb_accept;
        wb2_hit = wb2_accept;
        wb3_hit = wb3_accept;
    end
    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn)
            dbg_head_hole_prev <= 1'b0;
        else
            dbg_head_hole_prev <= !rob_empty && !q[h_idx].valid;
    end
    always_ff @(posedge pl_clk) begin
        if (pl_resetn) begin
            if (dbg_head_hole_prev && !rob_empty && !q[h_idx].valid) begin
                dbg_head_hole_cnt <= dbg_head_hole_cnt + 1;
                if (dbg_head_hole_cnt < 64) begin
                    $error("cpu_rob: persistent head hole (2+ cycles) head=%0d tail=%0d h1(v/d/prd/pc)= %0b/%0b/%0d/0x%08x",
                           head, tail, q[h1_idx].valid, q[h1_idx].done, q[h1_idx].prd, q[h1_idx].pc);
                end
            end
            if (rob_retire_valid)
                dbg_pop_cnt <= dbg_pop_cnt + (rob_retire1_valid ? 2 : 1);
            if ($test$plusargs("PRDTRACE") && (dbg_prd37_trace_cnt < 256)) begin
                if (alloc_en && alloc_prd == DBG_PRD)
                    begin dbg_prd37_trace_cnt <= dbg_prd37_trace_cnt + 1;
                    $display("[ROB%0d] alloc0 t=%0t head/tail=%0d/%0d pc=0x%08x inst=0x%08x", DBG_PRD, $time, head, tail, alloc_pc, alloc_inst); end
                if (alloc1_en && alloc1_prd == DBG_PRD)
                    begin dbg_prd37_trace_cnt <= dbg_prd37_trace_cnt + 1;
                    $display("[ROB%0d] alloc1 t=%0t head/tail=%0d/%0d pc=0x%08x inst=0x%08x", DBG_PRD, $time, head, tail, alloc1_pc, alloc1_inst); end
                if ((wb_en && wb_prd == DBG_PRD) || (wb2_en && wb2_prd == DBG_PRD) || (wb3_en && wb3_prd == DBG_PRD))
                    begin dbg_prd37_trace_cnt <= dbg_prd37_trace_cnt + 1;
                    $display("[ROB%0d] wb t=%0t wb0=%0b/%0d wb1=%0b/%0d wb2=%0b/%0d h(v/d/prd)=%0b/%0b/%0d",
                             DBG_PRD, $time, wb_en, wb_prd, wb2_en, wb2_prd, wb3_en, wb3_prd, q[h_idx].valid, q[h_idx].done, q[h_idx].prd); end
                if (retire_release_en && retire_release_prd == DBG_PRD)
                    begin dbg_prd37_trace_cnt <= dbg_prd37_trace_cnt + 1;
                    $display("[ROB%0d] release0 t=%0t head/tail=%0d/%0d", DBG_PRD, $time, head, tail); end
                if (retire1_release_en && retire1_release_prd == DBG_PRD)
                    begin dbg_prd37_trace_cnt <= dbg_prd37_trace_cnt + 1;
                    $display("[ROB%0d] release1 t=%0t head/tail=%0d/%0d", DBG_PRD, $time, head, tail); end
                if (!rob_empty && q[h_idx].valid && !q[h_idx].done && q[h_idx].prd == DBG_PRD && ((dbg_head_wait_streak % 1000) == 0))
                    begin dbg_prd37_trace_cnt <= dbg_prd37_trace_cnt + 1;
                    $display("[ROB%0d] head_wait t=%0t wait=%0d head=%0d tail=%0d pc=0x%08x inst=0x%08x",
                             DBG_PRD, $time, dbg_head_wait_streak, head, tail, q[h_idx].pc, q[h_idx].inst); end
            end
            if ((wb_en && wb_prd != 6'd0) || (wb2_en && wb2_prd != 6'd0) || (wb3_en && wb3_prd != 6'd0))
                dbg_wb_match_cnt <= dbg_wb_match_cnt
                    + ((wb_en && wb_prd != 6'd0) ? 1 : 0)
                    + ((wb2_en && wb2_prd != 6'd0) ? 1 : 0)
                    + ((wb3_en && wb3_prd != 6'd0) ? 1 : 0);
            if (((wb_en && wb_prd != 6'd0) && !wb_hit) ||
                ((wb2_en && wb2_prd != 6'd0) && !wb2_hit) ||
                ((wb3_en && wb3_prd != 6'd0) && !wb3_hit)) begin
                dbg_wb_nomatch_streak <= dbg_wb_nomatch_streak + 1;
            end else begin
                dbg_wb_nomatch_streak <= 0;
            end
            dbg_head_done_streak <= (rob_retire_valid ? 0 :
                ((!rob_empty && q[h_idx].valid && q[h_idx].done) ? (dbg_head_done_streak + 1) : 0));
            dbg_head_wait_streak <= (!rob_empty && q[h_idx].valid && !q[h_idx].done) ? (dbg_head_wait_streak + 1) : 0;
            if (dbg_head_done_streak == 32'd10000) begin
                $error("cpu_rob: head.done stuck >10000 cycles without retire pop (head=%0d tail=%0d wb_cnt=%0d pop_cnt=%0d)",
                       head, tail, dbg_wb_match_cnt, dbg_pop_cnt);
            end
            if (dbg_head_wait_streak == 32'd10000) begin
                $error("cpu_rob: head waiting >10000 cycles head v/d/exc/prd/pc= %0b/%0b/%0d/%0d/0x%08x tail=%0d",
                       q[h_idx].valid, q[h_idx].done, q[h_idx].exception, q[h_idx].prd, q[h_idx].pc, tail);
            end
            if ($test$plusargs("ROB_DBG") && (dbg_head_wait_streak % 50000) == 0 && dbg_head_wait_streak != 0) begin
                $display("[ROB_HEAD] wait=%0d head=%0d tail=%0d h(v/d/exc/prd/pc/inst)=%0b/%0b/%0d/%0d/0x%08x/0x%08x h1(v/d/prd/pc)=%0b/%0b/%0d/0x%08x pop=%0b r0=%0b r1=%0b wb=%0b/%0d wb2=%0b/%0d wb3=%0b/%0d",
                         dbg_head_wait_streak, head, tail,
                         q[h_idx].valid, q[h_idx].done, q[h_idx].exception, q[h_idx].prd, q[h_idx].pc, q[h_idx].inst,
                         q[h1_idx].valid, q[h1_idx].done, q[h1_idx].prd, q[h1_idx].pc,
                         pop_en, rob_retire_valid, rob_retire1_valid,
                         wb_en, wb_prd, wb2_en, wb2_prd, wb3_en, wb3_prd);
            end
            if (dbg_wb_nomatch_streak == 32'd10000) begin
                $error("cpu_rob: wb prd cannot match any pending entry for >10000 cycles");
            end
            if (wb_en && wb2_en && wb_prd != 6'd0 && wb_prd == wb2_prd)
                $error("cpu_rob: wb and wb2 same prd");
            if (wb_en && wb3_en && wb_prd != 6'd0 && wb_prd == wb3_prd)
                $error("cpu_rob: wb and wb3 same prd");
            if (wb2_en && wb3_en && wb2_prd != 6'd0 && wb2_prd == wb3_prd)
                $error("cpu_rob: wb2 and wb3 same prd");
            // Pending ROB entries must not share the same prd (wb would hit the wrong entry).
            begin
                static int unsigned dbg_dup_prd_reports = 0;
                if (dbg_dup_prd_reports < 64) begin
                    automatic logic dup_found = 1'b0;
                    for (int ii = 0; !dup_found && ii < ROB_DEPTH; ii++) begin
                        if (q[ii].valid && !q[ii].done && q[ii].prd != 6'd0) begin
                            for (int jj = ii + 1; !dup_found && jj < ROB_DEPTH; jj++) begin
                                if (q[jj].valid && !q[jj].done && q[jj].prd == q[ii].prd) begin
                                    $error("cpu_rob: duplicate pending prd=%0d idx=%0d/%0d pc=0x%08x/0x%08x",
                                           q[ii].prd, ii, jj, q[ii].pc, q[jj].pc);
                                    dbg_dup_prd_reports++;
                                    dup_found = 1'b1;
                                end
                            end
                        end
                    end
                end
            end
        end else begin
            dbg_head_done_streak <= 0;
            dbg_wb_match_cnt <= 0;
            dbg_pop_cnt <= 0;
            dbg_wb_nomatch_streak <= 0;
            dbg_head_wait_streak <= 0;
            dbg_prd37_trace_cnt <= 0;
            dbg_head_hole_cnt <= 0;
        end
    end
`endif

endmodule
