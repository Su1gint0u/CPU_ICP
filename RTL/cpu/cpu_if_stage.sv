// Instruction fetch stage: PC, L1I handshake, fetch buffer, IF/ID pipeline register.
// FETCH_W=64: PC steps by 8, fetch_buf holds full 64-bit bundle.
module cpu_if_stage #(
    parameter int unsigned FETCH_W = 32,
    parameter logic [31:0] RESET_PC = 32'h8000_0000
) (
    input  logic pl_clk,
    input  logic pl_resetn,

    input  logic stall_all,
    input  logic redirect_valid,
    input  logic [31:0] redirect_pc,
    input  logic consume_ifid,

    input  logic i_req_ready,
    input  logic i_resp_valid,
    input  logic [FETCH_W-1:0] i_resp_data,
    input  logic i_resp_err,

    input  logic bp_if_spec_taken,
    input  logic [31:0] bp_if_spec_target,

    input  logic        bp_pred_taken,
    input  logic [63:0] bp_pred_meta,

    // Slot1 BP prediction (independent per-slot, from BPU dual-port)
    input  logic        bp_pred_taken1,
    input  logic [63:0] bp_pred_meta1,

    output logic i_req_valid,
    output logic [31:0] i_req_addr,

    output logic ifid_valid,
    output logic [31:0] ifid_pc, ifid_inst, output logic ifid_err,
    output logic        ifid_bp_pred_taken, output logic [63:0] ifid_bp_pred_meta,
    // Slot 1 (second instruction from 64-bit bundle)
    output logic        ifid1_valid, output logic [31:0] ifid1_pc, ifid1_inst,
    output logic        ifid1_err,
    output logic        ifid1_bp_pred_taken, output logic [63:0] ifid1_bp_pred_meta,

    output logic fetch_inflight,
    output logic [31:0] pc_q_o,
    output logic mon_if_req_issue,
    output logic mon_if_resp_accept,
    output logic mon_if_resp_drop,
    output logic mon_if_buf_write,
    output logic mon_if_buf_read
);

    localparam int unsigned PC_STEP = FETCH_W / 8;  // 32→4, 64→8

    function automatic logic slot1_available(input logic [31:0] pc);
        if (FETCH_W >= 64)
            slot1_available = (pc[4:2] != 3'd7);
        else
            slot1_available = 1'b0;
    endfunction

    function automatic logic [31:0] seq_next_pc(input logic [31:0] pc);
        if (FETCH_W >= 64 && slot1_available(pc))
            seq_next_pc = pc + 32'd8;
        else
            seq_next_pc = pc + 32'd4;
    endfunction

    logic [31:0] pc_epoch_q;
    logic [1:0]  inflight_cnt;
    logic [31:0] req_pc_q0, req_pc_q1;
    logic        req_bp_taken_q0, req_bp_taken_q1;
    logic [63:0] req_bp_meta_q0, req_bp_meta_q1;
    logic        req_bp_taken1_q0, req_bp_taken1_q1;
    logic [63:0] req_bp_meta1_q0, req_bp_meta1_q1;
    logic [31:0] req_epoch_q0, req_epoch_q1;

    // fetch_buf holds a full FETCH_W bundle
    logic                           fetch_buf_valid;
    logic [31:0]                    fetch_buf_pc;
    logic [FETCH_W-1:0]             fetch_buf_data;
    logic                           fetch_buf_err;
    logic                           fetch_buf_bp_pred_taken;
    logic [63:0]                    fetch_buf_bp_pred_meta;
    logic                           fetch_buf_bp_pred_taken1;
    logic [63:0]                    fetch_buf_bp_pred_meta1;

    logic        if_buf_pop;
    logic        resp_to_ifid;
    logic        can_issue;
    logic        req_fire;
    logic        resp_fire;
    logic        head_epoch_match;
    logic [31:0] head_pc;
    logic        head_bp_taken;
    logic [63:0] head_bp_meta;
    logic        head_bp_taken1;
    logic [63:0] head_bp_meta1;

    always_comb begin
        fetch_inflight = (inflight_cnt != 2'd0);
        can_issue = !stall_all && !redirect_valid && (inflight_cnt < 2'd2)
            && (!fetch_buf_valid || if_buf_pop)
            && ((inflight_cnt == 2'd0) || !ifid_valid || consume_ifid);
        i_req_valid = can_issue;
        i_req_addr = pc_q_o;
        req_fire = i_req_valid && i_req_ready;
        resp_fire = i_resp_valid && fetch_inflight && !redirect_valid;
        head_pc = req_pc_q0;
        head_bp_taken = req_bp_taken_q0;
        head_bp_meta = req_bp_meta_q0;
        head_bp_taken1 = req_bp_taken1_q0;
        head_bp_meta1 = req_bp_meta1_q0;
        head_epoch_match = (req_epoch_q0 == pc_epoch_q);
        if_buf_pop = !stall_all && fetch_buf_valid && (consume_ifid || !ifid_valid);
        resp_to_ifid = resp_fire && head_epoch_match
            && !stall_all && !redirect_valid && !fetch_buf_valid && (consume_ifid || !ifid_valid);
        mon_if_resp_accept = resp_fire && head_epoch_match;
        mon_if_resp_drop   = resp_fire && !head_epoch_match;
        mon_if_buf_write   = mon_if_resp_accept && !resp_to_ifid;
        mon_if_buf_read    = if_buf_pop;
        mon_if_req_issue   = req_fire;
    end

    // pc_q_o drives the inferred IMEM BRAM address pins. Keep IF reset
    // synchronous so those BRAM control inputs are fully timed by Vivado.
    always_ff @(posedge pl_clk) begin
        if (!pl_resetn) begin
            pc_q_o <= RESET_PC;
            pc_epoch_q <= 32'd0;

            fetch_buf_valid <= 1'b0;
            fetch_buf_pc <= '0;
            fetch_buf_data <= '0;
            fetch_buf_err <= 1'b0;
            fetch_buf_bp_pred_taken <= 1'b0;
            fetch_buf_bp_pred_meta <= '0;
            fetch_buf_bp_pred_taken1 <= 1'b0;
            fetch_buf_bp_pred_meta1 <= '0;
            inflight_cnt <= 2'd0;
            req_pc_q0 <= '0;
            req_pc_q1 <= '0;
            req_bp_taken_q0 <= 1'b0;
            req_bp_taken_q1 <= 1'b0;
            req_bp_meta_q0 <= '0;
            req_bp_meta_q1 <= '0;
            req_bp_taken1_q0 <= 1'b0;
            req_bp_taken1_q1 <= 1'b0;
            req_bp_meta1_q0 <= '0;
            req_bp_meta1_q1 <= '0;
            req_epoch_q0 <= '0;
            req_epoch_q1 <= '0;

            ifid_valid <= 1'b0;
            ifid_pc <= '0;
            ifid_inst <= '0;
            ifid_err <= 1'b0;
            ifid_bp_pred_taken <= 1'b0;
            ifid_bp_pred_meta <= '0;
            ifid1_valid <= 1'b0; ifid1_pc <= '0; ifid1_inst <= '0; ifid1_err <= 1'b0;
            ifid1_bp_pred_taken <= 1'b0; ifid1_bp_pred_meta <= '0;
        end else begin
            if (redirect_valid) begin
                pc_q_o <= redirect_pc;
                pc_epoch_q <= pc_epoch_q + 32'd1;
                ifid_valid <= 1'b0;
                ifid1_valid <= 1'b0;
                fetch_buf_valid <= 1'b0;
                inflight_cnt <= 2'd0;
            end

            if (!redirect_valid && resp_fire) begin
                if (head_epoch_match) begin
                    if (resp_to_ifid) begin
                        ifid_valid <= 1'b1;
                        ifid_pc <= head_pc;
                        ifid_inst <= i_resp_data[31:0];
                        ifid_err <= i_resp_err;
                        ifid_bp_pred_taken <= head_bp_taken;
                        ifid_bp_pred_meta <= head_bp_meta;
                        if (FETCH_W >= 64 && slot1_available(head_pc)) begin
                            ifid1_valid <= 1'b1;
                            ifid1_pc   <= head_pc + 32'd4;
                            ifid1_inst <= i_resp_data[63:32];
                            ifid1_err  <= i_resp_err;
                            ifid1_bp_pred_taken <= head_bp_taken1;
                            ifid1_bp_pred_meta  <= head_bp_meta1;
                        end else begin
                            ifid1_valid <= 1'b0;
                        end
                        fetch_buf_valid <= 1'b0;
                    end else begin
                        fetch_buf_valid <= 1'b1;
                        fetch_buf_pc <= head_pc;
                        fetch_buf_data <= i_resp_data;
                        fetch_buf_err <= i_resp_err;
                        fetch_buf_bp_pred_taken <= head_bp_taken;
                        fetch_buf_bp_pred_meta <= head_bp_meta;
                        fetch_buf_bp_pred_taken1 <= head_bp_taken1;
                        fetch_buf_bp_pred_meta1 <= head_bp_meta1;
                    end
                end else begin
                    fetch_buf_valid <= 1'b0;
                end

                if (inflight_cnt == 2'd2) begin
                    req_pc_q0 <= req_pc_q1;
                    req_bp_taken_q0 <= req_bp_taken_q1;
                    req_bp_meta_q0 <= req_bp_meta_q1;
                    req_bp_taken1_q0 <= req_bp_taken1_q1;
                    req_bp_meta1_q0 <= req_bp_meta1_q1;
                    req_epoch_q0 <= req_epoch_q1;
                end
            end

            if (!redirect_valid) begin
                unique case ({req_fire, resp_fire})
                    2'b10: begin
                        if (inflight_cnt == 2'd0) begin
                            req_pc_q0 <= pc_q_o;
                            req_bp_taken_q0 <= bp_if_spec_taken;
                            req_bp_meta_q0 <= bp_pred_meta;
                            req_bp_taken1_q0 <= bp_pred_taken1;
                            req_bp_meta1_q0 <= bp_pred_meta1;
                            req_epoch_q0 <= pc_epoch_q;
                        end else if (inflight_cnt == 2'd1) begin
                            req_pc_q1 <= pc_q_o;
                            req_bp_taken_q1 <= bp_if_spec_taken;
                            req_bp_meta_q1 <= bp_pred_meta;
                            req_bp_taken1_q1 <= bp_pred_taken1;
                            req_bp_meta1_q1 <= bp_pred_meta1;
                            req_epoch_q1 <= pc_epoch_q;
                        end
                        inflight_cnt <= inflight_cnt + 2'd1;
                        pc_q_o <= bp_if_spec_taken ? bp_if_spec_target
                                : seq_next_pc(pc_q_o);
                    end
                    2'b01: begin
                        inflight_cnt <= inflight_cnt - 2'd1;
                    end
                    2'b11: begin
                        if (inflight_cnt == 2'd1) begin
                            req_pc_q0 <= pc_q_o;
                            req_bp_taken_q0 <= bp_if_spec_taken;
                            req_bp_meta_q0 <= bp_pred_meta;
                            req_bp_taken1_q0 <= bp_pred_taken1;
                            req_bp_meta1_q0 <= bp_pred_meta1;
                            req_epoch_q0 <= pc_epoch_q;
                        end else if (inflight_cnt == 2'd2) begin
                            req_pc_q1 <= pc_q_o;
                            req_bp_taken_q1 <= bp_if_spec_taken;
                            req_bp_meta_q1 <= bp_pred_meta;
                            req_bp_taken1_q1 <= bp_pred_taken1;
                            req_bp_meta1_q1 <= bp_pred_meta1;
                            req_epoch_q1 <= pc_epoch_q;
                        end
                        inflight_cnt <= inflight_cnt;
                        pc_q_o <= bp_if_spec_taken ? bp_if_spec_target
                                : seq_next_pc(pc_q_o);
                    end
                    default: begin
                        inflight_cnt <= inflight_cnt;
                    end
                endcase
            end

            // IF/ID: splice fetch_buf into IF/ID, providing both slots
            if (!redirect_valid && !stall_all) begin
                if (!resp_to_ifid && consume_ifid) begin
                    if (fetch_buf_valid) begin
                        ifid_valid <= 1'b1;
                        ifid_pc <= fetch_buf_pc;
                        ifid_inst <= fetch_buf_data[31:0];
                        ifid_err <= fetch_buf_err;
                        ifid_bp_pred_taken <= fetch_buf_bp_pred_taken;
                        ifid_bp_pred_meta <= fetch_buf_bp_pred_meta;
                        if (FETCH_W >= 64 && slot1_available(fetch_buf_pc)) begin
                            ifid1_valid <= 1'b1;
                            ifid1_pc   <= fetch_buf_pc + 32'd4;
                            ifid1_inst <= fetch_buf_data[63:32];
                            ifid1_err  <= fetch_buf_err;
                            ifid1_bp_pred_taken <= fetch_buf_bp_pred_taken1;
                            ifid1_bp_pred_meta  <= fetch_buf_bp_pred_meta1;
                        end else begin
                            ifid1_valid <= 1'b0;
                        end
                        fetch_buf_valid <= 1'b0;
                    end else begin
                        ifid_valid <= 1'b0;
                        ifid1_valid <= 1'b0;
                    end
                end else if (!resp_to_ifid && !ifid_valid && fetch_buf_valid) begin
                    ifid_valid <= 1'b1;
                    ifid_pc <= fetch_buf_pc;
                    ifid_inst <= fetch_buf_data[31:0];
                    ifid_err <= fetch_buf_err;
                    ifid_bp_pred_taken <= fetch_buf_bp_pred_taken;
                    ifid_bp_pred_meta <= fetch_buf_bp_pred_meta;
                    if (FETCH_W >= 64 && slot1_available(fetch_buf_pc)) begin
                        ifid1_valid <= 1'b1;
                        ifid1_pc   <= fetch_buf_pc + 32'd4;
                        ifid1_inst <= fetch_buf_data[63:32];
                        ifid1_err  <= fetch_buf_err;
                        ifid1_bp_pred_taken <= fetch_buf_bp_pred_taken1;
                        ifid1_bp_pred_meta  <= fetch_buf_bp_pred_meta1;
                    end else begin
                        ifid1_valid <= 1'b0;
                    end
                    fetch_buf_valid <= 1'b0;
                end
            end
        end
    end

endmodule
