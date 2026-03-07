// neuron_tb.sv — Unit test for single LIF neuron
// 6 tests: Leak, Sub-threshold, Suprathreshold, Refractory, No-underflow, Disabled

`timescale 1ns/1ps

module neuron_tb;

    // DUT signals
    logic       clk, rst_n, enable;
    logic signed [7:0] i_syn;
    logic [7:0] v_mem;
    logic       spike_out;

    // Instantiate DUT
    neuron #(
        .LEAK_FACTOR  (8'hE6),
        .THRESHOLD    (8'h40),
        .V_RESET      (8'h00),
        .REFRAC_PERIOD(4)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (enable),
        .i_syn    (i_syn),
        .v_mem    (v_mem),
        .spike_out(spike_out)
    );

    // 10 ns clock
    initial clk = 0;
    always #5 clk = ~clk;

    // Test tracking
    integer pass_count, fail_count;
    task pass_test(input string name);
        $display("  [PASS] %s", name);
        pass_count = pass_count + 1;
    endtask
    task fail_test(input string name, input string reason);
        $display("  [FAIL] %s — %s", name, reason);
        fail_count = fail_count + 1;
    endtask

    // Helper: apply reset
    task do_reset;
        rst_n  = 0;
        enable = 0;
        i_syn  = 8'h00;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst_n = 1;
        @(posedge clk); #1;
    endtask

    // Helper: run N cycles
    task run_cycles(input integer n);
        integer k;
        for (k = 0; k < n; k = k + 1)
            @(posedge clk);
        #1;
    endtask

    integer i;
    logic [7:0] v_prev;
    integer spike_count;
    integer first_spike_cycle;
    integer last_spike_cycle;
    logic saw_spike;
    logic underflow_seen;

    initial begin
        $dumpfile("build/neuron_tb.vcd");
        $dumpvars(0, neuron_tb);

        pass_count = 0;
        fail_count = 0;
        $display("=== NeuraEdge Neuron Unit Tests ===");

        // ============================================================
        // TEST 1 — Leak: no input, v_mem should decay toward 0
        // ============================================================
        $display("\nTEST 1 — Leak");
        do_reset;
        // Pre-charge membrane potential by forcing it high
        // Drive a current briefly to raise v_mem, then remove it
        enable = 1;
        i_syn  = 8'h30;   // 0.75 in Q2.6 — sub-threshold, charges up
        run_cycles(3);
        i_syn = 8'h00;
        v_prev = v_mem;
        if (v_prev == 8'h00) begin
            // Membrane never charged — inject more
            i_syn = 8'h20;
            run_cycles(5);
            i_syn = 8'h00;
            v_prev = v_mem;
        end
        // Now verify membrane decays over 10 cycles
        run_cycles(10);
        if (v_mem < v_prev)
            pass_test("Leak");
        else
            fail_test("Leak", $sformatf("v_mem=%0h did not decay from v_prev=%0h", v_mem, v_prev));

        // ============================================================
        // TEST 2 — Sub-threshold: small input, no spike expected
        // ============================================================
        $display("\nTEST 2 — Sub-threshold");
        do_reset;
        enable    = 1;
        i_syn     = 8'h04;   // 0.0625 in Q2.6 — tiny current
        saw_spike = 0;
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk); #1;
            if (spike_out) saw_spike = 1;
        end
        if (!saw_spike)
            pass_test("Sub-threshold");
        else
            fail_test("Sub-threshold", "Unexpected spike with small input");

        // ============================================================
        // TEST 3 — Suprathreshold: strong input, neuron should fire
        // ============================================================
        $display("\nTEST 3 — Suprathreshold");
        do_reset;
        enable           = 1;
        i_syn            = 8'h40;   // 1.0 in Q2.6 = threshold voltage
        spike_count      = 0;
        first_spike_cycle= -1;
        for (i = 0; i < 30; i = i + 1) begin
            @(posedge clk); #1;
            if (spike_out) begin
                spike_count = spike_count + 1;
                if (first_spike_cycle == -1)
                    first_spike_cycle = i;
            end
        end
        if (first_spike_cycle != -1 && first_spike_cycle < 5)
            pass_test($sformatf("Suprathreshold (first spike at cycle %0d, total %0d spikes)", first_spike_cycle, spike_count));
        else if (first_spike_cycle == -1)
            fail_test("Suprathreshold", "No spike produced");
        else
            fail_test("Suprathreshold", $sformatf("First spike too late: cycle %0d", first_spike_cycle));

        // ============================================================
        // TEST 4 — Refractory period: after spike, must wait REFRAC_PERIOD
        // ============================================================
        $display("\nTEST 4 — Refractory period");
        do_reset;
        enable      = 1;
        i_syn       = 8'h40;   // keep driving strongly
        saw_spike   = 0;
        first_spike_cycle = -1;
        last_spike_cycle  = -1;
        spike_count = 0;
        for (i = 0; i < 15; i = i + 1) begin
            @(posedge clk); #1;
            if (spike_out) begin
                spike_count = spike_count + 1;
                if (first_spike_cycle == -1)
                    first_spike_cycle = i;
                else
                    last_spike_cycle = i;
            end
        end
        // There should be at least 2 spikes, separated by >= 4 cycles
        if (spike_count >= 2 &&
            (last_spike_cycle - first_spike_cycle) >= 4)
            pass_test($sformatf("Refractory (gap=%0d cycles, expect>=4)", last_spike_cycle - first_spike_cycle));
        else if (spike_count < 2)
            fail_test("Refractory", $sformatf("Only %0d spikes, need at least 2", spike_count));
        else
            fail_test("Refractory", $sformatf("Gap=%0d cycles too short (need>=4)", last_spike_cycle - first_spike_cycle));

        // ============================================================
        // TEST 5 — No underflow: v_mem must never go below 0
        // ============================================================
        $display("\nTEST 5 — No underflow");
        do_reset;
        enable         = 1;
        underflow_seen = 0;
        // Inject strong inhibitory current
        i_syn = -8'h40;   // -1.0 in Q2.6 (signed)
        for (i = 0; i < 30; i = i + 1) begin
            @(posedge clk); #1;
            if ($signed(v_mem) < 0) underflow_seen = 1;
        end
        if (!underflow_seen)
            pass_test("No underflow");
        else
            fail_test("No underflow", "v_mem went below 0");

        // ============================================================
        // TEST 6 — Disabled neuron: spike_out must never assert
        // ============================================================
        $display("\nTEST 6 — Disabled neuron");
        do_reset;
        enable    = 0;   // disabled
        i_syn     = 8'h40;
        saw_spike = 0;
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk); #1;
            if (spike_out) saw_spike = 1;
        end
        if (!saw_spike)
            pass_test("Disabled neuron");
        else
            fail_test("Disabled neuron", "spike_out asserted when enable=0");

        // ============================================================
        $display("\n=== Summary: %0d PASS, %0d FAIL ===", pass_count, fail_count);
        $finish;
    end

endmodule
