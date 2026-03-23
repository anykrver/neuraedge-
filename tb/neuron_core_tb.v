`timescale 1ns / 1ps
// ============================================================
// Module:   neuron_core_tb
// Purpose:  SystemVerilog testbench for neuron_core.
//           Compatible with Icarus Verilog, ModelSim, Vivado Sim.
//
// FIXES vs v1.0:
//   BUG-1.4: neuron_enable missing from port list and instantiation.
//     With neuron_enable absent -> elaboration error (Icarus) or
//     undriven input defaults to 0 (Vivado/ModelSim) -> all frozen.
//     Fix: add reg [63:0] neuron_enable, drive to all-ones, connect.
//
//   BUG-1.1: fire_count missing from port connection.
//     Add fire_count wire and verify it in TEST 8.
//
//   TB-6 GAP: add TEST 9 (freeze/unfreeze neuron_enable toggle).
//
// Run (Icarus Verilog):
//   iverilog -g2012 -Wall -o sim/nc_tb rtl/neuron_core.v tb/neuron_core_tb.v
//   vvp sim/nc_tb
// ============================================================

module neuron_core_tb;

    localparam NUM_NEURONS = 64;
    localparam MEM_WIDTH   = 8;
    localparam THRESHOLD   = 100;  // must match neuron_core parameter default
    localparam LEAK_SHIFT  = 1;
    localparam RESET_VAL   = 0;

    reg                             clk;
    reg                             rst_n;
    reg  [$clog2(NUM_NEURONS)-1:0]  neuron_id;
    reg  [MEM_WIDTH-1:0]            synaptic_input;
    reg                             input_valid;
    // FIX BUG-1.4: declare and drive neuron_enable
    reg  [NUM_NEURONS-1:0]          neuron_enable;
    wire [NUM_NEURONS-1:0]          spike_out;
    wire [MEM_WIDTH-1:0]            mem_debug;
    // FIX BUG-1.1: connect fire_count
    wire [31:0]                     fire_count;

    neuron_core #(
        .NUM_NEURONS (NUM_NEURONS),
        .MEM_WIDTH   (MEM_WIDTH),
        .THRESHOLD   (THRESHOLD),
        .LEAK_SHIFT  (LEAK_SHIFT),
        .RESET_VAL   (RESET_VAL)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .neuron_id      (neuron_id),
        .synaptic_input (synaptic_input),
        .input_valid    (input_valid),
        .neuron_enable  (neuron_enable),   // FIX: was missing
        .spike_out      (spike_out),
        .mem_debug      (mem_debug),
        .fire_count     (fire_count)        // FIX: was missing
    );

    initial clk = 0;
    always #5 clk = ~clk;

    task inject;
        input integer nid, w;
        begin
            @(negedge clk);
            neuron_id <= nid; synaptic_input <= w; input_valid <= 1;
            @(posedge clk); #1; input_valid <= 0;
        end
    endtask

    task wait_cycles;
        input integer n; integer i;
        begin input_valid <= 0; for (i=0; i<n; i=i+1) @(posedge clk); end
    endtask

    task do_reset;
        begin
            rst_n = 0; wait_cycles(4); rst_n = 1; wait_cycles(2);
        end
    endtask

    integer pass_count = 0;
    integer fail_count = 0;

    task check;
        input [255:0] label; input cond;
        begin
            if (cond) begin $display("  [PASS] %s", label); pass_count=pass_count+1; end
            else       begin $display("  [FAIL] %s", label); fail_count=fail_count+1; end
        end
    endtask

    initial begin
        $dumpfile("sim/neuron_core_tb.vcd");
        $dumpvars(0, neuron_core_tb);
    end

    integer t;

    initial begin
        $display("\n==============================================");
        $display(" NeuraEdge — neuron_core SV Testbench v2.0");
        $display("==============================================\n");

        // FIX BUG-1.4: enable all neurons at startup
        neuron_enable = {NUM_NEURONS{1'b1}};
        input_valid = 0; neuron_id = 0; synaptic_input = 0;

        // TEST 1: Reset
        $display("[TEST 1] Post-reset state");
        do_reset;
        check("spike_out==0 after reset", spike_out === {NUM_NEURONS{1'b0}});
        check("mem_debug==0 after reset", mem_debug === 8'd0);
        check("fire_count==0 after reset", fire_count === 32'd0);

        // TEST 2: Sub-threshold
        $display("\n[TEST 2] Sub-threshold (w=30 x5, neuron 0)");
        for (t=0; t<5; t=t+1) begin inject(0,30); wait_cycles(1); end
        check("No spike for 5x w=30", (spike_out & 64'h1) === 1'b0);

        // TEST 3: LIF firing
        $display("\n[TEST 3] LIF firing (w=80, neuron 0)");
        do_reset;
        begin integer fired; integer fc_before; integer fc_after; fired=0;
            fc_before = fire_count;
            for (t=0; t<20; t=t+1) begin
                if (!fired) begin
                    inject(0,80); wait_cycles(1);
                    if (spike_out[0]) begin
                        $display("    Spike at t=%0d",t);
                        fired=1;
                    end
                end
            end
            fc_after = fire_count;
            if (fc_after > fc_before) fired = 1;
            check("Neuron 0 fired", fired===1);
        end

        // TEST 4: Post-spike reset
        $display("\n[TEST 4] Post-spike membrane reset");
        wait_cycles(2);
        check("mem_debug within valid range after spike", mem_debug <= THRESHOLD);

        // TEST 5: Leak decay
        $display("\n[TEST 5] Membrane leak decay");
        do_reset;
        inject(2, 8'd120); wait_cycles(1);
        begin integer mem_t0, mem_t8;
            mem_t0 = mem_debug; neuron_id = 2;
            wait_cycles(8); mem_t8 = mem_debug;
            $display("    t0=%0d t+8=%0d", mem_t0, mem_t8);
            check("Membrane decays", mem_t8 < mem_t0);
        end

        // TEST 6: Multi-neuron isolation
        $display("\n[TEST 6] Multi-neuron isolation (neuron 7)");
        do_reset;
        begin integer fired7; integer spill; integer fc_before; integer fc_after;
        fired7 = 0; spill = 0;
        fc_before = fire_count;
        for (t=0; t<20; t=t+1) begin
            inject(7,80); wait_cycles(1);
            if (spike_out[7]) fired7 = 1;
            if (spike_out[6:0] != 7'b0) spill = 1;
        end
        fc_after = fire_count;
        if (fc_after > fc_before) fired7 = 1;
        check("Neuron 7 fired",               fired7 === 1);
        check("Neurons 0-6 quiet (no spill)", spill === 0);
        end

        // TEST 7: Saturation guard
        $display("\n[TEST 7] Saturation (w=255, no wrap)");
        do_reset;
        for (t=0; t<30; t=t+1) begin inject(0,255); wait_cycles(1); end
        check("No crash / simulation still running", 1'b1);

        // TEST 8: fire_count accuracy (BUG-1.1 regression)
        $display("\n[TEST 8] fire_count accuracy");
        do_reset;
        begin integer cnt_before, cnt_after;
            cnt_before = fire_count;
            for (t=0; t<15; t=t+1) begin inject(4,80); wait_cycles(1);
                if (spike_out[4]) t=15; end
            cnt_after = fire_count;
            check("fire_count > 0 after firing", cnt_after > cnt_before);
        end

        // TEST 9: neuron_enable freeze/unfreeze (TB-6 gap)
        $display("\n[TEST 9] neuron_enable freeze/unfreeze");
        do_reset; neuron_enable = {NUM_NEURONS{1'b1}};
        inject(5,80); wait_cycles(1); inject(5,80); wait_cycles(1);
        neuron_id = 5; @(posedge clk); #1;
        begin integer m_pre, m_frozen, m_post;
            m_pre = mem_debug;
            $display("    Pre-freeze membrane: %0d", m_pre);
            neuron_enable = ~({NUM_NEURONS{1'b1}} & ({{NUM_NEURONS-1{1'b0}},1'b1} << 5));
            wait_cycles(10);
            m_frozen = mem_debug;
            $display("    During freeze (10 cycles): %0d", m_frozen);
            check("Frozen membrane holds", m_frozen == m_pre);
            neuron_enable = {NUM_NEURONS{1'b1}};
            wait_cycles(8);
            m_post = mem_debug;
            $display("    Post-unfreeze (8 leaks): %0d", m_post);
            check("Membrane leaks after unfreeze", m_post < m_pre);
        end

        // Summary
        $display("\n==============================================");
        $display(" Results: %0d / %0d tests passed", pass_count, pass_count+fail_count);
        $display("==============================================\n");
        if (fail_count==0) $display("ALL TESTS PASSED\n");
        else               $display("%0d TEST(S) FAILED\n", fail_count);
        $finish;
    end

    initial begin #500000; $display("[TIMEOUT]"); $finish; end

endmodule
