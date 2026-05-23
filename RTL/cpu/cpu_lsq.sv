// Load/Store Queue — multi-entry FIFO for in-flight memory operations.
// LSQ_DEPTH >= 1: accepts 0-2 ops/cycle (slot0 + slot1), issues 1/cycle to memory.
// In-order issue/response: head entry sent to D$, response completes head, head advances.
// Forwarding & replay deferred to later phases.

module cpu_lsq #(
    parameter int unsigned LSQ_DEPTH = 1
) (
    input  logic        pl_clk, input  logic        pl_resetn,
    // Slot 0 memory request
    input  logic        mem_req_valid, input  logic [31:0] mem_req_addr,
    input  logic [2:0]  mem_req_cmd,   input  logic [2:0]  mem_req_size,
    input  logic [31:0] mem_req_wdata, input  logic [3:0]  mem_req_wstrb,
    input  logic [4:0]  mem_req_amo_funct, input  logic mem_req_amo_aq, input  logic mem_req_amo_rl,
    input  logic        mem_req_is_load, input  logic mem_req_is_amo,
    input  logic [4:0]  mem_req_rd,    input  logic        mem_req_regwrite,
    input  logic [5:0]  mem_req_prd,
    // D-port (to memory)
    output logic        d_req_valid,   input  logic        d_req_ready,
    output logic [31:0] d_req_addr,    output logic [2:0]  d_req_cmd,
    output logic [2:0]  d_req_size,    output logic [31:0] d_req_wdata,
    output logic [3:0]  d_req_wstrb,   output logic [4:0]  d_req_amo_funct,
    output logic        d_req_amo_aq,  output logic        d_req_amo_rl,
    input  logic        d_resp_valid,  input  logic [31:0] d_resp_rdata,
    input  logic        d_resp_err,
    // WB output
    output logic        memwb_valid,   output logic [31:0] memwb_pc,
    output logic [31:0] memwb_inst,    output logic [4:0]  memwb_rd,
    output logic [5:0]  memwb_prd,
    output logic [5:0]  memwb_rob_ptr,
    output logic        memwb_regwrite,output logic [31:0] memwb_wdata,
    output logic [2:0]  memwb_load_funct3, output logic memwb_is_fp_load,
    output logic        memwb_is_amo,
    // Slot 0 snapshot
    input  logic [31:0] snap_pc,       input  logic [31:0] snap_inst,
    input  logic [2:0]  snap_load_funct3, input logic snap_is_fp_load,
    input  logic [5:0]  snap_rob_ptr,
    // Slot 1 memory request
    input  logic        mem_req1_valid,
    input  logic [31:0] mem_req1_addr, input  logic [2:0] mem_req1_cmd,
    input  logic [2:0]  mem_req1_size, input  logic [31:0] mem_req1_wdata,
    input  logic [3:0]  mem_req1_wstrb,
    input  logic        mem_req1_is_load, input  logic mem_req1_is_store,
    input  logic [4:0]  mem_req1_rd,    input  logic        mem_req1_regwrite,
    input  logic [5:0]  mem_req1_prd,
    output logic        d_req1_valid,  input  logic        d_req1_ready,
    output logic [31:0] d_req1_addr,   output logic [2:0]  d_req1_cmd,
    output logic [2:0]  d_req1_size,   output logic [31:0] d_req1_wdata,
    output logic [3:0]  d_req1_wstrb,
    input  logic        d_resp1_valid, input  logic [31:0] d_resp1_rdata,
    input  logic        d_resp1_err,
    input  logic [31:0] snap1_pc,      input  logic [31:0] snap1_inst,
    input  logic [2:0]  snap1_load_funct3, input logic snap1_is_fp_load,
    input  logic [5:0]  snap1_rob_ptr,
    input  logic [5:0]  alloc_rob_idx,
    output logic        replay_valid,  output logic [5:0] replay_rob_idx,
    output logic [31:0] replay_pc,
    output logic        lsq_empty_o,
    output logic        lsq_idle_o,
    output logic        lsq_full_o,
    output logic        lsq_resp_pending_o,
    output logic        stall_mem,
    output logic        mem_fault_redirect,
    output logic [31:0] mem_fault_mepc,
    output logic [31:0] mem_fault_mcause,
    output logic [5:0]  mem_fault_prd,
    output logic [5:0]  mem_fault_rob_ptr
);

    localparam int unsigned PTR_W = (LSQ_DEPTH == 1) ? 1 : $clog2(LSQ_DEPTH);
    localparam logic [2:0] SZ_1B = 3'd0;
    localparam logic [2:0] SZ_2B = 3'd1;
    localparam logic [2:0] SZ_4B = 3'd2;

    function automatic logic align_bad(input logic [31:0] addr, input logic [2:0] size);
        unique case (size)
            SZ_1B: align_bad = 1'b0;
            SZ_2B: align_bad = addr[0];
            SZ_4B: align_bad = (addr[1:0] != 2'b00);
            default: align_bad = 1'b1;
        endcase
    endfunction

    typedef struct packed {
        logic        valid;
        logic [31:0] addr;
        logic [2:0]  cmd;
        logic [2:0]  size;
        logic [31:0] wdata;
        logic [3:0]  wstrb;
        logic [4:0]  amo_funct;
        logic        amo_aq, amo_rl;
        logic        is_load, is_amo;
        logic [4:0]  rd;
        logic [5:0]  prd;
        logic [5:0]  rob_ptr;
        logic        regwrite;
        logic [31:0] pc, inst;
        logic [2:0]  load_funct3;
        logic        is_fp_load;
    } lsq_entry_t;

    lsq_entry_t entries [0:LSQ_DEPTH-1];
    logic [PTR_W:0] head_q, tail_q;
    logic           resp_pending_q;

    wire [PTR_W:0] alloc_cnt = tail_q - head_q;
    wire           lsq_empty = (head_q == tail_q);
    wire           lsq_full  = (alloc_cnt >= LSQ_DEPTH[PTR_W:0]);
    wire           free_cnt_is1 = (alloc_cnt == (LSQ_DEPTH[PTR_W:0] - 1'b1));

    wire [PTR_W-1:0] head_idx = head_q[PTR_W-1:0];
    wire [PTR_W-1:0] head_next_idx = (head_idx + 1'd1) & (LSQ_DEPTH - 1);
    wire [PTR_W-1:0] tail_idx = tail_q[PTR_W-1:0];
    wire [PTR_W-1:0] tail1_idx = (tail_idx + 1'd1) & (LSQ_DEPTH - 1);
    wire             head_align_bad = !lsq_empty && align_bad(entries[head_idx].addr, entries[head_idx].size);

    wire accept_slot0 = mem_req_valid && !lsq_full;
    wire accept_slot1 = mem_req1_valid && !lsq_full && !(accept_slot0 && free_cnt_is1);
    wire d_req_fire   = d_req_valid && d_req_ready;

    logic [PTR_W:0] tail_advance;
    always_comb begin
        tail_advance = '0;
        if (accept_slot0) tail_advance = tail_advance + 1'b1;
        if (accept_slot1) tail_advance = tail_advance + 1'b1;
    end

    assign stall_mem = lsq_full || (free_cnt_is1 && mem_req_valid && mem_req1_valid);
    assign lsq_empty_o = lsq_empty;
    assign lsq_idle_o  = lsq_empty && !resp_pending_q && !d_req_valid;
    assign lsq_full_o  = lsq_full;
    assign lsq_resp_pending_o = resp_pending_q;

    wire slot0_is_store = mem_req_valid && !mem_req_is_load && !mem_req_is_amo;
    wire slot1_is_store = mem_req1_valid &&  mem_req1_is_store;
    wire [31:0] slot0_store_addr = slot0_is_store ? mem_req_addr : 32'd0;
    wire [31:0] slot1_store_addr = slot1_is_store ? mem_req1_addr : 32'd0;

    logic        replay_detect;
    logic [5:0]  replay_detect_rob_ptr;
    logic [31:0] replay_detect_pc;
    always_comb begin
        replay_detect = 1'b0;
        replay_detect_rob_ptr = '0;
        replay_detect_pc = '0;
        for (int i = 0; i < LSQ_DEPTH; i++) begin
            if (entries[i].valid && entries[i].is_load
                && ((slot0_is_store && entries[i].addr == slot0_store_addr)
                 || (slot1_is_store && entries[i].addr == slot1_store_addr))) begin
                replay_detect = 1'b1;
                replay_detect_rob_ptr = entries[i].rob_ptr;
                replay_detect_pc = entries[i].pc;
            end
        end
    end

    // Keep the BRAM request controls on a timed reset path.
    always_ff @(posedge pl_clk) begin
        if (!pl_resetn) begin
            head_q         <= '0;
            tail_q         <= '0;
            resp_pending_q <= 1'b0;
            d_req_valid    <= 1'b0;
            d_req_addr     <= '0;
            d_req_cmd      <= 3'b001;
            d_req_size     <= 3'd2;
            d_req_wdata    <= '0;
            d_req_wstrb    <= '0;
            d_req_amo_funct<= '0;
            d_req_amo_aq   <= 1'b0;
            d_req_amo_rl   <= 1'b0;
            d_req1_valid   <= 1'b0; d_req1_addr <= '0; d_req1_cmd <= '0; d_req1_size <= '0;
            d_req1_wdata   <= '0; d_req1_wstrb <= '0;
            replay_valid   <= 1'b0; replay_rob_idx <= '0; replay_pc <= '0;
            memwb_valid    <= 1'b0;
            memwb_pc       <= '0;
            memwb_inst     <= '0;
            memwb_rd       <= '0;
            memwb_prd      <= '0;
            memwb_rob_ptr  <= '0;
            memwb_regwrite <= 1'b0;
            memwb_wdata    <= '0;
            memwb_load_funct3 <= '0;
            memwb_is_fp_load  <= 1'b0;
            memwb_is_amo      <= 1'b0;
            mem_fault_redirect <= 1'b0;
            mem_fault_mepc     <= '0;
            mem_fault_mcause   <= '0;
            mem_fault_prd      <= '0;
            mem_fault_rob_ptr  <= '0;
            for (int i = 0; i < LSQ_DEPTH; i++) begin
                entries[i].valid <= 1'b0;
            end
        end else begin
            memwb_valid <= 1'b0;
            mem_fault_redirect <= 1'b0;
            mem_fault_prd      <= '0;
            mem_fault_rob_ptr  <= '0;

            if (accept_slot0) begin
                entries[tail_idx].valid       <= 1'b1;
                entries[tail_idx].addr        <= mem_req_addr;
                entries[tail_idx].cmd         <= mem_req_cmd;
                entries[tail_idx].size        <= mem_req_size;
                entries[tail_idx].wdata       <= mem_req_wdata;
                entries[tail_idx].wstrb       <= mem_req_wstrb;
                entries[tail_idx].amo_funct   <= mem_req_amo_funct;
                entries[tail_idx].amo_aq      <= mem_req_amo_aq;
                entries[tail_idx].amo_rl      <= mem_req_amo_rl;
                entries[tail_idx].is_load     <= mem_req_is_load;
                entries[tail_idx].is_amo      <= mem_req_is_amo;
                entries[tail_idx].rd          <= mem_req_rd;
                entries[tail_idx].prd         <= mem_req_prd;
                entries[tail_idx].rob_ptr     <= snap_rob_ptr;
                entries[tail_idx].regwrite    <= mem_req_regwrite;
                entries[tail_idx].pc          <= snap_pc;
                entries[tail_idx].inst        <= snap_inst;
                entries[tail_idx].load_funct3 <= snap_load_funct3;
                entries[tail_idx].is_fp_load  <= snap_is_fp_load;
`ifndef SYNTHESIS
                if ($test$plusargs("LSQ_DBG")) begin
                    $display("[LSQ_DBG] enq0 t=%0t idx=%0d pc=0x%08x inst=0x%08x prd=%0d rob=%0d addr=0x%08x cmd=%0d rgw=%0b ld=%0b amo=%0b",
                             $time, tail_idx, snap_pc, snap_inst, mem_req_prd, snap_rob_ptr,
                             mem_req_addr, mem_req_cmd, mem_req_regwrite, mem_req_is_load, mem_req_is_amo);
                end
`endif
            end
            if (accept_slot1) begin
                entries[tail1_idx].valid       <= 1'b1;
                entries[tail1_idx].addr        <= mem_req1_addr;
                entries[tail1_idx].cmd         <= mem_req1_cmd;
                entries[tail1_idx].size        <= mem_req1_size;
                entries[tail1_idx].wdata       <= mem_req1_wdata;
                entries[tail1_idx].wstrb       <= mem_req1_wstrb;
                entries[tail1_idx].amo_funct   <= 5'd0;
                entries[tail1_idx].amo_aq      <= 1'b0;
                entries[tail1_idx].amo_rl      <= 1'b0;
                entries[tail1_idx].is_load     <= mem_req1_is_load;
                entries[tail1_idx].is_amo      <= 1'b0;
                entries[tail1_idx].rd          <= mem_req1_rd;
                entries[tail1_idx].prd         <= mem_req1_prd;
                entries[tail1_idx].rob_ptr     <= snap1_rob_ptr;
                entries[tail1_idx].regwrite    <= mem_req1_regwrite;
                entries[tail1_idx].pc          <= snap1_pc;
                entries[tail1_idx].inst        <= snap1_inst;
                entries[tail1_idx].load_funct3 <= snap1_load_funct3;
                entries[tail1_idx].is_fp_load  <= snap1_is_fp_load;
`ifndef SYNTHESIS
                if ($test$plusargs("LSQ_DBG")) begin
                    $display("[LSQ_DBG] enq1 t=%0t idx=%0d pc=0x%08x inst=0x%08x prd=%0d rob=%0d addr=0x%08x cmd=%0d rgw=%0b ld=%0b",
                             $time, tail1_idx, snap1_pc, snap1_inst, mem_req1_prd, snap1_rob_ptr,
                             mem_req1_addr, mem_req1_cmd, mem_req1_regwrite, mem_req1_is_load);
                end
`endif
            end

            if (tail_advance != '0) begin
                tail_q <= tail_q + tail_advance;
            end

            replay_valid   <= replay_detect;
            replay_rob_idx <= replay_detect_rob_ptr;
            replay_pc      <= replay_detect_pc;

            if (d_req_fire) begin
                if (!resp_pending_q && !head_align_bad && (alloc_cnt > {{PTR_W{1'b0}}, 1'b1})) begin
                    d_req_valid     <= 1'b1;
                    d_req_addr      <= entries[head_next_idx].addr;
                    d_req_cmd       <= entries[head_next_idx].cmd;
                    d_req_size      <= entries[head_next_idx].size;
                    d_req_wdata     <= entries[head_next_idx].wdata;
                    d_req_wstrb     <= entries[head_next_idx].wstrb;
                    d_req_amo_funct <= entries[head_next_idx].amo_funct;
                    d_req_amo_aq    <= entries[head_next_idx].amo_aq;
                    d_req_amo_rl    <= entries[head_next_idx].amo_rl;
                end else begin
                    d_req_valid    <= 1'b0;
                end
                resp_pending_q <= 1'b1;
`ifndef SYNTHESIS
                if ($test$plusargs("LSQ_DBG")) begin
                    $display("[LSQ_DBG] fire t=%0t idx=%0d pc=0x%08x prd=%0d rob=%0d addr=0x%08x cmd=%0d",
                             $time, head_idx, entries[head_idx].pc, entries[head_idx].prd,
                             entries[head_idx].rob_ptr, d_req_addr, d_req_cmd);
                end
`endif
            end else if (!resp_pending_q && !d_req_valid && !lsq_empty) begin
                d_req_valid     <= 1'b1;
                d_req_addr      <= entries[head_idx].addr;
                d_req_cmd       <= entries[head_idx].cmd;
                d_req_size      <= entries[head_idx].size;
                d_req_wdata     <= entries[head_idx].wdata;
                d_req_wstrb     <= entries[head_idx].wstrb;
                d_req_amo_funct <= entries[head_idx].amo_funct;
                d_req_amo_aq    <= entries[head_idx].amo_aq;
                d_req_amo_rl    <= entries[head_idx].amo_rl;
            end

            if (resp_pending_q && d_resp_valid) begin
                if (!d_resp_err) begin
                    memwb_valid       <= 1'b1;
                    memwb_pc          <= entries[head_idx].pc;
                    memwb_inst        <= entries[head_idx].inst;
                    memwb_rd          <= entries[head_idx].rd;
                    memwb_prd         <= entries[head_idx].prd;
                    memwb_rob_ptr     <= entries[head_idx].rob_ptr;
                    memwb_regwrite    <= entries[head_idx].regwrite;
                    memwb_wdata       <= d_resp_rdata;
                    memwb_load_funct3 <= entries[head_idx].load_funct3;
                    memwb_is_fp_load  <= entries[head_idx].is_fp_load;
                    memwb_is_amo      <= entries[head_idx].is_amo;
                end else begin
                    mem_fault_redirect <= 1'b1;
                    mem_fault_mepc     <= entries[head_idx].pc;
                    mem_fault_mcause   <= entries[head_idx].is_amo ? 32'd7
                                       : (entries[head_idx].is_load ? 32'd5 : 32'd7);
                    mem_fault_prd      <= entries[head_idx].prd;
                    mem_fault_rob_ptr  <= entries[head_idx].rob_ptr;
                end
`ifndef SYNTHESIS
                if ($test$plusargs("LSQ_DBG")) begin
                    $display("[LSQ_DBG] resp t=%0t idx=%0d pc=0x%08x inst=0x%08x prd=%0d rob=%0d rdata=0x%08x err=%0b rgw=%0b",
                             $time, head_idx, entries[head_idx].pc, entries[head_idx].inst,
                             entries[head_idx].prd, entries[head_idx].rob_ptr, d_resp_rdata, d_resp_err,
                             entries[head_idx].regwrite);
                end
`endif
                entries[head_idx].valid <= 1'b0;
                head_q         <= head_q + 1'b1;
                resp_pending_q <= d_req_fire;
                if (d_req_fire) begin
                    d_req_valid <= 1'b0;
                end else if (!d_resp_err && (alloc_cnt > {{PTR_W{1'b0}}, 1'b1})) begin
                    d_req_valid     <= 1'b1;
                    d_req_addr      <= entries[head_next_idx].addr;
                    d_req_cmd       <= entries[head_next_idx].cmd;
                    d_req_size      <= entries[head_next_idx].size;
                    d_req_wdata     <= entries[head_next_idx].wdata;
                    d_req_wstrb     <= entries[head_next_idx].wstrb;
                    d_req_amo_funct <= entries[head_next_idx].amo_funct;
                    d_req_amo_aq    <= entries[head_next_idx].amo_aq;
                    d_req_amo_rl    <= entries[head_next_idx].amo_rl;
                end
            end
        end
    end

endmodule
