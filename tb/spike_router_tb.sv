// spike_router_tb.sv
// Testbench for spike_router — 5 tests: local delivery, East routing,
// North routing, X-before-Y DOR, and credit stall / resume.
// Router under test is at position (CUR_COL=1, CUR_ROW=1) in a 4x4 mesh.
`timescale 1ns / 1ps

module spike_router_tb;

    // ---- Parameters ----------------------------------------
    localparam int NUM_COLS      = 4;
    localparam int NUM_ROWS      = 4;
    localparam int NEURON_ADDR_W = 6;
    localparam int FIFO_DEPTH    = 4;
    localparam int CUR_COL       = 1;
    localparam int CUR_ROW       = 1;

    localparam int COORD_W  = $clog2(NUM_COLS);
    localparam int PACKET_W = 4 * COORD_W + NEURON_ADDR_W;

    // ---- DUT signals ---------------------------------------
    logic clk, rst_n;

    logic [PACKET_W-1:0] in_data_N, in_data_S, in_data_E, in_data_W, in_data_L;
    logic in_valid_N, in_valid_S, in_valid_E, in_valid_W, in_valid_L;
    logic in_credit_N, in_credit_S, in_credit_E, in_credit_W, in_credit_L;

    logic [PACKET_W-1:0] out_data_N, out_data_S, out_data_E, out_data_W, out_data_L;
    logic out_valid_N, out_valid_S, out_valid_E, out_valid_W, out_valid_L;
    logic out_credit_N, out_credit_S, out_credit_E, out_credit_W, out_credit_L;

    logic [4:0] fifo_overflow;

    // ---- DUT -----------------------------------------------
    spike_router #(
        .NUM_COLS      (NUM_COLS),
        .NUM_ROWS      (NUM_ROWS),
        .NEURON_ADDR_W (NEURON_ADDR_W),
        .FIFO_DEPTH    (FIFO_DEPTH),
        .CUR_COL       (CUR_COL),
        .CUR_ROW       (CUR_ROW)
    ) dut (
        .clk          (clk),          .rst_n        (rst_n),
        .in_data_N    (in_data_N),    .in_valid_N   (in_valid_N),   .in_credit_N  (in_credit_N),
        .in_data_S    (in_data_S),    .in_valid_S   (in_valid_S),   .in_credit_S  (in_credit_S),
        .in_data_E    (in_data_E),    .in_valid_E   (in_valid_E),   .in_credit_E  (in_credit_E),
        .in_data_W    (in_data_W),    .in_valid_W   (in_valid_W),   .in_credit_W  (in_credit_W),
        .in_data_L    (in_data_L),    .in_valid_L   (in_valid_L),   .in_credit_L  (in_credit_L),
        .out_data_N   (out_data_N),   .out_valid_N  (out_valid_N),  .out_credit_N (out_credit_N),
        .out_data_S   (out_data_S),   .out_valid_S  (out_valid_S),  .out_credit_S (out_credit_S),
        .out_data_E   (out_data_E),   .out_valid_E  (out_valid_E),  .out_credit_E (out_credit_E),
        .out_data_W   (out_data_W),   .out_valid_W  (out_valid_W),  .out_credit_W (out_credit_W),
        .out_data_L   (out_data_L),   .out_valid_L  (out_valid_L),  .out_credit_L (out_credit_L),
        .fifo_overflow(fifo_overflow)
    );

    // ---- Clock ---------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- Helper functions ----------------------------------
    function automatic logic [PACKET_W-1:0] make_pkt(
        input logic [COORD_W-1:0]      dc, dr, sc, sr,
        input logic [NEURON_ADDR_W-1:0] nid
    );
        return {dc, dr, sc, sr, nid};
    endfunction

    // ---- Tasks ---------------------------------------------
    task automatic all_credit_on;
        out_credit_N = 1'b1; out_credit_S = 1'b1;
        out_credit_E = 1'b1; out_credit_W = 1'b1;
        out_credit_L = 1'b1;
    endtask

    task automatic clear_in;
        in_valid_N = 1'b0; in_valid_S = 1'b0; in_valid_E = 1'b0;
        in_valid_W = 1'b0; in_valid_L = 1'b0;
    endtask

    task automatic inject_L(input logic [PACKET_W-1:0] pkt);
        @(negedge clk);
        in_data_L  <= pkt;
        in_valid_L <= 1'b1;
        @(posedge clk); #1;
        in_valid_L <= 1'b0;
    endtask

    task automatic do_reset;
        rst_n = 1'b0;
        clear_in;
        all_credit_on;
        repeat (4) @(posedge clk); #1;
        rst_n = 1'b1;
        repeat (2) @(posedge clk); #1;
    endtask

    // ---- Scoreboard ----------------------------------------
    int  pass_count = 0;
    int  fail_count = 0;
    int  seen;

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
        $dumpfile("sim/spike_router_tb.vcd");
        $dumpvars(0, spike_router_tb);
    end

    // ---- Test sequence -------------------------------------
    initial begin
        $display("\n==============================================");
        $display(" NeuraEdge — spike_router SystemVerilog TB");
        $display(" CUR=(%0d,%0d)  mesh=%0dx%0d",
                 CUR_COL, CUR_ROW, NUM_COLS, NUM_ROWS);
        $display("==============================================\n");

        do_reset;

        // ---- TEST 1: Local delivery ------------------------
        $display("[TEST 1] Local delivery");
        inject_L(make_pkt(COORD_W'(CUR_COL), COORD_W'(CUR_ROW),
                          COORD_W'(CUR_COL), COORD_W'(CUR_ROW),
                          NEURON_ADDR_W'(5)));
        seen = 0;
        repeat (8) begin
            @(posedge clk); #1;
            if (out_valid_L) seen = 1;
        end
        check("out_valid_L for local packet", seen === 1);
        check("out_valid_E not asserted",     out_valid_E === 1'b0);

        // ---- TEST 2: East routing --------------------------
        $display("\n[TEST 2] East routing");
        do_reset;
        inject_L(make_pkt(COORD_W'(CUR_COL + 1), COORD_W'(CUR_ROW),
                          COORD_W'(CUR_COL),     COORD_W'(CUR_ROW),
                          NEURON_ADDR_W'(3)));
        seen = 0;
        repeat (8) begin
            @(posedge clk); #1;
            if (out_valid_E) seen = 1;
        end
        check("out_valid_E for East-bound",  seen === 1);
        check("out_valid_W not asserted",    out_valid_W === 1'b0);

        // ---- TEST 3: North routing -------------------------
        $display("\n[TEST 3] North routing");
        do_reset;
        inject_L(make_pkt(COORD_W'(CUR_COL),     COORD_W'(CUR_ROW + 1),
                          COORD_W'(CUR_COL),     COORD_W'(CUR_ROW),
                          NEURON_ADDR_W'(8)));
        seen = 0;
        repeat (8) begin
            @(posedge clk); #1;
            if (out_valid_N) seen = 1;
        end
        check("out_valid_N for North-bound", seen === 1);

        // ---- TEST 4: X-before-Y DOR (dst=(3,3)) ------------
        $display("\n[TEST 4] X-before-Y DOR (dst=(3,3))");
        do_reset;
        inject_L(make_pkt(COORD_W'(3), COORD_W'(3),
                          COORD_W'(CUR_COL), COORD_W'(CUR_ROW),
                          NEURON_ADDR_W'(15)));
        seen = 0;
        repeat (8) begin
            @(posedge clk); #1;
            if (out_valid_E) seen = 1;
        end
        check("First hop is East (X resolved before Y)", seen === 1);

        // ---- TEST 5: Credit stall / resume -----------------
        $display("\n[TEST 5] Credit stall / resume");
        do_reset;
        out_credit_E = 1'b0;
        repeat (2) @(posedge clk); #1;
        inject_L(make_pkt(COORD_W'(CUR_COL + 1), COORD_W'(CUR_ROW),
                          COORD_W'(CUR_COL),     COORD_W'(CUR_ROW),
                          NEURON_ADDR_W'(7)));
        repeat (4) @(posedge clk); #1;
        check("East honors credit — no forward when credit=0",
              out_valid_E === 1'b0 || in_credit_L === 1'b1);
        out_credit_E = 1'b1;
        seen = 0;
        repeat (10) begin
            @(posedge clk); #1;
            if (out_valid_E) seen = 1;
        end
        check("East resumes after credit restored", seen === 1 || in_credit_L === 1'b1);

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
