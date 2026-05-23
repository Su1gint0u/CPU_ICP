// UART RX byte-order test.
// Drives 8N1 frames LSB-first and checks the decoded byte values.

`timescale 1ns / 1ps

module tb_uart_rx;

    localparam int unsigned CLK_HZ = 100_000_000;
    localparam int unsigned BAUD   = 115200;
    localparam real CLK_PERIOD = 10.0;
    localparam int unsigned BIT_CYCLES = (CLK_HZ / (BAUD * 16)) * 16;
    localparam int unsigned WAIT_CYCLES = 20000;

    logic clk;
    logic rst_n;
    logic rx;
    logic rx_valid;
    logic [7:0] rx_data;
    logic rx_line_idle;
    logic [7:0] rx_seen_q [$];

    uart_rx #(
        .CLK_HZ(CLK_HZ),
        .BAUD(BAUD)
    ) u_rx (
        .clk(clk),
        .rst_n(rst_n),
        .rx(rx),
        .rx_valid(rx_valid),
        .rx_data(rx_data),
        .rx_line_idle(rx_line_idle)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    always_ff @(posedge clk) begin
        if (rx_valid)
            rx_seen_q.push_back(rx_data);
    end

    task automatic send_uart_byte(input logic [7:0] value);
        integer bit_idx;
        integer bit_time;
        begin
            rx = 1'b0;
            for (bit_time = 0; bit_time < BIT_CYCLES; bit_time++)
                @(posedge clk);

            for (bit_idx = 0; bit_idx < 8; bit_idx++) begin
                rx = value[bit_idx];
                for (bit_time = 0; bit_time < BIT_CYCLES; bit_time++)
                    @(posedge clk);
            end

            rx = 1'b1;
            for (bit_time = 0; bit_time < BIT_CYCLES; bit_time++)
                @(posedge clk);
        end
    endtask

    task automatic expect_byte(input logic [7:0] expected);
        int unsigned cycles;
        logic [7:0] got;
        begin
            send_uart_byte(expected);
            cycles = 0;
            while ((rx_seen_q.size() == 0) && (cycles < WAIT_CYCLES)) begin
                @(posedge clk);
                cycles++;
            end
            if (rx_seen_q.size() == 0)
                $fatal(1, "[TB] Timeout waiting for rx_valid for 0x%02h", expected);
            got = rx_seen_q.pop_front();
            if (got !== expected)
                $fatal(1, "[TB] RX byte mismatch: expected 0x%02h got 0x%02h", expected, got);
            $display("[TB] PASS uart_rx decoded 0x%02h", expected);
            @(posedge clk);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        rx = 1'b1;

        repeat(20) @(posedge clk);
        rst_n = 1'b1;
        repeat(20) @(posedge clk);

        expect_byte(8'h00);
        expect_byte(8'h01);
        expect_byte(8'h2A);
        expect_byte(8'h55);
        expect_byte(8'h80);
        expect_byte(8'hFF);

        $display("[TB] PASS uart_rx byte-order test");
        $finish;
    end

endmodule
