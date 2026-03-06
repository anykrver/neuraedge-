// stdp.sv — Spike-Timing-Dependent Plasticity learning engine
// FSM: S_IDLE → S_SCAN → S_READ → S_WAIT → S_WRITE → ...
// Iterates over all (pre, post) neuron pairs each learning pass.
// LTP if pre fired before/at post (causal); LTD if post fired before pre.
// Weight updates clamped to [W_MIN, W_MAX].

module stdp #(
    parameter N_NEURONS  = 32,
    parameter DATA_W     = 8,
    parameter ADDR_W     = 10,
    parameter signed W_MIN     = -128,
    parameter signed W_MAX     = 127,
    parameter [7:0]  A_PLUS    = 8'h08,   // LTP base step
    parameter [7:0]  A_MINUS   = 8'h04    // LTD base step
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  stdp_enable,
    input  logic                  run,             // pulse: start one learning pass
    input  logic [N_NEURONS-1:0]  spike_vector,   // spikes this timestep
    input  logic [15:0]           timestep,
    // synapse_mem port B interface (read-modify-write)
    output logic [ADDR_W-1:0]     mem_addr,
    output logic [DATA_W-1:0]     mem_wdata,
    output logic                  mem_wr_en,
    input  logic [DATA_W-1:0]     mem_rdata,      // read data (1-cycle latency via port A)
    output logic                  stdp_done
);

    // Spike timestamps; 0xFFFF = "never fired" sentinel
    logic [15:0] t_spike [N_NEURONS-1:0];

    typedef enum logic [2:0] {
        S_IDLE  = 3'd0,
        S_SCAN  = 3'd1,
        S_READ  = 3'd2,
        S_WAIT  = 3'd3,
        S_WRITE = 3'd4,
        S_DONE  = 3'd5
    } state_t;

    state_t state;

    logic [4:0] pre_idx, post_idx;

    // Timestamp tracking — update on each spike
    integer ni;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (ni = 0; ni < N_NEURONS; ni = ni + 1)
                t_spike[ni] <= 16'hFFFF;
        end else begin
            for (ni = 0; ni < N_NEURONS; ni = ni + 1)
                if (spike_vector[ni])
                    t_spike[ni] <= timestep;
        end
    end

    // Helper: weight delta with exponential decay approximation (shift by dt)
    function automatic [7:0] decay_delta;
        input [7:0]  base;
        input [15:0] dt;
        begin
            if (dt == 0)       decay_delta = base;
            else if (dt == 1)  decay_delta = base >> 1;
            else if (dt == 2)  decay_delta = base >> 2;
            else if (dt == 3)  decay_delta = base >> 3;
            else if (dt < 8)   decay_delta = base >> 4;
            else               decay_delta = 8'h01;  // minimum step
        end
    endfunction

    // STDP FSM
    logic [15:0] dt_val;
    logic signed [9:0] w_new_wide;
    logic [DATA_W-1:0] delta;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            pre_idx   <= 5'd0;
            post_idx  <= 5'd0;
            mem_wr_en <= 1'b0;
            mem_addr  <= {ADDR_W{1'b0}};
            mem_wdata <= {DATA_W{1'b0}};
            stdp_done <= 1'b0;
            dt_val    <= 16'h0;
        end else begin
            mem_wr_en <= 1'b0;  // default: no write

            case (state)
                S_IDLE: begin
                    stdp_done <= 1'b0;
                    if (run) begin
                        if (stdp_enable) begin
                            pre_idx  <= 5'd0;
                            post_idx <= 5'd0;
                            state    <= S_SCAN;
                        end else begin
                            // STDP disabled — complete immediately
                            stdp_done <= 1'b1;
                            state     <= S_DONE;
                        end
                    end
                end

                S_SCAN: begin
                    // Check if we've processed all pairs
                    if (pre_idx == 5'd31 &&
                        post_idx == 5'd31) begin
                        state <= S_DONE;
                    end else begin
                        // Advance to next pair
                        if (post_idx == 5'd31) begin
                            pre_idx  <= pre_idx + 5'd1;
                            post_idx <= 5'd0;
                        end else begin
                            post_idx <= post_idx + 5'd1;
                        end

                        // Only do read-modify-write if at least one neuron fired
                        if ((t_spike[pre_idx]  != 16'hFFFF) ||
                            (t_spike[post_idx] != 16'hFFFF)) begin
                            mem_addr <= {pre_idx, post_idx};
                            state    <= S_READ;
                        end
                        // else stay in S_SCAN (skip this pair)
                    end
                end

                S_READ: begin
                    // BRAM read issued; wait one cycle for data
                    state <= S_WAIT;
                end

                S_WAIT: begin
                    // mem_rdata now valid; compute weight update
                    if ((t_spike[pre_idx] != 16'hFFFF) &&
                        (t_spike[post_idx] != 16'hFFFF)) begin
                        if (t_spike[pre_idx] <= t_spike[post_idx]) begin
                            // LTP: pre → post (causal)
                            dt_val <= t_spike[post_idx] - t_spike[pre_idx];
                        end else begin
                            // LTD: post → pre (anti-causal)
                            dt_val <= t_spike[pre_idx] - t_spike[post_idx];
                        end
                    end
                    state <= S_WRITE;
                end

                S_WRITE: begin
                    if ((t_spike[pre_idx] != 16'hFFFF) &&
                        (t_spike[post_idx] != 16'hFFFF)) begin
                        if (t_spike[pre_idx] <= t_spike[post_idx]) begin
                            // LTP: increase weight
                            delta     = decay_delta(A_PLUS, dt_val);
                            w_new_wide = $signed({{2{mem_rdata[7]}}, mem_rdata}) +
                                         $signed({2'b0, delta});
                        end else begin
                            // LTD: decrease weight
                            delta     = decay_delta(A_MINUS, dt_val);
                            w_new_wide = $signed({{2{mem_rdata[7]}}, mem_rdata}) -
                                         $signed({2'b0, delta});
                        end
                        // Clamp to [W_MIN, W_MAX]
                        if (w_new_wide > $signed(W_MAX))
                            mem_wdata <= W_MAX[DATA_W-1:0];
                        else if (w_new_wide < $signed(W_MIN))
                            mem_wdata <= W_MIN[DATA_W-1:0];
                        else
                            mem_wdata <= w_new_wide[DATA_W-1:0];
                        mem_wr_en <= 1'b1;
                    end
                    state <= S_SCAN;
                end

                S_DONE: begin
                    stdp_done <= 1'b1;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
