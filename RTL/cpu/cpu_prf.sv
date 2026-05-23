// Physical Register File: wraps arch GPR with phys-reg mapping layer.
// Phase O1: identity mapping (phys_n == arch_n), Free List = all free.
// Ports match an extended cpu_regfile ideal for OoO:
//   - write_port: 1 WB write (phys_dst + data)
//   - read_ports: 2 async reads (phys_src1/2 → data1/2)
//   - free_list: allocate / release interface
module cpu_prf #(
    parameter int unsigned PRF_SIZE  = 68,   // >= 32 arch + spec
    parameter int unsigned DATA_W    = 32
) (
    input  logic        pl_clk,
    input  logic        pl_resetn,

    // === allocate (from RENAME) ===
    input  logic        allocate_en,         // request 1 new phys reg
    input  logic [4:0]  allocate_arch,       // arch reg to re-map (for info only in O1)
    output logic [5:0]  allocate_prd,        // allocated phys reg number (≥32 for spec)
    // Slot 1 allocate (ISSUE_WIDTH=2)
    input  logic        allocate1_en,
    input  logic [4:0]  allocate1_arch,
    output logic [5:0]  allocate1_prd,

    // === release (from COMMIT) ===
    input  logic        release_en,
    input  logic [5:0]  release_prd,
    input  logic        release1_en,
    input  logic [5:0]  release1_prd,
    // Speculative rename undo: return aborted tail tag(s) to free list (paired with RAT revert).
    input  logic        retract_en,
    input  logic [5:0]  retract_prd,
    input  logic        retract1_en,
    input  logic [5:0]  retract1_prd,

    // Squash release: one-hot mask of prds to return to free list on younger squash
    input  logic [63:0] squash_release_mask,
    // Delayed by 1 cycle: prevents same-cycle writeback aliasing with reallocated prd
    input  logic [63:0] squash_release_mask_d1,
    // Conservative live mask from ROB/RAT. A free-list bit may be stale after a
    // squash/retract corner, so allocation must never reuse an externally live prd.
    input  logic [63:0] inuse_prd_mask,

    // === write ports ===
    input  logic        we,                  // WB write enable
    input  logic [5:0]  waddr,              // WB phys reg
    input  logic [31:0] wdata,
    input  logic        we1,
    input  logic [5:0]  waddr1,
    input  logic [31:0] wdata1,

    // === read ports (async) ===
    input  logic [5:0]  raddr1,
    input  logic [5:0]  raddr2,
    output logic [31:0] rdata1,
    output logic [31:0] rdata2,
    // Slot 1 read ports (ISSUE_WIDTH=2)
    input  logic [5:0]  raddr3,
    input  logic [5:0]  raddr4,
    output logic [31:0] rdata3,
    output logic [31:0] rdata4
);
    localparam int unsigned PRD_ADDRABLE = 64;
    localparam int unsigned PRF_SCAN_MAX = (PRF_SIZE < PRD_ADDRABLE) ? PRF_SIZE : PRD_ADDRABLE;

    logic [31:0] x [0:PRF_SIZE-1];
    integer i;

    // Free List over the full physical namespace except x0. Arch identity PRDs become
    // reusable after their architectural mapping is superseded and committed.
    logic [PRF_SIZE-1:0] free_bits;
    logic [5:0]          next_free;
    logic [5:0]          allocated, allocated1;

    always_comb begin
        allocated = 6'd0;
        for (int i = 1; i < PRF_SCAN_MAX; i++) begin
            if (free_bits[i] && !inuse_prd_mask[i]) begin allocated = 6'(i); break; end
        end
        allocated1 = 6'd0;
        for (int i = 1; i < PRF_SCAN_MAX; i++) begin
            // Skip the phys reg already taken by slot 0
            if (free_bits[i] && !inuse_prd_mask[i] && (i != allocated)) begin
                allocated1 = 6'(i); break;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (PRF_SIZE > PRD_ADDRABLE)
            $error("cpu_prf: PRF_SIZE(%0d) exceeds 6-bit prd addressable range (%0d)", PRF_SIZE, PRD_ADDRABLE);
    end
`endif

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            for (int i = 0; i < PRF_SIZE; i++) free_bits[i] <= 1'b1;
        end else begin
            if (release_en && (release_prd != 6'd0))
                free_bits[release_prd]  <= 1'b1;
            if (release1_en && (release1_prd != 6'd0))
                free_bits[release1_prd] <= 1'b1;
            if (retract_en && (retract_prd != 6'd0))
                free_bits[retract_prd] <= 1'b1;
            if (retract1_en && (retract1_prd != 6'd0))
                free_bits[retract1_prd] <= 1'b1;
            // Squash release: free prds from ROB entries killed by younger squash
            // Use delayed mask: prevents WB aliasing (stale writeback in same cycle
            // would otherwise match a newly re-allocated entry with the same prd).
            for (int i = 0; i < PRD_ADDRABLE; i++) begin
                if (squash_release_mask_d1[i])
                    free_bits[i] <= 1'b1;
            end
            if (allocate_en && (allocated != 6'd0))
                free_bits[allocated] <= 1'b0;
            if (allocate1_en && (allocated1 != 6'd0))
                free_bits[allocated1] <= 1'b0;
        end
    end

    assign allocate_prd  = allocated;
    assign allocate1_prd = allocated1;

    // async reads with write-first bypass — x0 hardwired to 0.
    // Use 4-state-safe hit checks to avoid propagating X from transient unknown we/waddr.
    wire hit1_r1 = (we  == 1'b1) && (waddr  != 6'd0) && (waddr  == raddr1);
    wire hit2_r1 = (we1 == 1'b1) && (waddr1 != 6'd0) && (waddr1 == raddr1);
    wire hit1_r2 = (we  == 1'b1) && (waddr  != 6'd0) && (waddr  == raddr2);
    wire hit2_r2 = (we1 == 1'b1) && (waddr1 != 6'd0) && (waddr1 == raddr2);
    wire hit1_r3 = (we  == 1'b1) && (waddr  != 6'd0) && (waddr  == raddr3);
    wire hit2_r3 = (we1 == 1'b1) && (waddr1 != 6'd0) && (waddr1 == raddr3);
    wire hit1_r4 = (we  == 1'b1) && (waddr  != 6'd0) && (waddr  == raddr4);
    wire hit2_r4 = (we1 == 1'b1) && (waddr1 != 6'd0) && (waddr1 == raddr4);

    assign rdata1 = (raddr1 == 6'd0) ? 32'b0 : (hit1_r1 ? wdata : (hit2_r1 ? wdata1 : x[raddr1]));
    assign rdata2 = (raddr2 == 6'd0) ? 32'b0 : (hit1_r2 ? wdata : (hit2_r2 ? wdata1 : x[raddr2]));
    assign rdata3 = (raddr3 == 6'd0) ? 32'b0 : (hit1_r3 ? wdata : (hit2_r3 ? wdata1 : x[raddr3]));
    assign rdata4 = (raddr4 == 6'd0) ? 32'b0 : (hit1_r4 ? wdata : (hit2_r4 ? wdata1 : x[raddr4]));

    // sync write + reset init: architectural and physical regs start from zero.
    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            for (int i = 0; i < PRF_SIZE; i++)
                x[i] <= '0;
        end else begin
            x[0] <= 32'b0;
            if (we1 && (waddr1 != 6'd0))
                x[waddr1] <= wdata1;
            if (we && (waddr != 6'd0))
                x[waddr] <= wdata;
        end
    end

endmodule
