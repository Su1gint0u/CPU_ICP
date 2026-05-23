// Synthesizable L1 memory wrapper: IMEM BRAM + DMEM BRAM + UART MMIO.
// Replaces the behavioral l1_mem_model for FPGA synthesis.
//
// Address map:
//   i_req_addr -> IMEM BRAM (CPU instruction fetch, bridge-programmable)
//   d_req_addr -> DMEM BRAM (CPU data access)
//   d_req_addr == 32'h0001_0000 -> UART TX MMIO (CPU store triggers UART send)
//   d_req_addr == 32'h1000_0000 -> UART TX MMIO alias used by Nexys4/test_add.S
//
// BRAM inference: the actual arrays live in 1R1W byte-write modules at the
// bottom of this file. The wrapper only does request timing and write muxing.

module l1_mem_wrapper #(
    parameter int unsigned IMEM_DEPTH_WORDS = 16384,
    parameter int unsigned DMEM_DEPTH_WORDS = 16384,
    parameter int unsigned XLEN             = 32,
    parameter int unsigned FETCH_W          = 64
) (
    input  logic                 pl_clk,
    input  logic                 pl_resetn,

    input  logic                 i_req_valid,
    output logic                 i_req_ready,
    input  logic [31:0]          i_req_addr,
    output logic                 i_resp_valid,
    output logic [FETCH_W-1:0]   i_resp_data,
    output logic                 i_resp_err,

    input  logic                 d_req_valid,
    output logic                 d_req_ready,
    input  logic [31:0]          d_req_addr,
    input  logic [2:0]           d_req_cmd,
    input  logic [2:0]           d_req_size,
    input  logic [XLEN-1:0]      d_req_wdata,
    input  logic [3:0]           d_req_wstrb,
    input  logic [4:0]           d_req_amo_funct,
    input  logic                 d_req_amo_aq,
    input  logic                 d_req_amo_rl,

    output logic                 d_resp_valid,
    output logic [XLEN-1:0]      d_resp_rdata,
    output logic                 d_resp_err,

    input  logic                 ctl_req_valid,
    input  logic [2:0]           ctl_req_op,
    input  logic [31:0]          ctl_req_addr,
    output logic                 ctl_done,
    output logic                 ctl_err,

    input  logic                 imem_wr_en,
    input  logic [$clog2(IMEM_DEPTH_WORDS)-1:0] imem_wr_addr,
    input  logic [31:0]          imem_wr_data,
    input  logic [3:0]           imem_wr_be,
    input  logic                 mem_clear_en,
    input  logic [$clog2(IMEM_DEPTH_WORDS)-1:0] mem_clear_addr,

    output logic                 cpu_uart_tx_start,
    output logic [7:0]           cpu_uart_tx_byte,
    input  logic                 cpu_uart_tx_ready
);

    localparam int unsigned I_AW = $clog2(IMEM_DEPTH_WORDS);
    localparam int unsigned D_AW = $clog2(DMEM_DEPTH_WORDS);

    localparam logic [2:0] D_CMD_LD  = 3'b001;
    localparam logic [2:0] D_CMD_ST  = 3'b010;

    function automatic logic [I_AW-1:0] imem_idx(input logic [31:0] byte_addr);
        imem_idx = byte_addr[I_AW+1:2] & (IMEM_DEPTH_WORDS - 1);
    endfunction

    function automatic logic [D_AW-1:0] dmem_idx(input logic [31:0] byte_addr);
        dmem_idx = byte_addr[D_AW+1:2] & (DMEM_DEPTH_WORDS - 1);
    endfunction

    wire d_is_mmio = (d_req_addr == 32'h0001_0000)
                   || (d_req_addr == 32'h1000_0000);

    assign i_req_ready = 1'b1;
    assign d_req_ready = !((d_req_valid == 1'b1) && d_is_mmio
                        && (d_req_cmd == D_CMD_ST) && !cpu_uart_tx_ready);

    // Alignment
    logic i_align_bad;
    always_comb i_align_bad = (i_req_addr[1:0] != 2'b00);

    logic d_align_bad;
    always_comb begin
        d_align_bad = 1'b0;
        unique case (d_req_size)
            3'd0: d_align_bad = 1'b0;
            3'd1: d_align_bad = d_req_addr[0];
            3'd2: d_align_bad = (d_req_addr[1:0] != 2'b00);
            default: d_align_bad = 1'b1;
        endcase
    end

    // D-port pipeline: capture request in cycle N, respond in cycle N+1
    logic            d_req_valid_q;
    logic [2:0]      d_req_cmd_q;
    logic [2:0]      d_req_size_q;
    logic [31:0]     d_req_wdata_q;
    logic [3:0]      d_req_wstrb_q;
    logic            d_is_mmio_q;
    logic            d_align_bad_q;
    logic [31:0]     d_req_addr_q;
    logic [31:0]     dmem_load_rdata;

    always_ff @(posedge pl_clk) begin
        if (!pl_resetn) begin
            d_req_valid_q <= 1'b0;
            d_req_cmd_q   <= D_CMD_LD;
            d_req_size_q  <= 3'd2;
            d_req_wdata_q <= '0;
            d_req_wstrb_q <= '0;
            d_req_addr_q  <= '0;
            d_is_mmio_q   <= 1'b0;
            d_align_bad_q <= 1'b0;
        end else if (d_req_valid && d_req_ready) begin
            d_req_valid_q  <= 1'b1;
            d_req_cmd_q    <= d_req_cmd;
            d_req_size_q   <= d_req_size;
            d_req_wdata_q  <= d_req_wdata;
            d_req_wstrb_q  <= d_req_wstrb;
            d_req_addr_q   <= d_req_addr;
            d_is_mmio_q    <= d_is_mmio;
            d_align_bad_q  <= d_align_bad;
        end else begin
            d_req_valid_q  <= 1'b0;
        end
    end

    // ---- IMEM BRAM ----
    logic [I_AW-1:0] imem_rd_addr;
    logic [I_AW-1:0] imem_wr_addr_mux;
    logic [31:0]     imem_wr_data_mux;
    logic [3:0]      imem_wr_be_mux;
    logic            imem_wr_fire;
    logic [31:0]     imem_rdata_q;

    assign imem_rd_addr      = imem_idx(i_req_addr);
    assign imem_wr_fire      = mem_clear_en || imem_wr_en;
    assign imem_wr_addr_mux  = mem_clear_en ? mem_clear_addr : imem_wr_addr;
    assign imem_wr_data_mux  = mem_clear_en ? 32'h0000_0013 : imem_wr_data;
    assign imem_wr_be_mux    = mem_clear_en ? 4'hF : imem_wr_be;

    l1_imem_bram #(
        .DEPTH_WORDS(IMEM_DEPTH_WORDS),
        .ADDR_W(I_AW)
    ) u_imem (
        .clk    (pl_clk),
        // Keep the inferred BRAM read port enabled. i_resp_valid still gates
        // the CPU-visible response, while this avoids pulling ROB reset state
        // into RAMB ENBWREN through the IF request-valid cone.
        .rd_en  (1'b1),
        .rd_addr(imem_rd_addr),
        .rd_data(imem_rdata_q),
        .wr_en  (imem_wr_fire),
        .wr_addr(imem_wr_addr_mux),
        .wr_data(imem_wr_data_mux),
        .wr_be  (imem_wr_be_mux)
    );

    generate
        if (FETCH_W > 32) begin : gen_i_resp_wide
            assign i_resp_data = {{(FETCH_W-32){1'b0}}, imem_rdata_q};
        end else if (FETCH_W == 32) begin : gen_i_resp_word
            assign i_resp_data = imem_rdata_q;
        end else begin : gen_i_resp_narrow
            assign i_resp_data = imem_rdata_q[FETCH_W-1:0];
        end
    endgenerate

    // ---- DMEM BRAM ----
    // UART programming mirrors IMEM into DMEM so black-box binaries can read
    // constants/data with the same bare-metal address image.
    logic [D_AW-1:0] dmem_rd_addr;
    logic [D_AW-1:0] dmem_wr_addr;
    logic [31:0]     dmem_wr_data;
    logic [3:0]      dmem_wr_be;
    logic            dmem_wr_en;
    logic [31:0]     dmem_rdata_q;
    logic [31:0]     dmem_store_wdata;
    logic [3:0]      dmem_store_be;
    logic            dmem_cpu_store;
    logic            dmem_mirror_en;
    logic            dmem_clear_en;

    assign dmem_rd_addr   = dmem_idx(d_req_addr);
    assign dmem_clear_en  = mem_clear_en && (mem_clear_addr < DMEM_DEPTH_WORDS);
    assign dmem_mirror_en = imem_wr_en && (imem_wr_addr < DMEM_DEPTH_WORDS);
    // Non-MMIO DMEM requests are always accepted; only UART MMIO stores can
    // backpressure d_req_ready. Keep that UART ready cone off the BRAM ports.
    assign dmem_cpu_store = d_req_valid && (d_req_cmd == D_CMD_ST)
                          && !d_is_mmio && !d_align_bad;

    always_comb begin
        dmem_store_wdata = d_req_wdata;
        dmem_store_be    = 4'b0000;
        unique case (d_req_size)
            3'd0: begin
                dmem_store_wdata = {4{d_req_wdata[7:0]}};
                dmem_store_be    = 4'b0001 << d_req_addr[1:0];
            end
            3'd1: begin
                dmem_store_wdata = d_req_addr[1]
                    ? {d_req_wdata[15:0], 16'h0000}
                    : {16'h0000, d_req_wdata[15:0]};
                dmem_store_be = d_req_addr[1] ? 4'b1100 : 4'b0011;
            end
            3'd2: begin
                dmem_store_wdata = d_req_wdata;
                dmem_store_be    = d_req_wstrb;
            end
            default: begin
                dmem_store_wdata = d_req_wdata;
                dmem_store_be    = 4'b0000;
            end
        endcase
    end

    always_comb begin
        dmem_wr_en   = 1'b0;
        dmem_wr_addr = '0;
        dmem_wr_data = 32'h0000_0000;
        dmem_wr_be   = 4'h0;

        if (dmem_clear_en) begin
            dmem_wr_en   = 1'b1;
            dmem_wr_addr = mem_clear_addr[D_AW-1:0];
            dmem_wr_data = 32'h0000_0000;
            dmem_wr_be   = 4'hF;
        end else if (dmem_mirror_en) begin
            dmem_wr_en   = 1'b1;
            dmem_wr_addr = imem_wr_addr[D_AW-1:0];
            dmem_wr_data = imem_wr_data;
            dmem_wr_be   = imem_wr_be;
        end else if (dmem_cpu_store) begin
            dmem_wr_en   = |dmem_store_be;
            dmem_wr_addr = dmem_idx(d_req_addr);
            dmem_wr_data = dmem_store_wdata;
            dmem_wr_be   = dmem_store_be;
        end
    end

    l1_dmem_bram #(
        .DEPTH_WORDS(DMEM_DEPTH_WORDS),
        .ADDR_W(D_AW)
    ) u_dmem (
        .clk    (pl_clk),
        .rd_en  (d_req_valid && !d_is_mmio),
        .rd_addr(dmem_rd_addr),
        .rd_data(dmem_rdata_q),
        .wr_en  (dmem_wr_en),
        .wr_addr(dmem_wr_addr),
        .wr_data(dmem_wr_data),
        .wr_be  (dmem_wr_be)
    );

    always_comb begin
        unique case (d_req_size_q)
            3'd0: dmem_load_rdata = dmem_rdata_q >> (8 * d_req_addr_q[1:0]);
            3'd1: dmem_load_rdata = d_req_addr_q[1] ? {16'd0, dmem_rdata_q[31:16]}
                                                     : {16'd0, dmem_rdata_q[15:0]};
            default: dmem_load_rdata = dmem_rdata_q;
        endcase
    end

    // I-response (registered read from IMEM)
    always_ff @(posedge pl_clk) begin
        if (!pl_resetn) begin
            i_resp_valid <= 1'b0;
            i_resp_err   <= 1'b0;
        end else begin
            i_resp_valid <= i_req_valid && i_req_ready;
            if (i_req_valid && i_req_ready) begin
                i_resp_err   <= i_align_bad;
            end
        end
    end

    // D-response
    always_ff @(posedge pl_clk) begin
        if (!pl_resetn) begin
            d_resp_valid     <= 1'b0;
            d_resp_rdata     <= '0;
            d_resp_err       <= 1'b0;
            cpu_uart_tx_start <= 1'b0;
            cpu_uart_tx_byte  <= 8'd0;
        end else begin
            d_resp_valid     <= 1'b0;
            cpu_uart_tx_start <= 1'b0;

            if (d_req_valid_q) begin
                d_resp_valid <= 1'b1;
                d_resp_err   <= d_align_bad_q;

                if (d_is_mmio_q) begin
                    if (d_req_cmd_q == D_CMD_ST) begin
                        cpu_uart_tx_start <= 1'b1;
                        cpu_uart_tx_byte  <= d_req_wdata_q[7:0];
                        d_resp_rdata <= d_req_wdata_q;
                    end else begin
                        d_resp_rdata <= 32'd0;
                    end
                end else if (d_req_cmd_q == D_CMD_LD) begin
                    d_resp_rdata <= dmem_load_rdata;
                end else if (d_req_cmd_q == D_CMD_ST) begin
                    d_resp_rdata <= d_align_bad_q ? '0 : d_req_wdata_q;
                end else begin
                    d_resp_rdata <= '0;
                end
            end
        end
    end

    // Ctl passthrough
    always_ff @(posedge pl_clk) begin
        if (!pl_resetn) begin
            ctl_done <= 1'b0;
            ctl_err  <= 1'b0;
        end else begin
            ctl_done <= 1'b0;
            ctl_err  <= 1'b0;
            if (ctl_req_valid) begin
                ctl_done <= 1'b1;
                ctl_err  <= 1'b0;
            end
        end
    end

endmodule

module l1_imem_bram #(
    parameter int unsigned DEPTH_WORDS = 16384,
    parameter int unsigned ADDR_W      = $clog2(DEPTH_WORDS)
) (
    input  logic              clk,
    input  logic              rd_en,
    input  logic [ADDR_W-1:0] rd_addr,
    output logic [31:0]       rd_data,
    input  logic              wr_en,
    input  logic [ADDR_W-1:0] wr_addr,
    input  logic [31:0]       wr_data,
    input  logic [3:0]        wr_be
);
    (* ram_style = "block" *) logic [31:0] mem [0:DEPTH_WORDS-1];

    integer init_idx;
    initial begin
        for (init_idx = 0; init_idx < DEPTH_WORDS; init_idx = init_idx + 1)
            mem[init_idx] = 32'h0000_0013;
    end

    always_ff @(posedge clk) begin
        if (wr_en) begin
            if (wr_be[0]) mem[wr_addr][7:0]   <= wr_data[7:0];
            if (wr_be[1]) mem[wr_addr][15:8]  <= wr_data[15:8];
            if (wr_be[2]) mem[wr_addr][23:16] <= wr_data[23:16];
            if (wr_be[3]) mem[wr_addr][31:24] <= wr_data[31:24];
        end
        if (rd_en)
            rd_data <= mem[rd_addr];
    end
endmodule

module l1_dmem_bram #(
    parameter int unsigned DEPTH_WORDS = 16384,
    parameter int unsigned ADDR_W      = $clog2(DEPTH_WORDS)
) (
    input  logic              clk,
    input  logic              rd_en,
    input  logic [ADDR_W-1:0] rd_addr,
    output logic [31:0]       rd_data,
    input  logic              wr_en,
    input  logic [ADDR_W-1:0] wr_addr,
    input  logic [31:0]       wr_data,
    input  logic [3:0]        wr_be
);
    (* ram_style = "block" *) logic [31:0] mem [0:DEPTH_WORDS-1];

    integer init_idx;
    initial begin
        for (init_idx = 0; init_idx < DEPTH_WORDS; init_idx = init_idx + 1)
            mem[init_idx] = 32'h0000_0000;
    end

    always_ff @(posedge clk) begin
        if (wr_en) begin
            if (wr_be[0]) mem[wr_addr][7:0]   <= wr_data[7:0];
            if (wr_be[1]) mem[wr_addr][15:8]  <= wr_data[15:8];
            if (wr_be[2]) mem[wr_addr][23:16] <= wr_data[23:16];
            if (wr_be[3]) mem[wr_addr][31:24] <= wr_data[31:24];
        end
        if (rd_en)
            rd_data <= mem[rd_addr];
    end
endmodule
