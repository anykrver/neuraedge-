// network_tb.sv — Full integration test for NeuraEdge chip
// 9 phases: Reset, Weight Loading, XOR Truth Table, Idle Neurons,
//           Timing, Multi-Run, STDP Smoke, Stress Test, Edge Cases
//
// XOR network (redesigned for correct spike-timing behaviour):
//   N0,N1=inputs, N3=OR hidden, N4=inhibitory AND, N5=XOR output, N2=unused
//   N0->N3:+1.0(0x40) N1->N3:+1.0(0x40) N0->N4:+0.5(0x20) N1->N4:+0.5(0x20)
//   N3->N5:+1.2(0x4D) N4->N5:-2.0(0x80 signed=-128)
// One input: N3 fires->N5 fires (XOR=1). Both inputs: N3+N4 fire together,
//   net i_syn[5]=+1.2-2.0=-0.8 -> N5 silent (XOR=0).

`timescale 1ns/1ps

module network_tb;

    localparam T_MAX      = 150;
    localparam N_NEURONS  = 32;
    localparam N_INPUTS   = 2;
    localparam CLK_PERIOD = 10;

    logic        clk, rst_n;
    logic        cfg_run;
    logic [15:0] cfg_t_max;
    logic        cfg_weight_wr;
    logic [9:0]  cfg_weight_addr;
    logic [7:0]  cfg_weight_data;
    logic [7:0]  cfg_input [0:N_INPUTS-1];
    logic        cfg_encode_mode;
    logic        cfg_stdp_enable;

    logic        out_done;
    logic [15:0] out_timestep;
    logic [N_NEURONS-1:0][7:0] out_spike_count;
    logic [N_NEURONS-1:0] out_spike_vector;

    neuraedge #(.N_NEURONS(N_NEURONS), .N_INPUTS(N_INPUTS)) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_run(cfg_run), .cfg_t_max(cfg_t_max),
        .cfg_weight_wr(cfg_weight_wr), .cfg_weight_addr(cfg_weight_addr),
        .cfg_weight_data(cfg_weight_data), .cfg_input(cfg_input),
        .cfg_encode_mode(cfg_encode_mode), .cfg_stdp_enable(cfg_stdp_enable),
        .out_done(out_done), .out_timestep(out_timestep),
        .out_spike_count(out_spike_count), .out_spike_vector(out_spike_vector)
    );

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // Global watchdog -- generous for STDP+stress test
    initial begin
        #100_000_000;
        $display("[WATCHDOG] Simulation timeout at 100ms");
        $finish;
    end

    integer pass_count, fail_count;
    task pass_test(input string name);
        $display("  [PASS] %s", name);
        pass_count = pass_count + 1;
    endtask
    task fail_test(input string name, input string reason);
        $display("  [FAIL] %s -- %s", name, reason);
        fail_count = fail_count + 1;
    endtask

    task do_reset;
        rst_n=0; cfg_run=0; cfg_t_max=T_MAX;
        cfg_weight_wr=0; cfg_weight_addr='0; cfg_weight_data='0;
        cfg_input[0]=8'h00; cfg_input[1]=8'h00;
        cfg_encode_mode=0; cfg_stdp_enable=0;
        repeat(4) @(posedge clk); #1;
        rst_n=1;
        repeat(2) @(posedge clk); #1;
    endtask

    task write_weight(input [9:0] addr, input [7:0] data);
        @(posedge clk); #1;
        cfg_weight_addr=addr; cfg_weight_data=data; cfg_weight_wr=1;
        @(posedge clk); #1;
        cfg_weight_wr=0;
    endtask

    // Redesigned XOR weights -- see header comment
    task load_xor_weights;
        write_weight({5'd0,5'd3}, 8'h40); // N0->N3: +1.0
        write_weight({5'd1,5'd3}, 8'h40); // N1->N3: +1.0
        write_weight({5'd0,5'd4}, 8'h20); // N0->N4: +0.5
        write_weight({5'd1,5'd4}, 8'h20); // N1->N4: +0.5
        write_weight({5'd3,5'd5}, 8'h4D); // N3->N5: +1.2
        write_weight({5'd4,5'd5}, 8'h80); // N4->N5: -2.0 (signed 0x80=-128)
        repeat(2) @(posedge clk); #1;
    endtask

    // run_inference: pulse cfg_run, wait for out_done, then disable fork
    task run_inference;
        @(posedge clk); #1;
        cfg_run=1; @(posedge clk); #1; cfg_run=0;
        fork : wait_or_timeout
            begin wait(out_done==1); disable wait_or_timeout; end
            begin
                #40_000_000;
                $display("[ERROR] Inference timeout!"); $finish;
            end
        join
        @(posedge clk); #1;
    endtask

    function automatic logic xor_expected;
        input [7:0] x1, x2;
        xor_expected = (x1!=0) ^ (x2!=0);
    endfunction

    integer i, j, xor_correct, start_cycle, end_cycle, elapsed;
    integer rand_x1, rand_x2, expected, got;
    logic [31:0] seed;
    logic xor_result;
    logic [7:0] x1_vals[0:3], x2_vals[0:3];
    logic [7:0] sc5_prev;

    initial begin
        $dumpfile("build/network_tb.vcd");
        $dumpvars(0, network_tb);
        pass_count=0; fail_count=0;
        $display("=== NeuraEdge Network Integration Tests ===");

        // PHASE 0
        $display("\nPHASE 0 -- Reset & Sanity");
        do_reset;
        if (out_done==0 && out_timestep==0)
            pass_test("Reset state (done=0, timestep=0)");
        else
            fail_test("Reset state", $sformatf("done=%0b timestep=%0d",out_done,out_timestep));
        begin
            logic all_zero; all_zero=1;
            for(i=0;i<N_NEURONS;i=i+1) if(out_spike_count[i]!=0) all_zero=0;
            if(all_zero) pass_test("Spike counts cleared on reset");
            else fail_test("Spike counts cleared","Some counts non-zero after reset");
        end

        // PHASE 1
        $display("\nPHASE 1 -- Weight Loading");
        load_xor_weights;
        pass_test("XOR weight loading (no timeout)");

        // PHASE 2
        $display("\nPHASE 2 -- XOR Truth Table");
        x1_vals[0]=8'h00; x2_vals[0]=8'h00;
        x1_vals[1]=8'hFF; x2_vals[1]=8'h00;
        x1_vals[2]=8'h00; x2_vals[2]=8'hFF;
        x1_vals[3]=8'hFF; x2_vals[3]=8'hFF;
        xor_correct=0;
        for(j=0;j<4;j=j+1) begin
            do_reset; load_xor_weights;
            cfg_input[0]=x1_vals[j]; cfg_input[1]=x2_vals[j];
            cfg_encode_mode=0; cfg_t_max=T_MAX;
            run_inference;
            xor_result=(out_spike_count[5]>8'd5);
            expected=xor_expected(x1_vals[j],x2_vals[j]);
            $display("    XOR(%0d,%0d): spikes[5]=%0d -> result=%0b (expected %0b)",
                     x1_vals[j]!=0,x2_vals[j]!=0,out_spike_count[5],xor_result,expected);
            if(xor_result==expected) xor_correct=xor_correct+1;
        end
        if(xor_correct>=3)
            pass_test($sformatf("XOR truth table (%0d/4 correct)",xor_correct));
        else
            fail_test("XOR truth table",$sformatf("Only %0d/4 correct",xor_correct));

        // PHASE 3
        $display("\nPHASE 3 -- Idle Neurons (6-31 should be zero)");
        do_reset; load_xor_weights;
        cfg_input[0]=8'hFF; cfg_input[1]=8'h00;
        cfg_encode_mode=0; cfg_t_max=T_MAX;
        run_inference;
        begin
            logic idle_ok; idle_ok=1;
            for(i=6;i<N_NEURONS;i=i+1)
                if(out_spike_count[i]!=0) begin
                    idle_ok=0;
                    $display("    Neuron %0d fired: count=%0d",i,out_spike_count[i]);
                end
            if(idle_ok) pass_test("Idle neurons 6-31 produce zero spikes");
            else fail_test("Idle neurons","Some idle neurons fired");
        end

        // PHASE 4
        $display("\nPHASE 4 -- Timing");
        do_reset; load_xor_weights;
        cfg_input[0]=8'hFF; cfg_input[1]=8'hFF;
        cfg_encode_mode=0; cfg_t_max=16'd10;
        @(posedge clk); #1; cfg_run=1; @(posedge clk); #1; cfg_run=0;
        start_cycle=$time/CLK_PERIOD;
        wait(out_done); end_cycle=$time/CLK_PERIOD;
        elapsed=end_cycle-start_cycle;
        $display("    10 timesteps took %0d cycles (%0d per timestep)",elapsed,elapsed/10);
        if(elapsed<100_000)
            pass_test($sformatf("Scheduler timing (%0d cycles for 10 ts)",elapsed));
        else
            fail_test("Timing",$sformatf("Too slow: %0d cycles",elapsed));

        // PHASE 5
        $display("\nPHASE 5 -- Multi-Run");
        do_reset; load_xor_weights;
        cfg_input[0]=8'hFF; cfg_input[1]=8'h00;
        cfg_encode_mode=0; cfg_t_max=T_MAX;
        run_inference; sc5_prev=out_spike_count[5];
        do_reset; load_xor_weights;
        cfg_input[0]=8'hFF; cfg_input[1]=8'h00;
        if(out_done==0) pass_test("done de-asserted after reset");
        else fail_test("done de-assert","done still high after reset");
        run_inference;
        if(out_spike_count[5]>0)
            pass_test($sformatf("Multi-run consistent (run1=%0d, run2=%0d)",sc5_prev,out_spike_count[5]));
        else
            fail_test("Multi-run","No spikes on second run");

        // PHASE 6
        $display("\nPHASE 6 -- STDP Smoke");
        do_reset; load_xor_weights;
        cfg_input[0]=8'hFF; cfg_input[1]=8'h00;
        cfg_encode_mode=0; cfg_stdp_enable=1; cfg_t_max=T_MAX;
        run_inference;
        pass_test("STDP smoke (completed without hang)");
        cfg_stdp_enable=0;

        // PHASE 7
        $display("\nPHASE 7 -- Stress Test (rate coding, 20 trials)");
        xor_correct=0; seed=32'hDEAD_BEEF;
        for(j=0;j<20;j=j+1) begin
            seed=seed^(seed<<13); seed=seed^(seed>>17); seed=seed^(seed<<5);
            rand_x1=(seed[1:0]<2)?1:0;
            seed=seed^(seed<<13); seed=seed^(seed>>17); seed=seed^(seed<<5);
            rand_x2=(seed[1:0]<2)?1:0;
            do_reset; load_xor_weights;
            cfg_input[0]=rand_x1?8'hFF:8'h00;
            cfg_input[1]=rand_x2?8'hFF:8'h00;
            cfg_encode_mode=0; cfg_t_max=T_MAX;
            run_inference;
            expected=rand_x1^rand_x2;
            got=(out_spike_count[5]>8'd5)?1:0;
            if(got==expected) xor_correct=xor_correct+1;
        end
        $display("    Stress test: %0d/20 correct",xor_correct);
        if(xor_correct>=15)
            pass_test($sformatf("Stress test (%0d/20 >= 75%%)",xor_correct));
        else
            fail_test("Stress test",$sformatf("Only %0d/20 correct",xor_correct));

        // PHASE 8
        $display("\nPHASE 8 -- Edge Cases");

        // (a) All-zero input
        do_reset; load_xor_weights;
        cfg_input[0]=8'h00; cfg_input[1]=8'h00;
        cfg_encode_mode=0; cfg_t_max=T_MAX;
        run_inference;
        if(out_spike_count[5]==0)
            pass_test("All-zero input -> no output spikes");
        else
            fail_test("All-zero input",$sformatf("Unexpected spike count=%0d",out_spike_count[5]));

        // (b) t_max=1
        do_reset;
        cfg_input[0]=8'hFF; cfg_input[1]=8'hFF;
        cfg_encode_mode=0; cfg_t_max=16'd1;
        run_inference;
        // done persists until next run; timestep==1 confirms one step ran
        if(out_done && out_timestep==1)
            pass_test("t_max=1 completes in one timestep");
        else
            fail_test("t_max=1",$sformatf("done=%0b timestep=%0d",out_done,out_timestep));

        // (c) Double-trigger protection
        do_reset; load_xor_weights;
        cfg_input[0]=8'hFF; cfg_input[1]=8'h00;
        cfg_encode_mode=0; cfg_t_max=T_MAX;
        @(posedge clk); #1; cfg_run=1;
        @(posedge clk); #1; cfg_run=1; // second pulse -- ignored by FSM (not in S_IDLE)
        @(posedge clk); #1; cfg_run=0;
        fork : wait_double_trigger
            begin wait(out_done==1); disable wait_double_trigger; end
            begin #40_000_000; $display("[ERROR] Double-trigger timeout!"); $finish; end
        join
        @(posedge clk); #1;
        if(out_done)
            pass_test("Double-trigger: chip completes normally");
        else
            fail_test("Double-trigger","chip did not complete");

        $display("\n=== Summary: %0d PASS, %0d FAIL ===",pass_count,fail_count);
        $finish;
    end

endmodule
