// scheduler.sv — Event-driven timestep controller
// FSM: S_RESET → S_IDLE → S_ENCODE → S_INTEGRATE → S_FIRE → S_LATCH
//      → S_ROUTE → S_LEARN → S_ADVANCE → S_DONE
//
// Timing (all non-blocking registered signals):
//   S_ENCODE  : enc_run←1 visible at S_INTEGRATE posedge
//   S_INTEGRATE: encoder fires; neu_enable_all←1 visible at S_FIRE posedge
//   S_FIRE    : neurons integrate (enable=1); spike_vector visible at S_LATCH posedge
//   S_LATCH   : spike_latch captures spike_vector; visible at S_ROUTE posedge
//
// done stays asserted until the next cfg_run pulse (not de-asserted in S_IDLE).

module scheduler #(
    parameter N_NEURONS = 32
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               cfg_run,
    input  logic [15:0]        cfg_t_max,
    input  logic               stdp_enable,

    input  logic [N_NEURONS-1:0] spike_vector,
    input  logic                 route_done,
    input  logic                 stdp_done,

    output logic               enc_run,
    output logic               neu_enable_all,
    output logic               router_enable,
    output logic               stdp_run,
    output logic               capture_spikes,

    // Latched spike vector — safe input for router
    output logic [N_NEURONS-1:0] spike_latch_out,

    output logic [15:0]        timestep,
    output logic               done
);

    typedef enum logic [3:0] {
        S_RESET    = 4'd0,
        S_IDLE     = 4'd1,
        S_ENCODE   = 4'd2,
        S_INTEGRATE= 4'd3,
        S_FIRE     = 4'd4,
        S_LATCH    = 4'd5,
        S_ROUTE    = 4'd6,
        S_LEARN    = 4'd7,
        S_ADVANCE  = 4'd8,
        S_DONE     = 4'd9
    } state_t;

    state_t state;
    logic [N_NEURONS-1:0] spike_latch;

    assign spike_latch_out = spike_latch;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_RESET;
            timestep       <= 16'h0;
            done           <= 1'b0;
            spike_latch    <= {N_NEURONS{1'b0}};
            enc_run        <= 1'b0;
            neu_enable_all <= 1'b0;
            router_enable  <= 1'b0;
            stdp_run       <= 1'b0;
            capture_spikes <= 1'b0;
        end else begin
            // Default: deassert single-cycle control pulses
            enc_run        <= 1'b0;
            neu_enable_all <= 1'b0;
            capture_spikes <= 1'b0;
            stdp_run       <= 1'b0;

            case (state)
                S_RESET: begin
                    timestep <= 16'h0;
                    done     <= 1'b0;
                    state    <= S_IDLE;
                end

                S_IDLE: begin
                    // done stays asserted from previous run — cleared only by rst_n
                    // or by the next cfg_run (start of new inference)
                    if (cfg_run) begin
                        done     <= 1'b0;  // clear done when new run starts
                        timestep <= 16'h0;
                        state    <= S_ENCODE;
                    end
                end

                // enc_run←1 takes effect at S_INTEGRATE posedge
                S_ENCODE: begin
                    enc_run <= 1'b1;
                    state   <= S_INTEGRATE;
                end

                // neu_enable_all←1 takes effect at S_FIRE posedge
                // encoder sees run=1 here → enc_spikes updated after this posedge
                S_INTEGRATE: begin
                    neu_enable_all <= 1'b1;
                    state          <= S_FIRE;
                end

                // Neurons integrate at this posedge (enable=1 from S_INTEGRATE)
                // spike_vector updated AFTER this posedge → capture next cycle
                S_FIRE: begin
                    state <= S_LATCH;
                end

                // spike_vector now stable — capture it
                S_LATCH: begin
                    spike_latch    <= spike_vector;
                    capture_spikes <= 1'b1;
                    state          <= S_ROUTE;
                end

                // Energy optimisation: skip router if no spikes
                S_ROUTE: begin
                    if (|spike_latch) begin
                        if (route_done) begin
                            router_enable <= 1'b0;
                            state         <= S_LEARN;
                        end else begin
                            router_enable <= 1'b1;
                        end
                    end else begin
                        router_enable <= 1'b0;
                        state         <= S_LEARN;
                    end
                end

                // Energy optimisation: skip STDP if disabled
                S_LEARN: begin
                    if (stdp_enable) begin
                        stdp_run <= 1'b1;
                        if (stdp_done) begin
                            stdp_run <= 1'b0;
                            state    <= S_ADVANCE;
                        end
                    end else begin
                        state <= S_ADVANCE;
                    end
                end

                S_ADVANCE: begin
                    timestep <= timestep + 16'd1;
                    if (timestep + 16'd1 >= cfg_t_max)
                        state <= S_DONE;
                    else
                        state <= S_ENCODE;
                end

                // done stays 1 until next cfg_run or rst_n
                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
