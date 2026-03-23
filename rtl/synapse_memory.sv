// ============================================================
// Module:      synapse_memory
// Description: 4-bank interleaved BRAM synapse weight store.
//
// Change log:
//   v1.0 — initial (2-D array, no BRAM inference)
//   v1.1 — flat 1-D + (* ram_style="block" *) for BRAM inference
//   v1.2 — BUG-5/S1: dump task boffset fix
//   v1.3 — FIX BRAM INFERENCE (CRITICAL):
//           Removed rst_n branch from clocked read block.
//           Artix-7 BRAM18 output registers have NO synchronous reset.
//           The reset forced Vivado to fall back to distributed RAM
//           (30,221 LUTs instead of expected ~2,100).
//           rd_valid still resets — that is BRAM-inference-safe.
//   v2.0 — Converted to SystemVerilog (.sv):
//            reg → logic; always @(posedge clk) → always_ff;
//            BRAM read path kept as always_ff without sensitivity
//            list change — reset-free, required for BRAM18 inference.
//            No functional changes.
//
// Author:   NeuraEdge / Rahul Verma | Version: 2.0.0 | Apache 2.0
// ============================================================
`timescale 1ns / 1ps

module synapse_memory #(
    parameter int NUM_NEURONS   = 64,
    parameter int NUM_SYNAPSES  = 512,
    parameter int WIDTH         = 8,
    parameter int NUM_BANKS     = 4,
    parameter int MAX_WEIGHT    = 255,
    parameter int MIN_WEIGHT    = 0
)(
    input  logic clk,
    input  logic rst_n,

    // Write port
    input  logic [$clog2(NUM_NEURONS)-1:0]   wr_neuron,
    input  logic [$clog2(NUM_SYNAPSES)-1:0]  wr_syn,
    input  logic [WIDTH-1:0]                 wr_data,
    input  logic                             we,

    // Read port (4-bank parallel, 1-cycle registered latency)
    input  logic [$clog2(NUM_NEURONS)-1:0]   rd_neuron,
    input  logic [$clog2(NUM_SYNAPSES)-1:0]  rd_syn_base,

    output logic [WIDTH-1:0]  rd_data_b0,
    output logic [WIDTH-1:0]  rd_data_b1,
    output logic [WIDTH-1:0]  rd_data_b2,
    output logic [WIDTH-1:0]  rd_data_b3,
    output logic [WIDTH-1:0]  rd_data_sel,
    output logic              rd_valid
);

    localparam int BANK_SEL_BITS = $clog2(NUM_BANKS);
    localparam int SYNS_PER_BANK = NUM_SYNAPSES / NUM_BANKS;
    localparam int BANK_ADDR_W   = $clog2(SYNS_PER_BANK);
    localparam int NEURON_W      = $clog2(NUM_NEURONS);
    localparam int FLAT_ADDR_W   = NEURON_W + BANK_ADDR_W;
    localparam int DEPTH         = NUM_NEURONS * SYNS_PER_BANK;

    // ---- 4 flat BRAM banks ----------------------------------
    // No reset on output registers — required for BRAM18 inference on Artix-7.
    (* ram_style = "block" *) logic [WIDTH-1:0] bank0 [0:DEPTH-1];
    (* ram_style = "block" *) logic [WIDTH-1:0] bank1 [0:DEPTH-1];
    (* ram_style = "block" *) logic [WIDTH-1:0] bank2 [0:DEPTH-1];
    (* ram_style = "block" *) logic [WIDTH-1:0] bank3 [0:DEPTH-1];

    // Simulation initialisation (BRAMs are X at power-on in hardware)
    // synthesis translate_off
    initial begin
        for (int k = 0; k < DEPTH; k++) begin
            bank0[k] = {WIDTH{1'b0}};
            bank1[k] = {WIDTH{1'b0}};
            bank2[k] = {WIDTH{1'b0}};
            bank3[k] = {WIDTH{1'b0}};
        end
    end
    // synthesis translate_on

    // ---- Write decode ---------------------------------------
    logic [WIDTH-1:0]         wr_clamped;
    logic [BANK_SEL_BITS-1:0] wr_bank_sel;
    logic [BANK_ADDR_W-1:0]   wr_bank_addr;
    logic [FLAT_ADDR_W-1:0]   wr_flat;

    assign wr_clamped   = (wr_data > WIDTH'(MAX_WEIGHT)) ? WIDTH'(MAX_WEIGHT) :
                          (wr_data < WIDTH'(MIN_WEIGHT))  ? WIDTH'(MIN_WEIGHT) :
                           wr_data;
    assign wr_bank_sel  = wr_syn[BANK_SEL_BITS-1:0];
    assign wr_bank_addr = wr_syn[$clog2(NUM_SYNAPSES)-1:BANK_SEL_BITS];
    assign wr_flat      = {wr_neuron, wr_bank_addr};

    logic we_b0, we_b1, we_b2, we_b3;
    assign we_b0 = we & (wr_bank_sel == 2'd0);
    assign we_b1 = we & (wr_bank_sel == 2'd1);
    assign we_b2 = we & (wr_bank_sel == 2'd2);
    assign we_b3 = we & (wr_bank_sel == 2'd3);

    // ---- Read decode ----------------------------------------
    logic [BANK_ADDR_W-1:0]   rd_bank_addr;
    logic [FLAT_ADDR_W-1:0]   rd_flat;
    logic [BANK_SEL_BITS-1:0] rd_bank_sel;

    assign rd_bank_addr = rd_syn_base[$clog2(NUM_SYNAPSES)-1:BANK_SEL_BITS];
    assign rd_flat      = {rd_neuron, rd_bank_addr};
    assign rd_bank_sel  = rd_syn_base[BANK_SEL_BITS-1:0];

    // ---- Registered BRAM read — inference-safe template -----
    // One registered read per bank; no reset on output registers.
    // A second always_ff selects rd_data_sel from the registered bank outputs.
    always_ff @(posedge clk) begin
        rd_data_b0 <= bank0[rd_flat];
        rd_data_b1 <= bank1[rd_flat];
        rd_data_b2 <= bank2[rd_flat];
        rd_data_b3 <= bank3[rd_flat];
    end

    always_ff @(posedge clk) begin
        case (rd_bank_sel)
            2'd0:    rd_data_sel <= rd_data_b0;
            2'd1:    rd_data_sel <= rd_data_b1;
            2'd2:    rd_data_sel <= rd_data_b2;
            default: rd_data_sel <= rd_data_b3;
        endcase
    end

    // rd_valid: plain FF with synchronous reset — BRAM-inference-safe
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rd_valid <= 1'b0;
        else        rd_valid <= 1'b1;
    end

    // ---- Gated writes ---------------------------------------
    always_ff @(posedge clk) begin
        if (we_b0) bank0[wr_flat] <= wr_clamped;
        if (we_b1) bank1[wr_flat] <= wr_clamped;
        if (we_b2) bank2[wr_flat] <= wr_clamped;
        if (we_b3) bank3[wr_flat] <= wr_clamped;
    end

    // ---- Simulation-only weight dump ------------------------
    // synthesis translate_off
    task automatic dump_neuron_weights(input int nid, input int num_syns);
        logic [FLAT_ADDR_W-1:0] fa;
        logic [BANK_ADDR_W-1:0] boffset;
        int bank_idx;
        begin
            $display("=== Weight dump: neuron %0d ===", nid);
            for (int s = 0; s < num_syns; s += 4) begin
                bank_idx = s / 4;
                boffset  = BANK_ADDR_W'(bank_idx);
                fa       = {NEURON_W'(nid), boffset};
                $display("  syn[%3d..%3d]: %3d %3d %3d %3d",
                    s, s+3,
                    bank0[fa], bank1[fa], bank2[fa], bank3[fa]);
            end
        end
    endtask
    // synthesis translate_on

endmodule
