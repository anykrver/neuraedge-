// synapse_memory_tb.sv
// Testbench for synapse_memory — 8 tests: rd_valid gating, 1-cycle
// latency, write/read roundtrip, 4-bank parallel, rd_data_sel mux,
// multi-neuron isolation, overwrite, interleaved bank writes.
`timescale 1ns / 1ps

module synapse_memory_tb;

    // ---- Parameters ----------------------------------------
    localparam int NUM_NEURONS  = 64;
    localparam int NUM_SYNAPSES = 512;
    localparam int WIDTH        = 8;
    localparam int NUM_BANKS    = 4;
    localparam int MAX_WEIGHT   = 255;
    localparam int MIN_WEIGHT   = 0;

    localparam int NEURON_W = $clog2(NUM_NEURONS);
    localparam int SYN_W    = $clog2(NUM_SYNAPSES);

    // ---- DUT signals ---------------------------------------
    logic                  clk, rst_n;
    logic [NEURON_W-1:0]   wr_neuron, rd_neuron;
    logic [SYN_W-1:0]      wr_syn, rd_syn_base;
    logic [WIDTH-1:0]      wr_data;
    logic                  we, rd_en;
    logic [WIDTH-1:0]      rd_data_b0, rd_data_b1, rd_data_b2, rd_data_b3;
    logic [WIDTH-1:0]      rd_data_sel;
    logic                  rd_valid;

    // ---- DUT -----------------------------------------------
    synapse_memory #(
        .NUM_NEURONS  (NUM_NEURONS),
        .NUM_SYNAPSES (NUM_SYNAPSES),
        .WIDTH        (WIDTH),
        .NUM_BANKS    (NUM_BANKS),
        .MAX_WEIGHT   (MAX_WEIGHT),
        .MIN_WEIGHT   (MIN_WEIGHT)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_neuron   (wr_neuron),
        .wr_syn      (wr_syn),
        .wr_data     (wr_data),
        .we          (we),
        .rd_neuron   (rd_neuron),
        .rd_syn_base (rd_syn_base),
        .rd_en       (rd_en),
        .rd_data_b0  (rd_data_b0),
        .rd_data_b1  (rd_data_b1),
        .rd_data_b2  (rd_data_b2),
        .rd_data_b3  (rd_data_b3),
        .rd_data_sel (rd_data_sel),
        .rd_valid    (rd_valid)
    );

    // ---- Clock ---------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- Tasks ---------------------------------------------
    task automatic do_write(input int nid, syn, w);
        @(negedge clk);
        wr_neuron <= NEURON_W'(nid);
        wr_syn    <= SYN_W'(syn);
        wr_data   <= WIDTH'(w);
        we        <= 1'b1;
        @(posedge clk); #1;
        we <= 1'b0;
    endtask

    task automatic do_read(input int nid, syn_base);
        @(negedge clk);
        rd_neuron   <= NEURON_W'(nid);
        rd_syn_base <= SYN_W'(syn_base);
        rd_en       <= 1'b1;
        @(posedge clk); #1;
        rd_en <= 1'b0;
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
    initial $dumpfile("sim/synapse_memory_tb.vcd");
    initial $dumpvars(0, synapse_memory_tb);

    // ---- Test sequence -------------------------------------
    initial begin
        $display("\n==============================================");
        $display(" NeuraEdge — synapse_memory SystemVerilog TB");
        $display("==============================================\n");

        rst_n = 1'b0; we = 1'b0; rd_en = 1'b0;
        wr_neuron = '0; wr_syn = '0; wr_data = '0;
        rd_neuron = '0; rd_syn_base = '0;
        repeat (4) @(posedge clk); #1;
        rst_n = 1'b1;
        repeat (2) @(posedge clk); #1;

        // ---- TEST 1: rd_valid gated by rd_en ---------------
        $display("[TEST 1] rd_valid gated by rd_en");
        @(negedge clk);
        rd_neuron = '0; rd_syn_base = '0; rd_en = 1'b0;
        @(posedge clk); #1;
        check("rd_valid low when rd_en=0", rd_valid === 1'b0);

        // ---- TEST 2: 1-cycle read latency ------------------
        $display("\n[TEST 2] rd_valid 1-cycle latency");
        @(negedge clk); rd_en = 1'b1;
        @(posedge clk); #1; rd_en = 1'b0;
        check("rd_valid high 1 cycle after rd_en pulse", rd_valid === 1'b1);
        @(posedge clk); #1;
        check("rd_valid deasserts when rd_en=0", rd_valid === 1'b0);

        // ---- TEST 3: Write / read roundtrip ----------------
        $display("\n[TEST 3] Write/read roundtrip (n=0, syn=0, w=150)");
        do_write(0, 0, 150);
        repeat (2) @(posedge clk); #1;
        do_read(0, 0);
        check("Read back 150 on b0", rd_data_b0 === 8'd150);
        check("rd_valid asserted",    rd_valid   === 1'b1);

        // ---- TEST 4: 4-bank parallel read ------------------
        $display("\n[TEST 4] 4-bank parallel read (n=1, syns 16-19)");
        do_write(1, 16, 11); do_write(1, 17, 22);
        do_write(1, 18, 33); do_write(1, 19, 44);
        repeat (2) @(posedge clk); #1;
        do_read(1, 16);
        check("b0=11", rd_data_b0 === 8'd11);
        check("b1=22", rd_data_b1 === 8'd22);
        check("b2=33", rd_data_b2 === 8'd33);
        check("b3=44", rd_data_b3 === 8'd44);

        // ---- TEST 5: rd_data_sel bank mux ------------------
        $display("\n[TEST 5] rd_data_sel selects correct bank");
        do_read(1, 17);
        check("rd_data_sel=22 (bank1)", rd_data_sel === 8'd22);
        do_read(1, 18);
        check("rd_data_sel=33 (bank2)", rd_data_sel === 8'd33);

        // ---- TEST 6: Multi-neuron isolation ----------------
        $display("\n[TEST 6] Multi-neuron isolation");
        rst_n = 1'b0; repeat (2) @(posedge clk); #1;
        rst_n = 1'b1; repeat (2) @(posedge clk); #1;
        do_write(7, 0, 88);
        repeat (2) @(posedge clk); #1;
        do_read(8, 0);
        check("Neuron 8 unaffected by write to neuron 7", rd_data_b0 === 8'd0);
        do_read(7, 0);
        check("Neuron 7 reads 88", rd_data_b0 === 8'd88);

        // ---- TEST 7: Overwrite same address ----------------
        $display("\n[TEST 7] Overwrite same address");
        do_write(0, 0, 55);
        do_write(0, 0, 200);
        repeat (2) @(posedge clk); #1;
        do_read(0, 0);
        check("Second write wins (200)", rd_data_b0 === 8'd200);

        // ---- TEST 8: Interleaved bank writes ---------------
        $display("\n[TEST 8] Interleaved bank writes — no collision");
        do_write(10, 0, 10); do_write(10, 1, 20);
        do_write(10, 2, 30); do_write(10, 3, 40);
        repeat (2) @(posedge clk); #1;
        do_read(10, 0);
        check("b0=10", rd_data_b0 === 8'd10);
        check("b1=20", rd_data_b1 === 8'd20);
        check("b2=30", rd_data_b2 === 8'd30);
        check("b3=40", rd_data_b3 === 8'd40);

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
        #200_000;
        $display("[TIMEOUT] Simulation exceeded 200us");
        $finish;
    end

endmodule
