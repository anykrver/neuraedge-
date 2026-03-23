# Changelog

All notable changes to NeuraEdge are documented in this file.

## [2.5.0] — 2026-03-22

### Repository
- Full restructure: `scripts/` split into `scripts/vivado/` and `scripts/sim/`
- Makefile added: `make sim`, `make synth`, `make sim-iv`, `make clean`, `make help`
- `ARCHITECTURE.md` and `docs/architecture.md` deduplicated — canonical copy is `docs/architecture.md`
- `docs/timing_strategy.md` and `docs/scaling.md` added
- `sim/` timing reports moved to `reports/` (generated directory, gitignored for re-runs)
- `dfx_runtime.txt` and `sim/run_impl_and_report_rdptr.tcl` removed (internal debug artefacts)
- `.gitignore` updated and consolidated
- `scripts/vivado/pre_bitgen.tcl` path fixed in `synth.tcl`

### RTL Fixes (carried from v2.4.x)
- `constraints/neuraedge.xdc`: duplicate pin U1 removed; invalid P1 pin corrected to H1; `dvs_ready` NSTD-1 DRC fixed; LED/UART paths replaced with `set_false_path`
- `rtl/synapse_memory.v`: reset logic removed from BRAM output register path — BRAM18 inference now correct (32 RAMB18 vs previous 0)
- `rtl/neuraedge_top.v`: nested generate removed (Vivado elaboration bug); `pre_spike` one-hot decoder converted to flat combinational always block; `uart_byte` NBA race fixed; `spike_accum` window-boundary NBA conflict fixed

### Timing
- WNS: +0.112 ns (100 MHz, post-route)
- WHS: +0.050 ns
- DRC: 0 errors

## [2.4.0] — 2026-03-21
- XDC port names corrected to match `neuraedge_top` interface
- `rst_n` min/max input_delay added
- Shell quoting bug in `run_sim.sh` fixed

## [2.3.0] — 2026-03-21
- Vivado elaboration issues resolved in top-level
- Illegal nested generate removed from `neuraedge_top.v`
- Pre-spike STDP path restored

## [2.2.0] — 2026-03-21
- LTP path wiring restored in top-level learning integration
- Parameter guardrails added in neuron/learning flow

## [2.1.0] — 2026-03-21
- Incremental simulation and synthesis script stabilisation

## [1.0.0] — 2026-03-21
- Initial public release: RTL architecture, simulation harness, Vivado flow
