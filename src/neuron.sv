// neuron.sv — Single Leaky Integrate-and-Fire (LIF) neuron
// Q2.6 fixed-point arithmetic (8-bit: 2 integer + 6 fractional bits)
// THRESHOLD = 0x40 (1.0), LEAK_FACTOR = 0xE6 (≈0.9 as Q0.8), V_RESET = 0x00
//
// Leak formula: v_leaked = (v_mem * LEAK_FACTOR) >> 8
//   LEAK_FACTOR is treated as Q0.8 (all fractional), so 0xE6/256 ≈ 0.898 ≈ 0.9

module neuron #(
    parameter [7:0] LEAK_FACTOR   = 8'hE6,  // ≈0.9 in Q0.8 (divide by 256)
    parameter [7:0] THRESHOLD     = 8'h40,  // 1.0 in Q2.6
    parameter [7:0] V_RESET       = 8'h00,  // 0.0
    parameter       REFRAC_PERIOD = 4       // refractory cycles after spike
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              enable,
    input  logic signed [7:0] i_syn,      // signed Q2.6 synaptic current
    output logic        [7:0] v_mem,      // membrane potential (Q2.6, unsigned)
    output logic              spike_out   // asserted for one cycle on threshold crossing
);

    // Refractory down-counter; needs ceil(log2(REFRAC_PERIOD+1)) bits
    logic [2:0] refrac_cnt;

    // 16-bit intermediate for leak multiply
    logic [15:0] v_mul;
    logic  [7:0] v_leaked;

    // Combinational leak computation using continuous assigns
    // to avoid iverilog "constant-select in always_*" issues
    assign v_mul    = {8'h0, v_mem} * {8'h0, LEAK_FACTOR};
    assign v_leaked = v_mul[15:8];   // >> 8: LEAK_FACTOR is Q0.8

    // Clamped integrate result
    logic signed [9:0] v_sum;   // wide enough: [0..255] + [-128..127] = [-128..382]
    logic        [7:0] v_next;

    assign v_sum  = $signed({2'b0, v_leaked}) + $signed({{2{i_syn[7]}}, i_syn});
    assign v_next = (v_sum[9]) ? V_RESET : v_sum[7:0];  // floor at 0

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_mem      <= 8'h00;
            spike_out  <= 1'b0;
            refrac_cnt <= 3'h0;
        end else if (!enable) begin
            spike_out <= 1'b0;  // silent when disabled; v_mem frozen
        end else begin
            spike_out <= 1'b0;  // default: no spike

            if (refrac_cnt != 3'h0) begin
                // Refractory period: apply leak only, cannot fire
                v_mem      <= v_leaked;
                refrac_cnt <= refrac_cnt - 3'h1;
            end else begin
                // Check threshold on the integrated value
                if (v_next >= THRESHOLD) begin
                    spike_out  <= 1'b1;
                    v_mem      <= V_RESET;
                    refrac_cnt <= REFRAC_PERIOD[2:0];
                end else begin
                    v_mem <= v_next;
                end
            end
        end
    end

endmodule
