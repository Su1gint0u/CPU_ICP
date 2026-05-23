// Return-address stack (architectural push/pop at EX commit). Used with BTB "return" tag for IF target.
module bp_ras #(
    parameter int unsigned DEPTH = 8
) (
    input  logic        pl_clk,
    input  logic        pl_resetn,

    input  logic        push,
    input  logic        pop,
    input  logic [31:0] push_addr,

    output logic [31:0] top,
    output logic        empty
);

    localparam int unsigned SPW     = $clog2(DEPTH + 1);
    localparam int unsigned STK_IX_W = $clog2(DEPTH);

    logic [31:0] stack [0:DEPTH-1];
    logic [SPW-1:0] sp;

    wire [STK_IX_W-1:0] stk_top_ix = STK_IX_W'(sp - SPW'(1));

    assign empty = (sp == 0);
    assign top   = (sp != 0) ? stack[stk_top_ix] : 32'b0;

    always_ff @(posedge pl_clk) begin
        if (push && (sp < SPW'(DEPTH)))
            stack[STK_IX_W'(sp)] <= push_addr;
    end

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            sp <= '0;
        end else if (push && (sp < SPW'(DEPTH))) begin
            sp <= sp + SPW'(1);
        end else if (pop && (sp != 0)) begin
            sp <= sp - SPW'(1);
        end
    end

endmodule
