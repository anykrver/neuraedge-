// event_encoder_tb.sv
// Testbench for event_encoder — 6 tests: reset state, ON event tile/
// neuron mapping, tile routing, src==dst field consistency, backpressure
// flow control, and events_accepted counter accuracy.
`timescale 1ns / 1ps

module event_encoder_tb;

    // ---- Parameters ----------------------------------------
    localparam int SENSOR_W      = 8;
    localparam int SENSOR_H      = 8;
    localparam int NUM_COLS      = 2;
    localparam int NUM_ROWS      = 2;
    localparam int NEURON_ADDR_W = 6;
    localparam int TIMESTAMP_W   = 20;
    localparam int WINDOW_US     = 1000;
    localparam int WINDOW_MODE   = 0;
    localparam int FIFO_DEPTH    = 4;

    localparam int COORD_W    = $clog2(NUM_COLS);
    localparam int PACKET_W   = 4 * COORD_W + NEURON_ADDR_W;  // 10
    localparam int TILE_W     = SENSOR_W / NUM_COLS;           // 4
    localparam int TILE_H     = SENSOR_H / NUM_ROWS;           // 4
    localparam int SENSOR_X_W = $clog2(SENSOR_W);
    localparam int SENSOR_Y_W = $clog2(SENSOR_H);

    // ---- Packet field positions ----------------------------
    localparam int DST_COL_HI = PACKET_W - 1;
    localparam int DST_COL_LO = PACKET_W - COORD_W;
    localparam int DST_ROW_HI = DST_COL_LO - 1;
    localparam int DST_ROW_LO = DST_COL_LO - COORD_W;
    localparam int SRC_COL_HI = DST_ROW_LO - 1;
    localparam int SRC_COL_LO = DST_ROW_LO - COORD_W;
    localparam int SRC_ROW_HI = SRC_COL_LO - 1;
    localparam int SRC_ROW_LO = SRC_COL_LO - COORD_W;

    // ---- DUT signals ---------------------------------------
    logic clk, rst_n;
    logic [SENSOR_X_W-1:0]  dvs_x;
    logic [SENSOR_Y_W-1:0]  dvs_y;
    logic                   dvs_polarity;
    logic [TIMESTAMP_W-1:0] dvs_timestamp;
    logic                   dvs_valid;
    logic                   dvs_ready;
    logic                   window_advance;
    logic [PACKET_W-1:0]    pkt_data;
    logic                   pkt_valid;
    logic                   pkt_ready;
    logic [31:0]            events_accepted;
    logic [31:0]            events_dropped;
    logic                   fifo_overflow;

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
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- Helper function: expected neuron ID ---------------
    function automatic logic [NEURON_ADDR_W-1:0] exp_neuron(
        input int x, y, pol
    );
        automatic int lx = x % TILE_W;
        automatic int ly = y % TILE_H;
        return NEURON_ADDR_W'((ly * TILE_W + lx) * 2 + pol);
    endfunction

    // ---- Tasks ---------------------------------------------
    task automatic send_event(input int x, y, pol, ts);
        @(negedge clk);
        dvs_x         <= SENSOR_X_W'(x);
        dvs_y         <= SENSOR_Y_W'(y);
        dvs_polarity  <= logic'(pol);
        dvs_timestamp <= TIMESTAMP_W'(ts);
        dvs_valid     <= 1'b1;
        @(posedge clk); #1;
        dvs_valid <= 1'b0;
    endtask

    // ---- Scoreboard ----------------------------------------
    int pass_count = 0;
    int fail_count = 0;

    task automatic check(input string label, input logic cond);
        if (cond) begin
            $display("  [PASS] %s", label);
            pass_count++;
        end else begin
            $display("  [FAIL] %s", label);
            fail_count++;
        end
    endtask

    // ---- Waveform dump -------------------------------------
    initial begin
        $dumpfile("sim/event_encoder_tb.vcd");
        $dumpvars(0, event_encoder_tb);
    end

    // ---- Test sequence -------------------------------------
    initial begin
        $display("\n==============================================");
        $display(" NeuraEdge — event_encoder SystemVerilog TB");
        $display(" Sensor=%0dx%0d  Mesh=%0dx%0d  Tile=%0dx%0d",
                 SENSOR_W, SENSOR_H, NUM_COLS, NUM_ROWS, TILE_W, TILE_H);
        $display("==============================================\n");

        rst_n = 1'b0; dvs_valid = 1'b0; pkt_ready = 1'b1;
        dvs_x = '0; dvs_y = '0; dvs_polarity = 1'b0;
        dvs_timestamp = '0; window_advance = 1'b0;
        repeat (4) @(posedge clk); #1;
        rst_n = 1'b1;
        repeat (2) @(posedge clk); #1;

        // ---- TEST 1: Reset state ---------------------------
        $display("[TEST 1] Reset state");
        check("pkt_valid=0",       pkt_valid       === 1'b0);
        check("events_accepted=0", events_accepted === 32'd0);

        // ---- TEST 2: ON event → tile(0,0), neuron 13 ------
        $display("\n[TEST 2] ON event x=2,y=1 → tile(0,0) neuron=13");
        send_event(2, 1, 1, 0);
        repeat (3) @(posedge clk); #1;
        $display("    pkt=%010b  dst_col=%0d  dst_row=%0d  neuron=%0d",
                 pkt_data,
                 pkt_data[DST_COL_HI:DST_COL_LO],
                 pkt_data[DST_ROW_HI:DST_ROW_LO],
                 pkt_data[NEURON_ADDR_W-1:0]);
        check("pkt_valid",   pkt_valid === 1'b1);
        check("dst_col=0",   pkt_data[DST_COL_HI:DST_COL_LO] === COORD_W'(0));
        check("dst_row=0",   pkt_data[DST_ROW_HI:DST_ROW_LO] === COORD_W'(0));
        check("neuron=13",   pkt_data[NEURON_ADDR_W-1:0]      === exp_neuron(2, 1, 1));

        // ---- TEST 3: Top-right pixel → tile(1,0) -----------
        $display("\n[TEST 3] Top-right pixel x=7,y=0 → tile(1,0)");
        rst_n = 1'b0; repeat (2) @(posedge clk); #1;
        rst_n = 1'b1; pkt_ready = 1'b1;
        repeat (2) @(posedge clk); #1;
        send_event(7, 0, 1, 0);
        repeat (3) @(posedge clk); #1;
        check("dst_col=1 for x=7", pkt_data[DST_COL_HI:DST_COL_LO] === COORD_W'(1));
        check("dst_row=0 for y=0", pkt_data[DST_ROW_HI:DST_ROW_LO] === COORD_W'(0));

        // ---- TEST 4: src_col == dst_col, src_row == dst_row
        $display("\n[TEST 4] Source fields match destination");
        check("src_col == dst_col",
              pkt_data[SRC_COL_HI:SRC_COL_LO] === pkt_data[DST_COL_HI:DST_COL_LO]);
        check("src_row == dst_row",
              pkt_data[SRC_ROW_HI:SRC_ROW_LO] === pkt_data[DST_ROW_HI:DST_ROW_LO]);

        // ---- TEST 5: Backpressure --------------------------
        $display("\n[TEST 5] Backpressure: pkt_ready=0");
        rst_n = 1'b0; repeat (2) @(posedge clk); #1;
        rst_n = 1'b1; pkt_ready = 1'b0;
        repeat (2) @(posedge clk); #1;
        send_event(0, 0, 1, 0);
        repeat (4) @(posedge clk); #1;
        check("pkt_valid held when pkt_ready=0", pkt_valid === 1'b1);
        pkt_ready = 1'b1;
        repeat (2) @(posedge clk); #1;
        check("Packet consumed after pkt_ready=1", pkt_valid === 1'b0);

        // ---- TEST 6: events_accepted counter ---------------
        $display("\n[TEST 6] events_accepted counter");
        rst_n = 1'b0; repeat (2) @(posedge clk); #1;
        rst_n = 1'b1; pkt_ready = 1'b1;
        repeat (2) @(posedge clk); #1;
        for (int i = 0; i < 6; i++) begin
            send_event(i, 0, i[0], i * 10);
            @(posedge clk);
        end
        repeat (4) @(posedge clk); #1;
        check("events_accepted=6", events_accepted === 32'd6);

        // ---- Summary ---------------------------------------
        $display("\n==============================================");
        $display(" Results: %0d / %0d passed",
                 pass_count, pass_count + fail_count);
        $display("==============================================\n");
        if (fail_count == 0) $display("ALL TESTS PASSED\n");
        else                  $display("%0d FAILED\n", fail_count);
        $finish;
    end

    // ---- Watchdog ------------------------------------------
    initial begin
        #500_000;
        $display("[TIMEOUT] Simulation exceeded 500us");
        $finish;
    end

endmodule
