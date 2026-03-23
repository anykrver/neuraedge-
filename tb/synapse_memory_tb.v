// ============================================================
// Module:   synapse_memory_tb
// Purpose:  SystemVerilog testbench for synapse_memory.
//
// Version: 1.1.0
// FIX BUG-2.1: RTL synapse_memory.v now has sim-init for Icarus
//   portability. TEST 1 (b0==0 after reset) passes on all tools.
//
// Run (Icarus Verilog):
//   iverilog -g2012 -o sim/syn_tb \
//       rtl/synapse_memory.v testbench/synapse_memory_tb.v
//   vvp sim_syn_tb
// ============================================================

`timescale 1ns / 1ps

module synapse_memory_tb;

    // ---- DUT parameters ------------------------------------
    localparam NUM_NEURONS   = 64;
    localparam NUM_SYNAPSES  = 512;
    localparam WIDTH         = 8;
    localparam NUM_BANKS     = 4;
    localparam MAX_WEIGHT    = 255;
    localparam MIN_WEIGHT    = 0;

    localparam NEURON_W = $clog2(NUM_NEURONS);   // 6
    localparam SYN_W    = $clog2(NUM_SYNAPSES);  // 9

    // ---- DUT ports -----------------------------------------
    reg                   clk, rst_n;
    reg  [NEURON_W-1:0]   wr_neuron, rd_neuron;
    reg  [SYN_W-1:0]      wr_syn, rd_syn_base;
    reg  [WIDTH-1:0]      wr_data;
    reg                   we;
    wire [WIDTH-1:0]      rd_data_b0, rd_data_b1, rd_data_b2, rd_data_b3;
    wire                  rd_valid;

    // ---- DUT -----------------------------------------------
    synapse_memory #(
        .NUM_NEURONS  (NUM_NEURONS),
        .NUM_SYNAPSES (NUM_SYNAPSES),
        .WIDTH        (WIDTH),
        .NUM_BANKS    (NUM_BANKS),
        .MAX_WEIGHT   (MAX_WEIGHT),
        .MIN_WEIGHT   (MIN_WEIGHT)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .wr_neuron    (wr_neuron),
        .wr_syn       (wr_syn),
        .wr_data      (wr_data),
        .we           (we),
        .rd_neuron    (rd_neuron),
        .rd_syn_base  (rd_syn_base),
        .rd_data_b0   (rd_data_b0),
        .rd_data_b1   (rd_data_b1),
        .rd_data_b2   (rd_data_b2),
        .rd_data_b3   (rd_data_b3),
        .rd_valid     (rd_valid)
    );

    // ---- Clock ---------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // ---- Tasks ---------------------------------------------
    task do_write;
        input integer nid, syn, w;
        begin
            @(negedge clk);
            wr_neuron <= nid; wr_syn <= syn; wr_data <= w; we <= 1;
            @(posedge clk); #1;
            we <= 0;
        end
    endtask

    task do_read;
        input integer nid, syn_base;
        begin
            @(negedge clk);
            rd_neuron <= nid; rd_syn_base <= syn_base;
            @(posedge clk); #1;
        end
    endtask

    integer pass_count = 0;
    integer fail_count = 0;

    task check;
        input [255:0] label;
        input         cond;
        begin
            if (cond) begin
                $display("  [PASS] %0s", label);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s", label);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial $dumpfile("sim/synapse_memory_tb.vcd");
    initial $dumpvars(0, synapse_memory_tb);

    // ================================================================
    // TEST SEQUENCE
    // ================================================================
    initial begin
        $display("\n==============================================");
        $display(" NeuraEdge — synapse_memory SystemVerilog TB");
        $display("==============================================\n");

        rst_n = 0; we = 0; wr_neuron = 0; wr_syn = 0;
        wr_data = 0; rd_neuron = 0; rd_syn_base = 0;
        repeat(4) @(posedge clk); #1;
        rst_n = 1;
        repeat(2) @(posedge clk); #1;

        // ---- Test 1: Reset state ---------------------------
        $display("[TEST 1] Post-reset reads = 0");
        do_read(0, 0);
        check("b0==0 after reset", rd_data_b0 === 8'd0);
        check("b1==0 after reset", rd_data_b1 === 8'd0);
        check("b2==0 after reset", rd_data_b2 === 8'd0);
        check("b3==0 after reset", rd_data_b3 === 8'd0);
        check("rd_valid high",     rd_valid    === 1'b1);

        // ---- Test 2: Write / read --------------------------
        $display("\n[TEST 2] Write/read (n=0, syn=0, w=150)");
        do_write(0, 0, 150);
        repeat(2) @(posedge clk); #1;
        do_read(0, 0);
        check("Read back 150 from bank0", rd_data_b0 === 8'd150);

        // ---- Test 3: 4-bank parallel read ------------------
        $display("\n[TEST 3] 4-bank parallel read (n=1, syns 16-19)");
        do_write(1, 16, 11); do_write(1, 17, 22);
        do_write(1, 18, 33); do_write(1, 19, 44);
        repeat(2) @(posedge clk); #1;
        do_read(1, 16);
        $display("    b0=%0d b1=%0d b2=%0d b3=%0d",
                 rd_data_b0, rd_data_b1, rd_data_b2, rd_data_b3);
        check("b0==11", rd_data_b0 === 8'd11);
        check("b1==22", rd_data_b1 === 8'd22);
        check("b2==33", rd_data_b2 === 8'd33);
        check("b3==44", rd_data_b3 === 8'd44);

        // ---- Test 4: Multi-neuron isolation ----------------
        $display("\n[TEST 4] Multi-neuron isolation");
        rst_n = 0; repeat(2) @(posedge clk); #1; rst_n = 1;
        repeat(2) @(posedge clk); #1;
        do_write(7, 0, 88);
        repeat(2) @(posedge clk); #1;
        do_read(8, 0);
        check("Neuron 8 unaffected by write to neuron 7", rd_data_b0 === 8'd0);
        do_read(7, 0);
        check("Neuron 7 reads 88", rd_data_b0 === 8'd88);

        // ---- Test 5: Overwrite ----------------------------
        $display("\n[TEST 5] Overwrite same slot");
        do_write(0, 0, 55);
        do_write(0, 0, 200);
        repeat(2) @(posedge clk); #1;
        do_read(0, 0);
        check("Second write wins (200)", rd_data_b0 === 8'd200);

        // ---- Summary --------------------------------------
        $display("\n==============================================");
        $display(" Results: %0d / %0d passed",
                 pass_count, pass_count + fail_count);
        $display("==============================================\n");

        if (fail_count == 0) $display("ALL TESTS PASSED\n");
        else                  $display("%0d FAILED\n", fail_count);

        $finish;
    end

    // ---- Watchdog -----------------------------------------
    initial begin
        #200000;
        $display("[TIMEOUT] Simulation exceeded 200us");
        $finish;
    end

endmodule
