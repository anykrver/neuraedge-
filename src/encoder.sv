// encoder.sv — Spike encoder: converts raw input values to spike trains
// mode=0: Rate coding — LFSR-based pseudo-random, P(spike) ∝ raw_input
// mode=1: Temporal coding — one spike per input, latency ∝ (255 - raw_input)

module encoder #(
    parameter N_INPUTS = 2,
    parameter DATA_W   = 8
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  run,                      // pulse: trigger one encode step
    input  logic [DATA_W-1:0]     raw_input [N_INPUTS-1:0],// 0..255 input magnitudes
    input  logic [15:0]           timestep,
    input  logic                  mode,                     // 0=rate, 1=temporal
    output logic [N_INPUTS-1:0]   spike_out                 // encoded spikes this timestep
);

    // 8-bit Galois LFSR (taps: 8,6,5,4 → polynomial x^8+x^6+x^5+x^4+1)
    logic [7:0] lfsr;

    // Advance LFSR by one step combinationally
    function automatic [7:0] lfsr_step;
        input [7:0] s;
        begin
            lfsr_step = {s[6:0], s[7] ^ s[5] ^ s[4] ^ s[3]};
        end
    endfunction

    // Pre-compute N_INPUTS+1 LFSR values combinationally
    // lfsr_chain[0] = current, lfsr_chain[i] = after i steps
    logic [7:0] lfsr_chain [0:N_INPUTS];
    genvar gi;
    assign lfsr_chain[0] = lfsr;
    generate
        for (gi = 0; gi < N_INPUTS; gi = gi + 1) begin : gen_lfsr
            assign lfsr_chain[gi+1] = lfsr_step(lfsr_chain[gi]);
        end
    endgenerate

    // Per-input "fired already" flag for temporal coding
    logic [N_INPUTS-1:0] temporal_fired;

    // Latency for temporal coding: higher input → lower latency
    logic [DATA_W-1:0] t_latency [N_INPUTS-1:0];
    generate
        for (gi = 0; gi < N_INPUTS; gi = gi + 1) begin : gen_lat
            assign t_latency[gi] = 8'hFF - raw_input[gi];
        end
    endgenerate

    integer ii;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr           <= 8'hAC;          // non-zero seed
            spike_out      <= {N_INPUTS{1'b0}};
            temporal_fired <= {N_INPUTS{1'b0}};
        end else begin
            spike_out <= {N_INPUTS{1'b0}};    // default: no spike

            // Reset temporal tracking at start of each run (timestep == 0)
            if (run && (timestep == 16'h0))
                temporal_fired <= {N_INPUTS{1'b0}};

            if (run) begin
                if (mode == 1'b0) begin
                    // ---- Rate coding ----
                    // Spike if LFSR value < raw_input (probability ∝ input)
                    for (ii = 0; ii < N_INPUTS; ii = ii + 1)
                        spike_out[ii] <= (lfsr_chain[ii] < raw_input[ii]);
                    // Advance LFSR by N_INPUTS steps
                    lfsr <= lfsr_chain[N_INPUTS];
                end else begin
                    // ---- Temporal coding ----
                    // Each input fires once at timestep == latency
                    for (ii = 0; ii < N_INPUTS; ii = ii + 1) begin
                        if (!temporal_fired[ii] &&
                            (timestep[7:0] >= t_latency[ii])) begin
                            spike_out[ii]      <= 1'b1;
                            temporal_fired[ii] <= 1'b1;
                        end
                    end
                end
            end
        end
    end

endmodule
