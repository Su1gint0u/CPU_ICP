// Dual async read, single sync write GPR file (x0 hardwired to 0).
module cpu_regfile (
    input  logic        pl_clk,
    input  logic        pl_resetn,
    input  logic [4:0]  raddr1,
    input  logic [4:0]  raddr2,
    output logic [31:0] rdata1,
    output logic [31:0] rdata2,
    input  logic        we,
    input  logic [4:0]  waddr,
    input  logic [31:0] wdata
);

    logic [31:0] x [0:31];
    integer i;

    // Write-first behavior for same-cycle WB->ID RAW hazards.
    assign rdata1 = (raddr1 == 5'd0) ? 32'b0
        : ((we && (waddr != 5'd0) && (waddr == raddr1)) ? wdata : x[raddr1]);
    assign rdata2 = (raddr2 == 5'd0) ? 32'b0
        : ((we && (waddr != 5'd0) && (waddr == raddr2)) ? wdata : x[raddr2]);

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            for (i = 0; i < 32; i = i + 1)
                x[i] <= 32'b0;
        end else begin
            x[0] <= 32'b0;
            if (we && (waddr != 5'd0)) begin
                x[waddr] <= wdata;
            end
        end
    end

endmodule
