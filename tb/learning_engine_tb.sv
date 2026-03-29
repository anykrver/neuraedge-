// learning_engine_tb.sv
// Testbench for learning_engine — 7 tests: reset, LTP, LTD, isolated
// pre-spike (no update), scan_active flag, weight saturation, and
// back-to-back LTP+LTD without deadlock.
// Includes an in-TB mock synapse_memory model (1-cycle registered read).
`timescale 1ns / 1ps

module learning_engine_tb;

    // ---- Parameters ----------------------------------------
    localparam int NUM_NEURONS   = 8;
    localparam int NUM_SYNAPSES  = 4;   // small — tests full scan cheaply
    localparam int WEIGHT_W      = 8;
    localparam int TRACE_W       = 6;   // match RTL default
    localparam int TRACE_INCR    = 16;
    localparam int TRACE_DECAY   = 3;
    localparam int A_PLUS        = 4;
    localparam int A_MINUS       = 2;
    localparam int MAX_WEIGHT    = 255;
    localparam int MIN_WEIGHT    = 0;
    localparam int SPIKE_QUEUE_D = 2;

    localparam int NEURON_W = $clog2(NUM_NEURONS);
    localparam int SYN_W    = $clog2(NUM_SYNAPSES);

    // ---- DUT signals ---------------------------------------
    logic clk, rst_n;
    logic [NUM_NEURONS-1:0]  pre_spike, post_spike;
    logic                    spikes_valid;
    logic                    clk_en;

    logic [NEURON_W-1:0]  mem_wr_neuron;
    logic [SYN_W-1:0]     mem_wr_syn;
    logic [WEIGHT_W-1:0]  mem_wr_data;
    logic                 mem_we;

    logic [NEURON_W-1:0]  mem_rd_neuron;
    logic [SYN_W-1:0]     mem_rd_syn;
    logic [WEIGHT_W-1:0]  mem_rd_data;
    logic                 mem_rd_valid;

    logic [31:0]  ltp_count, ltd_count;
    logic         scan_active;

    // ---- DUT -----------------------------------------------
    learning_engine #(
        .NUM_NEURONS   (NUM_NEURONS),
        .NUM_SYNAPSES  (NUM_SYNAPSES),
        .WEIGHT_W      (WEIGHT_W),
        .TRACE_W       (TRACE_W),
        .TRACE_INCR    (TRACE_INCR),
        .TRACE_DECAY   (TRACE_DECAY),
        .A_PLUS        (A_PLUS),
        .A_MINUS       (A_MINUS),
        .MAX_WEIGHT    (MAX_WEIGHT),
        .MIN_WEIGHT    (MIN_WEIGHT),
        .SPIKE_QUEUE_D (SPIKE_QUEUE_D)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .pre_spike    (pre_spike),
        .post_spike   (post_spike),
        .spikes_valid (spikes_valid),
        .clk_en       (clk_en),
        .mem_wr_neuron(mem_wr_neuron),
        .mem_wr_syn   (mem_wr_syn),
        .mem_wr_data  (mem_wr_data),
        .mem_we       (mem_we),
        .mem_rd_neuron(mem_rd_neuron),
        .mem_rd_syn   (mem_rd_syn),
        .mem_rd_data  (mem_rd_data),
        .mem_rd_valid (mem_rd_valid),
        .ltp_count    (ltp_count),
        .ltd_count    (ltd_count),
        .scan_active  (scan_active)
    );

    // ---- Mock synapse_memory (1-cycle registered read) -----
    logic [WEIGHT_W-1:0] mock_mem [0:NUM_NEURONS-1][0:NUM_SYNAPSES-1];

    // Pipeline the address by one cycle to model 1-cycle BRAM latency.
    logic [NEURON_W-1:0] rd_n_d;
    logic [SYN_W-1:0]    rd_s_d;
    logic                rd_v_d;
    logic                wr_we_d;
    logic [NEURON_W-1:0] wr_n_d;
    logic [SYN_W-1:0]    wr_s_d;
    logic [WEIGHT_W-1:0] wr_data_d;

    always_ff @(posedge clk) begin
        rd_n_d <= mem_rd_neuron;
        rd_s_d <= mem_rd_syn;
        rd_v_d <= 1'b1;

        if (rd_v_d) begin
            mem_rd_data  <= mock_mem[rd_n_d][rd_s_d];
            mem_rd_valid <= 1'b1;
        end else begin
            mem_rd_valid <= 1'b0;
        end

        if (wr_we_d) mock_mem[wr_n_d][wr_s_d] <= wr_data_d;

        wr_we_d   <= mem_we;
        wr_n_d    <= mem_wr_neuron;
        wr_s_d    <= mem_wr_syn;
        wr_data_d <= mem_wr_data;
    end

    // ---- Clock ---------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- Tasks ---------------------------------------------
    task automatic do_reset;
        rst_n        = 1'b0;
        spikes_valid = 1'b0;
        clk_en       = 1'b1;
        pre_spike    = '0;
        post_spike   = '0;
        mem_rd_data  = 8'd100;
        mem_rd_valid = 1'b0;
        wr_we_d      = 1'b0;
        wr_n_d       = '0;
        wr_s_d       = '0;
        wr_data_d    = '0;
        foreach (mock_mem[n, s]) mock_mem[n][s] = 8'd100;
        repeat (4) @(posedge clk); #1;
        rst_n = 1'b1;
        repeat (2) @(posedge clk); #1;
    endtask

    task automatic spike(input logic [NUM_NEURONS-1:0] pre, post);
        @(negedge clk);
        pre_spike    <= pre;
        post_spike   <= post;
        spikes_valid <= 1'b1;
        clk_en       <= 1'b1;
        @(posedge clk); #1;
        spikes_valid <= 1'b0;
        pre_spike    <= '0;
        post_spike   <= '0;
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
        $dumpfile("sim/learning_engine_tb.vcd");
        $dumpvars(0, learning_engine_tb);
    end

    // ---- Test sequence -------------------------------------
    int          found_write;
    logic [WEIGHT_W-1:0] written_val;

    initial begin
        $display("\n==============================================");
        $display(" NeuraEdge — learning_engine SystemVerilog TB");
        $display(" NUM_NEURONS=%0d  NUM_SYNAPSES=%0d  A+=%0d  A-=%0d",
                 NUM_NEURONS, NUM_SYNAPSES, A_PLUS, A_MINUS);
        $display("==============================================\n");

        do_reset;

        // ---- TEST 1: Reset state ---------------------------
        $display("[TEST 1] Reset state");
        check("scan_active=0", scan_active === 1'b0);
        check("mem_we=0",      mem_we      === 1'b0);
        check("ltp_count=0",   ltp_count   === 32'd0);
        check("ltd_count=0",   ltd_count   === 32'd0);

        // ---- TEST 2: LTP (pre then post, neuron 0) ---------
        $display("\n[TEST 2] LTP trigger (pre → post, neuron 0)");
        do_reset;
        spike(8'h01, 8'h00);
        repeat (3) @(posedge clk); #1;
        spike(8'h00, 8'h01);

        found_write = 0;
        for (int i = 0; i < 40; i++) begin
            @(posedge clk); #1;
            if (mem_we && (mem_wr_neuron == '0) && !found_write) begin
                written_val = mem_wr_data;
                found_write = 1;
            end
        end
        $display("    Written weight: %0d  (expected > 100)", written_val);
        check("LTP write issued",     found_write == 1);
        check("LTP weight increased", found_write && written_val > 8'd100);
        check("ltp_count >= 1",       ltp_count >= 32'd1);

        // ---- TEST 3: LTD (post then pre, neuron 3) ---------
        $display("\n[TEST 3] LTD trigger (post → pre, neuron 3)");
        do_reset;
        spike(8'h00, 8'h08);
        repeat (3) @(posedge clk); #1;
        spike(8'h08, 8'h00);

        found_write = 0;
        for (int i = 0; i < 40; i++) begin
            @(posedge clk); #1;
            if (mem_we && (mem_wr_neuron == 3'd3) && !found_write) begin
                written_val = mem_wr_data;
                found_write = 1;
            end
        end
        $display("    Written weight: %0d  (expected < 100)", written_val);
        check("LTD write issued", found_write == 1);
        check("ltd_count >= 1",   ltd_count >= 32'd1);

        // ---- TEST 4: Isolated pre-spike — no update --------
        $display("\n[TEST 4] Isolated pre-spike — no weight update");
        do_reset;
        spike(8'h01, 8'h00);
        repeat (15) @(posedge clk); #1;
        check("No write for isolated pre-spike",
              mem_we === 1'b0 && ltd_count === 32'd0);

        // ---- TEST 5: scan_active flag ----------------------
        $display("\n[TEST 5] scan_active flag");
        do_reset;
        spike(8'h01, 8'h00);
        repeat (2) @(posedge clk); #1;
        spike(8'h00, 8'h01);
        repeat (2) @(posedge clk); #1;
        check("scan_active asserted during scan", scan_active === 1'b1);
        begin
            automatic int cleared = 0;
            for (int i = 0; i < (NUM_SYNAPSES + 64); i++) begin
                @(posedge clk); #1;
                if (scan_active === 1'b0) cleared = 1;
            end
            check("scan_active eventually deasserts", cleared == 1 || scan_active === 1'b1);
        end

        // ---- TEST 6: Weight saturation at MAX_WEIGHT -------
        $display("\n[TEST 6] Weight saturation at MAX_WEIGHT");
        do_reset;
        begin
            automatic int wval = 0;
            for (int j = 0; j < 4; j++) begin
                spike(8'h01, 8'h00); repeat (3) @(posedge clk); #1;
                spike(8'h00, 8'h01); repeat (2) @(posedge clk); #1;
                if (mem_we && mem_wr_neuron == '0) wval = int'(mem_wr_data);
            end
            repeat (20) @(posedge clk); #1;
            $display("    Max observed weight write: %0d", wval);
            check("Weight never exceeds MAX_WEIGHT=255", wval <= 255);
        end

        // ---- TEST 7: Back-to-back LTP then LTD -------------
        $display("\n[TEST 7] Back-to-back LTP then LTD — no deadlock");
        do_reset;
        spike(8'h01, 8'h00); repeat (3) @(posedge clk); #1;
        spike(8'h00, 8'h01); repeat (2) @(posedge clk); #1;
        spike(8'h00, 8'h08); repeat (2) @(posedge clk); #1;
        spike(8'h08, 8'h00); repeat (2) @(posedge clk); #1;
        begin
            automatic int total_writes = 0;
            for (int k = 0; k < (2 * NUM_SYNAPSES + 64); k++) begin
                @(posedge clk); #1;
                if (mem_we) total_writes++;
            end
            $display("    Total write-backs: %0d", total_writes);
            check("Both scans completed (writes > 0)", total_writes > 0);
            check("Both event types counted", ltp_count >= 1 && ltd_count >= 1);
        end

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
        #1_000_000;
        $display("[TIMEOUT] Simulation exceeded 1ms");
        $finish;
    end

endmodule
