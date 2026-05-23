// M-mode CSR file: Zicsr + counters + mip/mie + mtvec MODE; WARL on key fields.
// Trap / irq priority (single commit per cycle): mem fault > ctl fault > insn trap > irq > CSR write.

module cpu_csr_file #(
    parameter logic [31:0] P_MISA       = 32'h4000_1121,
    parameter logic [31:0] P_MVENDORID  = 32'h0,
    parameter logic [31:0] P_MARCHID    = 32'h0,
    parameter logic [31:0] P_MIMPID     = 32'h0,
    parameter logic [31:0] P_MHARTID    = 32'h0,
    parameter logic [31:0] P_RESET_MTVEC = 32'h8000_0000
) (
    input  logic        pl_clk,
    input  logic        pl_resetn,

    input  logic [11:0] csr_raddr,
    output logic [31:0] csr_rdata,

    input  logic        csr_wr_en,
    input  logic [11:0] csr_wr_addr,
    input  logic [31:0] csr_wr_data,

    input  logic        trap_mem,
    input  logic [31:0] trap_mem_mepc,
    input  logic [31:0] trap_mem_mcause,

    input  logic        trap_ctl,
    input  logic [31:0] trap_ctl_mepc,

    input  logic        trap_insn,
    input  logic [31:0] trap_insn_mepc,
    input  logic [31:0] trap_insn_mcause,

    input  logic        irq_take,
    input  logic [31:0] irq_mepc,
    input  logic [31:0] irq_mcause_val,

    input  logic        mret_taken,

    input  logic        irq_m_soft_i,
    input  logic        irq_m_timer_i,
    input  logic        irq_m_ext_i,

    input  logic        minstret_inc,

    input  logic        fp_fflags_we,
    input  logic [4:0]   fp_fflags_inc,

    // FLW completes in MEM/WB: FPR written when FS != Off (see core).
    input  logic        fp_fs_dirty_evt,

    output logic [31:0] mtvec_q_o,
    output logic [31:0] mepc_q_o,
    output logic [31:0] mstatus_q_o,
    output logic [31:0] mie_q_o,
    output logic [31:0] mip_live_o,
    output logic [2:0]  frm_q_o
);

    logic [31:0] mstatus_q;
    logic [31:0] mie_q;
    logic [31:0] mscratch_q;
    logic [31:0] mtvec_q;
    logic [31:0] mepc_q;
    logic [31:0] mcause_q;
    logic        mip_msip_q;

    logic [4:0]  fflags_q;
    logic [2:0]  frm_q;

    logic [31:0] mcycle_q;
    logic [31:0] mcycleh_q;
    logic [31:0] minstret_q;
    logic [31:0] minstreth_q;
    logic [31:0] mcountinhibit_q;

    wire [31:0] mip_comb = {20'b0, irq_m_ext_i, 3'b0, irq_m_timer_i, 3'b0, (mip_msip_q | irq_m_soft_i), 3'b0};

    assign mtvec_q_o   = mtvec_q;
    assign mepc_q_o    = mepc_q;
    assign mstatus_q_o = mstatus_q;
    assign mie_q_o     = mie_q;
    assign mip_live_o  = mip_comb;
    assign frm_q_o     = frm_q;

`ifndef SYNTHESIS
    initial begin
        if ($test$plusargs("CSR_DBG"))
            $display("[CSR_DBG] %m P_MHARTID=0x%08x", P_MHARTID);
    end
`endif

    // SD (mstatus[31]) is read-only summary: set when FS == Dirty (no XS).
    wire mstatus_sd_ro = (mstatus_q[14:13] == 2'b11);

    localparam logic [31:0] WMASK_MIE  = 32'h0000_0888;
    localparam logic [31:0] WMASK_MIP  = 32'h0000_0008;

    function automatic logic [31:0] warl_mstatus_wr(input logic [31:0] w);
        logic [31:0] x;
        begin
            x = mstatus_q;
            x[3]      = w[3];
            x[7]      = w[7];
            x[14:13]  = w[14:13];
            x[12:11]  = 2'b11;
            warl_mstatus_wr = x;
        end
    endfunction

    function automatic logic [31:0] warl_mtvec_wr(input logic [31:0] w);
        begin
            warl_mtvec_wr = {w[31:2], w[1:0] & 2'b11};
        end
    endfunction

    always_comb begin
        unique case (csr_raddr)
            12'h300: csr_rdata = {mstatus_sd_ro, mstatus_q[30:0]};
            12'h301: csr_rdata = P_MISA;
            12'h304: csr_rdata = mie_q;
            12'h305: csr_rdata = mtvec_q;
            12'h320: csr_rdata = mcountinhibit_q;
            12'h340: csr_rdata = mscratch_q;
            12'h341: csr_rdata = mepc_q;
            12'h342: csr_rdata = mcause_q;
            12'h344: csr_rdata = mip_comb;
            12'h001: csr_rdata = {27'b0, fflags_q};
            12'h002: csr_rdata = {29'b0, frm_q};
            12'h003: csr_rdata = {24'b0, frm_q, fflags_q};
            12'hB00: csr_rdata = mcycle_q;
            12'hB02: csr_rdata = minstret_q;
            12'hB80: csr_rdata = mcycleh_q;
            12'hB82: csr_rdata = minstreth_q;
            12'hF11: csr_rdata = P_MVENDORID;
            12'hF12: csr_rdata = P_MARCHID;
            12'hF13: csr_rdata = P_MIMPID;
            12'hF14: csr_rdata = P_MHARTID;
            default: csr_rdata = 32'b0;
        endcase
    end

`ifndef SYNTHESIS
    always_ff @(posedge pl_clk) begin
        if (pl_resetn && $test$plusargs("CSR_DBG") && csr_raddr == 12'hF14)
            $display("[CSR_DBG] read %m t=%0t raddr=0x%03x rdata=0x%08x", $time, csr_raddr, csr_rdata);
    end
`endif

    wire mcycle_en    = !mcountinhibit_q[0];
    wire minstret_en  = !mcountinhibit_q[2];

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            mstatus_q        <= 32'h0000_1800;
            mie_q            <= 32'b0;
            mscratch_q       <= 32'b0;
            mtvec_q          <= P_RESET_MTVEC;
            mepc_q           <= 32'b0;
            mcause_q         <= 32'b0;
            mip_msip_q       <= 1'b0;
            fflags_q         <= 5'b0;
            frm_q            <= 3'b0;
            mcycle_q         <= 32'b0;
            mcycleh_q        <= 32'b0;
            minstret_q       <= 32'b0;
            minstreth_q      <= 32'b0;
            mcountinhibit_q  <= 32'b0;
        end else begin
            if (fp_fflags_we) begin
                fflags_q <= fflags_q | fp_fflags_inc;
                if (mstatus_q[14:13] != 2'b00)
                    mstatus_q[14:13] <= 2'b11;
            end

            // FLW WB commit: before trap/CSR so a same-cycle CSRW mstatus wins over FS.
            if (fp_fs_dirty_evt && (mstatus_q[14:13] != 2'b00))
                mstatus_q[14:13] <= 2'b11;

            if (trap_mem) begin
                mepc_q     <= trap_mem_mepc;
                mcause_q   <= trap_mem_mcause;
                mstatus_q[7] <= mstatus_q[3];
                mstatus_q[3] <= 1'b0;
                mstatus_q[12:11] <= 2'b11;
            end else if (trap_ctl) begin
                mepc_q     <= trap_ctl_mepc;
                mcause_q   <= 32'd2;
                mstatus_q[7] <= mstatus_q[3];
                mstatus_q[3] <= 1'b0;
                mstatus_q[12:11] <= 2'b11;
            end else if (trap_insn) begin
                mepc_q     <= trap_insn_mepc;
                mcause_q   <= trap_insn_mcause;
                mstatus_q[7] <= mstatus_q[3];
                mstatus_q[3] <= 1'b0;
                mstatus_q[12:11] <= 2'b11;
            end else if (irq_take) begin
                mepc_q     <= irq_mepc;
                mcause_q   <= irq_mcause_val;
                mstatus_q[7] <= mstatus_q[3];
                mstatus_q[3] <= 1'b0;
                mstatus_q[12:11] <= 2'b11;
            end else if (csr_wr_en) begin
                unique case (csr_wr_addr)
                    12'h300: mstatus_q <= warl_mstatus_wr(csr_wr_data);
                    12'h301: ;
                    12'h304: mie_q <= csr_wr_data & WMASK_MIE;
                    12'h305: mtvec_q <= warl_mtvec_wr(csr_wr_data);
                    12'h320: mcountinhibit_q <= csr_wr_data & 32'h0000_007D;
                    12'h340: mscratch_q <= csr_wr_data;
                    12'h341: mepc_q     <= csr_wr_data & ~32'd2;
                    12'h342: mcause_q   <= csr_wr_data;
                    12'h344: mip_msip_q <= csr_wr_data[3];
                    12'h001: begin
                        fflags_q <= csr_wr_data[4:0];
                        if (mstatus_q[14:13] != 2'b00)
                            mstatus_q[14:13] <= 2'b11;
                    end
                    12'h002: begin
                        frm_q <= csr_wr_data[2:0];
                        if (mstatus_q[14:13] != 2'b00)
                            mstatus_q[14:13] <= 2'b11;
                    end
                    12'h003: begin
                        frm_q    <= csr_wr_data[7:5];
                        fflags_q <= csr_wr_data[4:0];
                        if (mstatus_q[14:13] != 2'b00)
                            mstatus_q[14:13] <= 2'b11;
                    end
                    default: ;
                endcase
            end

            if (mret_taken && !trap_mem && !trap_ctl && !trap_insn && !irq_take) begin
                mstatus_q[3] <= mstatus_q[7];
                mstatus_q[7] <= 1'b1;
            end

            if (!trap_mem && !trap_ctl && !trap_insn && !irq_take) begin
                if (csr_wr_en) begin
                    unique case (csr_wr_addr)
                        12'hB00: mcycle_q    <= csr_wr_data;
                        12'hB80: mcycleh_q   <= csr_wr_data;
                        12'hB02: minstret_q  <= csr_wr_data;
                        12'hB82: minstreth_q <= csr_wr_data;
                        default: ;
                    endcase
                end
                if (!(csr_wr_en && csr_wr_addr == 12'hB00) && mcycle_en) begin
                    {mcycleh_q, mcycle_q} <= {mcycleh_q, mcycle_q} + 64'd1;
                end
                if (!(csr_wr_en && csr_wr_addr == 12'hB02) && minstret_en && minstret_inc) begin
                    {minstreth_q, minstret_q} <= {minstreth_q, minstret_q} + 64'd1;
                end
            end else begin
                if (mcycle_en && !(csr_wr_en && csr_wr_addr == 12'hB00)) begin
                    {mcycleh_q, mcycle_q} <= {mcycleh_q, mcycle_q} + 64'd1;
                end
                if (minstret_en && minstret_inc && !(csr_wr_en && csr_wr_addr == 12'hB02)) begin
                    {minstreth_q, minstret_q} <= {minstreth_q, minstret_q} + 64'd1;
                end
            end
        end
    end

endmodule
