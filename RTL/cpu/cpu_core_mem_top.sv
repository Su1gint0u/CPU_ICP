// Minimal simulation top: RV32 CPU + branch predictor + unified behavioral IMEM/DMEM (l1_mem_model).
// irq_m_* and retire_* exposed as ports for TB to drive / observe.

module cpu_core_mem_top #(
    parameter int unsigned XLEN              = 32,
    parameter int unsigned ISSUE_WIDTH        = 2,
    parameter int unsigned FETCH_W            = 64,
    parameter logic [31:0] RESET_PC        = 32'h8000_0000,
    parameter int unsigned MEM_DEPTH_WORDS = 65536,
    parameter string  IMEM_HEX             = ""
) (
    input logic sys_clk,
    input logic sys_rst_n,

    input  logic irq_m_soft_i,
    input  logic irq_m_timer_i,
    input  logic irq_m_ext_i,

    output logic        retire_valid,
    output logic [31:0] retire_pc,
    output logic [31:0] retire_inst,
    output logic        retire_regwrite,
    output logic [4:0]  retire_waddr,
    output logic [31:0] retire_wdata,

    output logic        mon_trap_occurred
);

    logic        bp_if_valid;
    logic [31:0] bp_if_pc;
    logic        bp_pred_taken;
    logic [63:0] bp_pred_meta;
    logic        bp_pred_taken1;
    logic [63:0] bp_pred_meta1;
    logic        bp_if_spec_taken;
    logic [31:0] bp_if_spec_target;
    logic        bp_upd_valid;
    logic [31:0] bp_upd_pc;
    logic        bp_upd_taken;
    logic        bp_upd_mispredict;
    logic [63:0] bp_upd_meta;
    logic [31:0] bp_upd_branch_target;

    logic                   i_req_valid;
    logic                   i_req_ready;
    logic [31:0]            i_req_addr;
    logic                   i_resp_valid;
    logic [FETCH_W-1:0]    i_resp_data;
    logic                   i_resp_err;

    logic                   d_req_valid;
    logic                   d_req_ready;
    logic [31:0]            d_req_addr;
    logic [2:0]             d_req_cmd;
    logic [2:0]             d_req_size;
    logic [XLEN-1:0]        d_req_wdata;
    logic [3:0]             d_req_wstrb;
    logic [4:0]             d_req_amo_funct;
    logic                   d_req_amo_aq;
    logic                   d_req_amo_rl;
    logic                   d_resp_valid;
    logic [XLEN-1:0]       d_resp_rdata;
    logic                   d_resp_err;

    logic                   ctl_req_valid;
    logic [2:0]             ctl_req_op;
    logic [31:0]            ctl_req_addr;
    logic                   ctl_done;
    logic                   ctl_err;

    cpu_core #(
        .XLEN    (XLEN),
        .FETCH_W (FETCH_W),
        .RESET_PC(RESET_PC)
    ) u_cpu (
        .pl_clk               (sys_clk),
        .pl_resetn            (sys_rst_n),
        .i_req_valid          (i_req_valid),
        .i_req_ready          (i_req_ready),
        .i_req_addr           (i_req_addr),
        .i_resp_valid         (i_resp_valid),
        .i_resp_data          (i_resp_data),
        .i_resp_err           (i_resp_err),
        .d_req_valid          (d_req_valid),
        .d_req_ready          (d_req_ready),
        .d_req_addr           (d_req_addr),
        .d_req_cmd            (d_req_cmd),
        .d_req_size           (d_req_size),
        .d_req_wdata          (d_req_wdata),
        .d_req_wstrb          (d_req_wstrb),
        .d_req_amo_funct      (d_req_amo_funct),
        .d_req_amo_aq         (d_req_amo_aq),
        .d_req_amo_rl         (d_req_amo_rl),
        .d_resp_valid         (d_resp_valid),
        .d_resp_rdata         (d_resp_rdata),
        .d_resp_err           (d_resp_err),
        .ctl_req_valid        (ctl_req_valid),
        .ctl_req_op           (ctl_req_op),
        .ctl_req_addr         (ctl_req_addr),
        .ctl_done             (ctl_done),
        .ctl_err              (ctl_err),
        .bp_if_valid          (bp_if_valid),
        .bp_if_pc             (bp_if_pc),
        .bp_pred_taken        (bp_pred_taken),
        .bp_pred_meta         (bp_pred_meta),
        .bp_pred_taken1       (bp_pred_taken1),
        .bp_pred_meta1        (bp_pred_meta1),
        .bp_if_spec_taken     (bp_if_spec_taken),
        .bp_if_spec_target    (bp_if_spec_target),
        .bp_upd_valid         (bp_upd_valid),
        .bp_upd_pc            (bp_upd_pc),
        .bp_upd_taken         (bp_upd_taken),
        .bp_upd_mispredict    (bp_upd_mispredict),
        .bp_upd_meta          (bp_upd_meta),
        .bp_upd_branch_target (bp_upd_branch_target),
        .irq_m_soft_i         (irq_m_soft_i),
        .irq_m_timer_i        (irq_m_timer_i),
        .irq_m_ext_i          (irq_m_ext_i),
        .retire_valid         (retire_valid),
        .retire_pc            (retire_pc),
        .retire_inst          (retire_inst),
        .retire_regwrite      (retire_regwrite),
        .retire_waddr         (retire_waddr),
        .retire_wdata         (retire_wdata),
        .mon_trap_occurred    (mon_trap_occurred),
        .perf_backend_flags   ()
    );

    bp_predictor_simple u_bp (
        .pl_clk               (sys_clk),
        .pl_resetn            (sys_rst_n),
        .bp_if_valid          (bp_if_valid),
        .bp_if_pc             (bp_if_pc),
        .bp_if_pc1            (bp_if_pc + 32'd4),
        .bp_pred_taken        (bp_pred_taken),
        .bp_pred_taken1       (bp_pred_taken1),
        .bp_pred_meta         (bp_pred_meta),
        .bp_pred_meta1        (bp_pred_meta1),
        .bp_if_spec_taken     (bp_if_spec_taken),
        .bp_if_spec_target    (bp_if_spec_target),
        .bp_upd_valid         (bp_upd_valid),
        .bp_upd_pc            (bp_upd_pc),
        .bp_upd_taken         (bp_upd_taken),
        .bp_upd_mispredict    (bp_upd_mispredict),
        .bp_upd_meta          (bp_upd_meta),
        .bp_upd_branch_target (bp_upd_branch_target)
    );

    l1_mem_model #(
        .DEPTH_WORDS(MEM_DEPTH_WORDS),
        .XLEN       (XLEN),
        .FETCH_W    (FETCH_W),
        .LINE_BYTES (32),
        .IMEM_HEX   (IMEM_HEX)
    ) u_mem (
        .pl_clk        (sys_clk),
        .pl_resetn     (sys_rst_n),
        .i_req_valid   (i_req_valid),
        .i_req_ready   (i_req_ready),
        .i_req_addr    (i_req_addr),
        .i_resp_valid  (i_resp_valid),
        .i_resp_data   (i_resp_data),
        .i_resp_err    (i_resp_err),
        .d_req_valid   (d_req_valid),
        .d_req_ready   (d_req_ready),
        .d_req_addr    (d_req_addr),
        .d_req_cmd     (d_req_cmd),
        .d_req_size    (d_req_size),
        .d_req_wdata   (d_req_wdata),
        .d_req_wstrb   (d_req_wstrb),
        .d_req_amo_funct(d_req_amo_funct),
        .d_req_amo_aq  (d_req_amo_aq),
        .d_req_amo_rl  (d_req_amo_rl),
        .d_resp_valid  (d_resp_valid),
        .d_resp_rdata  (d_resp_rdata),
        .d_resp_err    (d_resp_err),
        .ctl_req_valid (ctl_req_valid),
        .ctl_req_op    (ctl_req_op),
        .ctl_req_addr  (ctl_req_addr),
        .ctl_done      (ctl_done),
        .ctl_err       (ctl_err)
    );

endmodule
