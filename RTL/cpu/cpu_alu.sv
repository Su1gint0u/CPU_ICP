// ALU functional unit: add/sub/shift/logic/comparison for RV32IM.
// Extracted from cpu_ex_stage; operates on already-forwarded operands.
module cpu_alu (
    input  logic [6:0]  opcode,
    input  logic [2:0]  funct3,
    input  logic [6:0]  funct7,
    input  logic [31:0] fwd_rs1_val,
    input  logic [31:0] fwd_rs2_val,
    input  logic [31:0] imm_i,
    input  logic [31:0] imm_u,
    input  logic [31:0] pc,

    output logic [31:0] result
);

    function automatic logic [31:0] sra32(input logic [31:0] value, input logic [4:0] shamt);
        logic [31:0] shifted;
        begin
            shifted = value >> shamt;
            if (value[31] && (shamt != 5'd0))
                sra32 = shifted | (32'hFFFF_FFFF << (32 - shamt));
            else
                sra32 = shifted;
        end
    endfunction

    always_comb begin
        result = 32'b0;
        unique case (opcode)
            7'b0110011: begin
                if (funct7[5])
                    unique case (funct3)
                        3'b000: result = fwd_rs1_val - fwd_rs2_val;
                        3'b001: result = fwd_rs1_val << fwd_rs2_val[4:0];
                        3'b010: result = ($signed(fwd_rs1_val) < $signed(fwd_rs2_val)) ? 32'd1 : 32'd0;
                        3'b011: result = (fwd_rs1_val < fwd_rs2_val) ? 32'd1 : 32'd0;
                        3'b100: result = fwd_rs1_val ^ fwd_rs2_val;
                        3'b101: result = sra32(fwd_rs1_val, fwd_rs2_val[4:0]);
                        3'b110: result = fwd_rs1_val | fwd_rs2_val;
                        3'b111: result = fwd_rs1_val & fwd_rs2_val;
                        default: result = 32'b0;
                    endcase
                else
                    unique case (funct3)
                        3'b000: result = fwd_rs1_val + fwd_rs2_val;
                        3'b001: result = fwd_rs1_val << fwd_rs2_val[4:0];
                        3'b010: result = ($signed(fwd_rs1_val) < $signed(fwd_rs2_val)) ? 32'd1 : 32'd0;
                        3'b011: result = (fwd_rs1_val < fwd_rs2_val) ? 32'd1 : 32'd0;
                        3'b100: result = fwd_rs1_val ^ fwd_rs2_val;
                        3'b101: result = fwd_rs1_val >> fwd_rs2_val[4:0];
                        3'b110: result = fwd_rs1_val | fwd_rs2_val;
                        3'b111: result = fwd_rs1_val & fwd_rs2_val;
                        default: result = 32'b0;
                    endcase
            end
            7'b0010011: begin
                unique case (funct3)
                    3'b000: result = fwd_rs1_val + imm_i;
                    3'b001: result = fwd_rs1_val << imm_i[4:0];
                    3'b010: result = ($signed(fwd_rs1_val) < $signed(imm_i)) ? 32'd1 : 32'd0;
                    3'b011: result = (fwd_rs1_val < imm_i)  ? 32'd1 : 32'd0;
                    3'b100: result = fwd_rs1_val ^ imm_i;
                    3'b101: result = funct7[5] ? sra32(fwd_rs1_val, imm_i[4:0]) : (fwd_rs1_val >> imm_i[4:0]);
                    3'b110: result = fwd_rs1_val | imm_i;
                    3'b111: result = fwd_rs1_val & imm_i;
                    default: result = 32'b0;
                endcase
            end
            7'b0110111: result = imm_u;
            7'b0010111: result = pc + imm_u;
            default: result = 32'b0;
        endcase
    end

endmodule
