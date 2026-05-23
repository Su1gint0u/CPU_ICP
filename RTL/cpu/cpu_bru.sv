// Branch Resolution Unit.
// Resolves branches (B-type), JAL, and JALR targets + redirect decisions.
// Extracted from cpu_ex_stage.

module cpu_bru (
    input  logic [6:0]  opcode,
    input  logic [2:0]  funct3,
    input  logic [31:0] fwd_rs1_val,
    input  logic [31:0] fwd_rs2_val,
    input  logic [31:0] idex_pc,
    input  logic [31:0] imm_b,
    input  logic [31:0] imm_j,
    input  logic [31:0] imm_i,
    input  logic        idex_valid,
    input  logic        bp_pred_taken,

    input  logic [31:0] branch_target,
    output logic        take_branch,
    output logic [31:0] jump_target,
    output logic        redirect_valid,
    output logic [31:0] redirect_pc
);

    always_comb begin
        take_branch   = 1'b0;
        jump_target   = 32'b0;
        redirect_valid = 1'b0;
        redirect_pc    = 32'b0;

        unique case (opcode)
            7'b1101111: begin
                jump_target = idex_pc + imm_j;
                redirect_valid = idex_valid && !bp_pred_taken;
                redirect_pc    = jump_target;
            end
            7'b1100111: begin
                jump_target = (fwd_rs1_val + imm_i) & 32'hFFFF_FFFE;
                redirect_valid = idex_valid;
                redirect_pc    = jump_target;
            end
            7'b1100011: begin
                unique case (funct3)
                    3'b000: take_branch = (fwd_rs1_val == fwd_rs2_val);
                    3'b001: take_branch = (fwd_rs1_val != fwd_rs2_val);
                    3'b100: take_branch = ($signed(fwd_rs1_val) < $signed(fwd_rs2_val));
                    3'b101: take_branch = ($signed(fwd_rs1_val) >= $signed(fwd_rs2_val));
                    3'b110: take_branch = (fwd_rs1_val < fwd_rs2_val);
                    3'b111: take_branch = (fwd_rs1_val >= fwd_rs2_val);
                    default: take_branch = 1'b0;
                endcase
                if (idex_valid && (bp_pred_taken != take_branch)) begin
                    redirect_valid = 1'b1;
                    redirect_pc    = take_branch ? branch_target : (idex_pc + 32'd4);
                end
            end
            default: ;
        endcase
    end

endmodule
