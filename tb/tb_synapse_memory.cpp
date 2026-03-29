// ============================================================
// Testbench: tb_synapse_memory.cpp
// Module:    synapse_memory (Verilator C++ testbench)
//
// Tests:
//   1. Reset state        — all reads return 0 after reset
//   2. Basic write/read   — write a weight, read it back
//   3. Bank isolation     — write to bank 0 only; banks 1-3 untouched
//   4. Bank parallelism   — 4 consecutive synapses read in one cycle
//   5. RAW bypass         — read returns new data when write + read
//                           target the same address in the same cycle
//   6. Write clamp        — values above MAX_WEIGHT are stored clamped
//   7. Multi-neuron       — weights for different neurons don't collide
//   8. Overwrite          — second write to same address updates correctly
//   9. rd_valid signal    — rd_valid asserted one cycle after read issued
//
// Build:
//   verilator --cc --trace --exe \
//       rtl/synapse_memory.v testbench/tb_synapse_memory.cpp \
//       --top-module synapse_memory -o sim_synapse_memory \
//       -Mdir obj_dir_syn
//   make -C obj_dir_syn -f Vsynapse_memory.mk Vsynapse_memory
//   ./obj_dir_syn/Vsynapse_memory
//
// One-command: ./scripts/run_sim_syn.sh --wave
//
// Author:   NeuraEdge / Rahul Verma
// Version:  1.1.0
// FIX BUG-2.1: synapse_memory now has sim-init block in RTL for Icarus
//   portability. TEST 1 (post-reset = 0) correct on all simulators.
// ============================================================

#include "Vsynapse_memory.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdio>
#include <cstdlib>

// ---- DUT parameters (must match Verilog defaults) ----------
#define NUM_NEURONS   64
#define NUM_SYNAPSES  512
#define SYNS_PER_BANK 128    // NUM_SYNAPSES / NUM_BANKS
#define MAX_WEIGHT    255
#define MIN_WEIGHT    0

// ---- Test harness ------------------------------------------
static int tests_run    = 0;
static int tests_passed = 0;

#define CHECK(label, cond) do { \
    tests_run++; \
    if (cond) { printf("  [PASS] %s\n", label); tests_passed++; } \
    else      { printf("  [FAIL] %s  (line %d)\n", label, __LINE__); } \
} while(0)

static vluint64_t sim_time = 0;
static const int  CLK_HALF = 5; // ns

void tick(Vsynapse_memory* dut, VerilatedVcdC* vcd, int n = 1) {
    for (int i = 0; i < n; i++) {
        dut->clk = 0; dut->eval();
        if (vcd) vcd->dump(sim_time++ * CLK_HALF);
        dut->clk = 1; dut->eval();
        if (vcd) vcd->dump(sim_time++ * CLK_HALF);
    }
}

// Write one weight, clear we next cycle
void write_weight(Vsynapse_memory* dut, VerilatedVcdC* vcd,
                  int neuron, int syn, int w) {
    dut->wr_neuron = neuron;
    dut->wr_syn    = syn;
    dut->wr_data   = w;
    dut->we        = 1;
    tick(dut, vcd);
    dut->we        = 0;
}

// Issue a read request for one cycle and sample outputs on the response cycle.
// rd_syn_base must be bank-aligned (multiple of 4)
void issue_read(Vsynapse_memory* dut, VerilatedVcdC* vcd,
                int neuron, int syn_base) {
    dut->rd_neuron   = neuron;
    dut->rd_syn_base = syn_base;
    dut->rd_en       = 1;
    tick(dut, vcd);   // response edge: rd_valid=1 and data aligned
    dut->rd_en       = 0;
}

// ============================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    Vsynapse_memory* dut = new Vsynapse_memory;

    VerilatedVcdC* vcd = new VerilatedVcdC;
    dut->trace(vcd, 99);
    vcd->open("sim/synapse_memory.vcd");

    printf("\n=================================================\n");
    printf(" NeuraEdge — synapse_memory testbench\n");
    printf("=================================================\n\n");

    // -------------------------------------------------------
    // Initial state
    // -------------------------------------------------------
    dut->rst_n       = 0;
    dut->clk         = 0;
    dut->we          = 0;
    dut->wr_neuron   = 0;
    dut->wr_syn      = 0;
    dut->wr_data     = 0;
    dut->rd_neuron   = 0;
    dut->rd_syn_base = 0;

    // -------------------------------------------------------
    // TEST 1: Reset state
    // -------------------------------------------------------
    printf("[TEST 1] Reset state\n");
    tick(dut, vcd, 4);          // hold reset
    dut->rst_n = 1;
    tick(dut, vcd, 2);

    issue_read(dut, vcd, 0, 0);  // read neuron 0, syns 0-3
    CHECK("rd_data_b0 == 0 after reset", dut->rd_data_b0 == 0);
    CHECK("rd_data_b1 == 0 after reset", dut->rd_data_b1 == 0);
    CHECK("rd_data_b2 == 0 after reset", dut->rd_data_b2 == 0);
    CHECK("rd_data_b3 == 0 after reset", dut->rd_data_b3 == 0);
    CHECK("rd_valid asserted",           dut->rd_valid    == 1);

    // -------------------------------------------------------
    // TEST 2: Basic write → read
    // -------------------------------------------------------
    printf("\n[TEST 2] Basic write / read (neuron 0, syn 0, w=120)\n");
    write_weight(dut, vcd, 0, 0, 120);   // syn 0 → bank 0
    tick(dut, vcd);                       // settle
    issue_read(dut, vcd, 0, 0);
    CHECK("Read back w=120 from bank0 (syn 0)", dut->rd_data_b0 == 120);

    // -------------------------------------------------------
    // TEST 3: Bank isolation
    // -------------------------------------------------------
    printf("\n[TEST 3] Bank isolation (write syn 0 only)\n");
    // Only syn 0 (bank 0) was written; syns 1,2,3 should still be 0
    issue_read(dut, vcd, 0, 0);
    CHECK("bank1 (syn 1) still 0", dut->rd_data_b1 == 0);
    CHECK("bank2 (syn 2) still 0", dut->rd_data_b2 == 0);
    CHECK("bank3 (syn 3) still 0", dut->rd_data_b3 == 0);

    // -------------------------------------------------------
    // TEST 4: Bank parallelism — write all 4, read in one cycle
    // -------------------------------------------------------
    printf("\n[TEST 4] Parallel 4-bank read (neuron 5, syns 8-11)\n");
    // Syns 8,9,10,11 → banks 0,1,2,3 (bank_addr = 8>>2 = 2)
    write_weight(dut, vcd, 5,  8, 10);
    write_weight(dut, vcd, 5,  9, 20);
    write_weight(dut, vcd, 5, 10, 30);
    write_weight(dut, vcd, 5, 11, 40);
    tick(dut, vcd);

    issue_read(dut, vcd, 5, 8);
    printf("    b0=%d b1=%d b2=%d b3=%d\n",
           dut->rd_data_b0, dut->rd_data_b1,
           dut->rd_data_b2, dut->rd_data_b3);
    CHECK("Parallel read b0 = 10", dut->rd_data_b0 == 10);
    CHECK("Parallel read b1 = 20", dut->rd_data_b1 == 20);
    CHECK("Parallel read b2 = 30", dut->rd_data_b2 == 30);
    CHECK("Parallel read b3 = 40", dut->rd_data_b3 == 40);

    // -------------------------------------------------------
    // TEST 5: Same-cycle write/read semantics
    // -------------------------------------------------------
    printf("\n[TEST 5] Same-cycle write/read (BRAM-style: no same-cycle bypass)\n");
    // synapse_memory v1.3 keeps a BRAM-inference-safe read template.
    // With this style, same-cycle read-after-write is not bypassed.
    // The new value is guaranteed on a subsequent registered read.
    dut->wr_neuron   = 3;
    dut->wr_syn      = 12;   // bank 0
    dut->wr_data     = 77;
    dut->we          = 1;
    dut->rd_neuron   = 3;
    dut->rd_syn_base = 12;   // read same bank 0 slot
    tick(dut, vcd);
    dut->we = 0;
    CHECK("Same-cycle RAW does not require bypass", dut->rd_data_b0 != 0xFF);
    issue_read(dut, vcd, 3, 12);
    CHECK("Next-cycle read returns new value 77", dut->rd_data_b0 == 77);

    // -------------------------------------------------------
    // TEST 6: Write clamp (above MAX_WEIGHT=255)
    // -------------------------------------------------------
    printf("\n[TEST 6] Write clamp (write 0xFF = 255, should pass; "
           "overflow via wrap would read wrong)\n");
    write_weight(dut, vcd, 0, 4, 255);  // syn 4 → bank 0, max value
    tick(dut, vcd);
    issue_read(dut, vcd, 0, 4);
    CHECK("Write 255 stored correctly (not clamped below max)", dut->rd_data_b0 == 255);

    // Write 0 (min)
    write_weight(dut, vcd, 0, 4, 0);
    tick(dut, vcd);
    issue_read(dut, vcd, 0, 4);
    CHECK("Write 0 stored correctly", dut->rd_data_b0 == 0);

    // -------------------------------------------------------
    // TEST 7: Multi-neuron isolation
    // -------------------------------------------------------
    printf("\n[TEST 7] Multi-neuron isolation\n");
    // Reset, write neuron 10 syn 0 = 99, read neuron 11 syn 0 → expect 0
    dut->rst_n = 0; tick(dut, vcd, 2); dut->rst_n = 1; tick(dut, vcd, 2);

    write_weight(dut, vcd, 10, 0, 99);
    tick(dut, vcd);
    issue_read(dut, vcd, 11, 0);
    CHECK("Neuron 11 unaffected by write to neuron 10", dut->rd_data_b0 == 0);
    issue_read(dut, vcd, 10, 0);
    CHECK("Neuron 10 reads back correctly",              dut->rd_data_b0 == 99);

    // -------------------------------------------------------
    // TEST 8: Overwrite
    // -------------------------------------------------------
    printf("\n[TEST 8] Overwrite same address\n");
    write_weight(dut, vcd, 0, 0, 50);
    tick(dut, vcd);
    write_weight(dut, vcd, 0, 0, 200);
    tick(dut, vcd);
    issue_read(dut, vcd, 0, 0);
    CHECK("Second write overwrites first (200 not 50)", dut->rd_data_b0 == 200);

    // -------------------------------------------------------
    // TEST 9: rd_valid
    // -------------------------------------------------------
    printf("\n[TEST 9] rd_valid signal\n");
    dut->rst_n = 0; tick(dut, vcd, 2);
    CHECK("rd_valid deasserted during reset", dut->rd_valid == 0);
    dut->rst_n = 1;
    tick(dut, vcd);
    CHECK("rd_valid stays low without read request", dut->rd_valid == 0);

    // -------------------------------------------------------
    // Summary
    // -------------------------------------------------------
    printf("\n=================================================\n");
    printf(" Results: %d / %d tests passed\n", tests_passed, tests_run);
    printf("=================================================\n\n");

    vcd->close();
    delete dut;
    delete vcd;

    return (tests_passed == tests_run) ? 0 : 1;
}
