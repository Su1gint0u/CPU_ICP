// Multi-cycle RV32M functional unit.
//
// The original EX path implemented multiply/divide/remainder as one large
// combinational block. Vivado mapped the divider/remainder operators into a
// very long carry chain, which dominated setup timing even at 50 MHz. This
// unit keeps the EX interface simple: start while the instruction is held,
// raise done with a stable result, then clear when EX accepts the result.
module cpu_muldiv (
    input  logic        pl_clk,
    input  logic        pl_resetn,

    input  logic        start,
    input  logic        clear,
    input  logic [2:0]  funct3,
    input  logic [31:0] fwd_rs1_val,
    input  logic [31:0] fwd_rs2_val,

    output logic        busy,
    output logic        done,
    output logic [31:0] result
);

    typedef enum logic [2:0] {
        MD_IDLE,
        MD_MUL,
        MD_DIV,
        MD_DIV_FINISH,
        MD_DONE
    } md_state_e;

    md_state_e state_q;

    logic [2:0]  funct3_q;
    logic [31:0] dividend_q;
    logic [31:0] divisor_q;
    logic [31:0] quotient_q;
    logic [32:0] remainder_q;
    logic [5:0]  div_count_q;
    logic        div_quot_neg_q;
    logic        div_rem_neg_q;
    logic        div_rem_op_q;
    logic [31:0] div_quot_abs_q;
    logic [31:0] div_rem_abs_q;
    logic [31:0] result_q;

    logic signed [32:0] mul_a_ext;
    logic signed [32:0] mul_b_ext;
    logic signed [65:0] mul_product;
    logic [31:0]        mul_result;

    logic [32:0] div_trial_remainder;
    logic        div_trial_ge;
    logic [32:0] div_remainder_next;
    logic [31:0] div_quotient_next;
    logic [31:0] div_dividend_next;

    function automatic logic [31:0] abs32(input logic [31:0] value);
        abs32 = value[31] ? (~value + 32'd1) : value;
    endfunction

    always_comb begin
        unique case (funct3_q)
            3'b010: begin
                mul_a_ext = {fwd_rs1_val[31], fwd_rs1_val};
                mul_b_ext = {1'b0, fwd_rs2_val};
            end
            3'b011: begin
                mul_a_ext = {1'b0, fwd_rs1_val};
                mul_b_ext = {1'b0, fwd_rs2_val};
            end
            default: begin
                mul_a_ext = {fwd_rs1_val[31], fwd_rs1_val};
                mul_b_ext = {fwd_rs2_val[31], fwd_rs2_val};
            end
        endcase
        mul_product = mul_a_ext * mul_b_ext;
        mul_result  = (funct3_q == 3'b000) ? mul_product[31:0] : mul_product[63:32];
    end

    always_comb begin
        div_trial_remainder = {remainder_q[31:0], dividend_q[31]};
        div_trial_ge        = div_trial_remainder >= {1'b0, divisor_q};
        div_remainder_next  = div_trial_ge ? (div_trial_remainder - {1'b0, divisor_q})
                                            : div_trial_remainder;
        div_quotient_next   = {quotient_q[30:0], div_trial_ge};
        div_dividend_next   = {dividend_q[30:0], 1'b0};
    end

    assign busy   = (state_q != MD_IDLE) && (state_q != MD_DONE);
    assign done   = (state_q == MD_DONE);
    assign result = result_q;

    always_ff @(posedge pl_clk or negedge pl_resetn) begin
        if (!pl_resetn) begin
            state_q        <= MD_IDLE;
            funct3_q       <= 3'b000;
            dividend_q     <= 32'b0;
            divisor_q      <= 32'b0;
            quotient_q     <= 32'b0;
            remainder_q    <= 33'b0;
            div_count_q    <= 6'b0;
            div_quot_neg_q <= 1'b0;
            div_rem_neg_q  <= 1'b0;
            div_rem_op_q   <= 1'b0;
            div_quot_abs_q <= 32'b0;
            div_rem_abs_q  <= 32'b0;
            result_q       <= 32'b0;
        end else begin
            unique case (state_q)
                MD_IDLE: begin
                    if (start) begin
                        funct3_q <= funct3;
                        if (!funct3[2]) begin
                            state_q <= MD_MUL;
                        end else begin
                            automatic logic is_signed_op;
                            automatic logic is_rem_op;
                            automatic logic div_by_zero;
                            automatic logic div_overflow;

                            is_signed_op = (funct3 == 3'b100) || (funct3 == 3'b110);
                            is_rem_op    = funct3[1];
                            div_by_zero  = (fwd_rs2_val == 32'b0);
                            div_overflow = is_signed_op
                                && (fwd_rs1_val == 32'h8000_0000)
                                && (fwd_rs2_val == 32'hFFFF_FFFF);

                            if (div_by_zero) begin
                                result_q <= is_rem_op ? fwd_rs1_val : 32'hFFFF_FFFF;
                                state_q  <= MD_DONE;
                            end else if (div_overflow) begin
                                result_q <= is_rem_op ? 32'b0 : 32'h8000_0000;
                                state_q  <= MD_DONE;
                            end else begin
                                dividend_q     <= is_signed_op ? abs32(fwd_rs1_val) : fwd_rs1_val;
                                divisor_q      <= is_signed_op ? abs32(fwd_rs2_val) : fwd_rs2_val;
                                quotient_q     <= 32'b0;
                                remainder_q    <= 33'b0;
                                div_count_q    <= 6'd32;
                                div_quot_neg_q <= is_signed_op && (fwd_rs1_val[31] ^ fwd_rs2_val[31]);
                                div_rem_neg_q  <= is_signed_op && fwd_rs1_val[31];
                                div_rem_op_q   <= is_rem_op;
                                state_q        <= MD_DIV;
                            end
                        end
                    end
                end

                MD_MUL: begin
                    result_q <= mul_result;
                    state_q  <= MD_DONE;
                end

                MD_DIV: begin
                    dividend_q  <= div_dividend_next;
                    quotient_q  <= div_quotient_next;
                    remainder_q <= div_remainder_next;
                    if (div_count_q == 6'd1) begin
                        div_quot_abs_q <= div_quotient_next;
                        div_rem_abs_q  <= div_remainder_next[31:0];
                        div_count_q    <= 6'd0;
                        state_q        <= MD_DIV_FINISH;
                    end else begin
                        div_count_q <= div_count_q - 6'd1;
                    end
                end

                MD_DIV_FINISH: begin
                    if (div_rem_op_q)
                        result_q <= div_rem_neg_q ? (~div_rem_abs_q + 32'd1) : div_rem_abs_q;
                    else
                        result_q <= div_quot_neg_q ? (~div_quot_abs_q + 32'd1) : div_quot_abs_q;
                    state_q <= MD_DONE;
                end

                MD_DONE: begin
                    if (clear)
                        state_q <= MD_IDLE;
                end

                default: begin
                    state_q <= MD_IDLE;
                end
            endcase
        end
    end

endmodule
