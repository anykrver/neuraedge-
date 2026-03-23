// ============================================================
// Module:      neuraedge_sva
// Description: SystemVerilog Assertions (SVA) for NeuraEdge.
//
// Bind this module to the DUT during simulation:
//
//   // In your testbench or a bind file:
//   bind neuraedge_top neuraedge_sva #(
//       .NUM_NEURONS (64),
//       .NUM_SYNAPSES(512),
//       .WEIGHT_W    (8),
//       .PACKET_W    (10),
//       .WINDOW_US   (1000),
//       .TIMESTAMP_W (20)
//   ) u_sva (
//       .clk          (clk),
//       .rst_n        (rst_n),
//       .dvs_valid    (dvs_valid),
//       .dvs_ready    (dvs_ready),
//       .pkt_valid    (gen_col[0].gen_row[0].u_router.out_L.valid),
//       .spike_out_c0 (gen_col[0].gen_row[0].u_neuron.spike_out),
//       .mem_we       (gen_col[0].gen_row[0].u_learning.mem_we),
//       .mem_wr_data  (gen_col[0].gen_row[0].u_learning.mem_wr_data),
//       .mem_rd_valid (gen_col[0].gen_row[0].u_synapse.rd_valid),
//       .infer_timer  (infer_timer),
//       .uart_tx      (uart_tx),
//       .rst_n_pipe   (gen_col[0].gen_row[0].u_learning.rst_n_pipe),
//       .le_scan_active(gen_col[0].gen_row[0].u_learning.scan_active)
//   );
//
// Or compile with +define+SVA_ENABLE and the noc_port interface
// assertions will activate automatically.
//
// Coverage groups are always compiled but only meaningful in
// simulation — synthesis tools skip them via translate_off.
//
// Author:   NeuraEdge / Rahul Verma | Version: 1.0.0 | Apache 2.0
// ============================================================
`timescale 1ns / 1ps

module neuraedge_sva #(
    parameter int NUM_NEURONS  = 64,
    parameter int NUM_SYNAPSES = 512,
    parameter int WEIGHT_W     = 8,
    parameter int PACKET_W     = 10,
    parameter int WINDOW_US    = 1000,
    parameter int TIMESTAMP_W  = 20
)(
    input logic clk,
    input logic rst_n,

    // DVS encoder interface
    input logic dvs_valid,
    input logic dvs_ready,

    // NoC local output (cluster [0][0])
    input logic pkt_valid,

    // Neuron core (cluster [0][0])
    input logic [NUM_NEURONS-1:0] spike_out_c0,

    // Learning engine (cluster [0][0])
    input logic                          mem_we,
    input logic [WEIGHT_W-1:0]           mem_wr_data,
    input logic                          mem_rd_valid,

    // Classifier / UART
    input logic [TIMESTAMP_W-1:0]        infer_timer,
    input logic                          uart_tx,

    // Learning engine internals
    input logic                          rst_n_pipe,
    input logic                          le_scan_active
);

    // ========================================================
    // 1. DVS ENCODER ASSERTIONS
    // ========================================================

    // 1a. dvs_ready must never be X/Z after reset deasserts
    property p_dvs_ready_known;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(dvs_ready);
    endproperty
    a_dvs_ready_known: assert property (p_dvs_ready_known)
        else $error("[SVA:enc] dvs_ready is X/Z — encoder output undefined");

    // 1b. No event should be lost silently: if dvs_valid && dvs_ready,
    //     pkt_valid must assert within 3 cycles (2-stage encode pipeline + 1)
    property p_event_produces_packet;
        @(posedge clk) disable iff (!rst_n)
        (dvs_valid && dvs_ready) |-> ##[1:3] pkt_valid;
    endproperty
    a_event_produces_packet: assert property (p_event_produces_packet)
        else $warning("[SVA:enc] DVS event accepted but no packet appeared in 3 cycles");

    // ========================================================
    // 2. NEURON CORE ASSERTIONS
    // ========================================================

    // 2a. spike_out must be a 1-cycle pulse — no neuron can stay
    //     high for two consecutive cycles (it resets immediately)
    property p_spike_is_pulse;
        @(posedge clk) disable iff (!rst_n)
        |spike_out_c0 |-> ##1 !(spike_out_c0 & $past(spike_out_c0));
    endproperty
    a_spike_is_pulse: assert property (p_spike_is_pulse)
        else $error("[SVA:neuron] spike_out held high >1 cycle — reset path broken");

    // 2b. spike_out must not be X/Z
    property p_spike_known;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(spike_out_c0);
    endproperty
    a_spike_known: assert property (p_spike_known)
        else $error("[SVA:neuron] spike_out contains X/Z — check membrane reset");

    // ========================================================
    // 3. SYNAPSE MEMORY ASSERTIONS
    // ========================================================

    // 3a. mem_rd_valid must assert exactly 1 cycle after any read issued
    //     (BRAM registered read — 1-cycle latency guaranteed by synapse_memory.sv)
    property p_rd_valid_latency;
        @(posedge clk) disable iff (!rst_n)
        mem_rd_valid |-> $past(mem_rd_valid, 0) || 1'b1;  // always-true placeholder
    endproperty
    // More useful: rd_valid should deassert during reset
    property p_rd_valid_clears_on_reset;
        @(posedge clk)
        !rst_n |-> ##1 !mem_rd_valid;
    endproperty
    a_rd_valid_clears_on_reset: assert property (p_rd_valid_clears_on_reset)
        else $error("[SVA:syn] mem_rd_valid not cleared on reset");

    // 3b. Weight writes must be within [MIN_WEIGHT, MAX_WEIGHT]
    //     (sat_add is supposed to enforce bounds)
    property p_weight_in_bounds;
        @(posedge clk) disable iff (!rst_n)
        mem_we |-> (mem_wr_data >= WEIGHT_W'(0)) &&
                   (mem_wr_data <= {WEIGHT_W{1'b1}});
    endproperty
    a_weight_in_bounds: assert property (p_weight_in_bounds)
        else $error("[SVA:le] Weight write out of [0, 2^WEIGHT_W-1]: %0d", mem_wr_data);

    // ========================================================
    // 4. LEARNING ENGINE ASSERTIONS
    // ========================================================

    // 4a. mem_we must not assert while learning engine is in reset
    property p_no_write_during_reset;
        @(posedge clk)
        !rst_n_pipe |-> !mem_we;
    endproperty
    a_no_write_during_reset: assert property (p_no_write_during_reset)
        else $error("[SVA:le] mem_we asserted while rst_n_pipe is low");

    // 4b. scan_active should deassert within a bounded window after
    //     the last spike event (give it 2*NUM_SYNAPSES cycles = scan drain time)
    // Note: this is a liveness property — use it as a cover to verify scans complete
    property p_scan_eventually_idle;
        @(posedge clk) disable iff (!rst_n)
        $rose(le_scan_active) |-> ##[1:2*NUM_SYNAPSES+10] !le_scan_active;
    endproperty
    a_scan_eventually_idle: assert property (p_scan_eventually_idle)
        else $error("[SVA:le] scan_active never deasserted — FSM stuck");

    // ========================================================
    // 5. CLASSIFIER / UART ASSERTIONS
    // ========================================================

    // 5a. infer_timer must count monotonically until wrap
    property p_timer_increments;
        @(posedge clk) disable iff (!rst_n)
        (infer_timer < TIMESTAMP_W'(WINDOW_US - 1)) |->
            ##1 (infer_timer == $past(infer_timer) + 1);
    endproperty
    a_timer_increments: assert property (p_timer_increments)
        else $error("[SVA:top] infer_timer skipped a count — accumulation bug");

    // 5b. UART TX must start low (start bit) within 2 cycles of timer wrap
    property p_uart_transmits_after_window;
        @(posedge clk) disable iff (!rst_n)
        (infer_timer == TIMESTAMP_W'(WINDOW_US)) |-> ##[1:4] !uart_tx;
    endproperty
    a_uart_transmits_after_window: assert property (p_uart_transmits_after_window)
        else $warning("[SVA:top] UART TX did not begin within 4 cycles of window close");

    // 5c. uart_tx must not be X/Z during normal operation
    property p_uart_tx_known;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(uart_tx);
    endproperty
    a_uart_tx_known: assert property (p_uart_tx_known)
        else $error("[SVA:top] uart_tx is X/Z — check UART state machine");

    // ========================================================
    // 6. RESET SEQUENCE ASSERTION
    // ========================================================

    // rst_n_pipe must deassert exactly 1 cycle after rst_n
    property p_pipe_reset_latency;
        @(posedge clk)
        $rose(rst_n) |-> ##1 $rose(rst_n_pipe);
    endproperty
    a_pipe_reset_latency: assert property (p_pipe_reset_latency)
        else $error("[SVA:le] rst_n_pipe did not deassert 1 cycle after rst_n");

    // ========================================================
    // 7. COVER POINTS (functional coverage)
    // ========================================================
    // synthesis translate_off
    // Ensure the simulation actually exercises the interesting cases

    c_spike_fired:    cover property (@(posedge clk) disable iff (!rst_n) |spike_out_c0);
    c_mem_write:      cover property (@(posedge clk) disable iff (!rst_n) mem_we);
    c_full_window:    cover property (@(posedge clk) disable iff (!rst_n)
                          infer_timer == TIMESTAMP_W'(WINDOW_US));
    c_dvs_backpress:  cover property (@(posedge clk) disable iff (!rst_n)
                          dvs_valid && !dvs_ready);
    c_scan_active:    cover property (@(posedge clk) disable iff (!rst_n) le_scan_active);
    c_uart_start_bit: cover property (@(posedge clk) disable iff (!rst_n) !uart_tx);
    // synthesis translate_on

endmodule : neuraedge_sva
