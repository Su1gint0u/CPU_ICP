// FPGA top-level: Nexys4 board integration.
// Integrates CPU core, branch predictor, synthesizable memory wrapper,
// UART RX/TX, and the UART bridge (transaction controller).

module fpga_top #(
    parameter int unsigned XLEN              = 32,
    parameter int unsigned FETCH_W           = 32,
    parameter logic [31:0]  RESET_PC         = 32'h8000_0000,
    parameter int unsigned IMEM_DEPTH_WORDS  = 4096,
    parameter int unsigned DMEM_DEPTH_WORDS  = 4096,
    parameter int unsigned SYS_CLK_HZ        = 50_000_000
) (
    input  logic        sys_clk_100m,
    input  logic        sys_rst_n,
    input  logic        uart_rxd,
    output logic        uart_txd,
    output logic [15:0] led_status
);

    // ---- All internal signal declarations ----
    logic        sys_clk;
    logic        sys_clk_locked;
    logic        sys_reset_n;

    logic        rx_line_idle;
    logic        rx_valid;
    logic [7:0]  rx_data;

    logic        uart_tx_start;
    logic [7:0]  uart_tx_data;
    logic        uart_tx_busy;

    logic                                    imem_wr_en;
    logic [$clog2(IMEM_DEPTH_WORDS)-1:0]    imem_wr_addr;
    logic [31:0]                             imem_wr_data;
    logic [3:0]                              imem_wr_be;
    logic                                    mem_clear_en;
    logic [$clog2(IMEM_DEPTH_WORDS)-1:0]     mem_clear_addr;
    logic                                    cpu_reset_n;

    logic        cpu_uart_tx_start;
    logic [7:0]  cpu_uart_tx_byte;
    logic        cpu_uart_tx_ready;

    logic        i_req_valid;
    logic        i_req_ready;
    logic [31:0] i_req_addr;
    logic        i_resp_valid;
    logic [FETCH_W-1:0] i_resp_data;
    logic        i_resp_err;

    logic        d_req_valid;
    logic        d_req_ready;
    logic [31:0] d_req_addr;
    logic [2:0]  d_req_cmd;
    logic [2:0]  d_req_size;
    logic [31:0] d_req_wdata;
    logic [3:0]  d_req_wstrb;
    logic [4:0]  d_req_amo_funct;
    logic        d_req_amo_aq;
    logic        d_req_amo_rl;
    logic        d_resp_valid;
    logic [31:0] d_resp_rdata;
    logic        d_resp_err;

    logic        ctl_req_valid;
    logic [2:0]  ctl_req_op;
    logic [31:0] ctl_req_addr;
    logic        ctl_done;
    logic        ctl_err;

    logic        mon_trap_occurred;
    logic [2:0]  bridge_dbg_state;
    logic [7:0]  bridge_dbg_status;

    logic        retire_valid;
    logic [31:0] retire_pc;
    logic [31:0] retire_inst;
    logic        retire_regwrite;
    logic [4:0]  retire_waddr;
    logic [31:0] retire_wdata;
    logic        retire1_valid;
    logic [31:0] retire1_pc;
    logic [31:0] retire1_inst;
    logic        retire1_regwrite;
    logic [4:0]  retire1_waddr;
    logic [31:0] retire1_wdata;
    logic [7:0]  perf_backend_flags;
    logic [7:0]  dbg_stall_flags;
    logic [7:0]  dbg_ex_flags;

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

    logic sys_rst_n_int;
    // Nexys4 DDR CPU_RESETN (C12) is active-low: unpressed=1, pressed=0.
    // Keep synthesis and simulation polarity identical so the MMCM is not
    // held in reset on hardware.
    assign sys_rst_n_int = sys_rst_n;

    fpga_sysclk_50m u_sysclk (
        .clk_100m (sys_clk_100m),
        .rst_n    (sys_rst_n_int),
        .clk_50m  (sys_clk),
        .locked   (sys_clk_locked)
    );

    assign sys_reset_n = sys_rst_n_int & sys_clk_locked;

    // ---- UART RX ----
    uart_rx #(
        .CLK_HZ(SYS_CLK_HZ), .BAUD(115200)
    ) u_uart_rx (
        .clk          (sys_clk), .rst_n (sys_reset_n),
        .rx           (uart_rxd),
        .rx_valid     (rx_valid), .rx_data (rx_data),
        .rx_line_idle (rx_line_idle)
    );

    // ---- UART TX ----
    uart_tx #(
        .CLK_HZ(SYS_CLK_HZ), .BAUD(115200)
    ) u_uart_tx (
        .clk      (sys_clk), .rst_n (sys_reset_n),
        .tx_start (uart_tx_start), .tx_data (uart_tx_data),
        .tx       (uart_txd), .tx_busy (uart_tx_busy),
        .uart_tx_line_idle ()
    );

    // ---- UART Bridge ----
    uart_bridge #(
        .CLK_HZ(SYS_CLK_HZ), .IMEM_DEPTH_WORDS(IMEM_DEPTH_WORDS),
        .IMEM_BASE(RESET_PC), .IDLE_GAP_THRESH(SYS_CLK_HZ / 2000),
        .TIMEOUT_CYCLES(SYS_CLK_HZ)
    ) u_bridge (
        .clk(sys_clk), .rst_n(sys_reset_n),
        .rx_line_idle(rx_line_idle), .rx_valid(rx_valid), .rx_data(rx_data),
        .tx_start(uart_tx_start), .tx_data(uart_tx_data), .tx_busy(uart_tx_busy),
        .cpu_uart_tx_start(cpu_uart_tx_start), .cpu_uart_tx_byte(cpu_uart_tx_byte),
        .cpu_uart_tx_ready(cpu_uart_tx_ready),
        .imem_wr_en(imem_wr_en), .imem_wr_addr(imem_wr_addr),
        .imem_wr_data(imem_wr_data), .imem_wr_be(imem_wr_be),
        .mem_clear_en(mem_clear_en), .mem_clear_addr(mem_clear_addr),
        .cpu_reset_n(cpu_reset_n), .mon_trap_occurred(mon_trap_occurred),
        .dbg_state(bridge_dbg_state), .dbg_status(bridge_dbg_status)
    );

    // ---- CPU core ----
    cpu_core #(
        .XLEN(XLEN), .FETCH_W(FETCH_W), .RESET_PC(RESET_PC)
    ) u_cpu (
        .pl_clk(sys_clk), .pl_resetn(cpu_reset_n & sys_reset_n),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_addr(i_req_addr),
        .i_resp_valid(i_resp_valid), .i_resp_data(i_resp_data), .i_resp_err(i_resp_err),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_addr(d_req_addr),
        .d_req_cmd(d_req_cmd), .d_req_size(d_req_size),
        .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_req_amo_funct(d_req_amo_funct), .d_req_amo_aq(d_req_amo_aq), .d_req_amo_rl(d_req_amo_rl),
        .d_resp_valid(d_resp_valid), .d_resp_rdata(d_resp_rdata), .d_resp_err(d_resp_err),
        .ctl_req_valid(ctl_req_valid), .ctl_req_op(ctl_req_op), .ctl_req_addr(ctl_req_addr),
        .ctl_done(ctl_done), .ctl_err(ctl_err),
        .bp_if_valid(bp_if_valid), .bp_if_pc(bp_if_pc),
        .bp_pred_taken(bp_pred_taken), .bp_pred_meta(bp_pred_meta),
        .bp_pred_taken1(bp_pred_taken1), .bp_pred_meta1(bp_pred_meta1),
        .bp_if_spec_taken(bp_if_spec_taken), .bp_if_spec_target(bp_if_spec_target),
        .bp_upd_valid(bp_upd_valid), .bp_upd_pc(bp_upd_pc),
        .bp_upd_taken(bp_upd_taken), .bp_upd_mispredict(bp_upd_mispredict),
        .bp_upd_meta(bp_upd_meta), .bp_upd_branch_target(bp_upd_branch_target),
        .irq_m_soft_i(1'b0), .irq_m_timer_i(1'b0), .irq_m_ext_i(1'b0),
        .retire_valid(retire_valid), .retire_pc(retire_pc), .retire_inst(retire_inst),
        .retire_regwrite(retire_regwrite), .retire_waddr(retire_waddr), .retire_wdata(retire_wdata),
        .retire1_valid(retire1_valid), .retire1_pc(retire1_pc), .retire1_inst(retire1_inst),
        .retire1_regwrite(retire1_regwrite), .retire1_waddr(retire1_waddr), .retire1_wdata(retire1_wdata),
        .mon_trap_occurred(mon_trap_occurred), .perf_backend_flags(perf_backend_flags),
        .dbg_stall_flags(dbg_stall_flags), .dbg_ex_flags(dbg_ex_flags)
    );

    // ---- Branch Predictor ----
    bp_predictor_simple u_bp (
        .pl_clk(sys_clk), .pl_resetn(cpu_reset_n & sys_reset_n),
        .bp_if_valid(bp_if_valid), .bp_if_pc(bp_if_pc),
        .bp_if_pc1(bp_if_pc + 32'd4),
        .bp_pred_taken(bp_pred_taken), .bp_pred_taken1(bp_pred_taken1),
        .bp_pred_meta(bp_pred_meta), .bp_pred_meta1(bp_pred_meta1),
        .bp_if_spec_taken(bp_if_spec_taken), .bp_if_spec_target(bp_if_spec_target),
        .bp_upd_valid(bp_upd_valid), .bp_upd_pc(bp_upd_pc),
        .bp_upd_taken(bp_upd_taken), .bp_upd_mispredict(bp_upd_mispredict),
        .bp_upd_meta(bp_upd_meta), .bp_upd_branch_target(bp_upd_branch_target)
    );

    // ---- Memory wrapper ----
    l1_mem_wrapper #(
        .IMEM_DEPTH_WORDS(IMEM_DEPTH_WORDS), .DMEM_DEPTH_WORDS(DMEM_DEPTH_WORDS),
        .XLEN(XLEN), .FETCH_W(FETCH_W)
    ) u_mem (
        .pl_clk(sys_clk), .pl_resetn(cpu_reset_n & sys_reset_n),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_addr(i_req_addr),
        .i_resp_valid(i_resp_valid), .i_resp_data(i_resp_data), .i_resp_err(i_resp_err),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_addr(d_req_addr),
        .d_req_cmd(d_req_cmd), .d_req_size(d_req_size), .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_req_amo_funct(d_req_amo_funct), .d_req_amo_aq(d_req_amo_aq), .d_req_amo_rl(d_req_amo_rl),
        .d_resp_valid(d_resp_valid), .d_resp_rdata(d_resp_rdata), .d_resp_err(d_resp_err),
        .ctl_req_valid(ctl_req_valid), .ctl_req_op(ctl_req_op), .ctl_req_addr(ctl_req_addr),
        .ctl_done(ctl_done), .ctl_err(ctl_err),
        .imem_wr_en(imem_wr_en), .imem_wr_addr(imem_wr_addr),
        .imem_wr_data(imem_wr_data), .imem_wr_be(imem_wr_be),
        .mem_clear_en(mem_clear_en), .mem_clear_addr(mem_clear_addr),
        .cpu_uart_tx_start(cpu_uart_tx_start), .cpu_uart_tx_byte(cpu_uart_tx_byte),
        .cpu_uart_tx_ready(cpu_uart_tx_ready)
    );

    // ---- ILA debug buses ----
    // Field order is documented in Nexys4/ILA_ACCEPTANCE.md. Keep the ILA
    // wiring local to this top-level integration instead of spreading debug
    // attributes through timing-sensitive CPU logic.
    logic [3:0]  probe_reset_bus;
    logic [8:0]  probe_uart_rx_bus;
    logic [12:0] probe_bridge_bus;
    logic [36+$clog2(IMEM_DEPTH_WORDS):0] probe_prog_bus;
    logic [$clog2(IMEM_DEPTH_WORDS):0]    probe_clear_bus;
    logic [75:0]  probe_mem_req_bus;
    logic [18:0]  probe_mmio_tx_bus;
    logic [102:0] probe_retire0_bus;
    logic [102:0] probe_retire1_bus;
    logic [67:0]  probe_bp_fetch_bus;
    logic [66:0]  probe_bp_update_bus;
    logic [24:0]  probe_cpu_debug_bus;
    logic [37:0]  probe_gpr_scan_bus;

    logic [31:0] dbg_gpr_mirror [0:31];
    logic [4:0]  dbg_gpr_scan_sel;
    logic [4:0]  dbg_gpr_scan_idx;
    logic [31:0] dbg_gpr_scan_data;
    logic        dbg_gpr_scan_valid;
    logic        dbg_gpr_retire_write;

    assign dbg_gpr_retire_write =
           (retire_valid && retire_regwrite && (retire_waddr != 5'd0))
        || (retire1_valid && retire1_regwrite && (retire1_waddr != 5'd0));

    always_ff @(posedge sys_clk) begin
        if (!(cpu_reset_n & sys_reset_n)) begin
            for (int gpr_i = 0; gpr_i < 32; gpr_i++)
                dbg_gpr_mirror[gpr_i] <= 32'd0;
            dbg_gpr_scan_sel   <= 5'd0;
            dbg_gpr_scan_idx   <= 5'd0;
            dbg_gpr_scan_data  <= 32'd0;
            dbg_gpr_scan_valid <= 1'b0;
        end else begin
            dbg_gpr_scan_idx   <= dbg_gpr_scan_sel;
            dbg_gpr_scan_data  <= dbg_gpr_mirror[dbg_gpr_scan_sel];
            dbg_gpr_scan_valid <= 1'b1;
            dbg_gpr_scan_sel   <= dbg_gpr_scan_sel + 5'd1;

            dbg_gpr_mirror[5'd0] <= 32'd0;
            if (retire_valid && retire_regwrite && (retire_waddr != 5'd0))
                dbg_gpr_mirror[retire_waddr] <= retire_wdata;
            if (retire1_valid && retire1_regwrite && (retire1_waddr != 5'd0))
                dbg_gpr_mirror[retire1_waddr] <= retire1_wdata;
        end
    end

    assign probe_reset_bus = {rx_line_idle, cpu_reset_n, sys_reset_n, sys_clk_locked};
    assign probe_uart_rx_bus = {rx_data, rx_valid};
    assign probe_bridge_bus = {cpu_uart_tx_ready, uart_tx_busy, bridge_dbg_status, bridge_dbg_state};
    assign probe_prog_bus = {imem_wr_data, imem_wr_addr, imem_wr_be, imem_wr_en};
    assign probe_clear_bus = {mem_clear_addr, mem_clear_en};
    assign probe_mem_req_bus = {
        d_req_wstrb,
        d_req_wdata,
        d_req_addr,
        d_req_size,
        d_req_cmd,
        d_req_ready,
        d_req_valid
    };
    assign probe_mmio_tx_bus = {
        uart_tx_busy,
        uart_tx_data,
        uart_tx_start,
        cpu_uart_tx_byte,
        cpu_uart_tx_start
    };
    assign probe_retire0_bus = {
        retire_wdata,
        retire_waddr,
        retire_regwrite,
        retire_inst,
        retire_pc,
        retire_valid
    };
    assign probe_retire1_bus = {
        retire1_wdata,
        retire1_waddr,
        retire1_regwrite,
        retire1_inst,
        retire1_pc,
        retire1_valid
    };
    assign probe_bp_fetch_bus = {
        bp_if_spec_target,
        bp_if_spec_taken,
        bp_pred_taken1,
        bp_pred_taken,
        bp_if_pc,
        bp_if_valid
    };
    assign probe_bp_update_bus = {
        bp_upd_branch_target,
        bp_upd_mispredict,
        bp_upd_taken,
        bp_upd_pc,
        bp_upd_valid
    };
    assign probe_cpu_debug_bus = {dbg_ex_flags, dbg_stall_flags, perf_backend_flags, mon_trap_occurred};
    assign probe_gpr_scan_bus = {dbg_gpr_scan_data, dbg_gpr_scan_idx, dbg_gpr_scan_valid};

`ifdef SYNTHESIS
    ila_cpu_uart_dbg u_ila_cpu_uart_dbg (
        .clk    (sys_clk),
        .probe0 (probe_reset_bus),
        .probe1 (probe_uart_rx_bus),
        .probe2 (probe_bridge_bus),
        .probe3 (probe_prog_bus),
        .probe4 (probe_clear_bus),
        .probe5 (probe_mem_req_bus),
        .probe6 (probe_mmio_tx_bus),
        .probe7 (probe_retire0_bus),
        .probe8 (probe_retire1_bus),
        .probe9 (probe_bp_fetch_bus),
        .probe10(probe_bp_update_bus),
        .probe11(probe_cpu_debug_bus),
        .probe12(cpu_reset_n),
        .probe13(imem_wr_en),
        .probe14(cpu_uart_tx_start),
        .probe15(mon_trap_occurred),
        .probe16(probe_gpr_scan_bus),
        .probe17(dbg_gpr_retire_write)
    );
`endif

    // ---- Status LEDs / debug ----
    logic rx_seen_q;
    logic tx_seen_q;
    logic cpu_run_seen_q;

    always_ff @(posedge sys_clk or negedge sys_reset_n) begin
        if (!sys_reset_n) begin
            rx_seen_q      <= 1'b0;
            tx_seen_q      <= 1'b0;
            cpu_run_seen_q <= 1'b0;
        end else begin
            if (rx_valid)
                rx_seen_q <= 1'b1;
            if (uart_tx_start)
                tx_seen_q <= 1'b1;
            if (cpu_reset_n)
                cpu_run_seen_q <= 1'b1;
        end
    end

    assign led_status[0]  = sys_rst_n_int;
    assign led_status[1]  = sys_clk_locked;
    assign led_status[2]  = sys_reset_n;
    assign led_status[3]  = rx_valid;
    assign led_status[4]  = rx_seen_q;
    assign led_status[5]  = uart_tx_busy;
    assign led_status[6]  = tx_seen_q;
    assign led_status[7]  = cpu_reset_n;
    assign led_status[8]  = cpu_run_seen_q;
    assign led_status[9]  = mon_trap_occurred;
    assign led_status[10] = rx_line_idle;
    assign led_status[11] = uart_txd;
    assign led_status[12] = i_req_valid;
    assign led_status[13] = d_req_valid;
    assign led_status[14] = retire_valid;
    assign led_status[15] = 1'b0;

endmodule

(* keep_hierarchy = "yes" *) module fpga_sysclk_50m (
    input  logic clk_100m,
    input  logic rst_n,
    output logic clk_50m,
    output logic locked
);

`ifdef SYNTHESIS
    logic clkfb_unbuf;
    logic clkfb_buf;
    logic clk50_unbuf;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(10.000),
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(10.000),
        .CLKFBOUT_PHASE(0.000),
        .CLKOUT0_DIVIDE_F(20.000),
        .CLKOUT0_DUTY_CYCLE(0.500),
        .CLKOUT0_PHASE(0.000),
        .STARTUP_WAIT("FALSE")
    ) u_mmcm (
        .CLKIN1(clk_100m),
        .CLKFBIN(clkfb_buf),
        .CLKFBOUT(clkfb_unbuf),
        .CLKFBOUTB(),
        .CLKOUT0(clk50_unbuf),
        .CLKOUT0B(),
        .CLKOUT1(),
        .CLKOUT1B(),
        .CLKOUT2(),
        .CLKOUT2B(),
        .CLKOUT3(),
        .CLKOUT3B(),
        .CLKOUT4(),
        .CLKOUT5(),
        .CLKOUT6(),
        .LOCKED(locked),
        .PWRDWN(1'b0),
        .RST(!rst_n)
    );

    BUFG u_clkfb_buf (
        .I(clkfb_unbuf),
        .O(clkfb_buf)
    );

    BUFG u_clk50_buf (
        .I(clk50_unbuf),
        .O(clk_50m)
    );
`else
    logic div_q;

    always_ff @(posedge clk_100m or negedge rst_n) begin
        if (!rst_n)
            div_q <= 1'b0;
        else
            div_q <= ~div_q;
    end

    assign clk_50m = div_q;
    assign locked  = rst_n;
`endif

endmodule
