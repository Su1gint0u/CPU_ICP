// Top-level branch predictor (Appendix 12.9): direction (bimodal / Gshare / TAGE) + BTB + RAS.
// bp_upd_meta[63:0]: [31:30] 2'b00 branch / 2'b01 JAL / 2'b10 JALR; TAGE snapshot in [63:32]|[29:0].
// P6: USE_GSHARE=1 selects bp_gshare. P7: BP_USE_TAGE/USE_TAGE=1 selects bp_tage (mutually exclusive with Gshare; SPEC §3.4.1).
module bp_predictor_simple #(
    parameter int unsigned ENTRIES = 64,
    parameter int unsigned IDX_BITS = 6,
    parameter int unsigned TAG_BITS = 22,
    parameter int unsigned RAS_DEPTH = 4,
    parameter bit          USE_GSHARE = 1'b0,
    parameter bit          USE_TAGE    = 1'b0,
    parameter bit          BP_USE_TAGE = 1'b0
) (
    input  logic        pl_clk,
    input  logic        pl_resetn,

    input  logic        bp_if_valid,
    input  logic [31:0] bp_if_pc,
    input  logic [31:0] bp_if_pc1,
    output logic [63:0] bp_pred_meta1,
    output logic        bp_pred_taken1,

    output logic        bp_pred_taken,
    output logic [63:0] bp_pred_meta,
    output logic        bp_if_spec_taken,
    output logic [31:0] bp_if_spec_target,

    input  logic        bp_upd_valid,
    input  logic [31:0] bp_upd_pc,
    input  logic        bp_upd_taken,
    input  logic        bp_upd_mispredict,
    input  logic [63:0] bp_upd_meta,
    input  logic [31:0] bp_upd_branch_target
);

    wire [IDX_BITS-1:0] if_idx  = bp_if_pc[IDX_BITS+1:2];
    wire [IDX_BITS-1:0] if_idx1 = bp_if_pc1[IDX_BITS+1:2];
    logic [1:0] ctr1_w;
    logic btb_hit1_w, btb_is_ret1_w;
    logic [31:0] btb_target1_w;

    logic btb_hit_w;
    logic btb_is_ret_w;
    logic [31:0] btb_target_w;
    logic [1:0] ctr_w;

    logic [1:0] ukind;
    logic [4:0] u_rd;
    logic [4:0] u_rs1;
    logic [11:0] u_imm12;
    logic jal_call;
    logic jalr_ret;
    logic upd_is_ret_w;
    logic ras_push_w;
    logic ras_pop_w;

    always_comb begin
        ukind   = bp_upd_meta[31:30];
        u_rd    = bp_upd_meta[26:22];
        u_rs1   = bp_upd_meta[21:17];
        u_imm12 = bp_upd_meta[16:5];
        jal_call = bp_upd_valid && (ukind == 2'b01) && ((u_rd == 5'd1) || (u_rd == 5'd5));
        jalr_ret = bp_upd_valid && (ukind == 2'b10) && (u_rd == 5'd0)
            && ((u_rs1 == 5'd1) || (u_rs1 == 5'd5)) && (u_imm12 == 12'h0);
        upd_is_ret_w = jalr_ret;
        ras_push_w   = jal_call;
        ras_pop_w    = jalr_ret;
    end

    wire upd_is_conditional = bp_upd_valid && (ukind == 2'b00);

    logic [31:0] ras_top_w;
    logic ras_empty_w;

    bp_ras #(
        .DEPTH(RAS_DEPTH)
    ) u_ras (
        .pl_clk(pl_clk),
        .pl_resetn(pl_resetn),
        .push(ras_push_w),
        .pop(ras_pop_w),
        .push_addr(bp_upd_pc + 32'd4),
        .top(ras_top_w),
        .empty(ras_empty_w)
    );

    logic [63:0] tage_meta_w, tage_meta1_w;

    localparam bit TAGE_ON = USE_TAGE | BP_USE_TAGE;

    generate
        if (TAGE_ON) begin : gen_tage
            bp_tage u_dir (
                .pl_clk(pl_clk),
                .pl_resetn(pl_resetn),
                .query_pc(bp_if_pc),
                .pred_taken_msb(bp_pred_taken),
                .counter_out(ctr_w),
                .pred_meta(tage_meta_w),
                .query_pc1(bp_if_pc1),
                .pred_taken_msb1(bp_pred_taken1),
                .counter_out1(ctr1_w),
                .pred_meta1(tage_meta1_w),
                .upd_valid(bp_upd_valid),
                .upd_pc(bp_upd_pc),
                .upd_taken(bp_upd_taken),
                .upd_mispredict(bp_upd_mispredict),
                .upd_meta(bp_upd_meta),
                .upd_is_conditional(upd_is_conditional)
            );
        end else if (USE_GSHARE) begin : gen_gshare
            assign tage_meta_w = 64'b0;
            bp_gshare #(
                .ENTRIES (ENTRIES),
                .IDX_BITS(IDX_BITS),
                .GHR_BITS(IDX_BITS)
            ) u_dir (
                .pl_clk(pl_clk),
                .pl_resetn(pl_resetn),
                .query_pc(bp_if_pc),
                .pred_taken_msb(bp_pred_taken),
                .counter_out(ctr_w),
                .upd_valid(bp_upd_valid),
                .upd_pc(bp_upd_pc),
                .upd_taken(bp_upd_taken)
            );
        end else begin : gen_bimod
            assign tage_meta_w = 64'b0;
            bp_direction_2bit #(
                .ENTRIES (ENTRIES),
                .IDX_BITS(IDX_BITS)
            ) u_dir (
                .pl_clk(pl_clk), .pl_resetn(pl_resetn),
                .ridx(if_idx),
                .pred_taken_msb(bp_pred_taken),
                .counter_out(ctr_w),
                .ridx1(if_idx1),
                .pred_taken_msb1(bp_pred_taken1),
                .counter_out1(ctr1_w),
                .upd_valid(bp_upd_valid),
                .upd_idx(bp_upd_pc[IDX_BITS+1:2]),
                .upd_taken(bp_upd_taken)
            );
        end
    endgenerate

    bp_btb_direct #(
        .ENTRIES (ENTRIES), .IDX_BITS(IDX_BITS), .TAG_BITS (TAG_BITS)
    ) u_btb (
        .pl_clk(pl_clk), .pl_resetn(pl_resetn),
        .query_pc(bp_if_pc),
        .hit(btb_hit_w), .target(btb_target_w), .is_ret(btb_is_ret_w),
        .query_pc1(bp_if_pc1),
        .hit1(btb_hit1_w), .target1(btb_target1_w), .is_ret1(btb_is_ret1_w),
        .upd_valid(bp_upd_valid), .upd_pc(bp_upd_pc),
        .upd_target(bp_upd_branch_target), .upd_is_ret(upd_is_ret_w)
    );

    wire ret_site = btb_hit_w && btb_is_ret_w;
    wire norm_btb = btb_hit_w && !btb_is_ret_w;

    always_comb begin
        if (TAGE_ON) begin
            bp_pred_meta  = tage_meta_w;
            bp_pred_meta1 = tage_meta1_w;
        end else begin
            bp_pred_meta  = {32'b0, 24'b0, 6'b0, ctr_w};
            bp_pred_meta1 = {32'b0, 24'b0, 6'b0, ctr1_w};
        end
        bp_if_spec_taken  = ret_site || (norm_btb && bp_pred_taken);
        bp_if_spec_target = ret_site ? (ras_empty_w ? btb_target_w : ras_top_w) : btb_target_w;
    end

endmodule
