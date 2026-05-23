// Testbench: fpga_top integration verification.
// Drives the UART RX pin at bit level, captures UART TX, and self-checks
// program load, CPU MMIO output, bridge response, and back-to-back transactions.

`timescale 1ns / 1ps

module tb_fpga_top;

    localparam int unsigned CLK_HZ        = 100_000_000;
    localparam int unsigned BAUD          = 115200;
    localparam real         CLK_PERIOD    = 10.0;   // ns
    localparam int unsigned RX_BIT_CYCLES = (CLK_HZ / (BAUD * 16)) * 16;
    localparam int unsigned TX_BIT_CYCLES = CLK_HZ / BAUD;
    localparam int unsigned IDLE_GAP_CYCLES = 60000;
    localparam int unsigned BYTE_WAIT_CYCLES = 30_000_000;
    localparam logic [31:0] IMEM_NOP = 32'h0000_0013;

    logic        clk;
    logic        rst_n;
    logic        uart_rxd;
    logic        uart_txd;
    logic [15:0] led;

    logic [7:0] uart_seen_q [$];

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
                if (uart_txd !== 1'b1)
                    $fatal(1, "[TB] UART TX stop bit was not high at t=%0t", $time);

                uart_seen_q.push_back(rx_byte);
                $display("[TB] UART_TX byte 0x%02h at t=%0t", rx_byte, $time);
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

    task automatic uart_send_frame(
        input logic [7:0]  cmd,
        input logic [31:0] addr,
        input logic [31:0] len,
        input logic [7:0]  data_bytes [$]
    );
        integer i;
        logic [7:0] chksum;
        begin
            uart_send_byte(cmd);
            chksum = cmd;

            for (i = 0; i < 4; i++) begin
                uart_send_byte(addr[8*i +: 8]);
                chksum ^= addr[8*i +: 8];
            end

            for (i = 0; i < 4; i++) begin
                uart_send_byte(len[8*i +: 8]);
                chksum ^= len[8*i +: 8];
            end

            for (i = 0; i < len; i++) begin
                uart_send_byte(data_bytes[i]);
                chksum ^= data_bytes[i];
            end

            uart_send_byte(chksum);
        end
    endtask

    task automatic send_idle_gap;
        begin
            uart_rxd = 1'b1;
            repeat(IDLE_GAP_CYCLES) @(posedge clk);
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
                $fatal(1, "[TB] Timeout waiting for %s", label);

            got = uart_seen_q.pop_front();
            if (got !== expected)
                $fatal(1, "[TB] %s mismatch: expected 0x%02h, got 0x%02h",
                       label, expected, got);
            $display("[TB] PASS %s = 0x%02h", label, got);
        end
    endtask

    task automatic wait_bridge_idle(input string label);
        integer cycles;
        begin
            cycles = 0;
            while (((u_dut.u_bridge.state_q !== 3'd0) || u_dut.uart_tx_busy)
                   && (cycles < BYTE_WAIT_CYCLES)) begin
                @(posedge clk);
                cycles++;
            end
            if (cycles >= BYTE_WAIT_CYCLES)
                $fatal(1, "[TB] Timeout waiting for bridge idle after %s", label);
        end
    endtask

    task automatic expect_image_word(
        input int unsigned idx,
        input logic [31:0] expected,
        input string label
    );
        begin
            if (u_dut.u_mem.u_imem.mem[idx] !== expected)
                $fatal(1, "[TB] %s IMEM mismatch at %0d: expected 0x%08h, got 0x%08h",
                       label, idx, expected, u_dut.u_mem.u_imem.mem[idx]);
            if (u_dut.u_mem.u_dmem.mem[idx] !== expected)
                $fatal(1, "[TB] %s DMEM mirror mismatch at %0d: expected 0x%08h, got 0x%08h",
                       label, idx, expected, u_dut.u_mem.u_dmem.mem[idx]);
            $display("[TB] PASS %s image[%0d] = 0x%08h", label, idx, expected);
        end
    endtask

    task automatic expect_cleared_tail(input int unsigned idx, input string label);
        begin
            if (u_dut.u_mem.u_imem.mem[idx] !== IMEM_NOP)
                $fatal(1, "[TB] %s IMEM tail not cleared at %0d: got 0x%08h",
                       label, idx, u_dut.u_mem.u_imem.mem[idx]);
            if (u_dut.u_mem.u_dmem.mem[idx] !== 32'h0000_0000)
                $fatal(1, "[TB] %s DMEM tail not cleared at %0d: got 0x%08h",
                       label, idx, u_dut.u_mem.u_dmem.mem[idx]);
            $display("[TB] PASS %s tail[%0d] cleared", label, idx);
        end
    endtask

    task automatic expect_ok_response(input string label);
        begin
            expect_uart_byte(8'h02, {label, " response cmd"});
            expect_uart_byte(8'h00, {label, " response status"});
            expect_uart_byte(8'h02, {label, " response checksum"});
        end
    endtask

    logic [7:0] prog1 [0:19];
    logic [7:0] prog2 [0:15];

    initial begin
        prog1[0]  = 8'h13;  prog1[1]  = 8'h05;  prog1[2]  = 8'hA0;  prog1[3]  = 8'h02;
        prog1[4]  = 8'hB7;  prog1[5]  = 8'h05;  prog1[6]  = 8'h01;  prog1[7]  = 8'h00;
        prog1[8]  = 8'h23;  prog1[9]  = 8'hA0;  prog1[10] = 8'hA5;  prog1[11] = 8'h00;
        prog1[12] = 8'h73;  prog1[13] = 8'h00;  prog1[14] = 8'h10;  prog1[15] = 8'h00;
        prog1[16] = 8'hEF;  prog1[17] = 8'hBE;  prog1[18] = 8'hAD;  prog1[19] = 8'hDE;

        prog2[0]  = 8'h13;  prog2[1]  = 8'h05;  prog2[2]  = 8'h50;  prog2[3]  = 8'h05;
        prog2[4]  = 8'hB7;  prog2[5]  = 8'h05;  prog2[6]  = 8'h01;  prog2[7]  = 8'h00;
        prog2[8]  = 8'h23;  prog2[9]  = 8'hA0;  prog2[10] = 8'hA5;  prog2[11] = 8'h00;
        prog2[12] = 8'h73;  prog2[13] = 8'h00;  prog2[14] = 8'h10;  prog2[15] = 8'h00;
    end

    initial begin
        fork
            uart_monitor();
        join_none
    end

    initial begin
        automatic logic [7:0] data_q [$];
        integer i;

        clk      = 1'b0;
        rst_n    = 1'b0;
        uart_rxd = 1'b1;

        $display("[TB] FPGA top UART integration self-check start");

        repeat(100) @(posedge clk);
        rst_n = 1'b1;
        repeat(100) @(posedge clk);

        data_q = '{};
        for (i = 0; i < 20; i++)
            data_q.push_back(prog1[i]);

        uart_seen_q.delete();
        send_idle_gap();
        $display("[TB] Transaction 1: send 20-byte image, expect CPU output 0x2a");
        uart_send_frame(8'h01, 32'h8000_0000, 32'd20, data_q);
        repeat(20) @(posedge clk);
        expect_image_word(0, 32'h02A0_0513, "txn1");
        expect_image_word(1, 32'h0001_05B7, "txn1");
        expect_image_word(2, 32'h00A5_A023, "txn1");
        expect_image_word(3, 32'h0010_0073, "txn1");
        expect_image_word(4, 32'hDEAD_BEEF, "txn1");
        expect_uart_byte(8'h2A, "txn1 cpu output");
        expect_ok_response("txn1");
        wait_bridge_idle("txn1");

        data_q = '{};
        for (i = 0; i < 16; i++)
            data_q.push_back(prog2[i]);

        uart_seen_q.delete();
        send_idle_gap();
        $display("[TB] Transaction 2: send 16-byte image without board reset, expect CPU output 0x55");
        uart_send_frame(8'h01, 32'h8000_0000, 32'd16, data_q);
        repeat(20) @(posedge clk);
        expect_image_word(0, 32'h0550_0513, "txn2");
        expect_image_word(1, 32'h0001_05B7, "txn2");
        expect_image_word(2, 32'h00A5_A023, "txn2");
        expect_image_word(3, 32'h0010_0073, "txn2");
        expect_cleared_tail(4, "txn2");
        expect_uart_byte(8'h55, "txn2 cpu output");
        expect_ok_response("txn2");
        wait_bridge_idle("txn2");

        if (uart_seen_q.size() != 0)
            $fatal(1, "[TB] Unexpected extra UART bytes after checks: %0d", uart_seen_q.size());

        $display("[TB] PASS fpga_top UART integration and continuous transaction test");
        $finish;
    end

endmodule
