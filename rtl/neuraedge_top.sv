// neuraedge_top.sv
// 2x2 LIF cluster mesh with credit-based NoC, STDP learning, DVS input, UART output.
// Target: Artix-7 xc7a100tcsg324-1, 100 MHz
// Author: Rahul Verma | Apache 2.0 | see CHANGELOG.md for revision history

`timescale 1ns / 1ps

module neuraedge_top #(
    parameter int NUM_COLS      = 2,
    parameter int NUM_ROWS      = 2,
    parameter int NUM_NEURONS   = 64,
    parameter int NUM_SYNAPSES  = 128, // reduced from 512 for power; sufficient for XOR/MNIST demo
    parameter int WEIGHT_W      = 8,
    parameter int MEM_WIDTH     = 8,
    parameter int THRESHOLD     = 200,
    parameter int LEAK_SHIFT    = 1,
    parameter int A_PLUS        = 4,
    parameter int A_MINUS       = 2,
    parameter int TRACE_W       = 6,   // trace register width; passed to learning_engine
    parameter int TRACE_INCR    = 16,
    parameter int TRACE_DECAY   = 3,
    parameter int MAX_WEIGHT    = 255,
    parameter int MIN_WEIGHT    = 0,
    parameter int SENSOR_W      = 8,
    parameter int SENSOR_H      = 8,
    parameter int NEURON_ADDR_W = 6,
    parameter int TIMESTAMP_W   = 20,
    parameter int WINDOW_US     = 1000,
    parameter int WINDOW_MODE   = 0,
    parameter int NUM_CLASSES   = 10,
    parameter int UART_CLK_DIV  = 868
)(
    input  logic clk,
    input  logic rst_n,

    input  logic [$clog2(SENSOR_W)-1:0]  dvs_x,
    input  logic [$clog2(SENSOR_H)-1:0]  dvs_y,
    input  logic                          dvs_polarity,
    input  logic [TIMESTAMP_W-1:0]        dvs_timestamp,
    input  logic                          dvs_valid,
    output logic                          dvs_ready,
    input  logic                          window_advance,

    input  logic  spi_sclk,
    input  logic  spi_mosi,
    input  logic  spi_cs_n,

    output logic  uart_tx,
    output logic [15:0] led
);

    localparam NUM_CLUSTERS = NUM_COLS * NUM_ROWS;
    localparam COORD_W      = $clog2(NUM_COLS > NUM_ROWS ? NUM_COLS : NUM_ROWS);
    localparam PACKET_W     = 4 * COORD_W + NEURON_ADDR_W;
    localparam NEURON_W     = $clog2(NUM_NEURONS);
    localparam SYN_W        = $clog2(NUM_SYNAPSES);

    // ---- Compile-time assertions --------------------------
    initial begin
        if (NUM_CLUSTERS & (NUM_CLUSTERS - 1))
            $fatal(1, "[neuraedge_top] NUM_CLUSTERS=%0d must be power of 2.", NUM_CLUSTERS);
        if (NUM_SYNAPSES % 4 != 0)
            $fatal(1, "[neuraedge_top] NUM_SYNAPSES=%0d must be divisible by 4.", NUM_SYNAPSES);
        if (THRESHOLD > ((1 << MEM_WIDTH) - 1))
            $fatal(1, "[neuraedge_top] THRESHOLD=%0d exceeds MEM_WIDTH=%0d capacity.", THRESHOLD, MEM_WIDTH);
    end

    // ---- event_encoder ------------------------------------
    logic [PACKET_W-1:0]  enc_pkt_data;
    logic                 enc_pkt_valid;
    logic                 enc_pkt_ready;
    logic [31:0]          enc_events_accepted /* verilator public */;
    logic [31:0]          enc_events_dropped;
    logic                 enc_fifo_overflow;

    event_encoder #(
        .SENSOR_W      (SENSOR_W),
        .SENSOR_H      (SENSOR_H),
        .NUM_COLS      (NUM_COLS),
        .NUM_ROWS      (NUM_ROWS),
        .NEURON_ADDR_W (NEURON_ADDR_W),
        .TIMESTAMP_W   (TIMESTAMP_W),
        .WINDOW_US     (WINDOW_US),
        .WINDOW_MODE   (WINDOW_MODE),
        .FIFO_DEPTH    (4)
    ) u_event_encoder (
        .clk             (clk),
        .rst_n           (rst_n),
        .dvs_x           (dvs_x),
        .dvs_y           (dvs_y),
        .dvs_polarity    (dvs_polarity),
        .dvs_timestamp   (dvs_timestamp),
        .dvs_valid       (dvs_valid),
        .dvs_ready       (dvs_ready),
        .window_advance  (window_advance),
        .pkt_data        (enc_pkt_data),
        .pkt_valid       (enc_pkt_valid),
        .pkt_ready       (enc_pkt_ready),
        .events_accepted (enc_events_accepted),
        .events_dropped  (enc_events_dropped),
        .fifo_overflow   (enc_fifo_overflow)
    );

    // ---- Mesh wiring (flat signals, tool-friendly) --------
    logic [PACKET_W-1:0] r_in_data_N   [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [PACKET_W-1:0] r_in_data_S   [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [PACKET_W-1:0] r_in_data_E   [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [PACKET_W-1:0] r_in_data_W   [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [PACKET_W-1:0] r_in_data_L   [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_in_valid_N  [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_in_valid_S  [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_in_valid_E  [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_in_valid_W  [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_in_valid_L  [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_in_credit_N [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_in_credit_S [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_in_credit_E [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_in_credit_W [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_in_credit_L [0:NUM_COLS-1][0:NUM_ROWS-1];

    logic [PACKET_W-1:0] r_out_data_N   [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [PACKET_W-1:0] r_out_data_S   [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [PACKET_W-1:0] r_out_data_E   [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [PACKET_W-1:0] r_out_data_W   [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [PACKET_W-1:0] r_out_data_L   [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_out_valid_N  [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_out_valid_S  [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_out_valid_E  [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_out_valid_W  [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_out_valid_L  [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_out_credit_N [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_out_credit_S [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_out_credit_E [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_out_credit_W [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                r_out_credit_L [0:NUM_COLS-1][0:NUM_ROWS-1];

    generate
        for (genvar gc = 0; gc < NUM_COLS; gc++) begin : mesh_col
            for (genvar gr = 0; gr < NUM_ROWS; gr++) begin : mesh_row
                if (gr < NUM_ROWS-1) begin : n_in
                    assign r_in_data_N [gc][gr] = r_out_data_S [gc][gr+1];
                    assign r_in_valid_N[gc][gr] = r_out_valid_S[gc][gr+1];
                    assign r_out_credit_N[gc][gr] = r_in_credit_S[gc][gr+1];
                end else begin : n_edge
                    assign r_in_data_N [gc][gr] = '0;
                    assign r_in_valid_N[gc][gr] = 1'b0;
                    assign r_out_credit_N[gc][gr] = 1'b0;
                end

                if (gr > 0) begin : s_in
                    assign r_in_data_S [gc][gr] = r_out_data_N [gc][gr-1];
                    assign r_in_valid_S[gc][gr] = r_out_valid_N[gc][gr-1];
                    assign r_out_credit_S[gc][gr] = r_in_credit_N[gc][gr-1];
                end else begin : s_edge
                    assign r_in_data_S [gc][gr] = '0;
                    assign r_in_valid_S[gc][gr] = 1'b0;
                    assign r_out_credit_S[gc][gr] = 1'b0;
                end

                if (gc < NUM_COLS-1) begin : e_in
                    assign r_in_data_E [gc][gr] = r_out_data_W [gc+1][gr];
                    assign r_in_valid_E[gc][gr] = r_out_valid_W[gc+1][gr];
                    assign r_out_credit_E[gc][gr] = r_in_credit_W[gc+1][gr];
                end else begin : e_edge
                    assign r_in_data_E [gc][gr] = '0;
                    assign r_in_valid_E[gc][gr] = 1'b0;
                    assign r_out_credit_E[gc][gr] = 1'b0;
                end

                if (gc > 0) begin : w_in
                    assign r_in_data_W [gc][gr] = r_out_data_E [gc-1][gr];
                    assign r_in_valid_W[gc][gr] = r_out_valid_E[gc-1][gr];
                    assign r_out_credit_W[gc][gr] = r_in_credit_E[gc-1][gr];
                end else begin : w_edge
                    assign r_in_data_W [gc][gr] = '0;
                    assign r_in_valid_W[gc][gr] = 1'b0;
                    assign r_out_credit_W[gc][gr] = 1'b0;
                end

                if (gc == 0 && gr == 0) begin : l_src
                    assign r_in_data_L [gc][gr] = enc_pkt_data;
                    assign r_in_valid_L[gc][gr] = enc_pkt_valid;
                    assign enc_pkt_ready         = r_in_credit_L[gc][gr];
                end else begin : l_idle
                    assign r_in_data_L [gc][gr] = '0;
                    assign r_in_valid_L[gc][gr] = 1'b0;
                end
                assign r_out_credit_L[gc][gr] = 1'b1;
            end
        end
    endgenerate

    // ---- Per-cluster signals ------------------------------
    logic [NUM_NEURONS-1:0] spike_out      [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [WEIGHT_W-1:0]    syn_rd_data_b0 [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [WEIGHT_W-1:0]    syn_rd_data_sel[0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                   syn_rd_valid   [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [NEURON_W-1:0]    le_wr_neuron   [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [SYN_W-1:0]       le_wr_syn      [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [WEIGHT_W-1:0]    le_wr_data     [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                   le_we          [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [NEURON_W-1:0]    le_rd_neuron   [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [SYN_W-1:0]       le_rd_syn      [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [31:0]            fire_cnt        [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                   le_scan_active  [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [31:0]            le_ltp_count    [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [31:0]            le_ltd_count    [0:NUM_COLS-1][0:NUM_ROWS-1];

    // spikes_valid: high when either pre or post spikes are present this cycle.
    // Gating traces and event generation on actual activity avoids continuous
    // toggle power when the mesh is idle (no DVS events, no firing neurons).
    logic                   any_spike       [0:NUM_COLS-1][0:NUM_ROWS-1];
    logic                   le_clk_en       [0:NUM_COLS-1][0:NUM_ROWS-1];

    // pre_spike one-hot decoder: each bit set when the router delivers
    // a packet to neuron ni in cluster (ci,cj). Registered one cycle to
    // break the long combinational path from router → learning engine.
    (* max_fanout = 16 *) logic [NUM_NEURONS-1:0] pre_spike_pipe [0:NUM_COLS-1][0:NUM_ROWS-1];
    (* max_fanout = 16 *) logic [NUM_NEURONS-1:0] post_spike_pipe[0:NUM_COLS-1][0:NUM_ROWS-1];
    logic [NEURON_ADDR_W-1:0] nc_neuron_id_flat  [0:NUM_CLUSTERS-1];
    logic                     nc_input_valid_flat [0:NUM_CLUSTERS-1];
    logic [NEURON_W-1:0]     wl_wr_neuron;
    logic [SYN_W-1:0]        wl_wr_syn;
    logic [WEIGHT_W-1:0]     wl_wr_data;
    logic [NUM_CLUSTERS-1:0] wl_we_sel;

    // Sticky overflow flags — one bit per cluster router port (5 ports each).
    // Set on first overflow, cleared only by reset. Exposed on UART status.
    logic [4:0] router_overflow_sticky [0:NUM_COLS-1][0:NUM_ROWS-1];

    // ---- pre_spike combinational decoder ------------------
    // Synthesises to NUM_CLUSTERS x NUM_NEURONS equality comparators.
    logic [NUM_NEURONS-1:0] pre_spike_reg [0:NUM_COLS-1][0:NUM_ROWS-1];

    always_comb begin
        for (int ci = 0; ci < NUM_COLS; ci++) begin
            for (int cj = 0; cj < NUM_ROWS; cj++) begin
                for (int ni = 0; ni < NUM_NEURONS; ni++) begin
                    pre_spike_reg[ci][cj][ni] =
                        nc_input_valid_flat[ci * NUM_ROWS + cj] &&
                        (nc_neuron_id_flat[ci * NUM_ROWS + cj] == ni[NEURON_W-1:0]);
                end
            end
        end
    end

    // Register pre_spike and post_spike vectors to cut long combinational paths.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int pi = 0; pi < NUM_COLS; pi++)
                for (int pj = 0; pj < NUM_ROWS; pj++)
                    pre_spike_pipe[pi][pj] <= {NUM_NEURONS{1'b0}};
        end else begin
            for (int pi = 0; pi < NUM_COLS; pi++)
                for (int pj = 0; pj < NUM_ROWS; pj++)
                    pre_spike_pipe[pi][pj] <= pre_spike_reg[pi][pj];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int pi = 0; pi < NUM_COLS; pi++)
                for (int pj = 0; pj < NUM_ROWS; pj++)
                    post_spike_pipe[pi][pj] <= {NUM_NEURONS{1'b0}};
        end else begin
            for (int pi = 0; pi < NUM_COLS; pi++)
                for (int pj = 0; pj < NUM_ROWS; pj++)
                    post_spike_pipe[pi][pj] <= spike_out[pi][pj];
        end
    end

    // Per-cluster activity gating
    // spikes_valid is only asserted when spikes are actually present.
    // clk_en additionally holds the learning engine idle when the queue is
    // empty and no new events are being generated — no spikes flowing means
    // no BRAM scans, no trace decay, no toggle power in the learning path.
    generate
        for (genvar gc = 0; gc < NUM_COLS; gc++) begin : act_col
            for (genvar gr = 0; gr < NUM_ROWS; gr++) begin : act_row
                // any_spike: true when this cluster has active pre or post spikes this cycle.
                // Derived from registered pipe signals so it is already 1 cycle delayed —
                // that is fine: the learning engine sees the same delayed spikes.
                assign any_spike[gc][gr] = |pre_spike_pipe[gc][gr] | |post_spike_pipe[gc][gr];

                // le_clk_en: hold the learning engine active while spikes are present OR
                // while a BRAM scan is still in progress. Falls to 0 when the mesh is quiet
                // and the queue is drained, stopping all FF toggling in the learning path.
                assign le_clk_en[gc][gr] = any_spike[gc][gr] | le_scan_active[gc][gr];
            end
        end
    endgenerate

    // ---- Cluster generate loop ----------------------------
    generate
        for (genvar gc = 0; gc < NUM_COLS; gc++) begin : gen_col
            for (genvar gr = 0; gr < NUM_ROWS; gr++) begin : gen_row

                // Per-cluster local signals
                logic [NEURON_W-1:0] nc_nid;
                logic [WEIGHT_W-1:0] nc_syn_weight;
                logic                nc_ivalid;
                logic [SYN_W-1:0]    syn_rd_syn_w;
                logic                syn_we_mux;
                logic [NEURON_W-1:0] syn_wr_neuron_mux;
                logic [SYN_W-1:0]    syn_wr_syn_mux;
                logic [WEIGHT_W-1:0] syn_wr_data_mux;
                logic [4:0]          router_overflow_raw;

                // Mirror router local output to pre_spike decoder arrays
                assign nc_neuron_id_flat [gc * NUM_ROWS + gr] = nc_nid;
                assign nc_input_valid_flat[gc * NUM_ROWS + gr] = nc_ivalid;

                // Sticky overflow latch — set on any router FIFO overflow, cleared on reset.
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) router_overflow_sticky[gc][gr] <= 5'b0;
                    else        router_overflow_sticky[gc][gr] <= router_overflow_sticky[gc][gr]
                                                                  | router_overflow_raw;
                end

                spike_router #(
                    .NUM_COLS(NUM_COLS), .NUM_ROWS(NUM_ROWS),
                    .NEURON_ADDR_W(NEURON_ADDR_W), .FIFO_DEPTH(4),
                    .CUR_COL(gc), .CUR_ROW(gr), .PACKET_W(PACKET_W)
                ) u_router (
                    .clk(clk), .rst_n(rst_n),
                    .in_data_N  (r_in_data_N [gc][gr]), .in_valid_N  (r_in_valid_N [gc][gr]), .in_credit_N (r_in_credit_N [gc][gr]),
                    .in_data_S  (r_in_data_S [gc][gr]), .in_valid_S  (r_in_valid_S [gc][gr]), .in_credit_S (r_in_credit_S [gc][gr]),
                    .in_data_E  (r_in_data_E [gc][gr]), .in_valid_E  (r_in_valid_E [gc][gr]), .in_credit_E (r_in_credit_E [gc][gr]),
                    .in_data_W  (r_in_data_W [gc][gr]), .in_valid_W  (r_in_valid_W [gc][gr]), .in_credit_W (r_in_credit_W [gc][gr]),
                    .in_data_L  (r_in_data_L [gc][gr]), .in_valid_L  (r_in_valid_L [gc][gr]), .in_credit_L (r_in_credit_L [gc][gr]),
                    .out_data_N (r_out_data_N[gc][gr]), .out_valid_N (r_out_valid_N[gc][gr]), .out_credit_N(r_out_credit_N[gc][gr]),
                    .out_data_S (r_out_data_S[gc][gr]), .out_valid_S (r_out_valid_S[gc][gr]), .out_credit_S(r_out_credit_S[gc][gr]),
                    .out_data_E (r_out_data_E[gc][gr]), .out_valid_E (r_out_valid_E[gc][gr]), .out_credit_E(r_out_credit_E[gc][gr]),
                    .out_data_W (r_out_data_W[gc][gr]), .out_valid_W (r_out_valid_W[gc][gr]), .out_credit_W(r_out_credit_W[gc][gr]),
                    .out_data_L (r_out_data_L[gc][gr]), .out_valid_L (r_out_valid_L[gc][gr]), .out_credit_L(r_out_credit_L[gc][gr]),
                    .fifo_overflow(router_overflow_raw)
                );

                assign nc_nid        = r_out_data_L[gc][gr][NEURON_ADDR_W-1:0];
                assign nc_ivalid     = r_out_valid_L[gc][gr];
                assign nc_syn_weight = syn_rd_data_b0[gc][gr];
                assign syn_rd_syn_w  = {SYN_W{1'b0}};

                neuron_core #(
                    .NUM_NEURONS(NUM_NEURONS), .MEM_WIDTH(MEM_WIDTH),
                    .THRESHOLD(THRESHOLD), .LEAK_SHIFT(LEAK_SHIFT)
                ) u_neuron (
                    .clk            (clk),
                    .rst_n          (rst_n),
                    .neuron_id      (nc_nid),
                    .synaptic_input (nc_syn_weight),
                    .input_valid    (nc_ivalid),
                    .neuron_enable  ({NUM_NEURONS{1'b1}}),
                    .spike_out      (spike_out[gc][gr]),
                    .mem_debug      (),
                    .fire_count     (fire_cnt[gc][gr])
                );

                assign syn_we_mux        = le_we[gc][gr] | wl_we_sel[gc*NUM_ROWS+gr];
                assign syn_wr_neuron_mux = le_we[gc][gr] ? le_wr_neuron[gc][gr] : wl_wr_neuron;
                assign syn_wr_syn_mux    = le_we[gc][gr] ? le_wr_syn   [gc][gr] : wl_wr_syn;
                assign syn_wr_data_mux   = le_we[gc][gr] ? le_wr_data  [gc][gr] : wl_wr_data;

                // rd_en gates the rd_valid pipeline so the learning FSM only
                // sees a valid read result when it actually issued a request.
                // Also ensures all 4 banks are functionally observed by Vivado.
                synapse_memory #(
                    .NUM_NEURONS(NUM_NEURONS), .NUM_SYNAPSES(NUM_SYNAPSES),
                    .WIDTH(WEIGHT_W), .MAX_WEIGHT(MAX_WEIGHT), .MIN_WEIGHT(MIN_WEIGHT)
                ) u_synapse (
                    .clk         (clk), .rst_n(rst_n),
                    .wr_neuron   (syn_wr_neuron_mux),
                    .wr_syn      (syn_wr_syn_mux),
                    .wr_data     (syn_wr_data_mux),
                    .we          (syn_we_mux),
                    .rd_neuron   (le_we[gc][gr] ? le_rd_neuron[gc][gr] : nc_nid),
                    .rd_syn_base (le_we[gc][gr] ? le_rd_syn   [gc][gr] : syn_rd_syn_w),
                    .rd_en       (le_we[gc][gr] ? 1'b1 : nc_ivalid),
                    .rd_data_b0  (syn_rd_data_b0[gc][gr]),
                    .rd_data_b1  (), .rd_data_b2(), .rd_data_b3(),
                    .rd_data_sel (syn_rd_data_sel[gc][gr]),
                    .rd_valid    (syn_rd_valid[gc][gr])
                );

                learning_engine #(
                    .NUM_NEURONS(NUM_NEURONS), .NUM_SYNAPSES(NUM_SYNAPSES),
                    .WEIGHT_W(WEIGHT_W), .TRACE_W(TRACE_W),
                    .A_PLUS(A_PLUS), .A_MINUS(A_MINUS),
                    .TRACE_INCR(TRACE_INCR), .TRACE_DECAY(TRACE_DECAY),
                    .MAX_WEIGHT(MAX_WEIGHT), .MIN_WEIGHT(MIN_WEIGHT)
                ) u_learning (
                    .clk          (clk), .rst_n(rst_n),
                    .pre_spike    (pre_spike_pipe[gc][gr]),
                    .post_spike   (post_spike_pipe[gc][gr]),
                    .spikes_valid (any_spike[gc][gr]),
                    .clk_en       (le_clk_en[gc][gr]),
                    .mem_wr_neuron(le_wr_neuron[gc][gr]),
                    .mem_wr_syn   (le_wr_syn   [gc][gr]),
                    .mem_wr_data  (le_wr_data  [gc][gr]),
                    .mem_we       (le_we       [gc][gr]),
                    .mem_rd_neuron(le_rd_neuron[gc][gr]),
                    .mem_rd_syn   (le_rd_syn   [gc][gr]),
                    .mem_rd_data  (syn_rd_data_sel[gc][gr]),
                    .mem_rd_valid (syn_rd_valid[gc][gr]),
                    .ltp_count    (le_ltp_count[gc][gr]),
                    .ltd_count    (le_ltd_count[gc][gr]),
                    .scan_active  (le_scan_active[gc][gr])
                );

            end
        end
    endgenerate

    // ---- SPI weight loader --------------------------------
    logic [39:0]            spi_shift;
    logic [5:0]             spi_bit_cnt;
    logic spi_sclk_r, spi_sclk_r2;
    logic                   spi_sclk_rise;
    assign spi_sclk_rise = spi_sclk_r && !spi_sclk_r2;
    logic [NEURON_W-1:0]     wl_wr_neuron_r;
    logic [SYN_W-1:0]        wl_wr_syn_r;
    logic [WEIGHT_W-1:0]     wl_wr_data_r;
    logic [NUM_CLUSTERS-1:0] wl_we_r;

    assign wl_wr_neuron = wl_wr_neuron_r;
    assign wl_wr_syn    = wl_wr_syn_r;
    assign wl_wr_data   = wl_wr_data_r;
    assign wl_we_sel    = wl_we_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_shift      <= 40'b0; spi_bit_cnt <= 6'd0;
            spi_sclk_r     <= 1'b0;  spi_sclk_r2 <= 1'b0;
            wl_wr_neuron_r <= {NEURON_W{1'b0}};
            wl_wr_syn_r    <= {SYN_W{1'b0}};
            wl_wr_data_r   <= {WEIGHT_W{1'b0}};
            wl_we_r        <= {NUM_CLUSTERS{1'b0}};
        end else begin
            spi_sclk_r  <= spi_sclk;
            spi_sclk_r2 <= spi_sclk_r;
            wl_we_r     <= {NUM_CLUSTERS{1'b0}};
            if (!spi_cs_n) begin
                if (spi_sclk_rise) begin
                    spi_shift   <= {spi_shift[38:0], spi_mosi};
                    spi_bit_cnt <= spi_bit_cnt + 1;
                end
                if (spi_bit_cnt == 6'd39) begin
                    spi_bit_cnt <= 6'd0;
                    begin : decode
                        logic [$clog2(NUM_CLUSTERS)-1:0] cid;
                        cid             = spi_shift[$clog2(NUM_CLUSTERS)+31:32] & ($clog2(NUM_CLUSTERS)'(NUM_CLUSTERS - 1));
                        wl_wr_neuron_r <= spi_shift[31:24];
                        wl_wr_syn_r    <= {spi_shift[23:16], spi_shift[15:8]};
                        wl_wr_data_r   <= spi_shift[7:0];
                        wl_we_r[cid]   <= 1'b1;
                    end
                end
            end else begin
                spi_bit_cnt <= 6'd0;
            end
        end
    end

    // ---- Output classifier --------------------------------
    localparam ACCUM_W = 16;
    logic [ACCUM_W-1:0]     spike_accum [0:NUM_CLASSES-1];
    logic [TIMESTAMP_W-1:0] infer_timer;
    logic [3:0]             best_class;
    logic [ACCUM_W-1:0]     best_count;
    logic result_valid;
    logic result_pending;
    logic [7:0]             uart_byte;
    logic uart_start;

    // Iterative argmax state:
    // one class compare per cycle to avoid deep carry-chain cones.
    logic cls_active;
    logic [3:0]             cls_best_class;
    logic [ACCUM_W-1:0]     cls_best_count;
    logic [$clog2(NUM_CLASSES)-1:0] cls_idx;
    logic [ACCUM_W-1:0]     cls_snapshot [0:NUM_CLASSES-1];

    // FIX v1.5 (CRITICAL): uart_byte NBA race.
    // Old code: uart_byte <= {4'b0, best_class} captured PRE-CLOCK best_class
    // because all NBA RHS values evaluate simultaneously. UART always sent
    // the PREVIOUS window's winner. First window always sent class 0x00.
    //
    // Fix: compute the winner combinationally in a for-loop BEFORE the clocked
    // block using a reg updated via blocking assignment in an always_comb block.
    // The registered always block then captures this combinational result.
    //
    // FIX v1.5 (MINOR): window boundary spike loss.
    // spike_accum[k] received two conflicting NBAs on the window boundary cycle:
    //   accum: spike_accum[k] <= spike_accum[k] + 1  (line A)
    //   clear: spike_accum[k] <= 0                    (line B, last NBA wins)
    // The spike firing on the last cycle of the window was dropped.
    // Fix: accumulate into spike_accum ONLY when infer_timer < WINDOW_US,
    // so the clear cycle is exclusive — no conflict.

        always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int k = 0; k < NUM_CLASSES; k++) spike_accum[k] <= {ACCUM_W{1'b0}};
            infer_timer  <= {TIMESTAMP_W{1'b0}};
            best_class   <= 4'd0; best_count <= {ACCUM_W{1'b0}};
            result_valid <= 1'b0; result_pending <= 1'b0; uart_start <= 1'b0;
            uart_byte    <= 8'd0;

            cls_active     <= 1'b0;
            cls_best_class <= 4'd0;
            cls_best_count <= {ACCUM_W{1'b0}};
            cls_idx        <= {($clog2(NUM_CLASSES)){1'b0}};
            for (int k = 0; k < NUM_CLASSES; k++)
                cls_snapshot[k] <= {ACCUM_W{1'b0}};
        end else begin
            uart_start <= 1'b0;

            // Iterative argmax: one compare per cycle from stable snapshot.
            if (cls_active) begin
                if (cls_snapshot[cls_idx] >= cls_best_count) begin
                    cls_best_count <= cls_snapshot[cls_idx];
                    cls_best_class <= cls_idx[3:0];
                end
                if (cls_idx == NUM_CLASSES[$clog2(NUM_CLASSES)-1:0] - 1) begin
                    cls_active     <= 1'b0;
                    result_valid   <= 1'b1;
                    result_pending <= 1'b1;
                    if (cls_snapshot[cls_idx] >= cls_best_count) begin
                        best_count <= cls_snapshot[cls_idx];
                        best_class <= cls_idx[3:0];
                    end else begin
                        best_count <= cls_best_count;
                        best_class <= cls_best_class;
                    end
                end else begin
                    cls_idx <= cls_idx + 1'b1;
                end
            end

            // Stage classification result by one cycle before UART launch.
            // This isolates UART launch from classifier update timing.
            if (result_pending) begin
                uart_byte      <= {4'b0000, best_class};
                uart_start     <= 1'b1;
                result_pending <= 1'b0;
            end

            // Accumulate output spikes from all clusters.
            // Each cluster's top NUM_CLASSES neurons map to classifier outputs.
            // Sum across all clusters before argmax.
            if (infer_timer != WINDOW_US[TIMESTAMP_W-1:0]) begin
                for (int k = 0; k < NUM_CLASSES; k++) begin
                    logic [3:0] cluster_fires;
                    cluster_fires = 4'd0;
                    for (int ci = 0; ci < NUM_COLS; ci++)
                        for (int ri = 0; ri < NUM_ROWS; ri++)
                            if (spike_out[ci][ri][NUM_NEURONS-NUM_CLASSES+k])
                                cluster_fires = cluster_fires + 4'd1;
                    if (cluster_fires > 4'd0)
                        spike_accum[k] <= spike_accum[k] + {12'd0, cluster_fires};
                end
            end
            infer_timer <= infer_timer + 1;
            if (infer_timer == WINDOW_US[TIMESTAMP_W-1:0]) begin
                infer_timer <= {TIMESTAMP_W{1'b0}};
                // Snapshot class counts, then start iterative argmax.
                for (int k = 0; k < NUM_CLASSES; k++)
                    cls_snapshot[k] <= spike_accum[k];
                cls_active     <= 1'b1;
                cls_idx        <= {{($clog2(NUM_CLASSES)-1){1'b0}}, 1'b1};
                cls_best_count <= spike_accum[0];
                cls_best_class <= 4'd0;
                for (int k = 0; k < NUM_CLASSES; k++)
                    spike_accum[k] <= {ACCUM_W{1'b0}};
            end
        end
    end

    // ---- UART 8N1 transmitter -----------------------------
    logic [3:0]  uart_bit_idx;
    logic [9:0]  uart_shift_r;
    logic [15:0] uart_clk_cnt;
    logic uart_busy;
    logic uart_tx_r;
    assign uart_tx = uart_tx_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_tx_r    <= 1'b1; uart_busy <= 1'b0;
            uart_clk_cnt <= 16'd0; uart_bit_idx <= 4'd0;
            uart_shift_r <= 10'h3FF;
        end else begin
            if (uart_start && !uart_busy) begin
                uart_shift_r <= {1'b1, uart_byte, 1'b0};
                uart_bit_idx <= 4'd0; uart_clk_cnt <= 16'd0;
                uart_busy    <= 1'b1; uart_tx_r    <= 1'b0;
            end else if (uart_busy) begin
                uart_clk_cnt <= uart_clk_cnt + 1;
                if (uart_clk_cnt == UART_CLK_DIV[15:0] - 1) begin
                    uart_clk_cnt <= 16'd0;
                    uart_bit_idx <= uart_bit_idx + 1;
                    uart_tx_r    <= uart_shift_r[uart_bit_idx + 1];
                    if (uart_bit_idx == 4'd8) begin
                        uart_busy <= 1'b0; uart_tx_r <= 1'b1;
                    end
                end
            end
        end
    end

    // ---- Debug LEDs ---------------------------------------
    assign led[ 3: 0] = spike_out[0][0][3:0];
    assign led[ 7: 4] = spike_out[1][0][3:0];
    assign led[11: 8] = spike_out[0][1][3:0];
    assign led[15:12] = spike_out[1][1][3:0];

endmodule
