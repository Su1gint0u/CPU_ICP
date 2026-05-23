// 32×32-bit floating-point register file (f0 is not hardwired; NaN-boxing is ISA-visible in consumers).
// 6 read ports: 3 for slot0 + 3 for slot1 (ISSUE_WIDTH=2).
module cpu_f_regfile (
    input  logic        pl_clk,
    input  logic        pl_resetn,
    input  logic [4:0]  raddr1,
    input  logic [4:0]  raddr2,
    input  logic [4:0]  raddr3,
    output logic [31:0] rdata1,
    output logic [31:0] rdata2,
    output logic [31:0] rdata3,
    // Slot 1 read ports (ISSUE_WIDTH=2)
    input  logic [4:0]  raddr4, raddr5, raddr6,
    output logic [31:0] rdata4, rdata5, rdata6,
    input  logic        we,
    input  logic [4:0]  waddr,
    input  logic [31:0] wdata,
    input  logic        we_b,
    input  logic [4:0]  waddr_b,
    input  logic [31:0] wdata_b
);

    logic [31:0] f [0:31];

    assign rdata1 = f[raddr1];
    assign rdata2 = f[raddr2];
    assign rdata3 = f[raddr3];
    assign rdata4 = f[raddr4];
    assign rdata5 = f[raddr5];
    assign rdata6 = f[raddr6];

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            for (int i = 0; i < 32; i++) f[i] <= 32'b0;
        end else begin
            if (we)  f[waddr]   <= wdata;
            if (we_b) f[waddr_b] <= wdata_b;
        end
    end

endmodule
