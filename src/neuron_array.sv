// neuron_array.sv — Array of N_NEURONS LIF neurons via generate

module neuron_array #(
    parameter N_NEURONS = 32
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic [N_NEURONS-1:0]         enable,
    // Unpacked input arrays (iverilog supports these fine as inputs)
    input  logic signed [7:0]            i_syn [N_NEURONS-1:0],
    output logic [N_NEURONS-1:0]         spike_vector,
    // v_mem_array as packed 2D for iverilog compat
    output logic [N_NEURONS-1:0][7:0]    v_mem_array
);

    genvar i;
    generate
        for (i = 0; i < N_NEURONS; i = i + 1) begin : gen_neurons
            neuron #(
                .LEAK_FACTOR   (8'hE6),
                .THRESHOLD     (8'h40),
                .V_RESET       (8'h00),
                .REFRAC_PERIOD (4)
            ) u_neuron (
                .clk       (clk),
                .rst_n     (rst_n),
                .enable    (enable[i]),
                .i_syn     (i_syn[i]),
                .v_mem     (v_mem_array[i]),
                .spike_out (spike_vector[i])
            );
        end
    endgenerate

endmodule
