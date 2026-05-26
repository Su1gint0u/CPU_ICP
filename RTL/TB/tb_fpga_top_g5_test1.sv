// Board-level regression for tests/grade5/g5_test1.s.
// Exercises RV32F add/sub/mul/sqrt through the UART-loaded program.

`timescale 1ns / 1ps

module tb_fpga_top_g5_test1;

    localparam int unsigned CLK_HZ        = 100_000_000;
    localparam int unsigned BAUD          = 115200;
    localparam real         CLK_PERIOD    = 10.0;
    localparam int unsigned RX_BIT_CYCLES = (CLK_HZ / (BAUD * 16)) * 16;
    localparam int unsigned TX_BIT_CYCLES = CLK_HZ / BAUD;
    localparam int unsigned IDLE_GAP_CYCLES = 60000;
    localparam int unsigned BYTE_WAIT_CYCLES = 120_000_000;
    localparam int unsigned BIN_LEN = 160;

    logic        clk;
    logic        rst_n;
    logic        uart_rxd;
    logic        uart_txd;
    logic [15:0] led;
    logic [7:0]  uart_seen_q [$];
    logic [7:0]  bin_bytes [0:BIN_LEN-1];

    logic [7:0] expected [0:6];

    fpga_top #(
        .IMEM_DEPTH_WORDS(16384),
        .DMEM_DEPTH_WORDS(16384)
    ) u_dut (
        .sys_clk_100m (clk),
        .sys_rst_n    (rst_n),
        .uart_rxd     (uart_rxd),
        .uart_txd     (uart_txd),
        .led_status   (led)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    task automatic uart_monitor;
        integer bit_idx;
        integer bit_time;
        logic [7:0] rx_byte;
        begin
            forever begin
                @(negedge uart_txd);
                for (bit_time = 0; bit_time < TX_BIT_CYCLES/2; bit_time++)
                    @(posedge clk);
                for (bit_idx = 0; bit_idx < 8; bit_idx++) begin
                    for (bit_time = 0; bit_time < TX_BIT_CYCLES; bit_time++)
                        @(posedge clk);
                    rx_byte[bit_idx] = uart_txd;
                end
                for (bit_time = 0; bit_time < TX_BIT_CYCLES; bit_time++)
                    @(posedge clk);
                uart_seen_q.push_back(rx_byte);
                $display("[TB_G5T1] UART_TX byte 0x%02h at t=%0t", rx_byte, $time);
            end
        end
    endtask

    task automatic uart_send_byte(input logic [7:0] data);
        integer bit_idx;
        integer bit_time;
        begin
            uart_rxd = 1'b0;
            for (bit_time = 0; bit_time < RX_BIT_CYCLES; bit_time++)
                @(posedge clk);
            for (bit_idx = 0; bit_idx < 8; bit_idx++) begin
                uart_rxd = data[bit_idx];
                for (bit_time = 0; bit_time < RX_BIT_CYCLES; bit_time++)
                    @(posedge clk);
            end
            uart_rxd = 1'b1;
            for (bit_time = 0; bit_time < RX_BIT_CYCLES; bit_time++)
                @(posedge clk);
        end
    endtask

    task automatic uart_send_frame(input logic [31:0] addr, input int unsigned len);
        integer i;
        logic [7:0] chksum;
        begin
            chksum = 8'h01;
            uart_send_byte(8'h01);
            for (i = 0; i < 4; i++) begin
                uart_send_byte(addr[8*i +: 8]);
                chksum ^= addr[8*i +: 8];
            end
            for (i = 0; i < 4; i++) begin
                uart_send_byte(len[8*i +: 8]);
                chksum ^= len[8*i +: 8];
            end
            for (i = 0; i < len; i++) begin
                uart_send_byte(bin_bytes[i]);
                chksum ^= bin_bytes[i];
            end
            uart_send_byte(chksum);
        end
    endtask

    task automatic expect_uart_byte(input logic [7:0] expected_byte, input string label);
        integer cycles;
        logic [7:0] got;
        begin
            cycles = 0;
            while ((uart_seen_q.size() == 0) && (cycles < BYTE_WAIT_CYCLES)) begin
                @(posedge clk);
                cycles++;
            end
            if (uart_seen_q.size() == 0)
                $fatal(1, "[TB_G5T1] Timeout waiting for %s", label);
            got = uart_seen_q.pop_front();
            if (got !== expected_byte)
                $fatal(1, "[TB_G5T1] %s mismatch: expected 0x%02h, got 0x%02h",
                       label, expected_byte, got);
            $display("[TB_G5T1] PASS %s = 0x%02h", label, got);
        end
    endtask

    initial begin
        integer fd;
        integer nread;
        integer i;

        expected = '{8'h73, 8'h8e, 8'h8b, 8'h42, 8'h02, 8'h00, 8'h02};

        clk = 1'b0;
        rst_n = 1'b0;
        uart_rxd = 1'b1;

        fd = $fopen("/media/alice/workplace/CPU_ICP/tests/grade5/artifacts/g5_test1/test.bin", "rb");
        if (fd == 0)
            $fatal(1, "[TB_G5T1] Could not open g5_test1 test.bin");
        nread = $fread(bin_bytes, fd);
        $fclose(fd);
        if (nread != BIN_LEN)
            $fatal(1, "[TB_G5T1] Expected %0d bytes, read %0d", BIN_LEN, nread);

        fork
            uart_monitor();
        join_none

        repeat(100) @(posedge clk);
        rst_n = 1'b1;
        repeat(100) @(posedge clk);

        repeat(IDLE_GAP_CYCLES) @(posedge clk);
        $display("[TB_G5T1] Sending tests/grade5/artifacts/g5_test1/test.bin");
        uart_send_frame(32'h8000_0000, BIN_LEN);

        for (i = 0; i < 7; i++)
            expect_uart_byte(expected[i], $sformatf("byte[%0d]", i));

        $display("[TB_G5T1] PASS g5_test1 board-level FPU regression");
        $finish;
    end

endmodule
