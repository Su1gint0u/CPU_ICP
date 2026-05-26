// Combinational RISC-V RV32IMAF instruction decode.
// Pure function of the instruction word — no pipeline state, no clock.
// Reusable across scalar / superscalar / OoO implementations.
module cpu_decode (
    input  logic [31:0] inst,
    input  logic        mstatus_fs_off,

    output logic [6:0]  opcode,
    output logic [4:0]  rs1,
    output logic [4:0]  rs2,
    output logic [4:0]  rd,
    output logic [2:0]  funct3,
    output logic [6:0]  funct7,
    output logic [31:0] imm_i,
    output logic [31:0] imm_s,
    output logic [31:0] imm_b,
    output logic [31:0] imm_u,
    output logic [31:0] imm_j,

    output logic        is_load,
    output logic        is_store,
    output logic        is_amo,
    output logic        is_branch,
    output logic        is_jal,
    output logic        is_jalr,
    output logic        is_fence,
    output logic [2:0]  fence_op,
    output logic        is_csr,
    output logic        is_fp_load,
    output logic        is_fp_store,
    output logic        is_fp_op,
    output logic        fregwrite,

    output logic        illegal,
    output logic        uses_rs1,
    output logic        uses_rs2,
    output logic        uses_frs1,
    output logic        uses_frs2,
    output logic        uses_frs3
);

    localparam logic [2:0] CTL_FENCE   = 3'b000;
    localparam logic [2:0] CTL_FENCE_I = 3'b001;

    wire [11:0] csr_addr   = inst[31:20];
    wire        is_csr_pat = (inst[6:0] == 7'b1110011) && ((inst[14:12] == 3'b001)
        || (inst[14:12] == 3'b010) || (inst[14:12] == 3'b011)
        || (inst[14:12] == 3'b101) || (inst[14:12] == 3'b110)
        || (inst[14:12] == 3'b111));
    wire        csr_is_fp_csr = (csr_addr == 12'h001) || (csr_addr == 12'h002)
        || (csr_addr == 12'h003);

    logic [12:0] imm_b13;
    logic [20:0] imm_j21;

    // ── immediate decode ──
    always_comb begin
        opcode  = inst[6:0];
        rd      = inst[11:7];
        funct3  = inst[14:12];
        rs1     = inst[19:15];
        rs2     = inst[24:20];
        funct7  = inst[31:25];

        imm_i = {{20{inst[31]}}, inst[31:20]};
        imm_s = {{20{inst[31]}}, inst[31:25], inst[11:7]};
        imm_b13 = {inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
        imm_b  = {{19{imm_b13[12]}}, imm_b13};
        imm_u  = {inst[31:12], 12'b0};
        imm_j21 = {inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};
        imm_j  = {{11{imm_j21[20]}}, imm_j21};
    end

    // ── operand usage ──
    logic [4:0] rs3 = inst[31:27];
    always_comb begin
        uses_rs1  = 1'b0;
        uses_rs2  = 1'b0;
        uses_frs1 = 1'b0;
        uses_frs2 = 1'b0;
        uses_frs3 = 1'b0;
        unique case (opcode)
            7'b0110011: begin
                uses_rs1 = 1'b1; uses_rs2 = 1'b1;
            end
            7'b0010011: begin
                uses_rs1 = 1'b1;
            end
            7'b0000011: begin
                uses_rs1 = 1'b1;
            end
            7'b0100011: begin
                uses_rs1 = 1'b1; uses_rs2 = 1'b1;
            end
            7'b1100011: begin
                uses_rs1 = 1'b1; uses_rs2 = 1'b1;
            end
            7'b1100111: begin
                uses_rs1 = 1'b1;
            end
            7'b1110011: begin
                if (is_csr_pat && !funct3[2] && (rs1 != 5'd0))
                    uses_rs1 = 1'b1;
            end
            7'b0000111: begin
                if (funct3 == 3'b010)
                    uses_rs1 = 1'b1;
            end
            7'b0100111: begin
                if (funct3 == 3'b010) begin
                    uses_rs1 = 1'b1; uses_frs2 = 1'b1;
                end
            end
            7'b0101111: begin
                uses_rs1 = 1'b1;
                if (inst[31:27] != 5'h02)
                    uses_rs2 = 1'b1;
            end
            7'b1010011: begin
                if (funct7 == 7'h68 && (rs2 == 5'b0 || rs2 == 5'b1))
                    uses_rs1 = 1'b1;
                else if (funct7 == 7'h60 && (rs2 == 5'b0 || rs2 == 5'b1))
                    uses_frs1 = 1'b1;
                else if (funct7 == 7'h00 || funct7 == 7'h04 || funct7 == 7'h08 || funct7 == 7'h0C) begin
                    uses_frs1 = 1'b1; uses_frs2 = 1'b1;
                end else if (funct7 == 7'h2C && rs2 == 5'b0)
                    uses_frs1 = 1'b1;
            end
            7'h43, 7'h47, 7'h4b, 7'h4f: begin
                uses_frs1 = 1'b0; uses_frs2 = 1'b0; uses_frs3 = 1'b0;
            end
            default: ;
        endcase
    end

    // ── instruction classification ──
    always_comb begin
        is_load      = 1'b0;
        is_store     = 1'b0;
        is_amo       = 1'b0;
        is_fp_load   = 1'b0;
        is_fp_store  = 1'b0;
        is_fp_op     = 1'b0;
        fregwrite    = 1'b0;
        is_branch    = 1'b0;
        is_jal       = 1'b0;
        is_jalr      = 1'b0;
        is_fence     = 1'b0;
        fence_op     = CTL_FENCE;

        unique case (opcode)
            7'b0000011:   is_load   = 1'b1;
            7'b0100011:   is_store  = 1'b1;
            7'b0000111: begin
                if (funct3 == 3'b010) begin
                    is_fp_load = 1'b1;
                    fregwrite = 1'b1;
                end
            end
            7'b0100111: begin
                if (funct3 == 3'b010) is_fp_store = 1'b1;
            end
            7'h43, 7'h47, 7'h4b, 7'h4f: begin
                if (fp_r4_legal()) begin
                    is_fp_op = 1'b1;
                    fregwrite = 1'b1;
                end
            end
            7'b1010011: begin
                if (fp_f0_legal()) begin
                    is_fp_op = 1'b1;
                    if (fp_f0_writes_frd()) fregwrite = 1'b1;
                end
            end
            7'b0101111:   is_amo    = 1'b1;
            7'b1100011:   is_branch = 1'b1;
            7'b1101111:   is_jal    = 1'b1;
            7'b1100111:   is_jalr   = 1'b1;
            7'b0001111: begin
                is_fence  = 1'b1;
                fence_op  = (funct3 == 3'b001) ? CTL_FENCE_I : CTL_FENCE;
            end
            default: ;
        endcase
    end

    // ── CSR detection ──
    assign is_csr = is_csr_pat;

    // ── illegal instruction ──
    always_comb begin
        illegal = 1'b0;
        unique case (opcode)
            7'b0110011, 7'b0010011, 7'b0000011, 7'b0100011,
            7'b1100011, 7'b1101111, 7'b1100111, 7'b0110111,
            7'b0010111, 7'b0001111: illegal = 1'b0;
            7'b0000111, 7'b0100111, 7'b1010011: illegal = !fp_f0_legal();
            7'h43, 7'h47, 7'h4b, 7'h4f: illegal = !fp_r4_legal();
            7'b1110011: begin
                if ((inst == 32'h00000073) || (inst == 32'h00100073) || (inst == 32'h30200073))
                    illegal = 1'b0;
                else if (is_csr_pat)
                    illegal = !csr_addr_supported(csr_addr);
                else
                    illegal = 1'b1;
            end
            7'b0101111: illegal = !amo_legal();
            default: illegal = 1'b1;
        endcase
        // FS-off legality depends on older CSR writes (mstatus/frm/fcsr). Until CSR rename is
        // fully serialized, do not bake the current CSR snapshot into younger FP uops here.
    end

    // ── legality sub-functions ──
    function automatic logic fp_f0_legal();
        logic [2:0] f3 = funct3;
        logic [6:0] f7 = funct7;
        logic [4:0] r2 = rs2;
        fp_f0_legal = 1'b0;
        if      (opcode == 7'b0000111)    fp_f0_legal = (f3 == 3'b010);
        else if (opcode == 7'b0100111)    fp_f0_legal = (f3 == 3'b010);
        else if (opcode == 7'b1010011) begin
            if ((f3 == 3'b101) || (f3 == 3'b110)) fp_f0_legal = 1'b0;
            else if (f7 == 7'h68 && (r2 == 5'b0||r2 == 5'b1))      fp_f0_legal = 1'b1;
            else if (f7 == 7'h60 && (r2 == 5'b0||r2 == 5'b1))      fp_f0_legal = 1'b1;
            else if (f7 == 7'h00||f7 == 7'h04||f7 == 7'h08||f7 == 7'h0C) fp_f0_legal = 1'b1;
            else if (f7 == 7'h2C && r2 == 5'b0)                     fp_f0_legal = 1'b1;
        end
    endfunction

    function automatic logic fp_f0_writes_frd();
        logic [6:0] f7 = funct7;
        fp_f0_writes_frd = fp_f0_legal()
            && !(f7 == 7'h60); // FCVT.W[U].S writes an integer register.
    endfunction

    function automatic logic fp_r4_legal();
        fp_r4_legal = 1'b0;
    endfunction

    function automatic logic amo_legal();
        logic [4:0] f5 = inst[31:27];
        amo_legal = 1'b0;
        if (opcode != 7'b0101111)          ;
        else if (funct3 != 3'b010)         ;
        else if (f5 == 5'h02)
            amo_legal = (rs2 == 5'b0);
        else
            unique case (f5)
                5'h00, 5'h01, 5'h03, 5'h04, 5'h08, 5'h0C, 5'h10, 5'h14, 5'h18, 5'h1C: amo_legal = 1'b1;
                default: amo_legal = 1'b0;
            endcase
    endfunction

    function automatic logic csr_addr_supported(input logic [11:0] a);
        unique case (a)
            12'h300, 12'h301, 12'h304, 12'h344, 12'h305, 12'h340,
            12'h341, 12'h342, 12'h001, 12'h002, 12'h003, 12'h320,
            12'hB00, 12'hB02, 12'hB80, 12'hB82,
            12'hF11, 12'hF12, 12'hF13, 12'hF14: csr_addr_supported = 1'b1;
            default: csr_addr_supported = 1'b0;
        endcase
    endfunction

endmodule
