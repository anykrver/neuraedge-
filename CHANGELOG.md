# Changelog

All notable changes to NeuraEdge are documented here.

## [2.1.0] — 2026-03-27

### Reports
- Replaced stale partial timing reports with full post-route outputs from Vivado 2025.2: `timing.rpt`, `utilisation.rpt`, `power.rpt`
- Removed four intermediate debug reports (`timing_rd_ptr_D_*`, `timing_summary_postchange.rpt`) that were committed during development and had no place in the final repository

### RTL Fixes
- **`rtl/neuraedge_top.sv`** — `spi_sclk_rise` declared as `logic var = expr` (static initializer, evaluated once at time-0). SPI weight loading was silently broken. Fixed to `assign spi_sclk_rise = spi_sclk_r && !spi_sclk_r2`.
- **`rtl/synapse_memory.sv`** — `rd_valid` permanently high after reset. The learning engine's pipeline stage never qualified against actual read latency, causing the first synapse of every STDP scan to read stale BRAM output. Added `rd_en` input; `rd_valid` now tracks `rd_en` with 1-cycle latency.
- **`rtl/neuraedge_top.sv`** — Classifier accumulation loop hard-coded to `spike_out[0][0]`. Three of four clusters contributed nothing to inference. Fixed to aggregate across all `(ci, ri)` cluster pairs.
- **`rtl/synapse_memory.sv`** — Removed second registered mux stage that created 2-cycle BRAM read latency while the learning FSM assumed 1 cycle. `rd_data_sel` is now a combinational mux on registered BRAM outputs; `rd_bank_sel` is registered alongside the BRAM read for timing alignment.
- **`rtl/learning_engine.sv`** — Dual non-blocking assignments to trace registers on spike events restructured. Leak value now computed as a local variable first; exactly one NBA issued per register per cycle.
- **`rtl/neuraedge_top.sv`** — SPI cluster ID `cid` was `logic [2:0]`, silently truncating to cluster 7 for any mesh larger than 2×4. Changed to `logic [$clog2(NUM_CLUSTERS)-1:0]`.
- **`rtl/neuron_core.sv`** — Threshold comparison changed from `>` to `>=` in all three locations (`next_membrane`, `spike_out`, `fires_this_cycle`). LIF neurons fire at V ≥ threshold, not V > threshold.
- **`rtl/neuraedge_top.sv`** — Router `fifo_overflow` was unconnected on all four cluster instantiations. Added per-cluster `router_overflow_sticky` registers (5-bit, OR-accumulated, reset-cleared). Added `set_false_path` for these in the XDC.
- **`rtl/neuraedge_top.sv`** — Removed `pre_spike_onehot` intermediate array and generate block. `pre_spike_pipe` now reads directly from `pre_spike_reg`.

### Testbenches
- **`tb/synapse_memory_tb.v`** — Added `rd_en` port to DUT instantiation. New tests: rd_valid gated by rd_en (Test 1), 1-cycle latency verification (Test 2), `rd_data_sel` mux selection (Test 5), interleaved 4-bank writes without collision (Test 8).
- **`tb/learning_engine_tb.v`** — Added Test 6 (weight saturation at MAX_WEIGHT under repeated LTP) and Test 7 (back-to-back LTP then LTD events, checks no deadlock and both counters increment).
- **`tb/sva_bind.sv`** — Created. Binds `neuraedge_sva` assertions to `neuraedge_top`. Previously the SVA module existed with no bind file, making all assertions dead in simulation.

### Documentation
- README updated to reflect actual synthesis results: WNS +0.248 ns, WHS +0.061 ns, 21,570 LUTs, 8,375 FFs, 32 RAMB36E1, 0 DSPs, 549 mW total power
- RTL file extensions corrected in README repository layout (.v → .sv)
- `docs/architecture.md`, `docs/timing_strategy.md`, `docs/expected_outputs.md` updated to match actual report numbers
- `scripts/vivado/synth.tcl` — Documented N-MNIST sensor parameter override (SENSOR_W=34, SENSOR_H=34, NEURON_ADDR_W=8)
- All RTL file headers stripped of multi-page changelog walls. Revision history belongs here and in git commits, not inline in the RTL.
- `software/benchmark.py` — `ENERGY_PER_SPIKE_NJ` labeled as rough ASIC estimate, not a hardware measurement
- `dfx_runtime.txt` deleted (orphaned DFX experiment artifact with no corresponding RTL)

---

## [2.0.0] — 2026-03-22

- Full RTL conversion to SystemVerilog (.sv): `reg` → `logic`, `always @(*)` → `always_comb`, `always @(posedge clk)` → `always_ff`, `integer` loop variables → `int`
- Repository restructured: `scripts/` split into `scripts/vivado/` and `scripts/sim/`
- Makefile added with `sim`, `synth`, `sim-iv`, `sim-wave`, `clean`, `help` targets
- `docs/` deduplicated; `timing_strategy.md` and `scaling.md` added
- Timing reports moved to `reports/`
- BRAM inference fix: synchronous reset removed from BRAM output register path — 32 RAMB18 now correctly inferred (previously fell back to 30,221 LUTs of distributed RAM)
- `pre_spike` one-hot decoder converted from illegal nested generate to flat combinational `always_comb` block
- `uart_byte` NBA race fixed: UART was transmitting the previous window's classification result
- `spike_accum` window-boundary NBA conflict resolved: spikes on the last cycle of a window were silently dropped
- WNS: +0.248 ns (post-route, Vivado 2025.2, 100 MHz, xc7a100tcsg324-1)
- WHS: +0.061 ns

---

## [1.6.0] — 2026-03-18

- XDC fully rebuilt for Nexys A7-100T: duplicate U1 pin removed, invalid P1 pin corrected, `dvs_ready` NSTD-1 DRC fixed, `set_false_path` applied to LED and UART outputs (removed 1,852 false timing violations)
- `rst_n` min/max `input_delay` added to XDC (resolved 0.105 ns WHS violation)
- Shell quoting bug in `run_sim.sh` fixed (mixed quote characters broke `cd` on bash 5.x)

---

## [1.5.0] — 2026-03-14

- XDC port names corrected to match actual `neuraedge_top` interface (`dvs_*`, `spi_*`, `led` — not internal signal names)
- Illegal nested generate block removed from top-level; `pre_spike` one-hot decoder rewritten as flat logic arrays with `always_comb`
- SPI cluster select changed from `%` to bitwise `&` (eliminates inferred divider)
- `$fatal` parameter validation assertions added for `NUM_CLUSTERS`, `NUM_SYNAPSES`, `THRESHOLD` range

---

## [1.4.0] — 2026-03-10

- `learning_engine`: 3-stage weight-update pipeline added (ST_SCAN_RD → ST_SCAN_WR → ST_SCAN_COMMIT). Separates BRAM read latency from arithmetic, reducing the critical path through the STDP weight update.
- `neuron_core`: `fire_count` popcount restructured to use a combinational accumulator before a single NBA — fixes silent undercount when multiple neurons fire in the same cycle
- `neuron_core`: `$fatal` assertion added for THRESHOLD > 2^MEM_WIDTH (was silently truncated, causing early firing)
- `neuron_core`: `fire_count` saturates at `32'hFFFF_FFFF` instead of wrapping

---

## [1.3.0] — 2026-03-06

- `learning_engine`: Off-by-one in scan FSM fixed — last synapse of each scan was silently dropped
- `learning_engine`: Queue empty/full detection changed to count-based (correct for any `SPIKE_QUEUE_D`)
- `spike_router`: Credit net-delta race fixed; per-port arbitration corrected
- Full Icarus Verilog compatibility pass — removed implicit wire declarations, fixed `initial` block scoping

---

## [1.2.0] — 2026-02-28

- `synapse_memory`: BRAM inference fix — synchronous reset on read port replaced with simulation-only `initial` block. Vivado now correctly infers RAMB18 instead of distributed RAM.
- `synapse_memory`: `dump_neuron_weights` task `boffset` width bug fixed (was zero-extending incorrectly on some tools)
- `neuron_core`: `neuron_enable` and `fire_count` ports added and connected in top-level

---

## [1.0.0] — 2026-02-20

- Initial release: 2×2 LIF mesh, credit-based NoC, trace-based STDP, DVS event encoder, UART output
- Verilator regression suite covering all six RTL modules
- Vivado batch synthesis flow targeting Nexys A7-100T
