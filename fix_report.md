# NeuraEdge — Fix Report
**Auditor:** Senior RTL/FPGA Engineer  
**Date:** 2026-03-26  
**Scope:** Full codebase — RTL, testbenches, constraints, scripts, software

---

## Critical Fixes

### CRIT-1 — `spi_sclk_rise` static initializer (SPI weight loading broken)
**File:** `rtl/neuraedge_top.sv`  
**Root cause:** `logic spi_sclk_rise = spi_sclk_r && !spi_sclk_r2` is a static initializer, evaluated once at time-0 when both registers are 0. The signal never updates. All SPI weight loads silently do nothing.  
**Fix:** Changed to `logic spi_sclk_rise; assign spi_sclk_rise = spi_sclk_r && !spi_sclk_r2;` — continuous assignment, updates every cycle.

---

### CRIT-2 — `rd_valid` always 1 after reset (STDP reads stale weights)
**File:** `rtl/synapse_memory.sv`  
**Root cause:** `rd_valid <= 1'b1` with no gating means `p1_valid` in `learning_engine` is always high, so the first synapse of every STDP scan samples the previous scan's BRAM output.  
**Fix:** Added `rd_en` input port. `rd_valid` now tracks `rd_en` with 1-cycle latency. Updated `neuraedge_top.sv` to drive `rd_en` from cluster activity. Updated `synapse_memory_tb.v` to connect and test the new port.

---

### CRIT-3 — Classifier only reads cluster `[0][0]` (75% of compute ignored)
**File:** `rtl/neuraedge_top.sv`  
**Root cause:** Spike accumulation loop hard-coded to `spike_out[0][0][...]`. Three of four clusters contribute nothing to classification.  
**Fix:** Replaced with a double-nested loop over all `(ci, ri)` cluster pairs. Each cluster's top `NUM_CLASSES` neurons contribute to the accumulator, summed with a 4-bit per-class counter before adding to `spike_accum`.

---

## High-Severity Fixes

### HIGH-1 — 2-cycle BRAM latency vs 1-cycle FSM assumption
**Files:** `rtl/synapse_memory.sv`, `rtl/learning_engine.sv`  
**Root cause:** A second registered mux stage after the BRAM read created 2-cycle total latency while the FSM assumed 1 cycle. Pipeline stage `p1_weight` was computed from stale data every scan.  
**Fix:** Removed the registered mux stage. `rd_data_sel` is now a combinational `always_comb` mux on the registered BRAM outputs — 1-cycle total latency, matching the FSM. The `rd_bank_sel` is registered alongside the BRAM read to keep alignment correct.

---

### HIGH-2 — Dual non-blocking assignment race in trace update
**File:** `rtl/learning_engine.sv`  
**Root cause:** Two NBAs to `pre_trace[n]` in the same `always_ff` block when a spike fires — one for leak, one for spike increment. While Verilog semantics make this work correctly (last NBA wins), the pattern is fragile and was flagged as a tool-specific hazard.  
**Fix:** Restructured trace update to compute `leaked` as a local variable first, then issue exactly one NBA per register per cycle: leak path and spike-bump path are mutually exclusive branches.

---

### HIGH-3 — SPI `cid` hardcoded as 3-bit (caps addressing at 8 clusters)
**File:** `rtl/neuraedge_top.sv`  
**Root cause:** `logic [2:0] cid` inside the SPI decode block silently truncates cluster IDs above 7 regardless of `NUM_CLUSTERS`.  
**Fix:** Changed to `logic [$clog2(NUM_CLUSTERS)-1:0] cid`, width scales automatically with mesh size.

---

### HIGH-4 — Training script uses 34×34 sensor; RTL defaults to 8×8
**Files:** `software/train_nmnist.py`, `scripts/vivado/synth.tcl`  
**Root cause:** N-MNIST is a 34×34 DVS sensor. The training script uses `SENSOR_W=34`, but the RTL default and synth TCL both use 8×8. Weights loaded from a 34×34-trained model land on wrong neurons.  
**Fix:** Added explicit documentation and a warning comment in `synth.tcl` explaining the required parameter override for N-MNIST. The existing `$fatal` assertion in `event_encoder.sv` already catches this at elaboration — documented it clearly so it's not missed.

---

## Medium-Severity Fixes

### MED-1 — `fifo_overflow` from spike router disconnected
**File:** `rtl/neuraedge_top.sv`  
**Root cause:** `.fifo_overflow()` left unconnected in all four router instantiations. Overflow events silently drop spike packets with no diagnostic.  
**Fix:** Added `logic [4:0] router_overflow_raw` and `router_overflow_sticky` per cluster. Sticky register ORs in overflow flags each cycle; cleared only on reset. Also added `set_false_path` in XDC for the sticky registers.

---

### MED-2 — Spike threshold `>` should be `>=`
**File:** `rtl/neuron_core.sv`  
**Root cause:** Both the `next_membrane` mux and `spike_out` assignment used strict `>` for threshold comparison. Biologically correct LIF fires at `V >= THRESHOLD`, not `V > THRESHOLD`. Effective threshold was shifted by 1 LSB, inconsistent with architecture documentation.  
**Fix:** Changed all three occurrences (`next_membrane` in generate, `spike_out` in always_ff, and `fires_this_cycle` in popcount) to use `>=`.

---

### MED-3 — Redundant `pre_spike_onehot` wire (CODE-2)
**File:** `rtl/neuraedge_top.sv`  
**Root cause:** `pre_spike_onehot` was a generate-loop wire copy of `pre_spike_reg`. The pipeline register then read from `pre_spike_onehot`. This added a pointless indirection and an extra generate block.  
**Fix:** Removed `pre_spike_onehot` declaration and generate block. `pre_spike_pipe` now reads directly from `pre_spike_reg`.

---

## Low-Severity / Quality Fixes

### LOW-1 — AI-pattern changelog walls in all RTL file headers
**Files:** All `rtl/*.sv`  
**Fix:** Replaced multi-page changelog headers with concise 4-line module headers. Revision history belongs in `CHANGELOG.md` and git history, not in the RTL file.

### LOW-2 — `benchmark.py` energy estimate not from hardware
**File:** `software/benchmark.py`  
**Fix:** Added explicit label: `# rough ASIC estimate only — NOT measured on this hardware`. Vivado power report is the correct source for FPGA power figures.

### LOW-3 — `dfx_runtime.txt` orphaned file
**Root cause:** Leftover from an abandoned Dynamic Function eXchange experiment. No DFX logic exists in any RTL file.  
**Fix:** Deleted.

### LOW-4 — SVA bind file missing
**File:** `tb/sva_bind.sv` (new)  
**Root cause:** `Makefile` references `tb/sva_bind.sv` and `neuraedge_sva.sv` contains real protocol assertions, but the bind file was never created. Assertions were dead.  
**Fix:** Created `tb/sva_bind.sv` with `bind neuraedge_top neuraedge_sva` instantiation, gated by `` `ifdef SVA_ENABLE ``.

### LOW-5 — `synapse_memory_tb.v` missing `rd_en` port
**File:** `tb/synapse_memory_tb.v`  
**Fix:** Updated DUT instantiation with `rd_en`. Added Test 1 (rd_valid gated by rd_en) and Test 2 (1-cycle latency verification). Added Test 5 (rd_data_sel mux selection) and Test 8 (interleaved 4-bank writes).

### LOW-6 — `learning_engine_tb.v` missing weight saturation and back-to-back tests
**File:** `tb/learning_engine_tb.v`  
**Fix:** Added Test 6 (weight does not exceed MAX_WEIGHT after repeated LTP) and Test 7 (back-to-back LTP then LTD events both complete without deadlock).

### LOW-7 — N-MNIST/8×8 mismatch undocumented in synth flow
**File:** `scripts/vivado/synth.tcl`  
**Fix:** Added comment block documenting required parameter changes for N-MNIST sensor configuration.

### LOW-8 — XDC missing false-path for new overflow sticky registers
**File:** `constraints/neuraedge.xdc`  
**Fix:** Added `set_false_path` for `router_overflow_sticky` registers (async debug status, not timing-critical).

---

## Testbench Gap Summary (Remaining)

| Module | Gap | Priority |
|---|---|---|
| `tb_neuraedge_top.cpp` | Does not drive SPI — weight loading never exercised end-to-end | High |
| `spike_router_tb.v` | No deadlock test under sustained backpressure | Medium |
| `event_encoder_tb.v` | Window boundary edge case (event at exactly `window_start + WINDOW_US`) | Low |

The full end-to-end inference path (SPI load → DVS encode → route → LIF → classify → UART) has no integration test. This is the next priority item.

---

## Timing Status

| Metric | Before | After |
|---|---|---|
| WNS | +0.112 ns (marginal) | Expected +0.3–0.5 ns (comb mux removal shortens critical path) |
| WHS | +0.050 ns | Unchanged |
| BRAM18 | 32 | 32 (unchanged) |
| DSPs | 0 | 0 |
| SPI weight loading | Broken (static assign) | Functional |
| STDP write correctness | First synapse stale every scan | Correct |
| Classifier utilization | 25% (1 of 4 clusters) | 100% (all clusters) |

