// Async assert, sync release for active-low reset (§1.3.2).
module rst_sync #(
    parameter int unsigned STAGES = 2
) (
    input  logic clk,
    input  logic async_rst_n,
    output logic sync_rst_n
);

    logic [STAGES-1:0] sh;

    always_ff @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n)
            sh <= '0;
        else
            sh <= {sh[STAGES-2:0], 1'b1};
    end

    assign sync_rst_n = sh[STAGES-1];

endmodule
