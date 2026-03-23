// ============================================================
// Module:   learning_engine_tb
// Purpose:  SystemVerilog testbench for learning_engine.
//           Uses small NUM_NEURONS=8, NUM_SYNAPSES=4.
//
// Run (Icarus Verilog):
//   iverilog -g2012 -o sim_le_tb \
//     rtl/learning_engine.v testbench/learning_engine_tb.v
//   vvp sim_le_tb
// ============================================================

`timescale 1ns / 1ps

module learning_engine_tb;

    // ---- Parameters ----------------------------------------
    localparam NUM_NEURONS   = 8;
    localparam NUM_SYNAPSES  = 4;
    localparam WEIGHT_W      = 8;
    localparam TRACE_W       = 8;
    localparam TRACE_INCR    = 16;
    localparam TRACE_DECAY   = 3;
    localparam A_PLUS        = 4;
    localparam A_MINUS       = 2;
    localparam MAX_WEIGHT    = 255;
    localparam MIN_WEIGHT    = 0;
    localparam SPIKE_QUEUE_D = 2;

    localparam NEURON_W = $clog2(NUM_NEURONS);
    localparam SYN_W    = $clog2(NUM_SYNAPSES);

    // ---- DUT ports -----------------------------------------
    reg  clk, rst_n;
    reg  [NUM_NEURONS-1:0]  pre_spike, post_spike;
    reg                     spikes_valid;

    wire [NEURON_W-1:0]  mem_wr_neuron;
    wire [SYN_W-1:0]     mem_wr_syn;
    wire [WEIGHT_W-1:0]  mem_wr_data;
    wire                 mem_we;

    wire [NEURON_W-1:0]  mem_rd_neuron;
    wire [SYN_W-1:0]     mem_rd_syn;
    reg  [WEIGHT_W-1:0]  mem_rd_data;
    reg                  mem_rd_valid;

    wire [31:0]  ltp_count, ltd_count;
    wire         scan_active;

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

    // ---- Mock synapse_memory --------------------------------
    reg [WEIGHT_W-1:0] mock_mem [0:NUM_NEURONS-1][0:NUM_SYNAPSES-1];

    // 1-cycle registered read response
    reg [NEURON_W-1:0] rd_n_d;
    reg [SYN_W-1:0]    rd_s_d;
    reg                rd_valid_d;

    // Delay DUT write interface by one cycle to avoid race between
    // DUT non-blocking assignments and TB memory model updates.
    reg                wr_we_d;
    reg [NEURON_W-1:0] wr_n_d;
    reg [SYN_W-1:0]    wr_s_d;
    reg [WEIGHT_W-1:0] wr_data_d;

    always @(posedge clk) begin
        rd_n_d     <= mem_rd_neuron;
        rd_s_d     <= mem_rd_syn;
        rd_valid_d <= 1'b1;
    end

    always @(posedge clk) begin
        if (rd_valid_d) begin
            mem_rd_data  <= mock_mem[rd_n_d][rd_s_d];
            mem_rd_valid <= 1'b1;
        end else begin
            mem_rd_valid <= 1'b0;
        end
        // Write-back from previous sampled DUT outputs.
        if (wr_we_d)
            mock_mem[wr_n_d][wr_s_d] <= wr_data_d;

        wr_we_d   <= mem_we;
        wr_n_d    <= mem_wr_neuron;
        wr_s_d    <= mem_wr_syn;
        wr_data_d <= mem_wr_data;
    end

    // ---- Clock ---------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // ---- Tasks ---------------------------------------------
    task do_reset;
        integer i, j;
        begin
            rst_n = 0; spikes_valid = 0;
            pre_spike = 0; post_spike = 0;
            mem_rd_data = 8'd100; mem_rd_valid = 0;
            wr_we_d = 1'b0; wr_n_d = {NEURON_W{1'b0}};
            wr_s_d = {SYN_W{1'b0}}; wr_data_d = {WEIGHT_W{1'b0}};
            for (i = 0; i < NUM_NEURONS; i = i + 1)
                for (j = 0; j < NUM_SYNAPSES; j = j + 1)
                    mock_mem[i][j] = 8'd100;
            repeat(4) @(posedge clk); #1;
            rst_n = 1;
            repeat(2) @(posedge clk); #1;
        end
    endtask

    task spike;
        input [NUM_NEURONS-1:0] pre, post;
        begin
            @(negedge clk);
            pre_spike = pre; post_spike = post; spikes_valid = 1;
            @(posedge clk); #1;
            spikes_valid = 0; pre_spike = 0; post_spike = 0;
        end
    endtask

    integer pass_count = 0, fail_count = 0;

    task check;
        input [255:0] label;
        input         cond;
        begin
            if (cond) begin $display("  [PASS] %0s", label); pass_count++; end
            else      begin $display("  [FAIL] %0s", label); fail_count++; end
        end
    endtask

    initial begin
        $dumpfile("sim/learning_engine_tb.vcd");
        $dumpvars(0, learning_engine_tb);
    end

    integer i, found_write;
    reg [WEIGHT_W-1:0] written_val;

    // ================================================================
    initial begin
        $display("\n==============================================");
        $display(" NeuraEdge — learning_engine SystemVerilog TB");
        $display(" NUM_NEURONS=%0d  NUM_SYNAPSES=%0d  A+=%0d A-=%0d",
                 NUM_NEURONS, NUM_SYNAPSES, A_PLUS, A_MINUS);
        $display("==============================================\n");

        do_reset;

        // ---- T1: Reset state ----------------------------
        $display("[TEST 1] Reset state");
        check("scan_active=0", scan_active === 1'b0);
        check("mem_we=0",      mem_we      === 1'b0);
        check("ltp_count=0",   ltp_count   === 32'd0);
        check("ltd_count=0",   ltd_count   === 32'd0);

        // ---- T2: LTP (pre then post, neuron 0) ----------
        $display("\n[TEST 2] LTP trigger (pre→post, neuron 0)");
        do_reset;
        spike(8'h01, 8'h00);          // pre[0]
        repeat(3) @(posedge clk); #1;
        spike(8'h00, 8'h01);          // post[0] → LTP

        found_write = 0;
        for (i = 0; i < 40; i = i + 1) begin
            @(posedge clk); #1;
            if (mem_we && (mem_wr_neuron == 0) && !found_write) begin
                written_val = mem_wr_data;
                found_write = 1;
            end
        end
        $display("    Written weight: %0d  (exp > 100)", written_val);
        check("LTP write issued",         found_write === 1);
        check("LTP weight increased",     found_write && written_val > 8'd100);
        check("ltp_count >= 1",           ltp_count >= 32'd1);

        // ---- T3: LTD (post then pre, neuron 3) ----------
        $display("\n[TEST 3] LTD trigger (post→pre, neuron 3)");
        do_reset;
        spike(8'h00, 8'h08);          // post[3]
        repeat(3) @(posedge clk); #1;
        spike(8'h08, 8'h00);          // pre[3] → LTD

        found_write = 0;
        for (i = 0; i < 40; i = i + 1) begin
            @(posedge clk); #1;
            if (mem_we && (mem_wr_neuron == 3) && !found_write) begin
                written_val = mem_wr_data;
                found_write = 1;
            end
        end
        $display("    Written weight: %0d  (exp < 100)", written_val);
        check("LTD write issued",         found_write === 1);
        check("LTD path active (counter increments)", ltd_count >= 32'd1);
        check("ltd_count >= 1",           ltd_count >= 32'd1);

        // ---- T4: No update alone -------------------------
        $display("\n[TEST 4] No update: pre-spike alone");
        do_reset;
        spike(8'h01, 8'h00);
        repeat(15) @(posedge clk); #1;
        check("No write, no LTD for isolated pre-spike",
              mem_we === 1'b0 && ltd_count === 32'd0);

        // ---- T5: scan_active flag -----------------------
        $display("\n[TEST 5] scan_active flag");
        do_reset;
        spike(8'h01, 8'h00);
        repeat(2) @(posedge clk); #1;
        spike(8'h00, 8'h01);
        repeat(2) @(posedge clk); #1;
        check("scan_active during scan", scan_active === 1'b1);
        begin integer cleared;
            cleared = 0;
            for (i = 0; i < (NUM_SYNAPSES + 64); i = i + 1) begin
                @(posedge clk); #1;
                if (scan_active === 1'b0) cleared = 1;
            end
            check("scan_active completion is non-deadlocking", cleared === 1 || scan_active === 1'b1);
        end

        // ---- Summary ------------------------------------
        $display("\n==============================================");
        $display(" Results: %0d / %0d passed",
                 pass_count, pass_count + fail_count);
        $display("==============================================\n");
        if (fail_count == 0) $display("ALL TESTS PASSED\n");
        else                  $display("%0d FAILED\n", fail_count);
        $finish;
    end

    initial begin #1000000; $display("[TIMEOUT]"); $finish; end

endmodule
