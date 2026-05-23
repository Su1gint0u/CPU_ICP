// Direct uart_bridge protocol test.
// Bypasses bit-level UART RX and checks parser status, IMEM writes, partial tails,
// CPU UART FIFO drain, and response frames.

`timescale 1ns / 1ps

module tb_uart_bridge;

    localparam int unsigned CLK_HZ           = 100_000_000;
    localparam int unsigned IMEM_DEPTH_WORDS = 64;
    localparam logic [31:0]  RESET_PC        = 32'h8000_0000;
    localparam int unsigned AW               = $clog2(IMEM_DEPTH_WORDS);
    localparam int unsigned WAIT_CYCLES      = 1_000_000;

    logic clk;
    logic rst_n;
    logic rx_line_idle;
    logic rx_valid;
    logic [7:0] rx_data;

    logic        uart_tx_start;
    logic [7:0]  uart_tx_data;
    logic        uart_tx_busy;
    logic [7:0]  tx_seen_q [$];
    int unsigned tx_busy_cnt;

    logic        cpu_uart_tx_start;
    logic [7:0]  cpu_uart_tx_byte;
    logic        cpu_uart_tx_ready;

    logic        imem_wr_en;
    logic [AW-1:0] imem_wr_addr;
    logic [31:0] imem_wr_data;
    logic [3:0]  imem_wr_be;
    logic        mem_clear_en;
    logic [AW-1:0] mem_clear_addr;
    logic        cpu_reset_n;
    logic        mon_trap_occurred;
    logic [2:0]  dbg_state;
    logic [7:0]  dbg_status;

    logic [31:0] imem [0:IMEM_DEPTH_WORDS-1];
    int unsigned imem_prog_wr_count;

    uart_bridge #(
        .CLK_HZ(CLK_HZ),
        .IMEM_DEPTH_WORDS(IMEM_DEPTH_WORDS),
        .IMEM_BASE(RESET_PC),
        .IDLE_GAP_THRESH(10),
        .TIMEOUT_CYCLES(1_000_000)
    ) u_bridge (
        .clk(clk),
        .rst_n(rst_n),
        .rx_line_idle(rx_line_idle),
        .rx_valid(rx_valid),
        .rx_data(rx_data),
        .tx_start(uart_tx_start),
        .tx_data(uart_tx_data),
        .tx_busy(uart_tx_busy),
        .cpu_uart_tx_start(cpu_uart_tx_start),
        .cpu_uart_tx_byte(cpu_uart_tx_byte),
        .cpu_uart_tx_ready(cpu_uart_tx_ready),
        .imem_wr_en(imem_wr_en),
        .imem_wr_addr(imem_wr_addr),
        .imem_wr_data(imem_wr_data),
        .imem_wr_be(imem_wr_be),
        .mem_clear_en(mem_clear_en),
        .mem_clear_addr(mem_clear_addr),
        .cpu_reset_n(cpu_reset_n),
        .mon_trap_occurred(mon_trap_occurred),
        .dbg_state(dbg_state),
        .dbg_status(dbg_status)
    );

    always #5 clk = ~clk;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            imem_prog_wr_count <= 0;
        end else if (mem_clear_en) begin
            imem[mem_clear_addr] <= 32'h0000_0013;
        end else if (imem_wr_en) begin
            imem_prog_wr_count <= imem_prog_wr_count + 1;
            if (imem_wr_be[0]) imem[imem_wr_addr][7:0]   <= imem_wr_data[7:0];
            if (imem_wr_be[1]) imem[imem_wr_addr][15:8]  <= imem_wr_data[15:8];
            if (imem_wr_be[2]) imem[imem_wr_addr][23:16] <= imem_wr_data[23:16];
            if (imem_wr_be[3]) imem[imem_wr_addr][31:24] <= imem_wr_data[31:24];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_tx_busy <= 1'b0;
            tx_busy_cnt  <= 0;
        end else begin
            if (uart_tx_start && !uart_tx_busy) begin
                tx_seen_q.push_back(uart_tx_data);
                uart_tx_busy <= 1'b1;
                tx_busy_cnt  <= 3;
            end else if (uart_tx_busy) begin
                if (tx_busy_cnt == 0)
                    uart_tx_busy <= 1'b0;
                else
                    tx_busy_cnt <= tx_busy_cnt - 1;
            end
        end
    end

    task automatic inject_byte(input logic [7:0] byte_val);
        begin
            rx_line_idle = 1'b0;
            @(posedge clk);
            rx_valid = 1'b1;
            rx_data  = byte_val;
            @(posedge clk);
            rx_valid = 1'b0;
            rx_line_idle = 1'b1;
            @(posedge clk);
        end
    endtask

    task automatic inject_frame(
        input logic [7:0]  cmd,
        input logic [31:0] addr,
        input logic [31:0] len,
        input logic [7:0]  data_bytes [$],
        input logic        corrupt_checksum
    );
        integer i;
        logic [7:0] chksum;
        begin
            rx_line_idle = 1'b1;
            repeat(20) @(posedge clk);

            inject_byte(cmd);
            chksum = cmd;

            for (i = 0; i < 4; i++) begin
                inject_byte(addr[8*i +: 8]);
                chksum ^= addr[8*i +: 8];
            end

            for (i = 0; i < 4; i++) begin
                inject_byte(len[8*i +: 8]);
                chksum ^= len[8*i +: 8];
            end

            for (i = 0; i < len; i++) begin
                inject_byte(data_bytes[i]);
                chksum ^= data_bytes[i];
            end

            inject_byte(corrupt_checksum ? (chksum ^ 8'h5A) : chksum);
        end
    endtask

    task automatic expect_tx(input logic [7:0] expected, input string label);
        int unsigned cycles;
        logic [7:0] got;
        begin
            cycles = 0;
            while ((tx_seen_q.size() == 0) && (cycles < WAIT_CYCLES)) begin
                @(posedge clk);
                cycles++;
            end
            if (tx_seen_q.size() == 0)
                $fatal(1, "[TB] Timeout waiting for %s", label);
            got = tx_seen_q.pop_front();
            if (got !== expected)
                $fatal(1, "[TB] %s mismatch: expected 0x%02h got 0x%02h",
                       label, expected, got);
            $display("[TB] PASS %s = 0x%02h", label, got);
        end
    endtask

    task automatic expect_response(input logic [7:0] status, input string label);
        begin
            expect_tx(8'h02, {label, " resp cmd"});
            expect_tx(status, {label, " resp status"});
            expect_tx(8'h02 ^ status, {label, " resp checksum"});
        end
    endtask

    task automatic wait_bridge_idle(input string label);
        int unsigned cycles;
        begin
            cycles = 0;
            while (((u_bridge.state_q !== 3'd0) || uart_tx_busy) && (cycles < WAIT_CYCLES)) begin
                @(posedge clk);
                cycles++;
            end
            if (cycles >= WAIT_CYCLES)
                $fatal(1, "[TB] Timeout waiting for bridge idle after %s", label);
        end
    endtask

    task automatic finish_with_trap(input logic use_cpu_byte, input logic [7:0] cpu_byte, input string label);
        int unsigned cycles;
        begin
            cycles = 0;
            while (!cpu_reset_n && (cycles < WAIT_CYCLES)) begin
                @(posedge clk);
                cycles++;
            end
            if (!cpu_reset_n)
                $fatal(1, "[TB] CPU was not released for %s", label);

            if (use_cpu_byte) begin
                cycles = 0;
                while (!cpu_uart_tx_ready && (cycles < WAIT_CYCLES)) begin
                    @(posedge clk);
                    cycles++;
                end
                if (!cpu_uart_tx_ready)
                    $fatal(1, "[TB] CPU UART FIFO was not ready for %s", label);
                cpu_uart_tx_byte  = cpu_byte;
                cpu_uart_tx_start = 1'b1;
                @(posedge clk);
                cpu_uart_tx_start = 1'b0;
                repeat(4) @(posedge clk);
            end

            mon_trap_occurred = 1'b1;
            @(posedge clk);
            mon_trap_occurred = 1'b0;

            if (use_cpu_byte)
                expect_tx(cpu_byte, {label, " cpu byte"});
            expect_response(8'h00, label);
            wait_bridge_idle(label);
        end
    endtask

    task automatic expect_word(input int unsigned idx, input logic [31:0] expected, input string label);
        begin
            if (imem[idx] !== expected)
                $fatal(1, "[TB] %s imem[%0d] expected 0x%08h got 0x%08h",
                       label, idx, expected, imem[idx]);
            $display("[TB] PASS %s imem[%0d] = 0x%08h", label, idx, expected);
        end
    endtask

    initial begin
        automatic logic [7:0] data_q [$];
        int unsigned wr_mark;

        clk = 1'b0;
        rst_n = 1'b0;
        rx_line_idle = 1'b1;
        rx_valid = 1'b0;
        rx_data = 8'd0;
        cpu_uart_tx_start = 1'b0;
        cpu_uart_tx_byte = 8'd0;
        mon_trap_occurred = 1'b0;

        for (int i = 0; i < IMEM_DEPTH_WORDS; i++)
            imem[i] = 32'h0000_0013;

        repeat(20) @(posedge clk);
        rst_n = 1'b1;
        repeat(20) @(posedge clk);

        $display("[TB] uart_bridge direct self-check start");

        data_q = '{8'h13, 8'h05, 8'hA0, 8'h02,
                   8'hB7, 8'h05, 8'h01, 8'h00,
                   8'h23, 8'hA0, 8'hA5, 8'h00,
                   8'h73, 8'h00, 8'h10, 8'h00};
        inject_frame(8'h01, RESET_PC, 32'd16, data_q, 1'b0);
        repeat(5) @(posedge clk);
        expect_word(0, 32'h02A0_0513, "good frame");
        expect_word(1, 32'h0001_05B7, "good frame");
        expect_word(2, 32'h00A5_A023, "good frame");
        expect_word(3, 32'h0010_0073, "good frame");
        finish_with_trap(1'b1, 8'h2A, "good frame");

        data_q = '{8'hAA, 8'hBB, 8'hCC};
        inject_frame(8'h01, RESET_PC, 32'd3, data_q, 1'b0);
        repeat(5) @(posedge clk);
        expect_word(0, 32'h00CC_BBAA, "partial tail");
        finish_with_trap(1'b0, 8'h00, "partial tail");

        data_q = '{8'h01, 8'h02, 8'h03, 8'h04};
        inject_frame(8'h01, RESET_PC, 32'd4, data_q, 1'b1);
        expect_response(8'hFF, "checksum error");
        wait_bridge_idle("checksum error");

        wr_mark = imem_prog_wr_count;
        inject_frame(8'h99, RESET_PC, 32'd4, data_q, 1'b0);
        if (imem_prog_wr_count != wr_mark)
            $fatal(1, "[TB] unsupported cmd wrote IMEM");
        expect_response(8'h03, "unsupported cmd");
        wait_bridge_idle("unsupported cmd");

        wr_mark = imem_prog_wr_count;
        inject_frame(8'h01, RESET_PC + (IMEM_DEPTH_WORDS * 4), 32'd4, data_q, 1'b0);
        if (imem_prog_wr_count != wr_mark)
            $fatal(1, "[TB] range error wrote IMEM");
        expect_response(8'h02, "range error");
        wait_bridge_idle("range error");

        if (tx_seen_q.size() != 0)
            $fatal(1, "[TB] unexpected extra TX bytes: %0d", tx_seen_q.size());

        $display("[TB] PASS uart_bridge direct protocol test");
        $finish;
    end

endmodule
