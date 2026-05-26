`timescale 1ns / 1ps

module tb_fpu_wrapper;

    logic        clk;
    logic        rst_n;
    logic        redirect_valid;
    logic        idex_valid;
    logic [31:0] idex_pc;
    logic [31:0] inst;
    logic [31:0] frs1;
    logic [31:0] frs2;
    logic [31:0] frs3;
    logic [31:0] irs1;
    logic [2:0]  frm_csr;
    logic [31:0] result;
    logic        illegal;
    logic [4:0]  fflags;
    logic        stall_fp;

    fpu_wrapper u_dut (
        .pl_clk(clk),
        .pl_resetn(rst_n),
        .redirect_valid(redirect_valid),
        .idex_valid(idex_valid),
        .idex_pc(idex_pc),
        .inst(inst),
        .frs1(frs1),
        .frs2(frs2),
        .frs3(frs3),
        .irs1(irs1),
        .frm_csr(frm_csr),
        .result(result),
        .illegal(illegal),
        .fflags(fflags),
        .stall_fp(stall_fp)
    );

    always #5 clk = ~clk;

    function automatic logic [31:0] fp_inst(input logic [6:0] f7, input logic [4:0] rs2, input logic [2:0] rm);
        fp_inst = {f7, rs2, 5'd1, rm, 5'd2, 7'b1010011};
    endfunction

    task automatic run_op(
        input string name,
        input logic [31:0] op_inst,
        input logic [31:0] a,
        input logic [31:0] b,
        input logic [31:0] i,
        input logic [31:0] expected
    );
        begin
            @(negedge clk);
            idex_pc += 32'd4;
            inst = op_inst;
            frs1 = a;
            frs2 = b;
            irs1 = i;
            idex_valid = 1'b1;
            @(posedge clk);
            while (stall_fp)
                @(posedge clk);
            #1;
            if (illegal)
                $fatal(1, "[TB_FPU] %s unexpectedly illegal", name);
            if (result !== expected)
                $fatal(1, "[TB_FPU] %s result mismatch: expected 0x%08x got 0x%08x flags=%b",
                       name, expected, result, fflags);
            $display("[TB_FPU] PASS %s result=0x%08x flags=%b", name, result, fflags);
            @(negedge clk);
            idex_valid = 1'b0;
            @(posedge clk);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        redirect_valid = 1'b0;
        idex_valid = 1'b0;
        idex_pc = 32'h8000_0000;
        inst = 32'd0;
        frs1 = 32'd0;
        frs2 = 32'd0;
        frs3 = 32'd0;
        irs1 = 32'd0;
        frm_csr = 3'b000;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        run_op("fcvt.s.w 100", fp_inst(7'h68, 5'd0, 3'b000), 32'd0, 32'd0, 32'd100, 32'h42c8_0000);
        run_op("fcvt.s.wu 20", fp_inst(7'h68, 5'd1, 3'b000), 32'd0, 32'd0, 32'd20, 32'h41a0_0000);
        run_op("fsub.s 100-20", fp_inst(7'h04, 5'd2, 3'b000), 32'h42c8_0000, 32'h41a0_0000, 32'd0, 32'h42a0_0000);
        run_op("fdiv.s 80/2", fp_inst(7'h0c, 5'd2, 3'b000), 32'h42a0_0000, 32'h4000_0000, 32'd0, 32'h4220_0000);
        run_op("fcvt.w.s -37.5", fp_inst(7'h60, 5'd0, 3'b000), 32'hc216_0000, 32'd0, 32'd0, 32'hffff_ffda);
        run_op("fcvt.wu.s -30", fp_inst(7'h60, 5'd1, 3'b000), 32'hc1f0_0000, 32'd0, 32'd0, 32'h0000_0000);
        run_op("fsqrt.s 4869", fp_inst(7'h2c, 5'd0, 3'b000), 32'h4598_2800, 32'd0, 32'd0, 32'h428b_8e73);

        @(negedge clk);
        inst = {7'h70, 5'd0, 5'd1, 3'b000, 5'd2, 7'b1010011}; // FMV.X.W is outside approval scope.
        idex_valid = 1'b1;
        #1;
        if (!illegal)
            $fatal(1, "[TB_FPU] FMV.X.W should be illegal in approval FPU");

        $display("[TB_FPU] PASS all self-contained FPU checks");
        $finish;
    end

endmodule
