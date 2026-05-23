module tb_cpu_alu;
    logic [6:0]  opcode;
    logic [2:0]  funct3;
    logic [6:0]  funct7;
    logic [31:0] fwd_rs1_val;
    logic [31:0] fwd_rs2_val;
    logic [31:0] imm_i;
    logic [31:0] imm_u;
    logic [31:0] pc;
    logic [31:0] result;

    cpu_alu u_dut (
        .opcode(opcode),
        .funct3(funct3),
        .funct7(funct7),
        .fwd_rs1_val(fwd_rs1_val),
        .fwd_rs2_val(fwd_rs2_val),
        .imm_i(imm_i),
        .imm_u(imm_u),
        .pc(pc),
        .result(result)
    );

    task automatic check(
        input logic [6:0]  t_opcode,
        input logic [2:0]  t_funct3,
        input logic [6:0]  t_funct7,
        input logic [31:0] t_rs1,
        input logic [31:0] t_rs2,
        input logic [31:0] t_imm_i,
        input logic [31:0] expected,
        input string       label
    );
        begin
            opcode      = t_opcode;
            funct3      = t_funct3;
            funct7      = t_funct7;
            fwd_rs1_val = t_rs1;
            fwd_rs2_val = t_rs2;
            imm_i       = t_imm_i;
            imm_u       = 32'd0;
            pc          = 32'd0;
            #1;
            if (result !== expected)
                $fatal(1, "[TB_ALU] %s expected 0x%08x got 0x%08x", label, expected, result);
            $display("[TB_ALU] PASS %s -> 0x%08x", label, result);
        end
    endtask

    initial begin
        check(7'b0010011, 3'b101, 7'h20, 32'h8000_0000, 32'd0, 32'h0000_0401,
              32'hC000_0000, "SRAI negative by 1");
        check(7'b0010011, 3'b101, 7'h20, 32'h8000_0000, 32'd0, 32'h0000_040F,
              32'hFFFF_0000, "SRAI negative by 15");
        check(7'b0010011, 3'b101, 7'h00, 32'h8000_0000, 32'd0, 32'h0000_000F,
              32'h0001_0000, "SRLI negative by 15");
        check(7'b0010011, 3'b101, 7'h20, 32'h8000_0000, 32'd0, 32'h0000_0400,
              32'h8000_0000, "SRAI negative by 0");
        check(7'b0110011, 3'b101, 7'h20, 32'h8000_0000, 32'd15, 32'd0,
              32'hFFFF_0000, "SRA negative by 15");
        check(7'b0110011, 3'b101, 7'h00, 32'h8000_0000, 32'd15, 32'd0,
              32'h0001_0000, "SRL negative by 15");

        $display("[TB_ALU] PASS cpu_alu shift tests");
        $finish;
    end
endmodule
