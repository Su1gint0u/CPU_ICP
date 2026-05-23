// Behavioral L1I/L1D memory model (separate IMEM/DMEM word arrays).
// Word index = physical_byte_addr[31:2] masked into DEPTH_WORDS (power-of-2).

module l1_mem_model #(
    parameter int unsigned DEPTH_WORDS = 4096,
    parameter int unsigned XLEN = 32,
    parameter int unsigned FETCH_W = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter string IMEM_HEX = ""
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
    output logic                 ctl_err
);

    localparam int unsigned AW = $clog2(DEPTH_WORDS);
    localparam logic [2:0] D_CMD_LD  = 3'b001;
    localparam logic [2:0] D_CMD_ST  = 3'b010;
    localparam logic [2:0] D_CMD_AMO = 3'b011;

    logic [31:0] imem [0:DEPTH_WORDS-1];
    logic [31:0] dmem [0:DEPTH_WORDS-1];

    initial begin
      string imem_path;
      // Plusarg overrides TB parameter (per-test IMEM from sim command line, cwd=sim/work/).
      if ($value$plusargs("imem_hex=%s", imem_path) && (imem_path.len() > 0)) begin
        $readmemh(imem_path, imem);
      end else if (IMEM_HEX.len() > 0) begin
        $readmemh(IMEM_HEX, imem);
      end
    end

    function automatic logic [AW-1:0] addr_to_idx(input logic [31:0] byte_addr);
        addr_to_idx = byte_addr[31:2] & (DEPTH_WORDS - 1);
    endfunction

    function automatic logic [31:0] d_line_base_addr(input logic [31:0] byte_addr);
        d_line_base_addr = byte_addr & ~(32'(LINE_BYTES) - 32'd1);
    endfunction

    wire h2_ar_sink = d_req_amo_aq | d_req_amo_rl;

    assign i_req_ready = 1'b1;
    // H2: AQ/RL 端口与 `l1_cache_cluster` 对齐；行为模型无 PUTM，ready 恒 1（tautology 引用 h2_ar_sink 避免 lint）。
    assign d_req_ready = 1'b1 | (h2_ar_sink | ~h2_ar_sink);

    logic [AW-1:0] i_idx;
    logic [AW-1:0] d_idx;
    logic          i_align_bad;
    logic          d_align_bad;

    always_comb begin
        i_idx = addr_to_idx(i_req_addr);
        d_idx = addr_to_idx(d_req_addr);
        i_align_bad = (i_req_addr[1:0] != 2'b00);
        d_align_bad = 1'b0;
        unique case (d_req_size)
            3'd0: d_align_bad = 1'b0; // byte
            3'd1: d_align_bad = d_req_addr[0]; // half
            3'd2: d_align_bad = (d_req_addr[1:0] != 2'b00); // word
            default: d_align_bad = 1'b1;
        endcase
    end

    logic [FETCH_W-1:0] i_rdata_c;
    logic [31:0] d_rdata_c;
    logic [31:0] store_wdata_masked;

    // i_rdata_c: read multiple words for wide fetch
    always_comb begin
        if (FETCH_W == 64) begin
            i_rdata_c = {imem[(i_idx + 1) & (DEPTH_WORDS - 1)], imem[i_idx]};
        end else begin
            i_rdata_c = {{FETCH_W-32{1'b0}}, imem[i_idx]};
        end
        d_rdata_c = dmem[d_idx];
        store_wdata_masked = d_req_wdata;
    end
    logic [31:0] store_oldv;
    logic [31:0] store_newv;
    logic        lr_res_valid;
    logic [31:0] lr_res_addr;



    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            i_resp_valid <= 1'b0;
            i_resp_data  <= '0;
            i_resp_err   <= 1'b0;
            d_resp_valid <= 1'b0;
            d_resp_rdata <= '0;
            d_resp_err   <= 1'b0;
            lr_res_valid <= 1'b0;
            lr_res_addr  <= '0;
            ctl_done     <= 1'b0;
            ctl_err      <= 1'b0;
            // Unified bare-metal image: DMEM starts matching IMEM (riscv-tests, etc.).
            for (int ii = 0; ii < DEPTH_WORDS; ii++) begin
                dmem[ii] <= imem[ii];
            end
        end else begin
            i_resp_valid <= 1'b0;
            d_resp_valid <= 1'b0;
            ctl_done     <= 1'b0;
            ctl_err      <= 1'b0;

            if (i_req_valid && i_req_ready) begin
                i_resp_valid <= 1'b1;
                i_resp_data  <= i_rdata_c;
                i_resp_err   <= i_align_bad;
            end

            if (d_req_valid && d_req_ready) begin
                d_resp_valid <= 1'b1;
                if (d_req_cmd == D_CMD_LD) begin
                    d_resp_err   <= d_align_bad;
                    d_resp_rdata <= d_rdata_c;
                end else if (d_req_cmd == D_CMD_ST) begin
                    d_resp_err <= d_align_bad;
                    if (!d_align_bad) begin
                        store_oldv = dmem[d_idx];
                        store_newv = store_oldv;
                        case (d_req_size)
                            3'd0: begin
                                case (d_req_addr[1:0])
                                    2'b00: store_newv = {store_oldv[31:8], d_req_wdata[7:0]};
                                    2'b01: store_newv = {store_oldv[31:16], d_req_wdata[7:0], store_oldv[7:0]};
                                    2'b10: store_newv = {store_oldv[31:24], d_req_wdata[7:0], store_oldv[15:0]};
                                    2'b11: store_newv = {d_req_wdata[7:0], store_oldv[23:0]};
                                endcase
                            end
                            3'd1: begin
                                if (!d_req_addr[1])
                                    store_newv = {store_oldv[31:16], d_req_wdata[15:0]};
                                else
                                    store_newv = {d_req_wdata[15:0], store_oldv[15:0]};
                            end
                            3'd2: store_newv = d_req_wdata;
                            default: store_newv = store_oldv;
                        endcase
                        dmem[d_idx] <= store_newv;
                        d_resp_rdata <= store_newv;
                        if (lr_res_valid && (lr_res_addr == d_line_base_addr(d_req_addr)))
                            lr_res_valid <= 1'b0;
                    end else begin
                        d_resp_rdata <= '0;
                    end
                end else if (d_req_cmd == D_CMD_AMO) begin
                    automatic logic [31:0] amo_o;
                    automatic logic [31:0] amo_n;
                    automatic logic        amo_w;
                    automatic logic        amo_ill;
                    amo_o = d_rdata_c;
                    amo_n = amo_o;
                    amo_w = 1'b0;
                    amo_ill = 1'b0;
                    d_resp_err <= d_align_bad;
                    d_resp_rdata <= '0;
                    if (!d_align_bad && (d_req_size == 3'd2)) begin
                        unique case (d_req_amo_funct)
                            5'h02: begin
                                d_resp_rdata <= amo_o;
                                lr_res_valid <= 1'b1;
                                lr_res_addr  <= d_line_base_addr(d_req_addr);
                            end
                            5'h03: begin
                                lr_res_valid <= 1'b0;
                                if (lr_res_valid && (lr_res_addr == d_line_base_addr(d_req_addr))) begin
                                    amo_n = d_req_wdata;
                                    amo_w = 1'b1;
                                    d_resp_rdata <= 32'b0;
                                end else begin
                                    d_resp_rdata <= 32'd1;
                                end
                            end
                            5'h01: begin amo_n = d_req_wdata; amo_w = 1'b1; d_resp_rdata <= amo_o; end
                            5'h00: begin amo_n = amo_o + d_req_wdata; amo_w = 1'b1; d_resp_rdata <= amo_o; end
                            5'h04: begin amo_n = amo_o ^ d_req_wdata; amo_w = 1'b1; d_resp_rdata <= amo_o; end
                            5'h08: begin amo_n = amo_o | d_req_wdata; amo_w = 1'b1; d_resp_rdata <= amo_o; end
                            5'h0C: begin amo_n = amo_o & d_req_wdata; amo_w = 1'b1; d_resp_rdata <= amo_o; end
                            5'h10: begin
                                if ($signed(amo_o) < $signed(d_req_wdata)) amo_n = amo_o; else amo_n = d_req_wdata;
                                amo_w = 1'b1; d_resp_rdata <= amo_o;
                            end
                            5'h14: begin
                                if ($signed(amo_o) > $signed(d_req_wdata)) amo_n = amo_o; else amo_n = d_req_wdata;
                                amo_w = 1'b1; d_resp_rdata <= amo_o;
                            end
                            5'h18: begin
                                if (amo_o < d_req_wdata) amo_n = amo_o; else amo_n = d_req_wdata;
                                amo_w = 1'b1; d_resp_rdata <= amo_o;
                            end
                            5'h1C: begin
                                if (amo_o > d_req_wdata) amo_n = amo_o; else amo_n = d_req_wdata;
                                amo_w = 1'b1; d_resp_rdata <= amo_o;
                            end
                            default: amo_ill = 1'b1;
                        endcase
                        if (amo_ill) begin
                            d_resp_err <= 1'b1;
                        end else if (amo_w) begin
                            dmem[d_idx] <= amo_n;
                            if (lr_res_valid && (lr_res_addr == d_line_base_addr(d_req_addr)))
                                lr_res_valid <= 1'b0;
                        end
                    end else begin
                        d_resp_err <= 1'b1;
                    end
                end else begin
                    d_resp_err   <= 1'b0;
                    d_resp_rdata <= '0;
                end
            end

            if (ctl_req_valid) begin
                ctl_done <= 1'b1;
                ctl_err  <= 1'b0;
            end
        end
    end

endmodule
