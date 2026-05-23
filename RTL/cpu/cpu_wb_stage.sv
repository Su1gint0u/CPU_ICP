// Writeback stage: GPR/FP write + commit output.
// ROB completion is driven from cpu_core (prd-tagged wb_*); this block only drives RF and wb_commit when ROB is empty.

module cpu_wb_stage (
    input  logic pl_clk, input  logic pl_resetn,
    input  logic exmem_valid, input  logic exmem_advance,
    input  logic [4:0] exmem_rd, input  logic exmem_regwrite, input  logic exmem_fregwrite,
    input  logic exmem_is_load, input  logic exmem_is_store, input  logic exmem_is_amo,
    input  logic exmem_is_branch, input  logic exmem_is_jal, input  logic exmem_is_jalr,
    input  logic exmem_is_fence, input  logic exmem_is_csr,
    input  logic [31:0] exmem_alu_result, input  logic [31:0] exmem_pc, input  logic [31:0] exmem_inst,
    input  logic memwb_valid, input  logic [31:0] memwb_pc, input  logic [31:0] memwb_inst,
    input  logic [4:0] memwb_rd, input  logic memwb_regwrite,
    input  logic [31:0] memwb_wdata, input  logic [2:0] memwb_load_funct3,
    input  logic memwb_is_fp_load,
    output logic rf_we, output logic [4:0] rf_waddr, output logic [31:0] rf_wdata,
    output logic rf_we_combo, output logic [4:0] rf_waddr_combo, output logic [31:0] rf_wdata_combo,
    output logic commit_valid, output logic [31:0] commit_pc, output logic [31:0] commit_inst,
    output logic commit_regwrite, output logic [4:0] commit_waddr, output logic [31:0] commit_wdata,
    output logic mon_commit_from_memwb, output logic mon_commit_from_exmem,
    output logic mon_commit_defer_exmem,
    output logic frf_we, output logic [4:0] frf_waddr, output logic [31:0] frf_wdata,
    output logic frf_we_b, output logic [4:0] frf_waddr_b, output logic [31:0] frf_wdata_b,
    input  logic rob_empty
);

    wire memwb_gpr_write = memwb_valid && memwb_regwrite && (memwb_rd != 5'd0);
    wire exmem_gpr_write = exmem_valid && exmem_regwrite
        && !exmem_is_load && !exmem_is_store && !exmem_is_amo && (exmem_rd != 5'd0);

    wire [31:0] memwb_wdata_signext =
        (memwb_load_funct3 == 3'b000) ? {{24{memwb_wdata[7]}},  memwb_wdata[7:0]} :
        (memwb_load_funct3 == 3'b100) ? {24'b0,                 memwb_wdata[7:0]} :
        (memwb_load_funct3 == 3'b001) ? {{16{memwb_wdata[15]}}, memwb_wdata[15:0]} :
        (memwb_load_funct3 == 3'b101) ? {16'b0,                 memwb_wdata[15:0]} :
        memwb_wdata;

    assign rf_we_combo = exmem_gpr_write || memwb_gpr_write;
    assign rf_waddr_combo = memwb_gpr_write ? memwb_rd : exmem_rd;
    assign rf_wdata_combo = memwb_gpr_write ? memwb_wdata_signext : exmem_alu_result;

    wire exmem_gpr_commit = exmem_advance && exmem_valid && exmem_regwrite
        && !exmem_is_load && !exmem_is_store && !exmem_is_amo;
    wire exmem_branch_commit = exmem_advance && exmem_valid && exmem_is_branch
        && !exmem_is_load && !exmem_is_store && !exmem_is_amo;
    wire exmem_store_commit = exmem_advance && exmem_valid && exmem_is_store;
    wire exmem_amo_commit   = exmem_advance && exmem_valid && exmem_is_amo;
    wire exmem_jal_commit   = exmem_advance && exmem_valid && exmem_is_jal;
    wire exmem_jalr_commit  = exmem_advance && exmem_valid && exmem_is_jalr;
    wire exmem_fence_commit = exmem_advance && exmem_valid && exmem_is_fence;
    wire exmem_csr_commit   = exmem_advance && exmem_valid && exmem_is_csr;
    wire exmem_slot_commit = exmem_gpr_commit || exmem_branch_commit || exmem_store_commit || exmem_amo_commit
        || exmem_jal_commit || exmem_jalr_commit || exmem_fence_commit || exmem_csr_commit;
    wire memwb_gpr_commit = memwb_valid && memwb_regwrite && (memwb_rd != 5'd0);

    // When ROB is empty, architectural commits come from wb_commit (serial).
    // Pending queue: memwb+exmem same cycle → memwb then exmem; draining pe may overlap new memwb (reload pe).
    logic        pe_valid;
    logic [31:0] pe_pc, pe_inst, pe_wdata;
    logic        pe_regwrite;
    logic [4:0]  pe_rd;
    logic        pe_from_memwb;
    logic        pe2_valid;
    logic [31:0] pe2_pc, pe2_inst, pe2_wdata;
    logic        pe2_regwrite;
    logic [4:0]  pe2_rd;

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            rf_we <= 1'b0; rf_waddr <= '0; rf_wdata <= '0;
            frf_we <= 1'b0; frf_waddr <= '0; frf_wdata <= '0;
            frf_we_b <= 1'b0; frf_waddr_b <= '0; frf_wdata_b <= '0;
            commit_valid <= 1'b0; commit_pc <= '0; commit_inst <= '0;
            commit_regwrite <= 1'b0; commit_waddr <= '0; commit_wdata <= '0;
            mon_commit_from_memwb <= 1'b0; mon_commit_from_exmem <= 1'b0;
            mon_commit_defer_exmem <= 1'b0;
            pe_valid <= 1'b0;
            pe2_valid <= 1'b0;
        end else begin
            rf_we <= 1'b0; frf_we <= 1'b0; frf_we_b <= 1'b0;
            commit_valid <= 1'b0; commit_regwrite <= 1'b0;
            mon_commit_from_memwb <= 1'b0; mon_commit_from_exmem <= 1'b0;
            mon_commit_defer_exmem <= 1'b0;

            // Regfile writes
            if (exmem_valid && exmem_fregwrite && !exmem_is_load && !exmem_is_store && !exmem_is_amo) begin
                {frf_we, frf_waddr, frf_wdata} <= {1'b1, exmem_rd, exmem_alu_result};
`ifndef SYNTHESIS
                if ($test$plusargs("FPU_DBG"))
                    $display("[FPU_DBG] frf_we t=%0t rd=f%0d data=0x%08x pc=0x%08x inst=0x%08x",
                             $time, exmem_rd, exmem_alu_result, exmem_pc, exmem_inst);
`endif
            end
            if (exmem_valid && exmem_regwrite && !exmem_is_load && !exmem_is_store && !exmem_is_amo && (exmem_rd != 5'd0))
                {rf_we, rf_waddr, rf_wdata} <= {1'b1, exmem_rd, exmem_alu_result};
            if (memwb_valid && memwb_is_fp_load) begin
                {frf_we_b, frf_waddr_b, frf_wdata_b} <= {1'b1, memwb_rd, memwb_wdata};
`ifndef SYNTHESIS
                if ($test$plusargs("FPU_DBG"))
                    $display("[FPU_DBG] frf_load_we t=%0t rd=f%0d data=0x%08x pc=0x%08x inst=0x%08x",
                             $time, memwb_rd, memwb_wdata, memwb_pc, memwb_inst);
`endif
            end
            if (memwb_valid && memwb_regwrite && (memwb_rd != 5'd0)) begin
                rf_we <= 1'b1; rf_waddr <= memwb_rd;
                unique case (memwb_load_funct3)
                    3'b000: rf_wdata <= {{24{memwb_wdata[7]}}, memwb_wdata[7:0]};
                    3'b100: rf_wdata <= {24'b0, memwb_wdata[7:0]};
                    3'b001: rf_wdata <= {{16{memwb_wdata[15]}}, memwb_wdata[15:0]};
                    3'b101: rf_wdata <= {16'b0, memwb_wdata[15:0]};
                    default: rf_wdata <= memwb_wdata;
                endcase
            end

            if (rob_empty) begin
                if (pe_valid) begin
                    commit_valid <= 1'b1;
                    commit_pc <= pe_pc;
                    commit_inst <= pe_inst;
                    commit_regwrite <= pe_regwrite;
                    commit_waddr <= pe_rd;
                    commit_wdata <= pe_wdata;
                    mon_commit_from_memwb <= pe_from_memwb;
                    mon_commit_from_exmem <= !pe_from_memwb;
                    mon_commit_defer_exmem <= !pe_from_memwb;
                    // Schedule following commits without dropping same-cycle memwb/exmem.
                    if (memwb_gpr_commit && exmem_slot_commit) begin
                        pe_pc <= memwb_pc;
                        pe_inst <= memwb_inst;
                        pe_regwrite <= 1'b1;
                        pe_rd <= memwb_rd;
                        unique case (memwb_load_funct3)
                            3'b000: pe_wdata <= {{24{memwb_wdata[7]}}, memwb_wdata[7:0]};
                            3'b100: pe_wdata <= {24'b0, memwb_wdata[7:0]};
                            3'b001: pe_wdata <= {{16{memwb_wdata[15]}}, memwb_wdata[15:0]};
                            3'b101: pe_wdata <= {16'b0, memwb_wdata[15:0]};
                            default: pe_wdata <= memwb_wdata;
                        endcase
                        pe_from_memwb <= 1'b1;
                        pe_valid <= 1'b1;
                        pe2_pc <= exmem_pc;
                        pe2_inst <= exmem_inst;
                        pe2_regwrite <= exmem_regwrite && (exmem_rd != 5'd0);
                        pe2_rd <= exmem_rd;
                        pe2_wdata <= exmem_alu_result;
                        pe2_valid <= 1'b1;
                    end else if (memwb_gpr_commit) begin
                        pe_pc <= memwb_pc;
                        pe_inst <= memwb_inst;
                        pe_regwrite <= 1'b1;
                        pe_rd <= memwb_rd;
                        unique case (memwb_load_funct3)
                            3'b000: pe_wdata <= {{24{memwb_wdata[7]}}, memwb_wdata[7:0]};
                            3'b100: pe_wdata <= {24'b0, memwb_wdata[7:0]};
                            3'b001: pe_wdata <= {{16{memwb_wdata[15]}}, memwb_wdata[15:0]};
                            3'b101: pe_wdata <= {16'b0, memwb_wdata[15:0]};
                            default: pe_wdata <= memwb_wdata;
                        endcase
                        pe_from_memwb <= 1'b1;
                        pe_valid <= 1'b1;
                        pe2_valid <= pe2_valid;
                    end else if (exmem_slot_commit) begin
                        pe_pc <= exmem_pc;
                        pe_inst <= exmem_inst;
                        pe_regwrite <= exmem_regwrite && (exmem_rd != 5'd0);
                        pe_rd <= exmem_rd;
                        pe_wdata <= exmem_alu_result;
                        pe_from_memwb <= 1'b0;
                        pe_valid <= 1'b1;
                        pe2_valid <= pe2_valid;
                    end else if (pe2_valid) begin
                        pe_pc <= pe2_pc;
                        pe_inst <= pe2_inst;
                        pe_regwrite <= pe2_regwrite;
                        pe_rd <= pe2_rd;
                        pe_wdata <= pe2_wdata;
                        pe_from_memwb <= 1'b0;
                        pe_valid <= 1'b1;
                        pe2_valid <= 1'b0;
                    end else begin
                        pe_valid <= 1'b0;
                    end
                end else if (memwb_gpr_commit && exmem_slot_commit) begin
                    commit_valid <= 1'b1;
                    mon_commit_from_memwb <= 1'b1;
                    commit_regwrite <= 1'b1;
                    commit_pc <= memwb_pc;
                    commit_inst <= memwb_inst;
                    commit_waddr <= memwb_rd;
                    unique case (memwb_load_funct3)
                        3'b000: commit_wdata <= {{24{memwb_wdata[7]}}, memwb_wdata[7:0]};
                        3'b100: commit_wdata <= {24'b0, memwb_wdata[7:0]};
                        3'b001: commit_wdata <= {{16{memwb_wdata[15]}}, memwb_wdata[15:0]};
                        3'b101: commit_wdata <= {16'b0, memwb_wdata[15:0]};
                        default: commit_wdata <= memwb_wdata;
                    endcase
                    pe_valid <= 1'b1;
                    pe_pc <= exmem_pc;
                    pe_inst <= exmem_inst;
                    pe_regwrite <= exmem_regwrite && (exmem_rd != 5'd0);
                    pe_rd <= exmem_rd;
                    pe_wdata <= exmem_alu_result;
                    pe_from_memwb <= 1'b0;
                    pe2_valid <= 1'b0;
                end else if (memwb_gpr_commit) begin
                    commit_valid <= 1'b1;
                    mon_commit_from_memwb <= 1'b1;
                    commit_regwrite <= 1'b1;
                    commit_pc <= memwb_pc;
                    commit_inst <= memwb_inst;
                    commit_waddr <= memwb_rd;
                    unique case (memwb_load_funct3)
                        3'b000: commit_wdata <= {{24{memwb_wdata[7]}}, memwb_wdata[7:0]};
                        3'b100: commit_wdata <= {24'b0, memwb_wdata[7:0]};
                        3'b001: commit_wdata <= {{16{memwb_wdata[15]}}, memwb_wdata[15:0]};
                        3'b101: commit_wdata <= {16'b0, memwb_wdata[15:0]};
                        default: commit_wdata <= memwb_wdata;
                    endcase
                end else if (exmem_slot_commit) begin
                    commit_valid <= 1'b1;
                    mon_commit_from_exmem <= 1'b1;
                    commit_regwrite <= exmem_regwrite && (exmem_rd != 5'd0);
                    commit_pc <= exmem_pc;
                    commit_inst <= exmem_inst;
                    commit_waddr <= exmem_rd;
                    commit_wdata <= exmem_alu_result;
                end else if (pe2_valid) begin
                    commit_valid <= 1'b1;
                    commit_pc <= pe2_pc;
                    commit_inst <= pe2_inst;
                    commit_regwrite <= pe2_regwrite;
                    commit_waddr <= pe2_rd;
                    commit_wdata <= pe2_wdata;
                    mon_commit_from_exmem <= 1'b1;
                    mon_commit_defer_exmem <= 1'b1;
                    pe2_valid <= 1'b0;
                end
            end else begin
                // ROB owns architectural commits; never drain stale peel entries later as duplicates.
                pe_valid  <= 1'b0;
                pe2_valid <= 1'b0;
            end
        end
    end
endmodule
