// Gshare-style direction predictor (P6): 2-bit PHT indexed by PC xor global history register.
// Drop-in replacement for bp_direction_2bit in bp_predictor_simple when USE_GSHARE=1.

module bp_gshare #(
    parameter int unsigned ENTRIES = 256,
    parameter int unsigned IDX_BITS = 8,
    parameter int unsigned GHR_BITS = 8
) (
    input  logic                 pl_clk,
    input  logic                 pl_resetn,

    input  logic [31:0]          query_pc,
    output logic                 pred_taken_msb,
    output logic [1:0]           counter_out,

    input  logic                 upd_valid,
    input  logic [31:0]          upd_pc,
    input  logic                 upd_taken
);

    logic [GHR_BITS-1:0] ghr;
    logic [1:0] counter [0:ENTRIES-1];

    wire [IDX_BITS-1:0] ridx = query_pc[IDX_BITS+1:2] ^ ghr[IDX_BITS-1:0];
    wire [IDX_BITS-1:0] uidx = upd_pc[IDX_BITS+1:2] ^ ghr[IDX_BITS-1:0];

    assign pred_taken_msb = counter[ridx][1];
    assign counter_out    = counter[ridx];

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            ghr <= '0;
            /* verilator lint_off BLKSEQ */
            for (int i = 0; i < ENTRIES; i++)
                counter[i] = 2'b01;
            /* verilator lint_on BLKSEQ */
        end else begin
            if (upd_valid) begin
                unique case (counter[uidx])
                    2'b00: counter[uidx] <= upd_taken ? 2'b01 : 2'b00;
                    2'b01: counter[uidx] <= upd_taken ? 2'b10 : 2'b00;
                    2'b10: counter[uidx] <= upd_taken ? 2'b11 : 2'b01;
                    2'b11: counter[uidx] <= upd_taken ? 2'b11 : 2'b10;
                    default: counter[uidx] <= 2'b01;
                endcase
                ghr <= {ghr[GHR_BITS-2:0], upd_taken};
            end
        end
    end

endmodule
