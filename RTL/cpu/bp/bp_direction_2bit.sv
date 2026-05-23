// PC-indexed 2-bit saturating counters (local direction predictor).
module bp_direction_2bit #(
    parameter int unsigned ENTRIES = 256,
    parameter int unsigned IDX_BITS = 8
) (
    input  logic                 pl_clk,
    input  logic                 pl_resetn,

    input  logic [IDX_BITS-1:0]  ridx,
    output logic                 pred_taken_msb,
    output logic [1:0]           counter_out,
    input  logic [IDX_BITS-1:0]  ridx1,
    output logic                 pred_taken_msb1,
    output logic [1:0]           counter_out1,

    input  logic                 upd_valid,
    input  logic [IDX_BITS-1:0]  upd_idx,
    input  logic                 upd_taken
);

    logic [1:0] counter [0:ENTRIES-1];

    assign pred_taken_msb  = counter[ridx][1];
    assign counter_out     = counter[ridx];
    assign pred_taken_msb1 = counter[ridx1][1];
    assign counter_out1    = counter[ridx1];

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            for (int i = 0; i < ENTRIES; i++) begin
                counter[i] = 2'b01;
            end
        end else if (upd_valid) begin
            unique case (counter[upd_idx])
                2'b00: counter[upd_idx] <= upd_taken ? 2'b01 : 2'b00;
                2'b01: counter[upd_idx] <= upd_taken ? 2'b10 : 2'b00;
                2'b10: counter[upd_idx] <= upd_taken ? 2'b11 : 2'b01;
                2'b11: counter[upd_idx] <= upd_taken ? 2'b11 : 2'b10;
                default: counter[upd_idx] <= 2'b01;
            endcase
        end
    end

endmodule
