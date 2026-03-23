// ============================================================
// Module:      neuron_core
// Project:     NeuraEdge Neuromorphic AI Processor
// Description: Leaky Integrate-and-Fire (LIF) neuron array.
//
// LIF equations (discrete-time):
//   V_next = clamp(V >> LEAK_SHIFT + w*input)  [no fire]
//   V_next = RESET_VAL                           [fire cycle]
//   fire   = (V_current >= THRESHOLD)
//
// Changelog:
//   v1.0 — initial
//   v1.1 — NBA ordering fix (BUG-1); added neuron_enable, fire_count
//   v1.2 — AUDIT FIX: fire_count NBA race (BUG-1.1)
//   v1.3 — FIX N3: inline wire init inside generate replaced with
//           explicit wire+assign for IEEE-1364 Verilog-2001 compliance.
//           Old: per-neuron NBA inside for-loop; last write wins when
//           multiple neurons fire simultaneously -> undercounts by N-1.
//           New: combinational popcount -> single NBA, always correct.
//   v1.4 — FIX: Added $fatal assertion — THRESHOLD > MEM_WIDTH capacity
//            was silently truncated to THRESHOLD[MEM_WIDTH-1:0] causing
//            neurons to fire far below intended threshold.
//          — FIX: fire_count now saturates at 32'hFFFFFFFF instead of
//            wrapping silently.
//   v2.0 — Converted to SystemVerilog (.sv):
//            reg → logic; always @(*) → always_comb;
//            always @(posedge clk) → always_ff @(posedge clk or negedge rst_n).
//            No functional changes.
//
// Author:  NeuraEdge / Rahul Verma | Version: 2.0.0 | Apache 2.0
// ============================================================
`timescale 1ns / 1ps

module neuron_core #(
    parameter int NUM_NEURONS = 64,
    parameter int MEM_WIDTH   = 8,
    parameter int THRESHOLD   = 100,  // sim-friendly default; neuraedge_top overrides to 200
    parameter int LEAK_SHIFT  = 1,
    parameter int RESET_VAL   = 0
)(
    input  logic                              clk,
    input  logic                              rst_n,
    input  logic [$clog2(NUM_NEURONS)-1:0]    neuron_id,
    input  logic [MEM_WIDTH-1:0]              synaptic_input,
    input  logic                              input_valid,
    input  logic [NUM_NEURONS-1:0]            neuron_enable,
    output logic [NUM_NEURONS-1:0]            spike_out,
    output logic [MEM_WIDTH-1:0]              mem_debug,
    output logic [31:0]                       fire_count
);

    // Compile-time guard — THRESHOLD must fit in MEM_WIDTH bits.
    // Without this, THRESHOLD=300 silently becomes THRESHOLD[7:0]=44 and
    // neurons fire far too early with no warning.
    initial begin
        if (THRESHOLD > ((1 << MEM_WIDTH) - 1))
            $fatal(1, "[neuron_core] THRESHOLD=%0d does not fit in MEM_WIDTH=%0d bits (max=%0d). Widen MEM_WIDTH or lower THRESHOLD.",
                   THRESHOLD, MEM_WIDTH, (1 << MEM_WIDTH) - 1);
        if (RESET_VAL > ((1 << MEM_WIDTH) - 1))
            $fatal(1, "[neuron_core] RESET_VAL=%0d does not fit in MEM_WIDTH=%0d bits.",
                   RESET_VAL, MEM_WIDTH);
    end

    logic [MEM_WIDTH-1:0] membrane [0:NUM_NEURONS-1];

    // Saturating unsigned add — returns MEM_WIDTH bits
    function automatic logic [MEM_WIDTH-1:0] sat_add(
        input logic [MEM_WIDTH-1:0] a, b
    );
        logic [MEM_WIDTH:0] s;
        s       = {1'b0, a} + {1'b0, b};
        sat_add = s[MEM_WIDTH] ? {MEM_WIDTH{1'b1}} : s[MEM_WIDTH-1:0];
    endfunction

    // ---- Combinational next-state for every neuron ----------
    logic [MEM_WIDTH-1:0] next_membrane [0:NUM_NEURONS-1];

    generate
        for (genvar gi = 0; gi < NUM_NEURONS; gi++) begin : gen_next
            logic [MEM_WIDTH-1:0] after_leak;
            logic [MEM_WIDTH-1:0] after_integrate;

            assign after_leak      = membrane[gi] >> LEAK_SHIFT;
            assign after_integrate = (input_valid && (gi == NUM_NEURONS'(neuron_id)))
                                     ? sat_add(after_leak, synaptic_input)
                                     : after_leak;

            assign next_membrane[gi] =
                !neuron_enable[gi]                                    ? membrane[gi]
              : (membrane[gi] > MEM_WIDTH'(THRESHOLD))                ? MEM_WIDTH'(RESET_VAL)
              : after_integrate;
        end
    endgenerate

    // ---- Combinational popcount — one NBA, no race ----------
    logic [6:0] fires_this_cycle;

    always_comb begin
        fires_this_cycle = 7'd0;
        for (int fc = 0; fc < NUM_NEURONS; fc++)
            if (neuron_enable[fc] && membrane[fc] > MEM_WIDTH'(THRESHOLD))
                fires_this_cycle = fires_this_cycle + 7'd1;
    end

    // ---- Clocked update -------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_NEURONS; i++)
                membrane[i] <= {MEM_WIDTH{1'b0}};
            spike_out  <= {NUM_NEURONS{1'b0}};
            fire_count <= 32'd0;
        end else begin
            for (int i = 0; i < NUM_NEURONS; i++) begin
                membrane[i]  <= next_membrane[i];
                spike_out[i] <= neuron_enable[i] &&
                                (membrane[i] > MEM_WIDTH'(THRESHOLD));
            end
            // Saturate fire_count at 32'hFFFFFFFF — no silent wrap
            fire_count <= (fire_count + {25'd0, fires_this_cycle} < fire_count)
                          ? 32'hFFFF_FFFF
                          : fire_count + {25'd0, fires_this_cycle};
        end
    end

    assign mem_debug = membrane[neuron_id];

endmodule
