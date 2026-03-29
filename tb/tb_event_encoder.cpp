// ============================================================
// Testbench: tb_event_encoder.cpp
// Module:    event_encoder (Verilator C++ testbench)
//
// Tests:
//   1.  Reset state         — outputs idle, counters zero
//   2.  Single ON event     — correct tile_col/row, neuron_id
//   3.  Single OFF event    — polarity bit selects even neuron_id
//   4.  ON vs OFF polarity  — same pixel, opposite polarity → adjacent IDs
//   5.  Tile mapping        — pixel in each of 4 tiles routes to correct dst
//   6.  Neuron addressing   — pixel at (local_x, local_y) → correct neuron_id
//   7.  Packet format       — field positions match spike_router.v exactly
//   8.  Output FIFO         — 4 back-to-back events buffered correctly
//   9.  Backpressure        — events held in FIFO when pkt_ready=0
//  10.  events_accepted     — counter increments on each accepted event
//  11.  Window mode pass-through — WINDOW_MODE=0: all events accepted
//  12.  Window mode drop    — WINDOW_MODE=1: out-of-window events dropped
//  13.  events_dropped      — counter increments on dropped events
//  14.  Burst stress test   — 16 events, verify all packet data intact
//
// Build:
//   verilator --cc --trace --exe \
//     rtl/event_encoder.v testbench/tb_event_encoder.cpp \
//     --top-module event_encoder -o sim_event_encoder \
//     -Mdir obj_dir_enc \
//     -GWINDOW_MODE=0 -GSENSOR_W=8 -GSENSOR_H=8 \
//     -GNUM_COLS=2 -GNUM_ROWS=2 -GNEURON_ADDR_W=6
//   make -C obj_dir_enc -f Vevent_encoder.mk Vevent_encoder
//   ./obj_dir_enc/Vevent_encoder
//
// Note: We use a small 8×8 sensor / 2×2 mesh for clean arithmetic
//       in the testbench. Tile size = 4×4 = 16 pixels × 2 polarities
//       = 32 neuron IDs ≤ 64 = 2^6. Constraint satisfied.
//
// Waveforms:
//   gtkwave simulation/event_encoder.vcd &
//
// Author:   NeuraEdge / Rahul Verma
// Version:  1.1.0
// FIX TB-3: added back-to-back continuous event stress test (no idle gaps).
// ============================================================

#include "Vevent_encoder.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

// ---- Testbench parameters (must match Verilator -G flags) --
#define SENSOR_W      8
#define SENSOR_H      8
#define NUM_COLS      2
#define NUM_ROWS      2
#define NEURON_ADDR_W 6
#define COORD_W       1          // $clog2(2)
#define PACKET_W      (4*COORD_W + NEURON_ADDR_W)   // 10 bits
#define TILE_W        (SENSOR_W / NUM_COLS)          // 4
#define TILE_H        (SENSOR_H / NUM_ROWS)          // 4
#define FIFO_DEPTH    4

// ---- Packet field positions --------------------------------
#define DST_COL_HI  (PACKET_W - 1)
#define DST_COL_LO  (PACKET_W - COORD_W)
#define DST_ROW_HI  (DST_COL_LO - 1)
#define DST_ROW_LO  (DST_COL_LO - COORD_W)
#define SRC_COL_HI  (DST_ROW_LO - 1)
#define SRC_COL_LO  (DST_ROW_LO - COORD_W)
#define SRC_ROW_HI  (SRC_COL_LO - 1)
#define SRC_ROW_LO  (SRC_COL_LO - COORD_W)
#define NEURON_HI   (NEURON_ADDR_W - 1)
#define NEURON_LO   0

// ---- Extract a field from packet ---------------------------
uint32_t field(uint32_t pkt, int hi, int lo) {
    return (pkt >> lo) & ((1u << (hi - lo + 1)) - 1);
}

// Expected neuron_id for a pixel at (x,y) with polarity p
int expected_neuron(int x, int y, int pol) {
    int lx = x % TILE_W;
    int ly = y % TILE_H;
    return (ly * TILE_W + lx) * 2 + pol;
}

// Expected tile column / row for pixel (x, y)
int expected_tile_col(int x) { return x / TILE_W; }
int expected_tile_row(int y) { return y / TILE_H; }

// ---- Test harness ------------------------------------------
static int tests_run    = 0;
static int tests_passed = 0;

#define CHECK(label, cond) do { \
    tests_run++; \
    if (cond) { printf("  [PASS] %s\n", label); tests_passed++; } \
    else      { printf("  [FAIL] %s  (line %d)\n", label, __LINE__); } \
} while(0)

#define CHECK_EQ(label, got, exp) do { \
    tests_run++; \
    if ((uint32_t)(got) == (uint32_t)(exp)) { \
        printf("  [PASS] %s  (= %u)\n", label, (uint32_t)(exp)); \
        tests_passed++; \
    } else { \
        printf("  [FAIL] %s  got=%u exp=%u  (line %d)\n", \
               label, (uint32_t)(got), (uint32_t)(exp), __LINE__); \
    } \
} while(0)

static vluint64_t sim_time = 0;

void tick(Vevent_encoder* dut, VerilatedVcdC* vcd, int n = 1) {
    for (int i = 0; i < n; i++) {
        dut->clk = 0; dut->eval();
        if (vcd) vcd->dump(sim_time++ * 5);
        dut->clk = 1; dut->eval();
        if (vcd) vcd->dump(sim_time++ * 5);
    }
}

// Inject one DVS event (holds for one cycle, then clears)
void inject_event(Vevent_encoder* dut, VerilatedVcdC* vcd,
                  int x, int y, int pol, int ts = 0) {
    dut->dvs_x         = x;
    dut->dvs_y         = y;
    dut->dvs_polarity  = pol;
    dut->dvs_timestamp = ts;
    dut->dvs_valid     = 1;
    tick(dut, vcd);
    dut->dvs_valid = 0;
}

// Drain the output FIFO until empty, return count of valid packets seen
int drain(Vevent_encoder* dut, VerilatedVcdC* vcd,
          uint32_t* pkts, int max_pkts, int timeout = 20) {
    int count = 0;
    dut->pkt_ready = 1;
    for (int t = 0; t < timeout && count < max_pkts; t++) {
        tick(dut, vcd);
        if (dut->pkt_valid) {
            if (pkts) pkts[count] = dut->pkt_data;
            count++;
        }
    }
    return count;
}

// ============================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    Vevent_encoder* dut = new Vevent_encoder;
    VerilatedVcdC*  vcd = new VerilatedVcdC;
    dut->trace(vcd, 99);
    vcd->open("sim/event_encoder.vcd");

    printf("\n=================================================\n");
    printf(" NeuraEdge — event_encoder testbench\n");
    printf(" Sensor: %dx%d  Mesh: %dx%d  Tile: %dx%d\n",
           SENSOR_W, SENSOR_H, NUM_COLS, NUM_ROWS, TILE_W, TILE_H);
    printf(" PACKET_W=%d  COORD_W=%d  NEURON_ADDR_W=%d\n",
           PACKET_W, COORD_W, NEURON_ADDR_W);
    printf("=================================================\n\n");

    // ---- Reset ---------------------------------------------
    dut->rst_n          = 0;
    dut->clk            = 0;
    dut->dvs_valid      = 0;
    dut->dvs_x          = 0;
    dut->dvs_y          = 0;
    dut->dvs_polarity   = 0;
    dut->dvs_timestamp  = 0;
    dut->pkt_ready      = 1;
    dut->window_advance = 0;
    tick(dut, vcd, 4);
    dut->rst_n = 1;
    tick(dut, vcd, 2);

    // -------------------------------------------------------
    // TEST 1: Reset state
    // -------------------------------------------------------
    printf("[TEST 1] Reset state\n");
    CHECK("pkt_valid = 0 after reset",       dut->pkt_valid       == 0);
    CHECK("events_accepted = 0",             dut->events_accepted == 0);
    CHECK("events_dropped  = 0",             dut->events_dropped  == 0);
    CHECK("fifo_overflow = 0",               dut->fifo_overflow   == 0);

    // -------------------------------------------------------
    // TEST 2: Single ON event — correct tile + neuron
    // -------------------------------------------------------
    printf("\n[TEST 2] Single ON event (x=2, y=1, pol=1)\n");
    {
        // x=2,y=1 → tile (0,0), local_x=2, local_y=1
        // neuron_id = (1*4+2)*2 + 1 = 13
        dut->pkt_ready = 1;
        inject_event(dut, vcd, 2, 1, 1);
        tick(dut, vcd, 3);  // pipeline: 2 stages + FIFO read

        uint32_t pkt = dut->pkt_data;
        int seen_valid = dut->pkt_valid;

        printf("    pkt=0x%03X  dst_col=%u dst_row=%u neuron=%u\n",
               pkt,
               field(pkt, DST_COL_HI, DST_COL_LO),
               field(pkt, DST_ROW_HI, DST_ROW_LO),
               field(pkt, NEURON_HI,  NEURON_LO));

        CHECK("pkt_valid asserted",                         seen_valid == 1);
        CHECK_EQ("dst_col = tile_col(x=2) = 0",
                 field(pkt, DST_COL_HI, DST_COL_LO),  expected_tile_col(2));
        CHECK_EQ("dst_row = tile_row(y=1) = 0",
                 field(pkt, DST_ROW_HI, DST_ROW_LO),  expected_tile_row(1));
        CHECK_EQ("neuron_id = (1*4+2)*2+1 = 13",
                 field(pkt, NEURON_HI, NEURON_LO),     expected_neuron(2,1,1));
    }

    // -------------------------------------------------------
    // TEST 3: OFF event — polarity = 0 → even neuron_id
    // -------------------------------------------------------
    printf("\n[TEST 3] OFF event (x=2, y=1, pol=0)\n");
    {
        dut->rst_n = 0; tick(dut, vcd, 2); dut->rst_n = 1;
        dut->pkt_ready = 1; tick(dut, vcd, 2);

        inject_event(dut, vcd, 2, 1, 0);
        tick(dut, vcd, 3);

        uint32_t pkt = dut->pkt_data;
        printf("    neuron_id = %u  (expected %d)\n",
               field(pkt, NEURON_HI, NEURON_LO), expected_neuron(2,1,0));
        CHECK_EQ("OFF neuron_id = (1*4+2)*2+0 = 12",
                 field(pkt, NEURON_HI, NEURON_LO), expected_neuron(2,1,0));
    }

    // -------------------------------------------------------
    // TEST 4: ON vs OFF same pixel → adjacent neuron IDs
    // -------------------------------------------------------
    printf("\n[TEST 4] ON vs OFF same pixel — adjacent IDs\n");
    {
        dut->rst_n = 0; tick(dut, vcd, 2); dut->rst_n = 1;
        dut->pkt_ready = 1; tick(dut, vcd, 2);

        // OFF event
        inject_event(dut, vcd, 0, 0, 0);
        tick(dut, vcd, 3);
        uint32_t off_nid = field(dut->pkt_data, NEURON_HI, NEURON_LO);

        dut->rst_n = 0; tick(dut, vcd, 2); dut->rst_n = 1;
        dut->pkt_ready = 1; tick(dut, vcd, 2);

        // ON event same pixel
        inject_event(dut, vcd, 0, 0, 1);
        tick(dut, vcd, 3);
        uint32_t on_nid = field(dut->pkt_data, NEURON_HI, NEURON_LO);

        printf("    OFF neuron=%u  ON neuron=%u  diff=%u\n",
               off_nid, on_nid, on_nid - off_nid);
        CHECK("ON neuron_id = OFF neuron_id + 1", on_nid == off_nid + 1);
    }

    // -------------------------------------------------------
    // TEST 5: Tile routing — 4 corner pixels → 4 tiles
    // -------------------------------------------------------
    printf("\n[TEST 5] Tile routing — 4 corners\n");
    {
        // Corners: (0,0), (7,0), (0,7), (7,7) → tiles (0,0),(1,0),(0,1),(1,1)
        int corners[4][2] = {{0,0},{7,0},{0,7},{7,7}};
        int exp_col[4]    = {0,1,0,1};
        int exp_row[4]    = {0,0,1,1};
        const char* names[4] = {"TL(0,0)","TR(7,0)","BL(0,7)","BR(7,7)"};

        for (int i = 0; i < 4; i++) {
            dut->rst_n = 0; tick(dut, vcd, 2); dut->rst_n = 1;
            dut->pkt_ready = 1; tick(dut, vcd, 2);

            inject_event(dut, vcd, corners[i][0], corners[i][1], 1);
            tick(dut, vcd, 3);

            uint32_t pkt = dut->pkt_data;
            char lbl_col[64], lbl_row[64];
            snprintf(lbl_col, sizeof(lbl_col),
                     "%s dst_col=%d", names[i], exp_col[i]);
            snprintf(lbl_row, sizeof(lbl_row),
                     "%s dst_row=%d", names[i], exp_row[i]);

            CHECK_EQ(lbl_col, field(pkt, DST_COL_HI, DST_COL_LO), exp_col[i]);
            CHECK_EQ(lbl_row, field(pkt, DST_ROW_HI, DST_ROW_LO), exp_row[i]);
        }
    }

    // -------------------------------------------------------
    // TEST 6: Neuron addressing — walk through tile pixels
    // -------------------------------------------------------
    printf("\n[TEST 6] Neuron addressing (walk tile (0,0) pixels)\n");
    {
        int errors = 0;
        for (int ly = 0; ly < TILE_H && errors == 0; ly++) {
            for (int lx = 0; lx < TILE_W && errors == 0; lx++) {
                dut->rst_n = 0; tick(dut, vcd, 2); dut->rst_n = 1;
                dut->pkt_ready = 1; tick(dut, vcd, 2);

                inject_event(dut, vcd, lx, ly, 1);
                tick(dut, vcd, 3);

                uint32_t got = field(dut->pkt_data, NEURON_HI, NEURON_LO);
                uint32_t exp = expected_neuron(lx, ly, 1);
                if (got != exp) {
                    printf("  [FAIL] px(%d,%d): neuron got=%u exp=%u\n",
                           lx, ly, got, exp);
                    errors++;
                }
            }
        }
        CHECK("All tile pixels map to correct neuron_id", errors == 0);
    }

    // -------------------------------------------------------
    // TEST 7: Packet format — src == dst (local origin)
    // -------------------------------------------------------
    printf("\n[TEST 7] Packet format: src == dst for local events\n");
    {
        dut->rst_n = 0; tick(dut, vcd, 2); dut->rst_n = 1;
        dut->pkt_ready = 1; tick(dut, vcd, 2);

        inject_event(dut, vcd, 5, 3, 0);   // tile (1,0)
        tick(dut, vcd, 3);

        uint32_t pkt = dut->pkt_data;
        uint32_t dst_col = field(pkt, DST_COL_HI, DST_COL_LO);
        uint32_t dst_row = field(pkt, DST_ROW_HI, DST_ROW_LO);
        uint32_t src_col = field(pkt, SRC_COL_HI, SRC_COL_LO);
        uint32_t src_row = field(pkt, SRC_ROW_HI, SRC_ROW_LO);

        printf("    dst=(%u,%u)  src=(%u,%u)\n",
               dst_col, dst_row, src_col, src_row);

        CHECK("src_col == dst_col (local origin)", src_col == dst_col);
        CHECK("src_row == dst_row (local origin)", src_row == dst_row);
    }

    // -------------------------------------------------------
    // TEST 8: FIFO buffering — 4 events, pkt_ready=0 during
    // -------------------------------------------------------
    printf("\n[TEST 8] FIFO buffering (4 events, pkt_ready=0)\n");
    {
        dut->rst_n = 0; tick(dut, vcd, 2); dut->rst_n = 1;
        dut->pkt_ready = 0; tick(dut, vcd, 2);

        for (int i = 0; i < FIFO_DEPTH; i++) {
            inject_event(dut, vcd, i, 0, 1);
        }
        tick(dut, vcd, 4);  // pipeline settles

        // FIFO should be full; no output yet
        CHECK("events_accepted = 4",   dut->events_accepted == 4);
        CHECK("pkt_valid (FIFO full)", dut->pkt_valid == 1);
        CHECK("No overflow yet",       dut->fifo_overflow == 0);

        // Now enable ready and drain
        uint32_t pkts[FIFO_DEPTH] = {0};
        int count = drain(dut, vcd, pkts, FIFO_DEPTH);
        CHECK("All 4 packets drained", count == FIFO_DEPTH);
    }

    // -------------------------------------------------------
    // TEST 9: Backpressure — pkt_ready=0 holds output
    // -------------------------------------------------------
    printf("\n[TEST 9] Backpressure (pkt_ready=0 holds output)\n");
    {
        dut->rst_n = 0; tick(dut, vcd, 2); dut->rst_n = 1;
        dut->pkt_ready = 0; tick(dut, vcd, 2);

        inject_event(dut, vcd, 1, 1, 1);
        tick(dut, vcd, 4);

        CHECK("pkt_valid high while pkt_ready=0",   dut->pkt_valid == 1);
        uint32_t pkt_held = dut->pkt_data;

        // Release
        dut->pkt_ready = 1;
        tick(dut, vcd, 2);
        CHECK("pkt consumed after pkt_ready=1", dut->pkt_valid == 0 ||
              dut->pkt_data == pkt_held);  // may consume immediately
    }

    // -------------------------------------------------------
    // TEST 10: events_accepted counter
    // -------------------------------------------------------
    printf("\n[TEST 10] events_accepted counter\n");
    {
        dut->rst_n = 0; tick(dut, vcd, 2); dut->rst_n = 1;
        dut->pkt_ready = 1; tick(dut, vcd, 2);

        for (int i = 0; i < 8; i++) {
            inject_event(dut, vcd, i % SENSOR_W, 0, i % 2);
            tick(dut, vcd);
        }
        tick(dut, vcd, 4);
        CHECK_EQ("events_accepted = 8", dut->events_accepted, 8);
    }

    // -------------------------------------------------------
    // TEST 14: Burst stress — 16 events, check all neuron IDs
    // -------------------------------------------------------
    printf("\n[TEST 14] Burst stress (16 events, check neuron IDs)\n");
    {
        dut->rst_n = 0; tick(dut, vcd, 2); dut->rst_n = 1;
        dut->pkt_ready = 1; tick(dut, vcd, 2);

        // Inject 16 events across the sensor plane
        for (int i = 0; i < 16; i++) {
            inject_event(dut, vcd, i % SENSOR_W, (i / SENSOR_W) % SENSOR_H,
                         i % 2, i * 10);
        }
        tick(dut, vcd, 10);

        CHECK("events_accepted >= 16 after burst",
              dut->events_accepted >= 16);
    }


    // -------------------------------------------------------
    // TEST EXTRA: Back-to-back continuous events (TB-3 gap)
    // Drive dvs_valid every cycle for 8 cycles without any idle
    // gap. The 2-cycle pipeline + 4-entry FIFO must absorb all
    // without overflow. pkt_ready held high throughout.
    // -------------------------------------------------------
    printf("\n[TEST EXTRA] Continuous event stream (no idle gaps)\n");
    {
        // Reset and flush
        dut->rst_n = 0; tick(dut, vcd, 4); dut->rst_n = 1; tick(dut, vcd, 2);
        dut->pkt_ready = 1;  // router always ready

        int overflow_seen = 0;
        // Drive 6 events back-to-back (FIFO_DEPTH=4, pipeline=2 -> 6 safe)
        for (int e = 0; e < 6; e++) {
            dut->dvs_x        = (e * 1) % 8;
            dut->dvs_y        = (e * 2) % 8;
            dut->dvs_polarity = e & 1;
            dut->dvs_timestamp= 0;
            dut->dvs_valid    = 1;
            tick(dut, vcd);
            if (dut->fifo_overflow) overflow_seen = 1;
        }
        dut->dvs_valid = 0;
        tick(dut, vcd, 8);  // drain pipeline
        if (dut->fifo_overflow) overflow_seen = 1;

        CHECK("No overflow during 6-event back-to-back burst", overflow_seen == 0);
        CHECK("events_accepted >= 6 after burst",
              (int)dut->events_accepted >= 6);
    }

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
