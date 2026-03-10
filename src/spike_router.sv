// spike_router.sv — AER (Address-Event Representation) spike router
// FSM: IDLE → ARBITRATE → READ_MEM → ACCUMULATE → (loop) → DONE
// Reads each fired neuron's weight row from synapse_mem and accumulates
// into i_syn_out for all destination neurons.

module spike_router #(
    parameter N_NEURONS = 32,
    parameter DATA_W    = 8,
    parameter ADDR_W    = 10
) (
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic                               enable,
    input  logic [N_NEURONS-1:0]               spike_vector,
    // synapse_mem port A (1-cycle read latency)
    output logic [ADDR_W-1:0]                  mem_addr,
    input  logic [DATA_W-1:0]                  mem_rdata,
    // accumulated synaptic currents (packed 2D: [neuron][bits])
    output logic [N_NEURONS-1:0][DATA_W-1:0]   i_syn_out,
    output logic                               route_done
);

    typedef enum logic [2:0] {
        IDLE      = 3'd0,
        ARBITRATE = 3'd1,
        READ_MEM  = 3'd2,
        ACCUMULATE= 3'd3,
        DONE      = 3'd4
    } state_t;

    state_t state;

    logic [N_NEURONS-1:0]  pending;
    logic [4:0]            src_id;
    logic [4:0]            dst_id;
    logic [4:0]            dst_next;
    assign dst_next = dst_id + 5'd1;

    // Priority encoder: returns index of lowest set bit
    function automatic [4:0] lowest_bit;
        input [N_NEURONS-1:0] vec;
        integer j;
        begin
            lowest_bit = 5'd0;
            for (j = N_NEURONS-1; j >= 0; j = j - 1)
                if (vec[j]) lowest_bit = j[4:0];
        end
    endfunction

    integer k;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            pending    <= {N_NEURONS{1'b0}};
            src_id     <= 5'd0;
            dst_id     <= 5'd0;
            route_done <= 1'b0;
            mem_addr   <= {ADDR_W{1'b0}};
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
                        src_id   <= lowest_bit(pending);
                        dst_id   <= 5'd0;
                        mem_addr <= {lowest_bit(pending), 5'd0};
                        state    <= READ_MEM;
                    end else begin
                        state <= DONE;
                    end
                end

                READ_MEM: begin
                    // Address is on mem_addr; BRAM latches it this cycle → data next cycle
                    state <= ACCUMULATE;
                end

                ACCUMULATE: begin
                    // mem_rdata valid for (src_id, dst_id)
                    i_syn_out[dst_id] <= $signed(i_syn_out[dst_id]) +
                                         $signed(mem_rdata);
                    if (dst_id == 5'(N_NEURONS-1)) begin
                        pending[src_id] <= 1'b0;
                        state           <= ARBITRATE;
                    end else begin
                        dst_id   <= dst_next;
                        mem_addr <= {src_id, dst_next};
                        state    <= READ_MEM;
                    end
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
