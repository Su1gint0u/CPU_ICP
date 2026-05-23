// Memory stage: L1D request/response handshake, MEM/WB register.
module cpu_mem_stage #(
    parameter int unsigned XLEN = 32
) (
    input  logic pl_clk,
    input  logic pl_resetn,

    input  logic d_req_ready,
    input  logic d_resp_valid,
    input  logic [XLEN-1:0] d_resp_rdata,
    input  logic d_resp_err,

    input  logic [31:0] exmem_pc,
    input  logic [31:0] exmem_inst,

    output logic d_req_valid,
    output logic [31:0] d_req_addr,
    output logic [2:0] d_req_cmd,
    output logic [2:0] d_req_size,
    output logic [XLEN-1:0] d_req_wdata,
    output logic [3:0] d_req_wstrb,
    output logic [4:0] d_req_amo_funct,
    output logic        d_req_amo_aq,
    output logic        d_req_amo_rl,

    input  logic        exmem_valid,
    input  logic [4:0]  exmem_rd,
    input  logic        exmem_regwrite,
    input  logic        exmem_is_load,
    input  logic        exmem_is_store,
    input  logic        exmem_is_amo,
    input  logic [31:0] exmem_alu_result,
    input  logic [31:0] exmem_mem_addr,
    input  logic [2:0]  exmem_mem_cmd,
    input  logic [2:0]  exmem_mem_size,
    input  logic [31:0] exmem_store_wdata,
    input  logic [3:0]  exmem_store_wstrb,
    input  logic [2:0]  exmem_load_funct3,
    input  logic [4:0]  exmem_amo_funct,
    input  logic        exmem_amo_aq,
    input  logic        exmem_amo_rl,
    input  logic        exmem_is_fp_load,
    input  logic [5:0]  exmem_prd,

    output logic        memwb_valid,
    output logic [31:0] memwb_pc,
    output logic [31:0] memwb_inst,
    output logic [4:0]  memwb_rd,
    output logic [5:0]  memwb_prd,
    output logic        memwb_regwrite,
    output logic [31:0] memwb_wdata,
    output logic [2:0]  memwb_load_funct3,
    output logic        memwb_is_fp_load,

    output logic        stall_mem,

    output logic        mem_fault_redirect,
    output logic [31:0] mem_fault_mepc,
    output logic [31:0] mem_fault_mcause
);

    localparam logic [2:0] D_CMD_LD = 3'b001;

    logic mem_busy;
    logic mem_req_issued;

    // Snapshot of EX/MEM when this memory op started. While mem_busy, EX/MEM may advance (e.g. lw
    // followed by nops); d_req and d_resp completion must use this snapshot, not live exmem_*.
    logic [31:0] mem_p_pc;
    logic [31:0] mem_p_inst;
    logic        mem_p_valid;
    logic [4:0]  mem_p_rd;
    logic [5:0]  mem_p_prd;
    logic        mem_p_regwrite;
    logic        mem_p_is_load;
    logic        mem_p_is_store;
    logic        mem_p_is_amo;
    logic [31:0] mem_p_alu_result;
    logic [31:0] mem_p_mem_addr;
    logic [2:0]  mem_p_mem_cmd;
    logic [2:0]  mem_p_mem_size;
    logic [31:0] mem_p_store_wdata;
    logic [3:0]  mem_p_store_wstrb;
    logic [2:0]  mem_p_load_funct3;
    logic [4:0]  mem_p_amo_funct;
    logic        mem_p_amo_aq;
    logic        mem_p_amo_rl;
    logic        mem_p_is_fp_load;

    assign stall_mem = mem_busy;

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            mem_busy <= 1'b0;
            mem_req_issued <= 1'b0;

            d_req_valid <= 1'b0;
            d_req_addr  <= '0;
            d_req_cmd   <= D_CMD_LD;
            d_req_size  <= 3'd2;
            d_req_wdata <= '0;
            d_req_wstrb <= '0;
            d_req_amo_funct <= '0;
            d_req_amo_aq    <= 1'b0;
            d_req_amo_rl    <= 1'b0;

            memwb_valid <= 1'b0;
            memwb_pc <= '0;
            memwb_inst <= '0;
            memwb_rd <= '0;
            memwb_prd <= '0;
            memwb_regwrite <= 1'b0;
            memwb_wdata <= '0;
            memwb_load_funct3 <= '0;
            memwb_is_fp_load <= 1'b0;
            mem_fault_redirect <= 1'b0;
            mem_fault_mepc <= 32'b0;
            mem_fault_mcause <= 32'b0;
            mem_p_pc <= '0;
            mem_p_inst <= '0;
            mem_p_valid <= 1'b0;
            mem_p_rd <= '0;
            mem_p_prd <= '0;
            mem_p_regwrite <= 1'b0;
            mem_p_is_load <= 1'b0;
            mem_p_is_store <= 1'b0;
            mem_p_is_amo <= 1'b0;
            mem_p_alu_result <= '0;
            mem_p_mem_addr <= '0;
            mem_p_mem_cmd <= D_CMD_LD;
            mem_p_mem_size <= 3'd2;
            mem_p_store_wdata <= '0;
            mem_p_store_wstrb <= '0;
            mem_p_load_funct3 <= '0;
            mem_p_amo_funct <= '0;
            mem_p_amo_aq <= 1'b0;
            mem_p_amo_rl <= 1'b0;
            mem_p_is_fp_load <= 1'b0;
        end else begin
            // Single-cycle MEM/WB bubble: otherwise memwb_valid sticks high and WB retires the same
            // load every cycle until the next memory op completes.
            memwb_valid <= 1'b0;
            mem_fault_redirect <= 1'b0;
            if (!mem_busy) begin
                d_req_valid <= 1'b0;
                d_req_addr  <= '0;
                d_req_cmd   <= D_CMD_LD;
                d_req_size  <= 3'd2;
                d_req_wdata <= '0;
                d_req_wstrb <= '0;
                d_req_amo_funct <= '0;
                d_req_amo_aq    <= 1'b0;
                d_req_amo_rl    <= 1'b0;
            end

            if (!mem_busy) begin
                if (exmem_valid && (exmem_is_load || exmem_is_store || exmem_is_amo)) begin
                    mem_busy <= 1'b1;
                    mem_req_issued <= 1'b0;
                    mem_p_pc <= exmem_pc;
                    mem_p_inst <= exmem_inst;
                    mem_p_valid <= exmem_valid;
                    mem_p_rd <= exmem_rd;
                    mem_p_prd <= exmem_prd;
                    mem_p_regwrite <= exmem_regwrite;
                    mem_p_is_load <= exmem_is_load;
                    mem_p_is_store <= exmem_is_store;
                    mem_p_is_amo <= exmem_is_amo;
                    mem_p_alu_result <= exmem_alu_result;
                    mem_p_mem_addr <= exmem_mem_addr;
                    mem_p_mem_cmd <= exmem_mem_cmd;
                    mem_p_mem_size <= exmem_mem_size;
                    mem_p_store_wdata <= exmem_store_wdata;
                    mem_p_store_wstrb <= exmem_store_wstrb;
                    mem_p_load_funct3 <= exmem_load_funct3;
                    mem_p_amo_funct <= exmem_amo_funct;
                    mem_p_amo_aq <= exmem_amo_aq;
                    mem_p_amo_rl <= exmem_amo_rl;
                    mem_p_is_fp_load <= exmem_is_fp_load;
                end
            end

            if (mem_busy) begin
                if (!mem_req_issued) begin
                    d_req_valid <= 1'b1;
                    d_req_addr  <= mem_p_mem_addr;
                    d_req_cmd   <= mem_p_mem_cmd;
                    d_req_size  <= mem_p_mem_size;
                    d_req_wdata <= mem_p_store_wdata;
                    d_req_wstrb <= mem_p_store_wstrb;
                    d_req_amo_funct <= mem_p_amo_funct;
                    d_req_amo_aq    <= mem_p_amo_aq;
                    d_req_amo_rl    <= mem_p_amo_rl;

                    if (d_req_valid && d_req_ready) begin
                        mem_req_issued <= 1'b1;
                    end
                end else begin
                    // Prevent re-entry: NBAs below haven't taken effect yet,
                    // but blocking mem_req_issued guards against d_resp_valid
                    // staying high for multiple cycles.
                    mem_req_issued <= 1'b0;
                    d_req_valid <= 1'b0;
                    if (d_resp_valid) begin
                        if (d_resp_err) begin
                            mem_fault_redirect <= 1'b1;
                            mem_fault_mepc <= mem_p_pc;
                            if (mem_p_is_amo)
                                mem_fault_mcause <= 32'd7;
                            else
                                mem_fault_mcause <= mem_p_is_load ? 32'd5 : 32'd7;
                            memwb_valid <= 1'b0;
                        end else begin
                            memwb_valid <= mem_p_valid;
                            memwb_pc <= mem_p_pc;
                            memwb_inst <= mem_p_inst;
                            memwb_rd <= mem_p_rd;
                            memwb_prd <= mem_p_prd;
                            memwb_regwrite <= mem_p_regwrite;

                            if (mem_p_is_load || mem_p_is_amo) begin
                                memwb_load_funct3 <= mem_p_load_funct3;
                                memwb_wdata <= d_resp_rdata;
                                memwb_is_fp_load <= mem_p_is_fp_load;
                            end else begin
                                memwb_load_funct3 <= 3'b0;
                                memwb_wdata <= mem_p_alu_result;
                                memwb_is_fp_load <= 1'b0;
                            end
                        end

                        mem_busy <= 1'b0;
                    end
                end
            end
        end
    end

endmodule
