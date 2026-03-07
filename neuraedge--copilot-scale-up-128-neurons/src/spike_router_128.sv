// spike_router_128.sv — Pipelined AER spike router for 128-neuron array
// FSM: IDLE → ARBITRATE → WAIT_RD1 → WAIT_RD2 → ACCUMULATE → DONE
// Uses synapse_mem_128 Port A (wide, 2-cycle pipeline) to read all 128 weights
// in one BRAM read and accumulate them all in one ACCUMULATE cycle.
// Throughput: 4 cycles per spike event (ARBITRATE+WAIT_RD1+WAIT_RD2+ACCUMULATE).
// At 10% firing rate (~13 spikes/timestep): ~52 routing cycles per timestep.

module spike_router_128 #(
    parameter N_NEURONS = 128,
    parameter DATA_W    = 8
) (
    input  logic                             clk,
    input  logic                             rst_n,
    input  logic                             enable,
    input  logic [N_NEURONS-1:0]             spike_vector,

    // synapse_mem_128 Port A — wide read (2-cycle latency)
    output logic [6:0]                        mem_addr,   // pre-synaptic index
    input  logic [N_NEURONS-1:0][DATA_W-1:0]  mem_rdata,  // all 128 weights of that row

    // Accumulated synaptic currents for all post-synaptic neurons
    output logic [N_NEURONS-1:0][DATA_W-1:0]  i_syn_out,
    output logic                              route_done
);

    typedef enum logic [2:0] {
        IDLE      = 3'd0,
        ARBITRATE = 3'd1,
        WAIT_RD1  = 3'd2,   // BRAM pipeline stage 1 (address registered in synapse_mem)
        WAIT_RD2  = 3'd3,   // BRAM pipeline stage 2 (data registered in synapse_mem)
        ACCUMULATE= 3'd4,   // data valid: update all 128 i_syn in one cycle
        DONE      = 3'd5
    } state_t;

    state_t state;

    logic [N_NEURONS-1:0] pending;  // tracks which spiking neurons still need routing
    logic [6:0]           src_id;  // pre-synaptic neuron being processed

    // Priority encoder: returns index of lowest set bit in N_NEURONS-wide vector.
    // Iterating from high→low and keeping the last match gives the lowest set bit.
    function automatic [6:0] lowest_bit_128;
        input [N_NEURONS-1:0] vec;
        integer j;
        begin
            lowest_bit_128 = 7'd0;
            for (j = N_NEURONS-1; j >= 0; j = j - 1)
                if (vec[j]) lowest_bit_128 = j[6:0];
        end
    endfunction

    integer k;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            pending    <= {N_NEURONS{1'b0}};
            src_id     <= 7'd0;
            route_done <= 1'b0;
            mem_addr   <= 7'd0;
            for (k = 0; k < N_NEURONS; k = k + 1)
                i_syn_out[k] <= {DATA_W{1'b0}};
        end else begin
            case (state)
                IDLE: begin
                    route_done <= 1'b0;
                    if (enable) begin
                        pending <= spike_vector;
                        for (k = 0; k < N_NEURONS; k = k + 1)
                            i_syn_out[k] <= {DATA_W{1'b0}};
                        state <= ARBITRATE;
                    end
                end

                ARBITRATE: begin
                    if (|pending) begin
                        src_id   <= lowest_bit_128(pending);
                        mem_addr <= lowest_bit_128(pending);
                        state    <= WAIT_RD1;
                    end else begin
                        state <= DONE;
                    end
                end

                WAIT_RD1: begin
                    // synapse_mem_128 stage 1: a_addr_r ← a_addr (mem_addr) registered
                    state <= WAIT_RD2;
                end

                WAIT_RD2: begin
                    // synapse_mem_128 stage 2: a_rdata ← mem[{a_addr_r, post}] registered
                    // mem_rdata will be stable at the ACCUMULATE posedge
                    state <= ACCUMULATE;
                end

                ACCUMULATE: begin
                    // mem_rdata valid: add all 128 weights to their target neurons
                    // Uses 8-bit wrapping addition; neuromorphic currents are small.
                    for (k = 0; k < N_NEURONS; k = k + 1)
                        i_syn_out[k] <= $signed(i_syn_out[k]) +
                                        $signed(mem_rdata[k]);
                    // Mark this source neuron as routed and continue
                    pending[src_id] <= 1'b0;
                    state <= ARBITRATE;
                end

                DONE: begin
                    route_done <= 1'b1;
                    if (!enable) begin
                        route_done <= 1'b0;
                        state      <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
