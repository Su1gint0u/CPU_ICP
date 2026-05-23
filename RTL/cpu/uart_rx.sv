// UART 8N1 receiver: 100 MHz clock, 115200 bps
// 16x oversampling: finds start-bit edge, then samples at nominal bit centres.
// rx_line_idle exposed for protocol idle-gap detection.

module uart_rx #(
    parameter int unsigned CLK_HZ   = 100_000_000,
    parameter int unsigned BAUD     = 115200,
    parameter int unsigned OVS      = 16
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       rx,
    output logic       rx_valid,
    output logic [7:0] rx_data,
    output logic       rx_line_idle
);

    localparam int unsigned DIV        = CLK_HZ / (BAUD * OVS);
    localparam int unsigned HALF_SAMP  = OVS / 2;

    typedef enum logic [1:0] {
        RX_IDLE,
        RX_START,
        RX_DATA,
        RX_STOP
    } rx_state_e;

    rx_state_e state_q, state_nxt;
    logic [$clog2(DIV)-1:0] ovs_cnt_q, ovs_cnt_nxt;
    logic [3:0] samp_cnt_q, samp_cnt_nxt;   // sample counter within each bit
    logic [2:0] bit_cnt_q, bit_cnt_nxt;
    logic [7:0] shift_q, shift_nxt;
    logic       rx_sync;
    logic       sample_tick;

    // 2-stage synchroniser
    logic rx_d, rx_d1, rx_d2;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rx_d  <= 1'b1;
            rx_d1 <= 1'b1;
            rx_d2 <= 1'b1;
        end else begin
            rx_d  <= rx;
            rx_d1 <= rx_d;
            rx_d2 <= rx_d1;
        end
    end
    assign rx_sync      = rx_d2;
    assign rx_line_idle = rx_sync;

    assign sample_tick = (ovs_cnt_q == (DIV - 1));

    always_comb begin
        state_nxt    = state_q;
        samp_cnt_nxt = samp_cnt_q;
        bit_cnt_nxt  = bit_cnt_q;
        shift_nxt    = shift_q;
        ovs_cnt_nxt  = ovs_cnt_q;
        rx_valid     = 1'b0;
        rx_data      = shift_q;

        if (sample_tick)
            ovs_cnt_nxt = '0;
        else if (state_q != RX_IDLE)
            ovs_cnt_nxt = ovs_cnt_q + 1'b1;

        unique case (state_q)
            RX_IDLE: begin
                samp_cnt_nxt = '0;
                bit_cnt_nxt  = '0;
                shift_nxt    = 8'h00;
                ovs_cnt_nxt  = (DIV > 0 ? DIV - 1 : 0);
                if (!rx_sync) begin
                    state_nxt   = RX_START;
                    ovs_cnt_nxt = '0;
                    samp_cnt_nxt = '0;
                end
            end

            RX_START: begin
                if (sample_tick) begin
                    samp_cnt_nxt = samp_cnt_q + 1'b1;
                    if (samp_cnt_q == (HALF_SAMP - 1)) begin
                        // centre of start bit: check it's still low
                        if (!rx_sync) begin
                            state_nxt    = RX_DATA;
                            bit_cnt_nxt  = '0;
                            ovs_cnt_nxt  = '0;
                            samp_cnt_nxt = '0;
                        end else begin
                            state_nxt = RX_IDLE;
                        end
                    end
                end
            end

            RX_DATA: begin
                if (sample_tick) begin
                    samp_cnt_nxt = samp_cnt_q + 1'b1;
                    if (samp_cnt_q == (OVS - 1)) begin
                        // UART sends LSB first; store each sampled bit in its final byte lane.
                        shift_nxt = shift_q;
                        shift_nxt[bit_cnt_q] = rx_sync;
                        samp_cnt_nxt = '0;
                        if (bit_cnt_q == 3'd7) begin
                            state_nxt = RX_STOP;
                        end else begin
                            bit_cnt_nxt = bit_cnt_q + 1'b1;
                        end
                    end
                end
            end

            RX_STOP: begin
                if (sample_tick) begin
                    samp_cnt_nxt = samp_cnt_q + 1'b1;
                    if (samp_cnt_q == (OVS - 1)) begin
                        state_nxt = RX_IDLE;
                        rx_valid  = 1'b1;
                        rx_data   = shift_q;
                    end
                end
            end

            default: state_nxt = RX_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q    <= RX_IDLE;
            ovs_cnt_q  <= '0;
            samp_cnt_q <= '0;
            bit_cnt_q  <= '0;
            shift_q    <= 8'h00;
        end else begin
            state_q    <= state_nxt;
            ovs_cnt_q  <= ovs_cnt_nxt;
            samp_cnt_q <= samp_cnt_nxt;
            bit_cnt_q  <= bit_cnt_nxt;
            shift_q    <= shift_nxt;
        end
    end

endmodule
