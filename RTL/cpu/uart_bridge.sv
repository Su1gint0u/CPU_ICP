// UART Bridge: frame protocol FSM, transaction controller, IMEM programmer.
//
// Frame format (PC -> FPGA):
//   [UART idle gap ~1ms] [CMD 1B] [ADDR 4B LE] [LEN 4B LE] [DATA LEN B] [CHKSUM 1B]
//   CMD = 0x01 : write program to IMEM and execute
//
// Response (FPGA -> PC):
//   [UART idle gap] [CMD=0x02 1B] [STATUS 1B] [CHKSUM 1B]
//   STATUS: 0x00=normal(trap), 0x01=timeout, 0x02=len/range_err,
//           0x03=unsupported_cmd, 0xFF=chksum_err
//
// Transaction FSM:
//   IDLE -> RX_FRAME -> CHKSUM_CHECK -> RELEASE_CPU -> MONITOR -> SEND_RESP -> IDLE
//
// During MONITOR, CPU MMIO writes to UART TX address are forwarded to uart_tx.
// Completion: mon_trap_occurred OR timeout (~1s at 100MHz).

module uart_bridge #(
    parameter int unsigned CLK_HZ           = 100_000_000,
    parameter int unsigned IMEM_DEPTH_WORDS = 16384,
    parameter logic [31:0]  IMEM_BASE       = 32'h8000_0000,
    parameter int unsigned IDLE_GAP_THRESH  = 50000,
    parameter int unsigned TIMEOUT_CYCLES   = 100_000_000,
    parameter int unsigned TX_FIFO_DEPTH    = 16
) (
    input  logic        clk,
    input  logic        rst_n,

    // --- UART RX ---
    input  logic        rx_line_idle,
    input  logic        rx_valid,
    input  logic [7:0]  rx_data,

    // --- UART TX ---
    output logic        tx_start,
    output logic [7:0]  tx_data,
    input  logic        tx_busy,

    // --- CPU MMIO UART TX (from l1_mem_wrapper) ---
    input  logic        cpu_uart_tx_start,
    input  logic [7:0]  cpu_uart_tx_byte,
    output logic        cpu_uart_tx_ready,

    // --- IMEM write port ---
    output logic                        imem_wr_en,
    output logic [$clog2(IMEM_DEPTH_WORDS)-1:0] imem_wr_addr,
    output logic [31:0]                imem_wr_data,
    output logic [3:0]                 imem_wr_be,
    output logic                        mem_clear_en,
    output logic [$clog2(IMEM_DEPTH_WORDS)-1:0] mem_clear_addr,

    // --- CPU control ---
    output logic        cpu_reset_n,

    // --- CPU monitor ---
    input  logic        mon_trap_occurred,

    // --- Read-only debug monitor ---
    output logic [2:0]  dbg_state,
    output logic [7:0]  dbg_status
);

    localparam int unsigned AW = $clog2(IMEM_DEPTH_WORDS);
    localparam int unsigned TX_FIFO_AW = $clog2(TX_FIFO_DEPTH);
    localparam logic [TX_FIFO_AW:0] TX_FIFO_DEPTH_COUNT = TX_FIFO_DEPTH;

    localparam logic [7:0] CMD_WRITE_EXEC = 8'h01;
    localparam logic [7:0] RESP_CMD       = 8'h02;
    localparam logic [7:0] STATUS_OK      = 8'h00;
    localparam logic [7:0] STATUS_TIMEOUT = 8'h01;
    localparam logic [7:0] STATUS_RANGE   = 8'h02;
    localparam logic [7:0] STATUS_CMD     = 8'h03;
    localparam logic [7:0] STATUS_CHKSUM  = 8'hFF;

    typedef enum logic [2:0] {
        F_IDLE,
        F_RX_FRAME,
        F_CHKSUM_CHECK,
        F_RELEASE_CPU,
        F_MONITOR,
        F_DRAIN_TX,
        F_SEND_RESP
    } fsm_state_e;

    fsm_state_e state_q, state_nxt;

    logic [23:0] idle_gap_cnt_q,  idle_gap_cnt_nxt;
    logic [25:0] frame_byte_cnt_q, frame_byte_cnt_nxt;
    logic [31:0] frame_addr_q,    frame_addr_nxt;
    logic [31:0] frame_len_q,     frame_len_nxt;

    logic [7:0]  cmd_reg_q,       cmd_reg_nxt;
    logic [7:0]  chksum_calc_q,   chksum_calc_nxt;
    logic [7:0]  chksum_rx_q,     chksum_rx_nxt;
    logic        chksum_ok;

    // Word assembly from UART bytes
    logic [31:0] word_buf_q, word_buf_nxt;
    logic [1:0]  word_byte_q, word_byte_nxt;
    logic [31:0] partial_word_data;
    logic [AW-1:0] wr_addr_q, wr_addr_nxt;
    logic [AW-1:0] clear_addr_q, clear_addr_nxt;

    logic [27:0] timeout_cnt_q, timeout_cnt_nxt;

    logic [23:0] resp_idle_q, resp_idle_nxt;
    logic [2:0]  resp_phase_q, resp_phase_nxt;
    logic [7:0]  resp_data_q, resp_data_nxt;
    logic [7:0]  resp_status_q, resp_status_nxt;
    logic        resp_tx_req_q, resp_tx_req_nxt;

    logic        frame_start;
    logic        idle_reset;
    logic        frame_addr_bad;
    logic        frame_len_bad;
    logic        frame_range_bad;
    logic        payload_write_en;
    logic [31:0] frame_start_word;
    logic [31:0] frame_words;

    logic [7:0]                  cpu_fifo_mem_q [0:TX_FIFO_DEPTH-1];
    logic [TX_FIFO_AW-1:0]       cpu_fifo_wr_ptr_q, cpu_fifo_wr_ptr_nxt;
    logic [TX_FIFO_AW-1:0]       cpu_fifo_rd_ptr_q, cpu_fifo_rd_ptr_nxt;
    logic [TX_FIFO_AW:0]         cpu_fifo_count_q, cpu_fifo_count_nxt;
    logic                        cpu_fifo_push;
    logic                        cpu_fifo_pop;
    logic                        cpu_tx_state;

    // ---- idle gap detection ----
    assign frame_start = (idle_gap_cnt_q >= IDLE_GAP_THRESH) && rx_valid;
    assign idle_reset  = (idle_gap_cnt_q >= IDLE_GAP_THRESH);

    assign chksum_ok = (chksum_calc_q == chksum_rx_q);

    assign frame_start_word = (frame_addr_q - IMEM_BASE) >> 2;
    assign frame_words      = (frame_len_q + 32'd3) >> 2;
    assign frame_addr_bad   = (frame_addr_q < IMEM_BASE) || (frame_addr_q[1:0] != 2'b00);
    assign frame_len_bad    = (frame_len_q == 32'd0) || (frame_len_q > (IMEM_DEPTH_WORDS * 4));
    assign frame_range_bad  = frame_addr_bad || frame_len_bad
                            || (frame_words > IMEM_DEPTH_WORDS)
                            || (frame_start_word > IMEM_DEPTH_WORDS)
                            || ((frame_start_word + frame_words) > IMEM_DEPTH_WORDS);
    assign payload_write_en = (cmd_reg_q == CMD_WRITE_EXEC) && !frame_range_bad;
    assign partial_word_data = (word_byte_q == 2'd1) ? {24'd0, word_buf_q[31:24]} :
                               (word_byte_q == 2'd2) ? {16'd0, word_buf_q[31:16]} :
                                                       {8'd0,  word_buf_q[31:8]};

    assign cpu_tx_state = (state_q == F_MONITOR) || (state_q == F_DRAIN_TX);
    assign cpu_fifo_pop = cpu_tx_state && !tx_busy && (cpu_fifo_count_q != '0);
    assign cpu_uart_tx_ready = cpu_tx_state
                            && ((cpu_fifo_count_q < TX_FIFO_DEPTH_COUNT) || cpu_fifo_pop);
    assign cpu_fifo_push = cpu_uart_tx_start && cpu_uart_tx_ready;
    assign dbg_state  = state_q;
    assign dbg_status = resp_status_q;

    // ---- TX mux: bridge vs CPU MMIO ----
    always_comb begin
        tx_start = 1'b0;
        tx_data  = 8'd0;
        if (state_q == F_SEND_RESP) begin
            tx_start = resp_tx_req_q;
            tx_data  = resp_data_q;
        end else if (cpu_fifo_pop) begin
            tx_start = 1'b1;
            tx_data  = cpu_fifo_mem_q[cpu_fifo_rd_ptr_q];
        end
    end

    // ---- FSM ----
    always_comb begin
        state_nxt        = state_q;
        idle_gap_cnt_nxt = idle_gap_cnt_q;
        frame_byte_cnt_nxt = frame_byte_cnt_q;
        frame_addr_nxt   = frame_addr_q;
        frame_len_nxt    = frame_len_q;
        cmd_reg_nxt      = cmd_reg_q;
        chksum_calc_nxt  = chksum_calc_q;
        chksum_rx_nxt    = chksum_rx_q;
        word_buf_nxt     = word_buf_q;
        word_byte_nxt    = word_byte_q;
        wr_addr_nxt      = wr_addr_q;
        clear_addr_nxt   = clear_addr_q;
        timeout_cnt_nxt  = timeout_cnt_q;
        resp_idle_nxt    = resp_idle_q;
        resp_phase_nxt   = resp_phase_q;
        resp_data_nxt    = resp_data_q;
        resp_status_nxt  = resp_status_q;
        resp_tx_req_nxt  = resp_tx_req_q;
        cpu_fifo_wr_ptr_nxt = cpu_fifo_wr_ptr_q;
        cpu_fifo_rd_ptr_nxt = cpu_fifo_rd_ptr_q;
        cpu_fifo_count_nxt  = cpu_fifo_count_q;
        imem_wr_en       = 1'b0;
        imem_wr_addr     = wr_addr_q;
        imem_wr_data     = word_buf_q;
        imem_wr_be       = 4'b1111;
        mem_clear_en     = 1'b0;
        mem_clear_addr   = clear_addr_q;
        cpu_reset_n      = 1'b0;

        if (cpu_fifo_pop) begin
            cpu_fifo_rd_ptr_nxt = cpu_fifo_rd_ptr_q + 1'b1;
            cpu_fifo_count_nxt  = cpu_fifo_count_nxt - 1'b1;
        end
        if (cpu_fifo_push) begin
            cpu_fifo_wr_ptr_nxt = cpu_fifo_wr_ptr_q + 1'b1;
            cpu_fifo_count_nxt  = cpu_fifo_count_nxt + 1'b1;
        end

        if (rx_valid)
            idle_gap_cnt_nxt = '0;
        else if (idle_gap_cnt_q < IDLE_GAP_THRESH)
            idle_gap_cnt_nxt = idle_gap_cnt_q + 1'b1;

        unique case (state_q)
            F_IDLE: begin
                cpu_reset_n = 1'b0;
                frame_byte_cnt_nxt = '0;
                chksum_calc_nxt     = 8'd0;
                word_buf_nxt = '0;
                word_byte_nxt = '0;
                wr_addr_nxt  = '0;
                timeout_cnt_nxt = '0;
                resp_phase_nxt = '0;
                resp_idle_nxt  = '0;
                resp_status_nxt = STATUS_OK;
                if (!rx_valid) begin
                    mem_clear_en   = 1'b1;
                    mem_clear_addr = clear_addr_q;
                    clear_addr_nxt = clear_addr_q + 1'b1;
                end

                if (frame_start) begin
                    cmd_reg_nxt      = rx_data;
                    chksum_calc_nxt  = rx_data;
                    frame_addr_nxt   = '0;
                    frame_len_nxt    = '0;
                    frame_byte_cnt_nxt = 26'd1;
                    clear_addr_nxt   = '0;
                    cpu_fifo_wr_ptr_nxt = '0;
                    cpu_fifo_rd_ptr_nxt = '0;
                    cpu_fifo_count_nxt  = '0;
                    state_nxt = F_RX_FRAME;
                end
            end

            F_RX_FRAME: begin
                cpu_reset_n = 1'b0;

                if (rx_valid) begin
                    // XOR all frame bytes except CHKSUM (which is byte index frame_len_q after data)
                    if ((frame_byte_cnt_q - 26'd9) != frame_len_q) begin
                        chksum_calc_nxt = chksum_calc_q ^ rx_data;
                    end
                    frame_byte_cnt_nxt = frame_byte_cnt_q + 1'b1;

                    // Byte 1-4: address (LE)
                    if (frame_byte_cnt_q < 26'd5) begin
                        frame_addr_nxt = {rx_data, frame_addr_q[31:8]};
                    end
                    // Byte 5-8: length (LE)
                    else if (frame_byte_cnt_q < 26'd9) begin
                        frame_len_nxt = {rx_data, frame_len_q[31:8]};
                    end
                    // Byte 9+: data payload
                    else if ((frame_byte_cnt_q - 26'd9) < frame_len_q) begin
                        word_buf_nxt = {rx_data, word_buf_q[31:8]};
                        if (word_byte_q == 2'd3) begin
                            if (payload_write_en) begin
                                imem_wr_en   = 1'b1;
                                imem_wr_addr = wr_addr_q;
                                imem_wr_data = {rx_data, word_buf_q[31:8]};
                                imem_wr_be   = 4'b1111;
                            end
                            word_byte_nxt = 2'd0;
                            wr_addr_nxt = wr_addr_q + 1'b1;
                        end else begin
                            word_byte_nxt = word_byte_q + 1'b1;
                        end
                    end
                    // After data: checksum byte
                    else if ((frame_byte_cnt_q - 26'd9) == frame_len_q) begin
                        chksum_rx_nxt = rx_data;
                        state_nxt = F_CHKSUM_CHECK;
                    end

                    // Set initial wr_addr from frame address
                    if (frame_byte_cnt_q == 26'd5) begin
                        wr_addr_nxt = ((frame_addr_q - IMEM_BASE) >> 2);
                        word_byte_nxt = '0;
                    end
                end
                // Reset on spurious idle gap (long gap during frame = error)
                if (idle_reset) begin
                    state_nxt = F_IDLE;
                end
            end

            F_CHKSUM_CHECK: begin
                cpu_reset_n = 1'b0;
                resp_phase_nxt = '0;
                resp_idle_nxt  = '0;
                resp_tx_req_nxt = 1'b0;

                if (chksum_calc_q != chksum_rx_q) begin
                    resp_status_nxt = STATUS_CHKSUM;
                    state_nxt = F_SEND_RESP;
                end else if (cmd_reg_q != CMD_WRITE_EXEC) begin
                    resp_status_nxt = STATUS_CMD;
                    state_nxt = F_SEND_RESP;
                end else if (frame_range_bad) begin
                    resp_status_nxt = STATUS_RANGE;
                    state_nxt = F_SEND_RESP;
                end else begin
                    // Write leftover partial word if any
                    if (word_byte_q != 2'd0) begin
                        imem_wr_en   = 1'b1;
                        imem_wr_addr = wr_addr_q;
                        imem_wr_data = partial_word_data;
                        imem_wr_be   = (word_byte_q == 2'd1) ? 4'b0001 :
                                       (word_byte_q == 2'd2) ? 4'b0011 : 4'b0111;
                    end
                    state_nxt = F_RELEASE_CPU;
                end
            end

            F_RELEASE_CPU: begin
                cpu_reset_n = 1'b1;
                timeout_cnt_nxt = '0;
                state_nxt = F_MONITOR;
            end

            F_MONITOR: begin
                cpu_reset_n = 1'b1;
                timeout_cnt_nxt = timeout_cnt_q + 1'b1;

                if (mon_trap_occurred) begin
                    resp_status_nxt = STATUS_OK;
                    resp_phase_nxt  = '0;
                    resp_idle_nxt   = '0;
                    resp_tx_req_nxt = 1'b0;
                    state_nxt = F_DRAIN_TX;
                end else if (timeout_cnt_q >= TIMEOUT_CYCLES) begin
                    resp_status_nxt = STATUS_TIMEOUT;
                    resp_phase_nxt  = '0;
                    resp_idle_nxt   = '0;
                    resp_tx_req_nxt = 1'b0;
                    state_nxt = F_DRAIN_TX;
                end
            end

            F_DRAIN_TX: begin
                cpu_reset_n = 1'b0;
                if ((cpu_fifo_count_q == '0) && !tx_busy) begin
                    resp_phase_nxt  = '0;
                    resp_idle_nxt   = '0;
                    resp_tx_req_nxt = 1'b0;
                    state_nxt = F_SEND_RESP;
                end
            end

            F_SEND_RESP: begin
                cpu_reset_n = 1'b0;
                resp_idle_nxt = resp_idle_q + 1'b1;
                // resp_tx_req pulses get cleared when uart_tx latches (tx_busy rises)
                resp_tx_req_nxt = resp_tx_req_q && !tx_busy;

                // Response frame: [idle gap] [CMD=0x02] [STATUS] [CHKSUM]
                // resp_phase: 0=idle_gap, 1=CMD, 2=STATUS, 3=CHKSUM
                if (resp_phase_q == 3'd0) begin
                    if (resp_idle_q >= 24'd100000) begin
                        resp_phase_nxt  = 3'd1;
                        resp_data_nxt   = RESP_CMD;
                        resp_tx_req_nxt = 1'b1;
                    end
                end else if (resp_phase_q == 3'd1) begin
                    if (tx_busy)
                        resp_tx_req_nxt = 1'b0;
                    else if (!resp_tx_req_q) begin
                        resp_phase_nxt  = 3'd2;
                        resp_data_nxt   = resp_status_q;
                        resp_tx_req_nxt = 1'b1;
                    end
                end else if (resp_phase_q == 3'd2) begin
                    if (tx_busy)
                        resp_tx_req_nxt = 1'b0;
                    else if (!resp_tx_req_q) begin
                        resp_phase_nxt  = 3'd3;
                        resp_data_nxt   = RESP_CMD ^ resp_status_q;
                        resp_tx_req_nxt = 1'b1;
                    end
                end else if (resp_phase_q == 3'd3) begin
                    if (tx_busy)
                        resp_tx_req_nxt = 1'b0;
                    else if (!resp_tx_req_q) begin
                        state_nxt = F_IDLE;
                    end
                end
            end

            default: state_nxt = F_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idle_gap_cnt_q <= '0;
            timeout_cnt_q  <= '0;
            resp_idle_q    <= '0;
            resp_phase_q   <= '0;
            resp_data_q    <= '0;
            resp_status_q  <= STATUS_OK;
            resp_tx_req_q  <= '0;
            cpu_fifo_wr_ptr_q <= '0;
            cpu_fifo_rd_ptr_q <= '0;
            cpu_fifo_count_q  <= '0;
        end else begin
`ifndef SYNTHESIS
            if ($test$plusargs("BRIDGE_DBG")) begin
                if (state_q != state_nxt)
                    $display("[BRIDGE] t=%0t state %0d -> %0d", $time, state_q, state_nxt);
                if (imem_wr_en)
                    $display("[BRIDGE] t=%0t IMEM_WR addr=%0d data=0x%08h", $time, imem_wr_addr, imem_wr_data);
                if (mon_trap_occurred)
                    $display("[BRIDGE] t=%0t TRAP_DETECTED", $time);
                if (state_nxt == F_CHKSUM_CHECK)
                    $display("[BRIDGE] t=%0t CHKSUM calc=0x%02h rx=0x%02h OK=%0b", $time, chksum_calc_q, chksum_rx_nxt, (chksum_calc_q == chksum_rx_nxt));
            end
`endif
            idle_gap_cnt_q <= idle_gap_cnt_nxt;
            timeout_cnt_q  <= timeout_cnt_nxt;
            resp_idle_q    <= resp_idle_nxt;
            resp_phase_q   <= resp_phase_nxt;
            resp_data_q    <= resp_data_nxt;
            resp_status_q  <= resp_status_nxt;
            resp_tx_req_q  <= resp_tx_req_nxt;
            cpu_fifo_wr_ptr_q <= cpu_fifo_wr_ptr_nxt;
            cpu_fifo_rd_ptr_q <= cpu_fifo_rd_ptr_nxt;
            cpu_fifo_count_q  <= cpu_fifo_count_nxt;
        end
    end

    // state_q feeds cpu_reset_n, which reaches the DMEM BRAM read-address
    // cone through the CPU data-port registers. Keep that release control on
    // a synchronous reset path so Vivado can time the BRAM address pins.
    always_ff @(posedge clk) begin
        if (!rst_n)
            state_q <= F_IDLE;
        else
            state_q <= state_nxt;
    end

    // These bridge registers feed the mirrored IMEM/DMEM programming cone.
    // Keep their reset assertion timed while leaving the transaction FSM reset
    // behavior unchanged.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            frame_byte_cnt_q <= '0;
            frame_addr_q <= '0;
            frame_len_q  <= '0;
            cmd_reg_q    <= '0;
            chksum_calc_q<= '0;
            chksum_rx_q  <= '0;
            word_buf_q   <= '0;
            word_byte_q  <= '0;
            wr_addr_q    <= '0;
            clear_addr_q <= '0;
        end else begin
            frame_byte_cnt_q <= frame_byte_cnt_nxt;
            frame_addr_q <= frame_addr_nxt;
            frame_len_q  <= frame_len_nxt;
            cmd_reg_q    <= cmd_reg_nxt;
            chksum_calc_q<= chksum_calc_nxt;
            chksum_rx_q  <= chksum_rx_nxt;
            word_buf_q   <= word_buf_nxt;
            word_byte_q  <= word_byte_nxt;
            wr_addr_q    <= wr_addr_nxt;
            clear_addr_q <= clear_addr_nxt;
        end
    end

    always_ff @(posedge clk) begin
        if (cpu_fifo_push)
            cpu_fifo_mem_q[cpu_fifo_wr_ptr_q] <= cpu_uart_tx_byte;
    end

endmodule
