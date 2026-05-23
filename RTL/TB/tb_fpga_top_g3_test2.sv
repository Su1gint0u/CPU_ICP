// Board-level regression for tests/grade3/g3_test2.s.
// Checks that the UART loader preserves the SRAI encoding bit and that CPU
// execution returns the same observed bytes as Spike.

`timescale 1ns / 1ps

module tb_fpga_top_g3_test2;

    localparam int unsigned CLK_HZ        = 100_000_000;
    localparam int unsigned BAUD          = 115200;
    localparam real         CLK_PERIOD    = 10.0;
    localparam int unsigned RX_BIT_CYCLES = (CLK_HZ / (BAUD * 16)) * 16;
    localparam int unsigned TX_BIT_CYCLES = CLK_HZ / BAUD;
    localparam int unsigned IDLE_GAP_CYCLES = 60000;
    localparam int unsigned BYTE_WAIT_CYCLES = 80_000_000;
    localparam int unsigned BIN_LEN = 120;

    logic        clk;
    logic        rst_n;
    logic        uart_rxd;
    logic        uart_txd;
    logic [15:0] led;
    logic [7:0]  uart_seen_q [$];
    logic [7:0]  bin_bytes [0:BIN_LEN-1];

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
                $display("[TB_G3T2] UART_TX byte 0x%02h at t=%0t", rx_byte, $time);
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

    task automatic expect_uart_byte(input logic [7:0] expected, input string label);
        integer cycles;
        logic [7:0] got;
        begin
            cycles = 0;
            while ((uart_seen_q.size() == 0) && (cycles < BYTE_WAIT_CYCLES)) begin
                @(posedge clk);
                cycles++;
            end
            if (uart_seen_q.size() == 0)
                $fatal(1, "[TB_G3T2] Timeout waiting for %s", label);
            got = uart_seen_q.pop_front();
            if (got !== expected)
                $fatal(1, "[TB_G3T2] %s mismatch: expected 0x%02h, got 0x%02h",
                       label, expected, got);
            $display("[TB_G3T2] PASS %s = 0x%02h", label, got);
        end
    endtask

    initial begin
        integer fd;
        integer nread;

        clk = 1'b0;
        rst_n = 1'b0;
        uart_rxd = 1'b1;

        fd = $fopen("/media/alice/workplace/CPU_ICP/tests/grade3/artifacts/g3_test2/test.bin", "rb");
        if (fd == 0)
            $fatal(1, "[TB_G3T2] Could not open g3_test2 test.bin");
        nread = $fread(bin_bytes, fd);
        $fclose(fd);
        if (nread != BIN_LEN)
            $fatal(1, "[TB_G3T2] Expected %0d bytes, read %0d", BIN_LEN, nread);

        fork
            uart_monitor();
        join_none

        repeat(100) @(posedge clk);
        rst_n = 1'b1;
        repeat(100) @(posedge clk);

        repeat(IDLE_GAP_CYCLES) @(posedge clk);
        $display("[TB_G3T2] Sending tests/grade3/artifacts/g3_test2/test.bin");
        uart_send_frame(32'h8000_0000, BIN_LEN);
        repeat(20) @(posedge clk);

        if (u_dut.u_mem.u_imem.mem[10] !== 32'h4014_5413)
            $fatal(1, "[TB_G3T2] SRAI word corrupted in IMEM: expected 0x40145413, got 0x%08h",
                   u_dut.u_mem.u_imem.mem[10]);
        $display("[TB_G3T2] PASS IMEM[10] SRAI word = 0x%08h", u_dut.u_mem.u_imem.mem[10]);

        expect_uart_byte(8'h00, "x8 byte0");
        expect_uart_byte(8'h00, "x8 byte1");
        expect_uart_byte(8'hFF, "x8 byte2");
        expect_uart_byte(8'hFF, "x8 byte3");
        expect_uart_byte(8'h00, "x9 byte0");
        expect_uart_byte(8'h00, "x9 byte1");
        expect_uart_byte(8'h00, "x9 byte2");
        expect_uart_byte(8'h00, "x9 byte3");
        expect_uart_byte(8'h02, "response cmd");
        expect_uart_byte(8'h00, "response status");
        expect_uart_byte(8'h02, "response checksum");

        $display("[TB_G3T2] PASS g3_test2 board-level SRAI regression");
        $finish;
    end

endmodule
