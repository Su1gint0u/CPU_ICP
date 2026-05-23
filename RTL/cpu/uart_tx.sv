// UART 8N1 transmitter: 100 MHz clock, 115200 bps
// Load byte via tx_start / tx_data, shifts out LSB-first.
// uart_tx_line_idle = 1 when line is driven high (no active transmission).

module uart_tx #(
    parameter int unsigned CLK_HZ   = 100_000_000,
    parameter int unsigned BAUD     = 115200
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       tx_start,
    input  logic [7:0] tx_data,
    output logic       tx,
    output logic       tx_busy,
    output logic       uart_tx_line_idle
);

    localparam int unsigned DIV        = CLK_HZ / BAUD;
    localparam int unsigned DIV_BITS   = $clog2(DIV);

    typedef enum logic [0:0] {
        TX_IDLE,
        TX_SHIFT
    } tx_state_e;

    tx_state_e state_q, state_nxt;
    logic [$clog2(DIV)-1:0] div_cnt_q, div_cnt_nxt;
    logic [3:0] bit_cnt_q, bit_cnt_nxt;
    logic [9:0] shift_q, shift_nxt;
    logic       div_tick;

    assign div_tick = (div_cnt_q == (DIV - 1));

    always_comb begin
        state_nxt   = state_q;
        bit_cnt_nxt = bit_cnt_q;
        shift_nxt   = shift_q;
        div_cnt_nxt = div_cnt_q;
        tx_busy     = 1'b0;

        if (state_q == TX_SHIFT) begin
            if (div_tick)
                div_cnt_nxt = '0;
            else
                div_cnt_nxt = div_cnt_q + 1'b1;
        end

        unique case (state_q)
            TX_IDLE: begin
                div_cnt_nxt = '0;
                bit_cnt_nxt = '0;
                // load shift register: [stop=1][data(MSB..LSB)][start=0]
                shift_nxt          = 10'h3FF;
                shift_nxt[0]       = 1'b0;
                shift_nxt[8:1]     = tx_data;
                uart_tx_line_idle   = 1'b1;
                if (tx_start) begin
                    state_nxt = TX_SHIFT;
                    div_cnt_nxt = '0;
                    uart_tx_line_idle = 1'b0;
                end
            end

            TX_SHIFT: begin
                tx_busy = 1'b1;
                uart_tx_line_idle = 1'b0;
                if (div_tick) begin
                    shift_nxt = {1'b1, shift_q[9:1]};
                    if (bit_cnt_q == 4'd9) begin
                        state_nxt = TX_IDLE;
                    end else begin
                        bit_cnt_nxt = bit_cnt_q + 1'b1;
                    end
                end
            end

            default: state_nxt = TX_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q   <= TX_IDLE;
            div_cnt_q <= '0;
            bit_cnt_q <= '0;
            shift_q   <= 10'h3FF;
        end else begin
            state_q   <= state_nxt;
            div_cnt_q <= div_cnt_nxt;
            bit_cnt_q <= bit_cnt_nxt;
            shift_q   <= shift_nxt;
        end
    end

    assign tx = (state_q == TX_SHIFT) ? shift_q[0] : 1'b1;

endmodule
