// neuraedge.sv — Top-level NeuraEdge chip integration

module neuraedge #(
    parameter N_NEURONS  = 32,
    parameter N_INPUTS   = 2,
    parameter DATA_W     = 8,
    parameter ADDR_W     = 10
) (
    input  logic                              clk,
    input  logic                              rst_n,
    input  logic                              cfg_run,
    input  logic [15:0]                       cfg_t_max,
    input  logic                              cfg_weight_wr,
    input  logic [ADDR_W-1:0]                 cfg_weight_addr,
    input  logic [DATA_W-1:0]                 cfg_weight_data,
    input  logic [DATA_W-1:0]                 cfg_input [N_INPUTS-1:0],
    input  logic                              cfg_encode_mode,
    input  logic                              cfg_stdp_enable,
    output logic                              out_done,
    output logic [15:0]                       out_timestep,
    output logic [N_NEURONS-1:0][DATA_W-1:0]  out_spike_count,
    output logic [N_NEURONS-1:0]              out_spike_vector
);

    // ---- Internal signals ----
    logic [N_INPUTS-1:0]               enc_spikes;
    logic [N_NEURONS-1:0]              neuron_enable;
    logic signed [DATA_W-1:0]          i_syn_array  [N_NEURONS-1:0];
    logic [N_NEURONS-1:0]              spike_vector;
    logic [N_NEURONS-1:0][DATA_W-1:0]  v_mem_array;

    logic [ADDR_W-1:0]                 smem_a_addr;
    logic [DATA_W-1:0]                 smem_a_rdata;
    logic [ADDR_W-1:0]                 smem_b_addr;
    logic [DATA_W-1:0]                 smem_b_wdata;
    logic                              smem_b_wr_en;

    logic [ADDR_W-1:0]                 router_mem_addr;
    logic [N_NEURONS-1:0][DATA_W-1:0]  router_i_syn;
    logic                              router_enable;
    logic                              route_done;

    logic [ADDR_W-1:0]                 stdp_mem_addr;
    logic [DATA_W-1:0]                 stdp_mem_wdata;
    logic                              stdp_mem_wr_en;
    logic                              stdp_run;
    logic                              stdp_done;

    logic                              enc_run;
    logic                              neu_enable_all;
    logic                              capture_spikes;
    logic [N_NEURONS-1:0]              spike_latch;  // from scheduler

    // Port A mux: STDP uses port A for reads (during S_LEARN, router is idle)
    assign smem_a_addr = stdp_mem_wr_en ? stdp_mem_addr : router_mem_addr;

    // Port B mux: STDP writes override cfg writes
    always_comb begin
        if (stdp_mem_wr_en) begin
            smem_b_addr  = stdp_mem_addr;
            smem_b_wdata = stdp_mem_wdata;
            smem_b_wr_en = 1'b1;
        end else begin
            smem_b_addr  = cfg_weight_addr;
            smem_b_wdata = cfg_weight_data;
            smem_b_wr_en = cfg_weight_wr;
        end
    end

    // ---- Sub-modules ----
    encoder #(.N_INPUTS(N_INPUTS)) u_enc (
        .clk       (clk),
        .rst_n     (rst_n),
        .run       (enc_run),
        .raw_input (cfg_input),
        .timestep  (out_timestep),
        .mode      (cfg_encode_mode),
        .spike_out (enc_spikes)
    );

    synapse_mem #(.N_NEURONS(N_NEURONS)) u_smem (
        .clk     (clk),
        .rst_n   (rst_n),
        .a_addr  (smem_a_addr),
        .a_rdata (smem_a_rdata),
        .b_addr  (smem_b_addr),
        .b_wdata (smem_b_wdata),
        .b_wr_en (smem_b_wr_en)
    );

    // Router uses spike_latch (stable spike captures) not raw spike_vector
    spike_router #(.N_NEURONS(N_NEURONS)) u_router (
        .clk         (clk),
        .rst_n       (rst_n),
        .enable      (router_enable),
        .spike_vector(spike_latch),  // latched by scheduler in S_LATCH
        .mem_addr    (router_mem_addr),
        .mem_rdata   (smem_a_rdata),
        .i_syn_out   (router_i_syn),
        .route_done  (route_done)
    );

    stdp #(.N_NEURONS(N_NEURONS)) u_stdp (
        .clk         (clk),
        .rst_n       (rst_n),
        .stdp_enable (cfg_stdp_enable),
        .run         (stdp_run),
        .spike_vector(spike_vector),  // raw spikes for timestamp update
        .timestep    (out_timestep),
        .mem_addr    (stdp_mem_addr),
        .mem_wdata   (stdp_mem_wdata),
        .mem_wr_en   (stdp_mem_wr_en),
        .mem_rdata   (smem_a_rdata),
        .stdp_done   (stdp_done)
    );

    // Merge encoder spikes + router accumulated currents
    generate
        genvar nn;
        for (nn = 0; nn < N_NEURONS; nn = nn + 1) begin : gen_isyn
            if (nn < N_INPUTS) begin
                assign i_syn_array[nn] = $signed(router_i_syn[nn]) +
                    $signed(enc_spikes[nn] ? 8'h30 : 8'h00);
            end else begin
                assign i_syn_array[nn] = $signed(router_i_syn[nn]);
            end
        end
    endgenerate

    assign neuron_enable = {N_NEURONS{neu_enable_all}};

    neuron_array #(.N_NEURONS(N_NEURONS)) u_neu (
        .clk         (clk),
        .rst_n       (rst_n),
        .enable      (neuron_enable),
        .i_syn       (i_syn_array),
        .spike_vector(spike_vector),
        .v_mem_array (v_mem_array)
    );

    scheduler #(.N_NEURONS(N_NEURONS)) u_sched (
        .clk            (clk),
        .rst_n          (rst_n),
        .cfg_run        (cfg_run),
        .cfg_t_max      (cfg_t_max),
        .stdp_enable    (cfg_stdp_enable),
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

    // Spike counting — one register per neuron
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

endmodule
