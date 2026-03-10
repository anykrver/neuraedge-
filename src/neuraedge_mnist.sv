// neuraedge_mnist.sv — 128-neuron MNIST top-level chip
//
// Network topology:
//   Input   : neurons 0..63   (64 inputs — 7×7 avg-pooled MNIST, zero-padded)
//   Hidden  : neurons 64..117 (54 hidden neurons with recurrent connections)
//   Output  : neurons 118..127 (10 output neurons, one per digit class 0-9)
//
// Weight memory: synapse_mem_128 (128×128 × 8-bit, 4-bank BRAM, 16KB)
// Spike router : spike_router_128 (5-state pipelined FSM, 4 cycles/spike)
// Encoder      : encoder.sv with N_INPUTS=64 (rate or temporal coding)
// Neuron array : neuron_array.sv with N_NEURONS=128 (LIF, Q2.6 fixed-point)
// Scheduler    : scheduler.sv with N_NEURONS=128 (event-driven timestep loop)
// Decoder      : decoder.sv (argmax over output neurons 118-127)
//
// STDP is disabled in this inference-only variant (stdp_enable hardwired=0).
// To enable on-chip learning, extend stdp.sv with 7-bit neuron index support
// and connect it to synapse_mem_128 Port S (narrow read) and Port B (write).

module neuraedge_mnist #(
    parameter N_NEURONS  = 128,
    parameter N_INPUTS   = 64,    // 7×7 avg-pooled MNIST image, zero-padded to 64
    parameter N_CLASSES  = 10,    // MNIST digit classes 0-9
    parameter DATA_W     = 8,
    parameter MEM_AW     = 14     // {pre[6:0], post[6:0]}
) (
    input  logic                              clk,
    input  logic                              rst_n,
    input  logic                              cfg_run,
    input  logic [15:0]                       cfg_t_max,
    // Weight configuration (written before inference)
    input  logic                              cfg_weight_wr,
    input  logic [MEM_AW-1:0]                 cfg_weight_addr, // {pre[6:0], post[6:0]}
    input  logic [DATA_W-1:0]                 cfg_weight_data,
    // Input pixel intensities (0-255) for rate / temporal encoding
    input  logic [DATA_W-1:0]                 cfg_input [N_INPUTS-1:0],
    input  logic                              cfg_encode_mode, // 0=rate, 1=temporal
    // Outputs
    output logic                              out_done,
    output logic [15:0]                       out_timestep,
    output logic [N_NEURONS-1:0][DATA_W-1:0]  out_spike_count,
    output logic [N_NEURONS-1:0]              out_spike_vector,
    output logic [$clog2(N_CLASSES)-1:0]      out_class,       // predicted digit 0-9
    output logic                              out_class_valid   // at least one output fired
);

    // ---- Internal signals ----
    logic [N_INPUTS-1:0]               enc_spikes;
    logic [N_NEURONS-1:0]              neuron_enable;
    logic signed [DATA_W-1:0]          i_syn_array [N_NEURONS-1:0];
    logic [N_NEURONS-1:0]              spike_vector;
    logic [N_NEURONS-1:0][DATA_W-1:0]  v_mem_array;

    // Spike router → synapse memory (Port A, wide)
    logic [6:0]                        router_mem_addr;
    logic [N_NEURONS-1:0][DATA_W-1:0]  router_mem_rdata;
    logic [N_NEURONS-1:0][DATA_W-1:0]  router_i_syn;
    logic                              router_enable;
    logic                              route_done;

    // Scheduler control
    logic                              enc_run;
    logic                              neu_enable_all;
    logic                              stdp_run;    // driven by scheduler but unused
    logic                              capture_spikes;
    logic [N_NEURONS-1:0]              spike_latch;

    // STDP not instantiated — assert stdp_done=1 so scheduler advances immediately
    // when stdp_enable=0 (which is hardwired below).
    logic stdp_done;
    assign stdp_done = 1'b1;

    // ---- Encoder ----
    encoder #(.N_INPUTS(N_INPUTS)) u_enc (
        .clk       (clk),
        .rst_n     (rst_n),
        .run       (enc_run),
        .raw_input (cfg_input),
        .timestep  (out_timestep),
        .mode      (cfg_encode_mode),
        .spike_out (enc_spikes)
    );

    // ---- Synaptic memory (128×128, 4-bank, 16KB) ----
    synapse_mem_128 #(.N_NEURONS(N_NEURONS)) u_smem (
        .clk     (clk),
        .rst_n   (rst_n),
        // Port A: wide read for spike router
        .a_addr  (router_mem_addr),
        .a_rdata (router_mem_rdata),
        // Port S: narrow read (not connected — STDP disabled)
        .s_addr  ({MEM_AW{1'b0}}),
        .s_rdata (),
        // Port B: write port for weight configuration
        .b_addr  (cfg_weight_addr),
        .b_wdata (cfg_weight_data),
        .b_wr_en (cfg_weight_wr)
    );

    // ---- Spike router (128 neurons, pipelined) ----
    spike_router_128 #(.N_NEURONS(N_NEURONS)) u_router (
        .clk         (clk),
        .rst_n       (rst_n),
        .enable      (router_enable),
        .spike_vector(spike_latch),    // latched spikes (stable during routing)
        .mem_addr    (router_mem_addr),
        .mem_rdata   (router_mem_rdata),
        .i_syn_out   (router_i_syn),
        .route_done  (route_done)
    );

    // ---- Merge encoder spikes + router currents ----
    // Input neurons (0..N_INPUTS-1) receive both direct encoder injection and
    // synaptic feedback from the weight matrix.
    genvar nn;
    generate
        for (nn = 0; nn < N_NEURONS; nn = nn + 1) begin : gen_isyn
            if (nn < N_INPUTS) begin
                // Direct encoder injection: 0x30 = 0.75 in Q2.6 per encoded spike
                assign i_syn_array[nn] = $signed(router_i_syn[nn]) +
                    $signed(enc_spikes[nn] ? 8'h30 : 8'h00);
            end else begin
                assign i_syn_array[nn] = $signed(router_i_syn[nn]);
            end
        end
    endgenerate

    assign neuron_enable = {N_NEURONS{neu_enable_all}};

    // ---- Neuron array (128 parallel LIF neurons) ----
    neuron_array #(.N_NEURONS(N_NEURONS)) u_neu (
        .clk         (clk),
        .rst_n       (rst_n),
        .enable      (neuron_enable),
        .i_syn       (i_syn_array),
        .spike_vector(spike_vector),
        .v_mem_array (v_mem_array)
    );

    // ---- Scheduler (event-driven timestep controller) ----
    scheduler #(.N_NEURONS(N_NEURONS)) u_sched (
        .clk            (clk),
        .rst_n          (rst_n),
        .cfg_run        (cfg_run),
        .cfg_t_max      (cfg_t_max),
        .stdp_enable    (1'b0),        // STDP disabled: inference-only mode
        .spike_vector   (spike_vector),
        .route_done     (route_done),
        .stdp_done      (stdp_done),
        .enc_run        (enc_run),
        .neu_enable_all (neu_enable_all),
        .router_enable  (router_enable),
        .stdp_run       (stdp_run),
        .capture_spikes (capture_spikes),
        .spike_latch_out(spike_latch),
        .timestep       (out_timestep),
        .done           (out_done)
    );

    // ---- Spike counting (one saturating counter per neuron) ----
    generate
        genvar sc;
        for (sc = 0; sc < N_NEURONS; sc = sc + 1) begin : gen_sc
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    out_spike_count[sc] <= {DATA_W{1'b0}};
                else if (cfg_run)
                    out_spike_count[sc] <= {DATA_W{1'b0}};
                else if (spike_vector[sc])
                    out_spike_count[sc] <= (out_spike_count[sc] == {DATA_W{1'b1}}) ?
                                           {DATA_W{1'b1}} : out_spike_count[sc] + 8'd1;
            end
        end
    endgenerate

    assign out_spike_vector = spike_vector;

    // ---- MNIST output decoder (argmax over neurons 118-127) ----
    localparam N_OFFSET = N_NEURONS - N_CLASSES;  // = 118

    decoder #(
        .N_OUT    (N_CLASSES),
        .N_OFFSET (N_OFFSET),
        .DATA_W   (DATA_W),
        .N_NEURONS(N_NEURONS)
    ) u_dec (
        .spike_count  (out_spike_count),
        .class_id     (out_class),
        .class_spikes (),
        .valid        (out_class_valid)
    );

endmodule
