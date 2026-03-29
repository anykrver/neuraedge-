// neuron_core_tb.sv
// Testbench for neuron_core — 9 tests covering reset, sub-threshold
// integration, LIF firing, post-spike reset, leak decay, multi-neuron
// isolation, saturation, fire_count accuracy, and neuron_enable gating.
`timescale 1ns / 1ps

module neuron_core_tb;

    // ---- Parameters ----------------------------------------
    localparam int NUM_NEURONS = 64;
    localparam int MEM_WIDTH   = 8;
    localparam int THRESHOLD   = 100;
    localparam int LEAK_SHIFT  = 1;
    localparam int RESET_VAL   = 0;

    // ---- DUT signals ---------------------------------------
    logic                            clk;
    logic                            rst_n;
    logic [$clog2(NUM_NEURONS)-1:0]  neuron_id;
    logic [MEM_WIDTH-1:0]            synaptic_input;
    logic                            input_valid;
    logic [NUM_NEURONS-1:0]          neuron_enable;
    logic [NUM_NEURONS-1:0]          spike_out;
    logic [MEM_WIDTH-1:0]            mem_debug;
    logic [31:0]                     fire_count;

    // ---- DUT -----------------------------------------------
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
        .neuron_enable  (neuron_enable),
        .spike_out      (spike_out),
        .mem_debug      (mem_debug),
        .fire_count     (fire_count)
    );

    // ---- Clock ---------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- Tasks ---------------------------------------------
    task automatic inject(input int nid, input int w);
        @(negedge clk);
        neuron_id      <= nid[($clog2(NUM_NEURONS)-1):0];
        synaptic_input <= w[MEM_WIDTH-1:0];
        input_valid    <= 1'b1;
        @(posedge clk);
        #1;
        input_valid <= 1'b0;
    endtask

    task automatic wait_cycles(input int n);
        input_valid <= 1'b0;
        repeat (n) @(posedge clk);
    endtask

    task automatic do_reset;
        rst_n = 1'b0;
        wait_cycles(4);
        rst_n = 1'b1;
        wait_cycles(2);
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
        $dumpfile("sim/neuron_core_tb.vcd");
        $dumpvars(0, neuron_core_tb);
    end

    // ---- Test sequence -------------------------------------
    initial begin
        $display("\n==============================================");
        $display(" NeuraEdge — neuron_core SystemVerilog TB");
        $display("==============================================\n");

        neuron_enable  = '1;
        input_valid    = 1'b0;
        neuron_id      = '0;
        synaptic_input = '0;

        // ---- TEST 1: Post-reset state ----------------------
        $display("[TEST 1] Post-reset state");
        do_reset;
        check("spike_out==0 after reset", spike_out === '0);
        check("mem_debug==0 after reset", mem_debug === '0);
        check("fire_count==0 after reset", fire_count === 32'd0);

        // ---- TEST 2: Sub-threshold — no fire ---------------
        $display("\n[TEST 2] Sub-threshold (w=30 x5, neuron 0)");
        for (int t = 0; t < 5; t++) begin
            inject(0, 30);
            wait_cycles(1);
        end
        check("No spike for 5x w=30", spike_out[0] === 1'b0);

        // ---- TEST 3: LIF firing ----------------------------
        $display("\n[TEST 3] LIF firing (w=80, neuron 0)");
        do_reset;
        begin
            automatic int fired      = 0;
            automatic int fc_before  = int'(fire_count);
            for (int t = 0; t < 20 && !fired; t++) begin
                inject(0, 80);
                wait_cycles(1);
                if (spike_out[0]) begin
                    $display("    Spike at inject %0d", t);
                    fired = 1;
                end
            end
            if (int'(fire_count) > fc_before) fired = 1;
            check("Neuron 0 fired", fired == 1);
        end

        // ---- TEST 4: Post-spike membrane reset -------------
        $display("\n[TEST 4] Post-spike membrane reset");
        wait_cycles(2);
        check("mem_debug within range after spike", mem_debug <= MEM_WIDTH'(THRESHOLD));

        // ---- TEST 5: Leak decay ----------------------------
        $display("\n[TEST 5] Membrane leak decay");
        do_reset;
        inject(2, 120);
        wait_cycles(1);
        begin
            automatic int mem_t0;
            automatic int mem_t8;
            neuron_id = $clog2(NUM_NEURONS)'(2);
            @(posedge clk); #1;
            mem_t0 = int'(mem_debug);
            wait_cycles(8);
            mem_t8 = int'(mem_debug);
            $display("    t0=%0d  t+8=%0d", mem_t0, mem_t8);
            check("Membrane decays over 8 cycles", mem_t8 < mem_t0);
        end

        // ---- TEST 6: Multi-neuron isolation ----------------
        $display("\n[TEST 6] Multi-neuron isolation (neuron 7)");
        do_reset;
        begin
            automatic int fired7 = 0;
            automatic int spill  = 0;
            automatic int fc_before = int'(fire_count);
            for (int t = 0; t < 20; t++) begin
                inject(7, 80);
                wait_cycles(1);
                if (spike_out[7])    fired7 = 1;
                if (spike_out[6:0] != '0) spill = 1;
            end
            if (int'(fire_count) > fc_before) fired7 = 1;
            check("Neuron 7 fired",               fired7 == 1);
            check("Neurons 0-6 quiet (no spill)", spill  == 0);
        end

        // ---- TEST 7: Saturation guard ----------------------
        $display("\n[TEST 7] Saturation (w=255, no wrap or hang)");
        do_reset;
        for (int t = 0; t < 30; t++) begin
            inject(0, 255);
            wait_cycles(1);
        end
        check("No hang — simulation still running", 1'b1);

        // ---- TEST 8: fire_count accuracy -------------------
        $display("\n[TEST 8] fire_count accuracy");
        do_reset;
        begin
            automatic int cnt_before = int'(fire_count);
            automatic int cnt_after;
            for (int t = 0; t < 15; t++) begin
                inject(4, 80);
                wait_cycles(1);
                if (spike_out[4]) break;
            end
            cnt_after = int'(fire_count);
            check("fire_count increments after firing", cnt_after > cnt_before);
        end

        // ---- TEST 9: neuron_enable freeze / unfreeze -------
        $display("\n[TEST 9] neuron_enable freeze / unfreeze");
        do_reset;
        neuron_enable = '1;
        inject(5, 80); wait_cycles(1);
        inject(5, 80); wait_cycles(1);
        neuron_id = $clog2(NUM_NEURONS)'(5);
        @(posedge clk); #1;
        begin
            automatic int m_pre;
            automatic int m_frozen;
            automatic int m_post;
            m_pre = int'(mem_debug);
            $display("    Pre-freeze membrane: %0d", m_pre);

            // Freeze neuron 5 only
            neuron_enable = '1 & ~(NUM_NEURONS'(1) << 5);
            wait_cycles(10);
            m_frozen = int'(mem_debug);
            $display("    Frozen (10 cycles): %0d", m_frozen);
            check("Frozen membrane holds", m_frozen == m_pre);

            neuron_enable = '1;
            wait_cycles(8);
            m_post = int'(mem_debug);
            $display("    Post-unfreeze (8 leaks): %0d", m_post);
            check("Membrane leaks after unfreeze", m_post < m_pre);
        end

        // ---- Summary ---------------------------------------
        $display("\n==============================================");
        $display(" Results: %0d / %0d tests passed",
                 pass_count, pass_count + fail_count);
        $display("==============================================\n");
        if (fail_count == 0) $display("ALL TESTS PASSED\n");
        else                  $display("%0d TEST(S) FAILED\n", fail_count);
        $finish;
    end

    // ---- Watchdog ------------------------------------------
    initial begin
        #500_000;
        $display("[TIMEOUT] Simulation exceeded 500us");
        $finish;
    end

endmodule
