// Instruction Buffer: decouples IF fetch from IF/ID consumption.
// Stores 64-bit bundles (4 deep) with PC and BP metadata.
module cpu_instr_buffer #(
    parameter int unsigned DEPTH = 4,
    parameter int unsigned FETCH_W = 64
) (
    input  logic        pl_clk,
    input  logic        pl_resetn,

    // Write port (from IF stage)
    input  logic        wr_en,
    input  logic [31:0] wr_pc,
    input  logic [FETCH_W-1:0] wr_data,
    input  logic        wr_err,
    input  logic        wr_bp_pred_taken,
    input  logic [63:0] wr_bp_pred_meta,
    output logic        full,

    // Read port (to IF/ID register)
    input  logic        rd_en,
    output logic [31:0] ifid_pc,
    output logic [31:0] ifid_inst,
    output logic [31:0] ifid1_inst,
    output logic        ifid_err,
    output logic        ifid_bp_pred_taken,
    output logic [63:0] ifid_bp_pred_meta,
    output logic        empty
);

    localparam int PTR_W = $clog2(DEPTH+1) >= 1 ? $clog2(DEPTH+1) : 1;

    typedef struct packed {
        logic [31:0] pc;
        logic [FETCH_W-1:0] data;
        logic        err;
        logic        bp_pred_taken;
        logic [63:0] bp_pred_meta;
    } buf_entry_t;

    buf_entry_t q [0:DEPTH-1];
    logic [PTR_W-1:0] wptr, rptr;

    assign empty = (wptr == rptr);
    assign full  = (wptr == rptr + DEPTH[PTR_W-1:0]'(DEPTH));

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            wptr <= 0; rptr <= 0;
        end else begin
            if (wr_en && !full) begin
                q[wptr] <= '{
                    pc: wr_pc, data: wr_data, err: wr_err,
                    bp_pred_taken: wr_bp_pred_taken, bp_pred_meta: wr_bp_pred_meta
                };
                wptr <= wptr + 1'b1;
            end
            if (rd_en && !empty) begin
                rptr <= rptr + 1'b1;
            end
        end
    end

    wire buf_entry_t head = q[rptr];
    assign ifid_pc   = head.pc;
    assign ifid_inst = head.data[31:0];
    assign ifid1_inst = head.data[63:32];
    assign ifid_err  = head.err;
    assign ifid_bp_pred_taken = head.bp_pred_taken;
    assign ifid_bp_pred_meta  = head.bp_pred_meta;

endmodule
