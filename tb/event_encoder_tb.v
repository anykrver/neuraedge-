// ============================================================
// Module:   event_encoder_tb
// Purpose:  SystemVerilog testbench for event_encoder.
//           Uses 8×8 sensor / 2×2 mesh for clean arithmetic.
//
// Run (Icarus Verilog):
//   iverilog -g2012 -o sim_enc_tb \
//     rtl/event_encoder.v testbench/event_encoder_tb.v
//   vvp sim_enc_tb
// ============================================================

`timescale 1ns / 1ps

module event_encoder_tb;

    // ---- Parameters ----------------------------------------
    localparam SENSOR_W      = 8;
    localparam SENSOR_H      = 8;
    localparam NUM_COLS      = 2;
    localparam NUM_ROWS      = 2;
    localparam NEURON_ADDR_W = 6;
    localparam TIMESTAMP_W   = 20;
    localparam WINDOW_US     = 1000;
    localparam WINDOW_MODE   = 0;
    localparam FIFO_DEPTH    = 4;

    localparam COORD_W  = $clog2(NUM_COLS);
    localparam PACKET_W = 4 * COORD_W + NEURON_ADDR_W;  // 10
    localparam TILE_W   = SENSOR_W / NUM_COLS;            // 4
    localparam TILE_H   = SENSOR_H / NUM_ROWS;            // 4

    localparam SENSOR_X_W = $clog2(SENSOR_W);
    localparam SENSOR_Y_W = $clog2(SENSOR_H);

    // ---- Packet field positions ----------------------------
    localparam DST_COL_HI = PACKET_W - 1;
    localparam DST_COL_LO = PACKET_W - COORD_W;
    localparam DST_ROW_HI = DST_COL_LO - 1;
    localparam DST_ROW_LO = DST_COL_LO - COORD_W;
    localparam SRC_COL_HI = DST_ROW_LO - 1;
    localparam SRC_COL_LO = DST_ROW_LO - COORD_W;
    localparam SRC_ROW_HI = SRC_COL_LO - 1;
    localparam SRC_ROW_LO = SRC_COL_LO - COORD_W;

    // ---- DUT ports -----------------------------------------
    reg  clk, rst_n;
    reg  [SENSOR_X_W-1:0]  dvs_x;
    reg  [SENSOR_Y_W-1:0]  dvs_y;
    reg                    dvs_polarity;
    reg  [TIMESTAMP_W-1:0] dvs_timestamp;
    reg                    dvs_valid;
    wire                   dvs_ready;
    reg                    window_advance;
    wire [PACKET_W-1:0]    pkt_data;
    wire                   pkt_valid;
    reg                    pkt_ready;
    wire [31:0]            events_accepted, events_dropped;
    wire                   fifo_overflow;

    // ---- DUT -----------------------------------------------
    event_encoder #(
        .SENSOR_W      (SENSOR_W),
        .SENSOR_H      (SENSOR_H),
        .NUM_COLS      (NUM_COLS),
        .NUM_ROWS      (NUM_ROWS),
        .NEURON_ADDR_W (NEURON_ADDR_W),
        .TIMESTAMP_W   (TIMESTAMP_W),
        .WINDOW_US     (WINDOW_US),
        .WINDOW_MODE   (WINDOW_MODE),
        .FIFO_DEPTH    (FIFO_DEPTH)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .dvs_x           (dvs_x),
        .dvs_y           (dvs_y),
        .dvs_polarity    (dvs_polarity),
        .dvs_timestamp   (dvs_timestamp),
        .dvs_valid       (dvs_valid),
        .dvs_ready       (dvs_ready),
        .window_advance  (window_advance),
        .pkt_data        (pkt_data),
        .pkt_valid       (pkt_valid),
        .pkt_ready       (pkt_ready),
        .events_accepted (events_accepted),
        .events_dropped  (events_dropped),
        .fifo_overflow   (fifo_overflow)
    );

    // ---- Clock ---------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // ---- Tasks ---------------------------------------------
    task send_event;
        input integer x, y, pol, ts;
        begin
            @(negedge clk);
            dvs_x = x; dvs_y = y; dvs_polarity = pol;
            dvs_timestamp = ts; dvs_valid = 1;
            @(posedge clk); #1;
            dvs_valid = 0;
        end
    endtask

    function [NEURON_ADDR_W-1:0] exp_neuron;
        input integer x, y, pol;
        integer lx, ly;
        begin
            lx = x % TILE_W;
            ly = y % TILE_H;
            exp_neuron = (ly * TILE_W + lx) * 2 + pol;
        end
    endfunction

    integer pass_count = 0, fail_count = 0;

    task check;
        input [255:0] label;
        input cond;
        begin
            if (cond) begin $display("  [PASS] %0s", label); pass_count++; end
            else      begin $display("  [FAIL] %0s", label); fail_count++; end
        end
    endtask

    initial begin
        $dumpfile("sim/event_encoder_tb.vcd");
        $dumpvars(0, event_encoder_tb);
    end

    integer i;

    // ================================================================
    initial begin
        $display("\n==============================================");
        $display(" NeuraEdge — event_encoder SystemVerilog TB");
        $display(" Sensor=%0dx%0d  Mesh=%0dx%0d  Tile=%0dx%0d",
                 SENSOR_W, SENSOR_H, NUM_COLS, NUM_ROWS, TILE_W, TILE_H);
        $display("==============================================\n");

        rst_n = 0; dvs_valid = 0; pkt_ready = 1;
        dvs_x = 0; dvs_y = 0; dvs_polarity = 0;
        dvs_timestamp = 0; window_advance = 0;
        repeat(4) @(posedge clk); #1;
        rst_n = 1;
        repeat(2) @(posedge clk); #1;

        // ---- T1: Reset ---------------------------------
        $display("[TEST 1] Reset state");
        check("pkt_valid=0",       pkt_valid       === 1'b0);
        check("events_accepted=0", events_accepted === 32'd0);

        // ---- T2: ON event → tile(0,0) neuron 13 -------
        $display("\n[TEST 2] ON event x=2,y=1 → tile(0,0) neuron=13");
        send_event(2, 1, 1, 0);
        repeat(3) @(posedge clk); #1;
        $display("    pkt=%0b  dst_col=%0d dst_row=%0d neuron=%0d",
                 pkt_data,
                 pkt_data[DST_COL_HI:DST_COL_LO],
                 pkt_data[DST_ROW_HI:DST_ROW_LO],
                 pkt_data[NEURON_ADDR_W-1:0]);
        check("pkt_valid",         pkt_valid === 1'b1);
        check("dst_col=0",         pkt_data[DST_COL_HI:DST_COL_LO] === 1'd0);
        check("dst_row=0",         pkt_data[DST_ROW_HI:DST_ROW_LO] === 1'd0);
        check("neuron=13",         pkt_data[NEURON_ADDR_W-1:0] === exp_neuron(2,1,1));

        // ---- T3: Tile routing (top-right pixel) --------
        $display("\n[TEST 3] Top-right pixel x=7,y=0 → tile(1,0)");
        rst_n = 0; repeat(2) @(posedge clk); #1; rst_n = 1;
        pkt_ready = 1; repeat(2) @(posedge clk); #1;
        send_event(7, 0, 1, 0);
        repeat(3) @(posedge clk); #1;
        check("dst_col=1 for x=7", pkt_data[DST_COL_HI:DST_COL_LO] === 1'd1);
        check("dst_row=0 for y=0", pkt_data[DST_ROW_HI:DST_ROW_LO] === 1'd0);

        // ---- T4: src == dst ----------------------------
        $display("\n[TEST 4] src_col==dst_col, src_row==dst_row");
        check("src_col==dst_col",
              pkt_data[SRC_COL_HI:SRC_COL_LO] ===
              pkt_data[DST_COL_HI:DST_COL_LO]);
        check("src_row==dst_row",
              pkt_data[SRC_ROW_HI:SRC_ROW_LO] ===
              pkt_data[DST_ROW_HI:DST_ROW_LO]);

        // ---- T5: Backpressure --------------------------
        $display("\n[TEST 5] Backpressure: pkt_ready=0");
        rst_n = 0; repeat(2) @(posedge clk); #1; rst_n = 1;
        pkt_ready = 0; repeat(2) @(posedge clk); #1;
        send_event(0, 0, 1, 0);
        repeat(4) @(posedge clk); #1;
        check("pkt_valid high when pkt_ready=0", pkt_valid === 1'b1);
        pkt_ready = 1;
        repeat(2) @(posedge clk); #1;
        check("packet consumed after pkt_ready=1", pkt_valid === 1'b0);

        // ---- T6: events_accepted counter ---------------
        $display("\n[TEST 6] events_accepted counter");
        rst_n = 0; repeat(2) @(posedge clk); #1; rst_n = 1;
        pkt_ready = 1; repeat(2) @(posedge clk); #1;
        for (i = 0; i < 6; i = i + 1) begin
            send_event(i, 0, i[0], i * 10);
            repeat(1) @(posedge clk);
        end
        repeat(4) @(posedge clk); #1;
        check("events_accepted=6", events_accepted === 32'd6);

        // ---- Summary -----------------------------------
        $display("\n==============================================");
        $display(" Results: %0d / %0d passed",
                 pass_count, pass_count + fail_count);
        $display("==============================================\n");
        if (fail_count == 0) $display("ALL TESTS PASSED\n");
        else                  $display("%0d FAILED\n", fail_count);
        $finish;
    end

    initial begin #500000; $display("[TIMEOUT]"); $finish; end

endmodule
