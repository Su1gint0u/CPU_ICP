// Direct-mapped BTB: tag (PC high) + target + optional return-site flag (RAS target select).
module bp_btb_direct #(
    parameter int unsigned ENTRIES = 256,
    parameter int unsigned IDX_BITS = 8,
    parameter int unsigned TAG_BITS = 22
) (
    input  logic                 pl_clk,
    input  logic                 pl_resetn,

    input  logic [31:0]          query_pc,
    output logic                 hit,
    output logic [31:0]          target,
    output logic                 is_ret,
    input  logic [31:0]          query_pc1,
    output logic                 hit1,
    output logic [31:0]          target1,
    output logic                 is_ret1,

    input  logic                 upd_valid,
    input  logic [31:0]          upd_pc,
    input  logic [31:0]          upd_target,
    input  logic                 upd_is_ret
);

    localparam int unsigned TAG_W = 32 - IDX_BITS - 2;

    logic                    valid [0:ENTRIES-1];
    logic [TAG_W-1:0]        tag   [0:ENTRIES-1];
    logic [31:0]             tgt   [0:ENTRIES-1];
    logic                    ret_s [0:ENTRIES-1];

    wire [IDX_BITS-1:0] qidx  = query_pc[IDX_BITS+1:2];
    wire [IDX_BITS-1:0] qidx1 = query_pc1[IDX_BITS+1:2];
    wire [TAG_W-1:0] qtag  = query_pc[31:IDX_BITS+2];
    wire [TAG_W-1:0] qtag1 = query_pc1[31:IDX_BITS+2];
    wire [TAG_W-1:0] wtag  = upd_pc[31:IDX_BITS+2];

    assign hit     = valid[qidx] && (tag[qidx] == qtag);
    assign target  = tgt[qidx];
    assign is_ret  = valid[qidx] && (tag[qidx] == qtag) && ret_s[qidx];
    assign hit1    = valid[qidx1] && (tag[qidx1] == qtag1);
    assign target1 = tgt[qidx1];
    assign is_ret1 = valid[qidx1] && (tag[qidx1] == qtag1) && ret_s[qidx1];

    wire [IDX_BITS-1:0] widx = upd_pc[IDX_BITS+1:2];

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            for (int i = 0; i < ENTRIES; i++) begin
                valid[i] = 1'b0;
                tag[i]   = '0;
                tgt[i]   = 32'b0;
                ret_s[i] = 1'b0;
            end
        end else if (upd_valid) begin
            valid[widx] <= 1'b1;
            tag[widx]   <= wtag;
            tgt[widx]   <= upd_target;
            ret_s[widx] <= upd_is_ret;
        end
    end

endmodule
