// decoder.sv — Argmax spike-count decoder for multi-class classification
// Scans N_OUT output neurons and selects the one with the highest spike count.
// Combinational: output class_id updates whenever out_spike_count changes.
// Tie-breaking: lowest neuron index wins on equal spike counts.

module decoder #(
    parameter N_OUT     = 10,    // number of output classes (e.g. 10 for MNIST)
    parameter N_OFFSET  = 118,   // index of first output neuron in the array
    parameter DATA_W    = 8,
    parameter N_NEURONS = 128
) (
    // Full spike-count vector from the neuron array
    input  logic [N_NEURONS-1:0][DATA_W-1:0] spike_count,

    // Predicted class (0..N_OUT-1) and its spike count
    output logic [$clog2(N_OUT)-1:0] class_id,
    output logic [DATA_W-1:0]        class_spikes,
    output logic                     valid       // asserted when any output neuron fired
);

    // Extract the N_OUT output neuron spike counts into a local array using a
    // generate block.  This avoids constant-index selects inside always_* blocks
    // (iverilog 12 limitation) while still being fully combinational.
    logic [DATA_W-1:0] out_counts [0:N_OUT-1];
    genvar gi;
    generate
        for (gi = 0; gi < N_OUT; gi = gi + 1) begin : gen_out_extract
            assign out_counts[gi] = spike_count[N_OFFSET + gi];
        end
    endgenerate

    // Argmax over out_counts — all indices use the runtime variable ci, so no
    // constant-select warning.
    integer best_idx_int;
    logic [DATA_W-1:0] best_cnt;
    integer ci;

    always_comb begin
        best_idx_int = 0;
        best_cnt     = out_counts[0];
        for (ci = 1; ci < N_OUT; ci = ci + 1) begin
            if (out_counts[ci] > best_cnt) begin
                best_cnt     = out_counts[ci];
                best_idx_int = ci;
            end
        end
    end

    assign class_id     = best_idx_int;  // truncated to [$clog2(N_OUT)-1:0] width
    assign class_spikes = best_cnt;
    assign valid        = (best_cnt != {DATA_W{1'b0}});

endmodule
