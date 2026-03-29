// ============================================================
// Module:      neuraedge_top_ila
// Description: Synthesis wrapper that instantiates neuraedge_top
//              alongside four Vivado ILA debug cores for real-time
//              hardware signal capture on the Nexys A7.
//
// ILA cores
// ---------
//   ILA 0 — Spike activity monitor
//     Captures spike_out vectors across all 4 clusters plus
//     the encoder packet stream. Triggers on any spike in
//     cluster[0][0]. Use this to measure spike rate and
//     verify end-to-end DVS→neuron firing.
//
//   ILA 1 — STDP weight update monitor
//     Captures learning_engine write-back to synapse_memory:
//     neuron address, synapse address, weight value, direction
//     (LTP/LTD). Triggers on any weight write. Use this to
//     verify that STDP is converging in the right direction.
//
//   ILA 2 — Output classifier monitor
//     Captures spike accumulators, inference timer, and UART
//     transmit events. Triggers on uart_start. Use this to
//     verify N-MNIST classification output matches Python.
//
//   ILA 3 — Event encoder / SPI loader monitor
//     Captures DVS input, encoded packet, SPI frame loading,
//     and fifo_overflow flag. Triggers on dvs_valid. Use this
//     to verify that pixel events are encoded correctly before
//     they enter the NoC.
//
// Probe depth
// -----------
//   Default: 1024 samples per trigger (adjustable via DATA_DEPTH).
//   At 100 MHz, 1024 samples = 10.24 µs of capture. For N-MNIST
//   inference (~25 ms window), trigger on window_advance and
//   increase DATA_DEPTH to 4096 if BRAM budget allows.
//
// How to use
// ----------
//   1. Set this file as the synthesis top (see synth_ila.tcl).
//   2. In Vivado Hardware Manager, select the ILA core by index.
//   3. Set trigger conditions (see comments per ILA below).
//   4. Arm the trigger and inject DVS events.
//   5. Download captured waveform as CSV for benchmark.py.
//
// Resource overhead of ILA
// ------------------------
//   Each ILA core uses ~2× BRAM18K for the capture buffer.
//   Four cores at depth 1024 = ~8 BRAM18K additional.
//   Total with ILA: ~68 BRAM18K / 270 available = 25%.
//   LUT overhead: ~2000 additional LUTs for probe muxes.
//
// Author:   NeuraEdge / Rahul Verma
// Version:  2.0.0
// FIXED: Replaced explicit ILA instantiations (required IP generation)
//        with MARK_DEBUG attribute flow (works with any Vivado version).
// v2.0 -- Converted to SystemVerilog (.sv). No functional changes.
// License:  Apache 2.0
// ============================================================

`timescale 1ns / 1ps

module neuraedge_top_ila #(
    parameter int ILA_DATA_DEPTH = 1024   // samples per trigger; power of 2
)(
    input  logic clk,
    input  logic rst_n,

    // ---- DVS camera (pass-through to neuraedge_top) ----------
    input  logic [5:0]   dvs_x,
    input  logic [5:0]   dvs_y,
    input  logic         dvs_polarity,
    input  logic [19:0]  dvs_timestamp,
    input  logic         dvs_valid,
    output logic         dvs_ready,
    input  logic         window_advance,

    // ---- SPI weight loader -----------------------------------
    input  logic  spi_sclk,
    input  logic  spi_mosi,
    input  logic  spi_cs_n,

    // ---- UART -----------------------------------------------
    output logic  uart_tx,

    // ---- Debug LEDs (direct from neuraedge_top) -------------
    output logic [15:0]  led
);

    // --------------------------------------------------------
    // Internal signals tapped from neuraedge_top
    // These are routed as (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *) to prevent
    // Vivado from optimising them away during synthesis.
    // --------------------------------------------------------

    // Spike vectors — all 4 clusters
    (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *) logic [63:0] spike_c00, spike_c10, spike_c01, spike_c11;

    // Encoder
    (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *) logic [13:0] enc_pkt_data;
    (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *) logic enc_pkt_valid;
    (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *) logic [31:0] enc_events_accepted;
    (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *) logic enc_fifo_overflow;

    // Learning engine write-back (cluster[0][0])
    (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *) logic [5:0]  le_wr_neuron_c00;
    (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *) logic [8:0]  le_wr_syn_c00;
    (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *) logic [7:0]  le_wr_data_c00;
    (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *) logic le_we_c00;

    // Output classifier
    (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *) logic [15:0] spike_accum_0, spike_accum_1;
    (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *) logic [19:0] infer_timer;
    (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *) logic result_valid;
    (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *) logic [3:0]  best_class;
    (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *) logic uart_busy_mon;

    // SPI loader
    (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *) logic [39:0] spi_shift_mon;
    (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *) logic [5:0]  spi_bit_cnt_mon;

    // --------------------------------------------------------
    // neuraedge_top instantiation
    // --------------------------------------------------------
    neuraedge_top #(
        .NUM_COLS      (2),
        .NUM_ROWS      (2),
        .NUM_NEURONS   (64),
        .NUM_SYNAPSES  (128), // power-optimised default
        .WEIGHT_W      (8),
        .MEM_WIDTH     (8),
        .THRESHOLD     (200),
        .LEAK_SHIFT    (1),
        .A_PLUS        (4),
        .A_MINUS       (2),
        .TRACE_W       (6),
        .TRACE_INCR    (16),
        .TRACE_DECAY   (3),
        .MAX_WEIGHT    (255),
        .MIN_WEIGHT    (0),
        .SENSOR_W      (34),
        .SENSOR_H      (34),
        .NEURON_ADDR_W (6),
        .TIMESTAMP_W   (20),
        .WINDOW_US     (1000),
        .WINDOW_MODE   (0),
        .NUM_CLASSES   (10),
        .UART_CLK_DIV  (868)
    ) u_top (
        .clk           (clk),
        .rst_n         (rst_n),
        .dvs_x         (dvs_x),
        .dvs_y         (dvs_y),
        .dvs_polarity  (dvs_polarity),
        .dvs_timestamp (dvs_timestamp),
        .dvs_valid     (dvs_valid),
        .dvs_ready     (dvs_ready),
        .window_advance(window_advance),
        .spi_sclk      (spi_sclk),
        .spi_mosi      (spi_mosi),
        .spi_cs_n      (spi_cs_n),
        .uart_tx       (uart_tx),
        .led           (led)
    );

    // --------------------------------------------------------
    // Hierarchical signal taps
    // These paths reference signals inside the generate block.
    // Vivado resolves these at elaboration using the genvar
    // instance names: gen_col[C].gen_row[R].u_neuron etc.
    //
    // If Vivado cannot resolve the path, use the ILA Tcl flow
    // (see synth_ila.tcl) to mark signals with set_property
    // MARK_DEBUG instead of these assignments.
    // --------------------------------------------------------

    assign spike_c00 = u_top.spike_out[0][0];
    assign spike_c10 = u_top.spike_out[1][0];
    assign spike_c01 = u_top.spike_out[0][1];
    assign spike_c11 = u_top.spike_out[1][1];

    assign enc_pkt_data       = u_top.enc_pkt_data;
    assign enc_pkt_valid      = u_top.enc_pkt_valid;
    assign enc_events_accepted= u_top.enc_events_accepted;
    assign enc_fifo_overflow  = u_top.enc_fifo_overflow;

    assign le_wr_neuron_c00   = u_top.le_wr_neuron[0][0];
    assign le_wr_syn_c00      = u_top.le_wr_syn[0][0];
    assign le_wr_data_c00     = u_top.le_wr_data[0][0];
    assign le_we_c00          = u_top.le_we[0][0];

    assign spike_accum_0      = u_top.spike_accum[0];
    assign spike_accum_1      = u_top.spike_accum[1];
    assign infer_timer        = u_top.infer_timer;
    assign result_valid       = u_top.result_valid;
    assign best_class         = u_top.best_class;
    assign uart_busy_mon      = u_top.uart_busy;

    assign spi_shift_mon      = u_top.spi_shift;
    assign spi_bit_cnt_mon    = u_top.spi_bit_cnt;

    // --------------------------------------------------------
    // ILA Debug Probes — MARK_DEBUG flow (Vivado auto-insert)
    //
    // The ILA modules (ila_spike_monitor etc.) are Xilinx IP cores
    // that cannot be instantiated as plain Verilog modules without
    // first generating them via create_ip. This causes:
    //   ERROR [Synth 8-439] module 'ila_spike_monitor' not found
    //
    // FIX: Use (* MARK_DEBUG = "TRUE" *) attribute flow instead.
    // Vivado automatically inserts ILA cores during implementation
    // for any signal tagged with MARK_DEBUG. The probe signals
    // declared above already carry (* KEEP="TRUE", MARK_DEBUG="TRUE" *).
    //
    // To capture in Hardware Manager:
    //   1. Run implementation (not just synthesis).
    //   2. Open Hardware Manager → Program Device.
    //   3. ILA cores appear automatically — one per clock domain.
    //   4. Set trigger conditions on probe signals by name.
    //   5. Use ila_capture_to_csv.tcl to export captured data.
    //
    // Probe signals tagged for capture:
    //   spike_c00, spike_c10, spike_c01, spike_c11  — spike activity
    //   enc_pkt_data, enc_pkt_valid                  — encoder output
    //   le_wr_neuron_c00, le_wr_syn_c00, le_wr_data_c00, le_we_c00
    //                                                — STDP writes
    //   spike_accum_0/1, infer_timer, result_valid   — classifier
    //   uart_busy_mon, best_class                    — UART output
    //   spi_shift_mon, spi_bit_cnt_mon               — SPI loader
    // --------------------------------------------------------

endmodule
