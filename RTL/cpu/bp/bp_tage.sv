// L-TAGE-style direction predictor (see DOCUMENT/L-TAGE_计划清单.md): base 1024x2b + 4 tagged 512x(10t+3c+2u), 64b GHR.
// Meta: only [63:32] and [29:0]; [31:30] tied 0 (EX forces 00 on branch bp_upd_meta).

module bp_tage (
    input  logic        pl_clk,
    input  logic        pl_resetn,

    input  logic [31:0] query_pc,
    output logic        pred_taken_msb,
    output logic [1:0]  counter_out,
    output logic [63:0] pred_meta,

    // Slot1 prediction (PC+4, second instruction in 64-bit fetch bundle)
    input  logic [31:0] query_pc1,
    output logic        pred_taken_msb1,
    output logic [1:0]  counter_out1,
    output logic [63:0] pred_meta1,

    input  logic        upd_valid,
    input  logic [31:0] upd_pc,
    input  logic        upd_taken,
    input  logic        upd_mispredict,
    input  logic [63:0] upd_meta,
    input  logic        upd_is_conditional
);

    localparam int unsigned N_TAG = 4;
    localparam int unsigned BASE_ENTRIES = 1024;
    localparam int unsigned TAG_ENTRIES = 512;
    localparam int unsigned TAG_W = 10;
    localparam int unsigned TIDX_W = 9;
    localparam int unsigned BIDX_W = 10;

    logic [63:0] ghr;

    logic [1:0] base_ctr [0:BASE_ENTRIES-1];
    logic [TAG_W-1:0] t_tag [0:N_TAG-1][0:TAG_ENTRIES-1];
    logic [2:0] t_ctr [0:N_TAG-1][0:TAG_ENTRIES-1];
    logic [1:0] t_u   [0:N_TAG-1][0:TAG_ENTRIES-1];

    wire [BIDX_W-1:0] bidx = query_pc[BIDX_W+1:2];

    wire [TIDX_W-1:0] i0 = query_pc[TIDX_W+1:2] ^ {5'h0, ghr[3:0]};
    wire [TIDX_W-1:0] i1 = query_pc[TIDX_W+1:2] ^ ghr[8:0];
    wire [TIDX_W-1:0] i2 = query_pc[TIDX_W+1:2] ^ ghr[15:7];
    wire [TIDX_W-1:0] i3 = query_pc[TIDX_W+1:2] ^ ghr[31:23];

    wire [TAG_W-1:0] g0 = query_pc[21:12] ^ ghr[9:0];
    wire [TAG_W-1:0] g1 = query_pc[21:12] ^ ghr[17:8];
    wire [TAG_W-1:0] g2 = query_pc[21:12] ^ ghr[25:16];
    wire [TAG_W-1:0] g3 = query_pc[21:12] ^ ghr[39:30];

    wire hit0 = (t_tag[0][i0] == g0);
    wire hit1 = (t_tag[1][i1] == g1);
    wire hit2 = (t_tag[2][i2] == g2);
    wire hit3 = (t_tag[3][i3] == g3);

    logic [2:0] prov_id;
    logic       prov_is_base;
    logic [TIDX_W-1:0] prov_ti;
    logic [TAG_W-1:0]  prov_tg;
    logic [BIDX_W-1:0] prov_bi;
    logic [2:0] prov_ctr_r;
    logic [1:0] prov_u_r;

    always_comb begin
        prov_id = 3'd0;
        prov_is_base = 1'b1;
        prov_bi = bidx;
        prov_ti = '0;
        prov_tg = '0;
        prov_ctr_r = {1'b0, base_ctr[bidx]};
        prov_u_r = 2'b11;
        if (hit3) begin
            prov_id = 3'd4;
            prov_is_base = 1'b0;
            prov_ti = i3;
            prov_tg = g3;
            prov_ctr_r = t_ctr[3][i3];
            prov_u_r   = t_u[3][i3];
        end else if (hit2) begin
            prov_id = 3'd3;
            prov_is_base = 1'b0;
            prov_ti = i2;
            prov_tg = g2;
            prov_ctr_r = t_ctr[2][i2];
            prov_u_r   = t_u[2][i2];
        end else if (hit1) begin
            prov_id = 3'd2;
            prov_is_base = 1'b0;
            prov_ti = i1;
            prov_tg = g1;
            prov_ctr_r = t_ctr[1][i1];
            prov_u_r   = t_u[1][i1];
        end else if (hit0) begin
            prov_id = 3'd1;
            prov_is_base = 1'b0;
            prov_ti = i0;
            prov_tg = g0;
            prov_ctr_r = t_ctr[0][i0];
            prov_u_r   = t_u[0][i0];
        end
    end

    logic final_taken;
    always_comb begin
        if (prov_is_base)
            final_taken = base_ctr[bidx][1];
        else begin
            unique case (prov_id)
                3'd1: final_taken = t_ctr[0][prov_ti][2];
                3'd2: final_taken = t_ctr[1][prov_ti][2];
                3'd3: final_taken = t_ctr[2][prov_ti][2];
                3'd4: final_taken = t_ctr[3][prov_ti][2];
                default: final_taken = base_ctr[bidx][1];
            endcase
        end
    end

    assign pred_taken_msb = final_taken;
    assign counter_out    = prov_is_base ? base_ctr[bidx]
        : {t_ctr[prov_id-1][prov_ti][2], t_ctr[prov_id-1][prov_ti][1]};

    // [31:30]=0; [29:0] and [63:32] hold payload (62 bits)
    always_comb begin
        pred_meta = '0;
        pred_meta[63:32] = ghr[63:32];
        pred_meta[2:0]   = prov_id;
        pred_meta[5:3]   = 3'd0;
        pred_meta[6]     = 1'b0;
        pred_meta[16:7]  = prov_bi;
        pred_meta[25:17] = prov_ti;
        pred_meta[29:26] = prov_tg[3:0];
        pred_meta[37:32] = prov_tg[9:4];
        pred_meta[59:57] = prov_ctr_r;
        pred_meta[61:60] = prov_u_r;
    end

    // ─── Slot1 prediction (PC+4) — replicated from slot0, same arrays, independent lookups ───

    wire [BIDX_W-1:0] bidx1 = query_pc1[BIDX_W+1:2];

    wire [TIDX_W-1:0] i0_1 = query_pc1[TIDX_W+1:2] ^ {5'h0, ghr[3:0]};
    wire [TIDX_W-1:0] i1_1 = query_pc1[TIDX_W+1:2] ^ ghr[8:0];
    wire [TIDX_W-1:0] i2_1 = query_pc1[TIDX_W+1:2] ^ ghr[15:7];
    wire [TIDX_W-1:0] i3_1 = query_pc1[TIDX_W+1:2] ^ ghr[31:23];

    wire [TAG_W-1:0] g0_1 = query_pc1[21:12] ^ ghr[9:0];
    wire [TAG_W-1:0] g1_1 = query_pc1[21:12] ^ ghr[17:8];
    wire [TAG_W-1:0] g2_1 = query_pc1[21:12] ^ ghr[25:16];
    wire [TAG_W-1:0] g3_1 = query_pc1[21:12] ^ ghr[39:30];

    wire hit0_1 = (t_tag[0][i0_1] == g0_1);
    wire hit1_1 = (t_tag[1][i1_1] == g1_1);
    wire hit2_1 = (t_tag[2][i2_1] == g2_1);
    wire hit3_1 = (t_tag[3][i3_1] == g3_1);

    logic [2:0] prov_id1;
    logic       prov_is_base1;
    logic [TIDX_W-1:0] prov_ti1;
    logic [TAG_W-1:0]  prov_tg1;
    logic [BIDX_W-1:0] prov_bi1;
    logic [2:0] prov_ctr_r1;
    logic [1:0] prov_u_r1;

    always_comb begin
        prov_id1 = 3'd0;
        prov_is_base1 = 1'b1;
        prov_bi1 = bidx1;
        prov_ti1 = '0;
        prov_tg1 = '0;
        prov_ctr_r1 = {1'b0, base_ctr[bidx1]};
        prov_u_r1 = 2'b11;
        if (hit3_1) begin
            prov_id1 = 3'd4; prov_is_base1 = 1'b0;
            prov_ti1 = i3_1; prov_tg1 = g3_1;
            prov_ctr_r1 = t_ctr[3][i3_1]; prov_u_r1 = t_u[3][i3_1];
        end else if (hit2_1) begin
            prov_id1 = 3'd3; prov_is_base1 = 1'b0;
            prov_ti1 = i2_1; prov_tg1 = g2_1;
            prov_ctr_r1 = t_ctr[2][i2_1]; prov_u_r1 = t_u[2][i2_1];
        end else if (hit1_1) begin
            prov_id1 = 3'd2; prov_is_base1 = 1'b0;
            prov_ti1 = i1_1; prov_tg1 = g1_1;
            prov_ctr_r1 = t_ctr[1][i1_1]; prov_u_r1 = t_u[1][i1_1];
        end else if (hit0_1) begin
            prov_id1 = 3'd1; prov_is_base1 = 1'b0;
            prov_ti1 = i0_1; prov_tg1 = g0_1;
            prov_ctr_r1 = t_ctr[0][i0_1]; prov_u_r1 = t_u[0][i0_1];
        end
    end

    logic final_taken1;
    always_comb begin
        if (prov_is_base1)
            final_taken1 = base_ctr[bidx1][1];
        else begin
            unique case (prov_id1)
                3'd1: final_taken1 = t_ctr[0][prov_ti1][2];
                3'd2: final_taken1 = t_ctr[1][prov_ti1][2];
                3'd3: final_taken1 = t_ctr[2][prov_ti1][2];
                3'd4: final_taken1 = t_ctr[3][prov_ti1][2];
                default: final_taken1 = base_ctr[bidx1][1];
            endcase
        end
    end

    assign pred_taken_msb1 = final_taken1;
    assign counter_out1    = prov_is_base1 ? base_ctr[bidx1]
        : {t_ctr[prov_id1-1][prov_ti1][2], t_ctr[prov_id1-1][prov_ti1][1]};

    always_comb begin
        pred_meta1 = '0;
        pred_meta1[63:32] = ghr[63:32];
        pred_meta1[2:0]   = prov_id1;
        pred_meta1[5:3]   = 3'd0;
        pred_meta1[6]     = 1'b0;
        pred_meta1[16:7]  = prov_bi1;
        pred_meta1[25:17] = prov_ti1;
        pred_meta1[29:26] = prov_tg1[3:0];
        pred_meta1[37:32] = prov_tg1[9:4];
        pred_meta1[59:57] = prov_ctr_r1;
        pred_meta1[61:60] = prov_u_r1;
    end

    function automatic logic [1:0] sat2_train(input logic [1:0] c, input logic t);
        begin
            unique case (c)
                2'b00: sat2_train = t ? 2'b01 : 2'b00;
                2'b01: sat2_train = t ? 2'b10 : 2'b00;
                2'b10: sat2_train = t ? 2'b11 : 2'b01;
                2'b11: sat2_train = t ? 2'b11 : 2'b10;
                default: sat2_train = 2'b01;
            endcase
        end
    endfunction

    function automatic logic [2:0] sat3_train(input logic [2:0] c, input logic t);
        begin
            if (t && c != 3'b111)
                sat3_train = c + 3'd1;
            else if (!t && c != 3'b000)
                sat3_train = c - 3'd1;
            else
                sat3_train = c;
        end
    endfunction

    logic [11:0] upd_ctr;
    logic [TIDX_W-1:0] age_idx;

    wire [2:0] um_prov = upd_meta[2:0];
    wire [BIDX_W-1:0] um_bi = upd_meta[16:7];
    wire [TIDX_W-1:0] um_pti = upd_meta[25:17];
    wire [TAG_W-1:0]  um_ptg = {upd_meta[37:32], upd_meta[29:26]};

    integer bi, ti, ai, train_tbl, alloc_tbl;
    logic [2:0] prv_c;

    wire [63:0] ghr_next = {ghr[62:0], upd_taken};

    // 误预测分配索引/Tag 必须用「本分支之前」的全局历史 ghr；ghr_next 已含当前结果，会造成时空错位
    wire [TIDX_W-1:0] aidx0 = upd_pc[TIDX_W+1:2] ^ {5'h0, ghr[3:0]};
    wire [TIDX_W-1:0] aidx1 = upd_pc[TIDX_W+1:2] ^ ghr[8:0];
    wire [TIDX_W-1:0] aidx2 = upd_pc[TIDX_W+1:2] ^ ghr[15:7];
    wire [TIDX_W-1:0] aidx3 = upd_pc[TIDX_W+1:2] ^ ghr[31:23];
    wire [TAG_W-1:0] atag0 = upd_pc[21:12] ^ ghr[9:0];
    wire [TAG_W-1:0] atag1 = upd_pc[21:12] ^ ghr[17:8];
    wire [TAG_W-1:0] atag2 = upd_pc[21:12] ^ ghr[25:16];
    wire [TAG_W-1:0] atag3 = upd_pc[21:12] ^ ghr[39:30];

    // Adjacent slot: upd_pc ^ 4 shares training (slot0↔slot1 in same 64-bit bundle)
    wire [31:0] adj_pc = upd_pc ^ 32'd4;
    wire [BIDX_W-1:0] adj_bi = adj_pc[BIDX_W+1:2];
    wire [TIDX_W-1:0] adj_aidx0 = adj_pc[TIDX_W+1:2] ^ {5'h0, ghr[3:0]};
    wire [TIDX_W-1:0] adj_aidx1 = adj_pc[TIDX_W+1:2] ^ ghr[8:0];
    wire [TIDX_W-1:0] adj_aidx2 = adj_pc[TIDX_W+1:2] ^ ghr[15:7];
    wire [TIDX_W-1:0] adj_aidx3 = adj_pc[TIDX_W+1:2] ^ ghr[31:23];
    wire [TAG_W-1:0] adj_atag0 = adj_pc[21:12] ^ ghr[9:0];
    wire [TAG_W-1:0] adj_atag1 = adj_pc[21:12] ^ ghr[17:8];
    wire [TAG_W-1:0] adj_atag2 = adj_pc[21:12] ^ ghr[25:16];
    wire [TAG_W-1:0] adj_atag3 = adj_pc[21:12] ^ ghr[39:30];

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            ghr <= '0;
            upd_ctr <= '0;
            age_idx <= '0;
            for (bi = 0; bi < BASE_ENTRIES; bi++)
                base_ctr[bi] <= 2'b01;
            for (ti = 0; ti < N_TAG; ti++)
                for (ai = 0; ai < TAG_ENTRIES; ai++) begin
                    t_tag[ti][ai] <= '0;
                    t_ctr[ti][ai] <= 3'b010;
                    t_u[ti][ai]   <= 2'b0;
                end
        end else begin
            if (upd_valid && upd_is_conditional) begin
                ghr <= ghr_next;
                upd_ctr <= upd_ctr + 12'd1;
                if (upd_ctr == 12'hFFF) begin
                    age_idx <= age_idx + 1'b1;
                    for (ti = 0; ti < N_TAG; ti++) begin
                        if (t_u[ti][age_idx] != 2'b0)
                            t_u[ti][age_idx] <= t_u[ti][age_idx] - 2'd1;
                    end
                end

                if (um_prov == 3'd0) begin
                    base_ctr[um_bi] <= sat2_train(base_ctr[um_bi], upd_taken);
                end else begin
                    train_tbl = um_prov - 1;
                    prv_c = t_ctr[train_tbl][um_pti];
                    t_ctr[train_tbl][um_pti] <= sat3_train(prv_c, upd_taken);
                    if (!upd_mispredict) begin
                        if (((prv_c >= 3'd4) == upd_taken) && (t_u[train_tbl][um_pti] != 2'b11))
                            t_u[train_tbl][um_pti] <= t_u[train_tbl][um_pti] + 2'd1;
                    end else begin
                        if (t_u[train_tbl][um_pti] != 2'b0)
                            t_u[train_tbl][um_pti] <= t_u[train_tbl][um_pti] - 2'd1;
                    end
                end

                base_ctr[adj_bi] <= sat2_train(base_ctr[adj_bi], upd_taken);

                if (upd_mispredict && (um_prov < 4)) begin
                    alloc_tbl = um_prov;
                    unique case (alloc_tbl)
                        0: begin
                            if (t_u[0][aidx0] <= 2'b01) begin
                                t_tag[0][aidx0] <= atag0;
                                t_ctr[0][aidx0] <= upd_taken ? 3'b110 : 3'b001;
                                t_u[0][aidx0]   <= 2'b0;
                            end else begin
                                t_u[0][aidx0] <= t_u[0][aidx0] - 2'd1;
                            end
                        end
                        1: begin
                            if (t_u[1][aidx1] <= 2'b01) begin
                                t_tag[1][aidx1] <= atag1;
                                t_ctr[1][aidx1] <= upd_taken ? 3'b110 : 3'b001;
                                t_u[1][aidx1]   <= 2'b0;
                            end else begin
                                t_u[1][aidx1] <= t_u[1][aidx1] - 2'd1;
                            end
                        end
                        2: begin
                            if (t_u[2][aidx2] <= 2'b01) begin
                                t_tag[2][aidx2] <= atag2;
                                t_ctr[2][aidx2] <= upd_taken ? 3'b110 : 3'b001;
                                t_u[2][aidx2]   <= 2'b0;
                            end else begin
                                t_u[2][aidx2] <= t_u[2][aidx2] - 2'd1;
                            end
                        end
                        3: begin
                            if (t_u[3][aidx3] <= 2'b01) begin
                                t_tag[3][aidx3] <= atag3;
                                t_ctr[3][aidx3] <= upd_taken ? 3'b110 : 3'b001;
                                t_u[3][aidx3]   <= 2'b0;
                            end else begin
                                t_u[3][aidx3] <= t_u[3][aidx3] - 2'd1;
                            end
                        end
                        default: ;
                    endcase

                    unique case (alloc_tbl)
                        0: begin
                            if (t_u[0][adj_aidx0] <= 2'b01) begin
                                t_tag[0][adj_aidx0] <= adj_atag0;
                                t_ctr[0][adj_aidx0] <= upd_taken ? 3'b110 : 3'b001;
                                t_u[0][adj_aidx0]   <= 2'b0;
                            end else
                                t_u[0][adj_aidx0] <= t_u[0][adj_aidx0] - 2'd1;
                        end
                        1: begin
                            if (t_u[1][adj_aidx1] <= 2'b01) begin
                                t_tag[1][adj_aidx1] <= adj_atag1;
                                t_ctr[1][adj_aidx1] <= upd_taken ? 3'b110 : 3'b001;
                                t_u[1][adj_aidx1]   <= 2'b0;
                            end else
                                t_u[1][adj_aidx1] <= t_u[1][adj_aidx1] - 2'd1;
                        end
                        2: begin
                            if (t_u[2][adj_aidx2] <= 2'b01) begin
                                t_tag[2][adj_aidx2] <= adj_atag2;
                                t_ctr[2][adj_aidx2] <= upd_taken ? 3'b110 : 3'b001;
                                t_u[2][adj_aidx2]   <= 2'b0;
                            end else
                                t_u[2][adj_aidx2] <= t_u[2][adj_aidx2] - 2'd1;
                        end
                        3: begin
                            if (t_u[3][adj_aidx3] <= 2'b01) begin
                                t_tag[3][adj_aidx3] <= adj_atag3;
                                t_ctr[3][adj_aidx3] <= upd_taken ? 3'b110 : 3'b001;
                                t_u[3][adj_aidx3]   <= 2'b0;
                            end else
                                t_u[3][adj_aidx3] <= t_u[3][adj_aidx3] - 2'd1;
                        end
                        default: ;
                    endcase
                end
            end
        end
    end

endmodule
