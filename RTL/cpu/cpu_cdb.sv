// Common Data Bus: broadcasts FU results for RS wakeup.
// Phase O2: 1-entry pass-through (no actual broadcast — single FU at a time).
// Phase O3+: multi-entry, broadcast to all RS entries.

module cpu_cdb (
    input  logic        pl_clk,
    input  logic        pl_resetn,

    // === write ports (from WB / FU outputs) ===
    input  logic        wb0_valid,
    input  logic [5:0]  wb0_prd,          // phys dst register written
    input  logic [31:0] wb0_data,
    input  logic [4:0]  wb0_rd,           // arch dst (for RAT update)

    // === read port (to RS wakeup logic) ===
    output logic        cdb_valid,
    output logic [5:0]  cdb_prd,
    output logic [31:0] cdb_data
);

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            cdb_valid <= 1'b0;
            cdb_prd   <= '0;
            cdb_data  <= '0;
        end else begin
            cdb_valid <= wb0_valid;
            cdb_prd   <= wb0_prd;
            cdb_data  <= wb0_data;
        end
    end

endmodule
