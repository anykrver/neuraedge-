# NeuraEdge v2.1.0

> 2×2 LIF cluster mesh neuromorphic accelerator — SystemVerilog, Verilator simulation, timing closure at 100 MHz on Artix-7, online STDP learning with activity-gated power optimisation.

[![Simulation](https://img.shields.io/badge/sim-6%2F6%20passing-brightgreen)](#simulation)
[![Timing](https://img.shields.io/badge/WNS-%2B0.248%20ns-brightgreen)](#key-results)
[![Power](https://img.shields.io/badge/power-549%20mW%20total-orange)](#key-results)
[![Target](https://img.shields.io/badge/FPGA-Artix--7%20100T-blue)](#fpga-target--pin-map)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

---

NeuraEdge v1 was a single LIF neuron on a Basys 3. **NeuraEdge v2** adds a 2×2 mesh NoC with credit-based flow control, trace-based online STDP, DVS event input, and full timing closure at 100 MHz on Artix-7. v2.1.0 adds three hardware power optimisations: activity-gated `spikes_valid`, a `clk_en` that idles the learning engine when no events are queued, and a narrower 6-bit trace register. The design synthesises and programs without modification. Every engineering decision is documented.

---

## Overview

- [Authorship](#authorship)
- [Background](#background)
- [What Changed from v1](#what-changed-from-v1)
- [Architecture](#architecture)
- [Key Results](#key-results)
- [Repository Layout](#repository-layout)
- [Quick Start](#quick-start)
- [Simulation](#simulation)
- [FPGA Build](#fpga-build)
- [FPGA Target & Pin Map](#fpga-target--pin-map)
- [ASIC Migration Path](#asic-migration-path)
- [Roadmap](#roadmap)
- [Documentation](#documentation)

---

## Authorship

All six RTL modules (`neuraedge_top.sv`, `neuron_core.sv`, `spike_router.sv`, `synapse_memory.sv`, `learning_engine.sv`, `event_encoder.sv`) were designed and written by me from scratch. The Verilator testbenches, Vivado TCL synthesis flow, and XDC constraints are also hand-written.

[`CHANGELOG.md`](CHANGELOG.md) documents 20+ real bugs found and fixed across synthesis, simulation, and board bring-up — including a BRAM inference bug that caused Vivado to fall back to 30,000+ LUTs of distributed RAM, a silent classifier accumulation error that excluded three of four clusters from inference, and a dual NBA race in the STDP trace registers. These are not generated artefacts; they are the normal history of building real hardware.

---

## Background

Neuromorphic hardware differs from a CPU or matrix accelerator in three ways that show up directly in the RTL.

Spike timing carries information, not just spike presence — so the router and learning engine must propagate timestamps alongside data. Synaptic weights live physically adjacent to neuron cores, breaking the CPU/memory separation — every routing hop is also a BRAM access, and BRAM inference correctness is non-negotiable. And learning is strictly local: STDP updates one synapse using only the two endpoints' spike times, with no global error signal. It has to run online in hardware without stalling the datapath.

NeuraEdge v2 is small enough to read completely in an afternoon and real enough to synthesise without modification.

---

## What Changed from v1

| Feature | v1 (Basys 3 baseline) | v2 (this project) |
|---|---|---|
| Neurons | 32 / 128 (two configs) | 256 total (4 clusters × 64) |
| Interconnect | AER bus, flat | 2×2 mesh NoC, credit flow control |
| Routing | Priority encoder, 4-state FSM | X-then-Y DOR, 5-state FSM |
| Learning | STDP (offline) | Trace-based STDP, online, bidirectional |
| Input | Rate / temporal encoded | DVS-style event stream (x, y, polarity, timestamp) |
| Memory | Single BRAM per config | 4-bank banked BRAM, 8 KB/cluster, 32 KB total (128 syn/neuron) |
| Timing closure | ~180 MHz (Artix-7 35T) | 100 MHz, WNS +0.248 ns (Artix-7 100T) |
| Debug | LEDs only | UART telemetry + ILA ChipScope |
| ASIC path | Not targeted | Synthesisable for OpenLane / SKY130 |

---

## Architecture

### System overview

![NeuraEdge top-level architecture](docs/neuraedge-architecture.svg)

### LIF neuron core

The fundamental compute unit is the **Leaky Integrate-and-Fire (LIF) neuron** — the biological neuron reduced to its essential electrical behaviour.

A biological neuron integrates incoming current on its membrane capacitance and fires an action potential when voltage exceeds threshold. The "leaky" part comes from passive membrane resistance that continuously drains charge back toward rest.

In hardware:

```
V[t+1] = (V[t] >> LEAK_SHIFT) + I_syn[t]   // integrate + leak

if V[t+1] >= THRESHOLD:
    emit spike
    V[t+1] = 0                               // fire + reset
```

NeuraEdge v2 uses `THRESHOLD=200`, `LEAK_SHIFT=1` (50% leak per cycle), 8-bit membrane datapath. All 64 neurons in a cluster update in parallel every clock cycle — no time-multiplexing, no iteration.

### Spike router (mesh NoC)

The router implements a 5-port (N/S/E/W/local) credit-based mesh with **X-then-Y dimension-order routing** — deadlock-free by construction.

![NeuraEdge NoC routing and router FSM](docs/neuraedge-noc.svg)

Credits prevent FIFO overflow without backpressure stalls. Each router tracks available downstream FIFO space and only forwards when credit > 0. At 10% firing rate (~6 spikes/timestep/cluster), routing overhead is ~24 cycles per timestep per cluster.

### Synapse memory

4-bank BRAM layout for parallel weight access. `NUM_SYNAPSES=128` per neuron, `WEIGHT_W=8`:

```
Bank 0: W[pre][synapses 0..31]
Bank 1: W[pre][synapses 32..63]
Bank 2: W[pre][synapses 64..95]
Bank 3: W[pre][synapses 96..127]

All 4 banks read in parallel → all 128 weights for one pre-neuron in 1 cycle
```

8 KB per cluster → 32 KB total → **8 RAMB36E1** on Artix-7. The key BRAM inference rule: the output register must have no synchronous reset. Any reset on that register forces Vivado to fall back to distributed RAM — 30,000+ LUTs instead of 8 block RAMs. This was the main synthesis bug fixed in v2.0.0.

### STDP learning engine

**Spike-Timing-Dependent Plasticity** updates weights using only local information: the relative timing of pre- and post-synaptic spikes. No global error signal, no backpropagation.

The biological rule:
- Pre fires **before** post → strengthen synapse (Long-Term Potentiation)
- Pre fires **after** post → weaken synapse (Long-Term Depression)

v2 implements **trace-based** STDP — each neuron maintains a running eligibility trace that decays over time, which is more hardware-efficient than tracking exact spike timestamps:

```
pre_trace[i]  += TRACE_INCR on pre-spike,  decays >>TRACE_DECAY each cycle
post_trace[j] += TRACE_INCR on post-spike, decays >>TRACE_DECAY each cycle

On pre-spike:   W[i][j] -= A_MINUS * post_trace[j]   // LTD
On post-spike:  W[i][j] += A_PLUS  * pre_trace[i]    // LTP
```

Parameters: `A_PLUS=4`, `A_MINUS=2`, `TRACE_W=6`, `TRACE_INCR=16`, `TRACE_DECAY=3`. Weights saturate to `[0, 255]`. The engine exposes `ltp_count`, `ltd_count`, and `scan_active` for observability via UART/ILA.

**Power optimisations (v2.1.0):**
- `spikes_valid` is now derived from actual spike activity rather than hardwired `1'b1` — trace decay and event generation only run when the mesh is firing
- `clk_en` idles all learning engine FFs when the event queue drains — no BRAM scans, no toggle power during quiet periods
- `TRACE_W` reduced from 8 to 6 bits — halves trace register toggle density with negligible effect on learning dynamics at TRACE_DECAY=3

### Event encoder

Converts DVS-style events `(x, y, polarity, timestamp, valid)` into AER packets for the mesh. Maps sensor coordinates to cluster addresses using the tile formula: `neuron_id = (y/TILE_H)*TILE_W + (x/TILE_W)`. Supports optional time-windowing mode (`WINDOW_MODE`, `WINDOW_US=1000`). Tracks accepted/dropped event counters and applies backpressure via `pkt_ready`.

**Tile constraint** (checked at synthesis via `$fatal`):

```
TILE_W * TILE_H * 2 <= 2^NEURON_ADDR_W
// Default: 4 * 4 * 2 = 32 <= 64 = 2^6  ✅
```

---

## Key Results

> All numbers from Vivado 2025.2 post-route on `xc7a100tcsg324-1`, 100 MHz, v2.1.0 (NUM_SYNAPSES=128).

| Metric | Measured |
|--------|----------|
| Clock | 100 MHz |
| WNS | **+0.248 ns** ✅ |
| WHS | **+0.061 ns** ✅ |
| TNS Failing Endpoints | **0** ✅ |
| Slice LUTs | 21,570 (34.02%) |
| Slice FFs | 8,375 (6.60%) |
| Block RAM Tiles | 32 × RAMB36E1 |
| DSPs | 0 |
| Total On-Chip Power | 549 mW (448 mW dynamic + 100 mW static) |
| DRC errors | 0 |

Reference reports: [`reports/timing.rpt`](reports/timing.rpt) · [`reports/utilisation.rpt`](reports/utilisation.rpt) · [`reports/power.rpt`](reports/power.rpt)

---

## Repository Layout

```
neuraedge/
├── rtl/                          # Synthesisable RTL (SystemVerilog)
│   ├── neuraedge_top.sv          # Top-level: 2×2 mesh, UART, LEDs
│   ├── neuraedge_top_ila.sv      # ILA debug wrapper (ChipScope)
│   ├── event_encoder.sv          # DVS event → AER packet
│   ├── spike_router.sv           # Mesh NoC router (credit, X-then-Y DOR)
│   ├── neuron_core.sv            # LIF neuron array (64 neurons/cluster)
│   ├── synapse_memory.sv         # 4-bank BRAM weight store
│   ├── learning_engine.sv        # Trace-based STDP engine
│   └── neuraedge_sva.sv          # SVA assertion module
├── tb/                           # Testbenches
│   ├── *.sv                      # SystemVerilog testbenches (Icarus + Verilator)
│   ├── tb_*.cpp                  # Verilator C++ wrappers (primary regression)
│   └── sva_bind.sv               # SVA bind module (enable with +define+SVA_ENABLE)
├── constraints/
│   └── neuraedge.xdc             # Nexys A7-100T pins + timing constraints
├── scripts/
│   ├── sim/
│   │   ├── run_sim.sh            # Verilator regression (all 6 modules)
│   │   └── run_iverilog.sh       # Icarus Verilog alternative
│   └── vivado/
│       ├── synth.tcl             # Synth + impl + bitstream (batch mode)
│       ├── synth_ila.tcl         # ILA-enabled build
│       ├── synth_bram_fix.tcl    # BRAM inference debug flow
│       ├── pre_bitgen.tcl        # Pre-bitstream hook
│       └── ila_capture_to_csv.tcl
├── docs/
│   ├── architecture.md           # Module specs, parameters, interfaces
│   ├── timing_strategy.md        # Constraint rationale, closure approach
│   ├── scaling.md                # Scaling neurons, mesh, ASIC migration
│   ├── ila_guide.md              # ILA ChipScope setup
│   ├── ila_bringup_guide.md      # Board bring-up checklist
│   ├── expected_outputs.md       # Reference sim/synth outputs
│   └── sim_hardware_disclaimer.md
├── reports/                      # Committed post-route reports (v2.1.0)
├── software/
│   ├── train_nmnist.py           # N-MNIST training pipeline
│   ├── benchmark.py              # Throughput benchmark
│   └── requirements.txt
├── Makefile                      # make sim / synth / clean / help
├── CHANGELOG.md                  # Full revision history
├── .gitignore
└── LICENSE                       # Apache 2.0
```

---

## Quick Start

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Verilator | ≥ 5.0 | `apt install verilator` |
| make + g++ | any recent | `apt install build-essential` |
| Icarus Verilog | ≥ 11 | `apt install iverilog` (optional) |
| Vivado | 2025.2+ | [AMD/Xilinx downloads](https://www.xilinx.com/support/download.html) |
| Python | ≥ 3.10 | for software utilities only |

### Clone & run

```bash
git clone https://github.com/anykrver/neuraedge-v2
cd neuraedge-v2

# Full simulation regression
make sim

# FPGA bitstream (requires Vivado in PATH)
make synth
```

### Python environment (optional)

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r software/requirements.txt
```

---

## Simulation

```bash
# Verilator — full regression (all 6 modules)
make sim

# Single module
make sim MOD=neuron_core
make sim MOD=spike_router
make sim MOD=learning_engine

# Open GTKWave waveform on first VCD
make sim-wave

# Icarus Verilog — catches X-propagation issues Verilator masks
make sim-iv
```

Expected output:

```
[PASS] neuron_core:     Results: 12/12 checks passed
[PASS] synapse_memory:  Results: 12/12 checks passed
[PASS] spike_router:    Results: 10/10 checks passed
[PASS] event_encoder:   Results: 6/6 checks passed
[PASS] learning_engine: Results: 11/11 checks passed
[PASS] neuraedge_top:   Results: integration test passed
ALL TESTS PASSED
```

For a detailed breakdown of what simulation validates vs what requires hardware, see [`docs/sim_hardware_disclaimer.md`](docs/sim_hardware_disclaimer.md).

---

## FPGA Build

```bash
# Synthesis + implementation + bitstream
make synth

# With ILA ChipScope debug cores (~8 BRAM18 overhead)
make synth-ila

# Override Vivado binary path
make synth VIVADO=/opt/Xilinx/Vivado/2025.2/bin/vivado
```

Outputs land in `vivado_proj/neuraedge.runs/impl_1/`:

| File | Description |
|------|-------------|
| `neuraedge_top.bit` | Bitstream — verify WNS ≥ 0 before programming |
| `timing.rpt` | WNS, TNS, WHS, THS — check for 0 failing endpoints |
| `utilisation.rpt` | LUT / FF / BRAM / DSP breakdown by hierarchy |
| `power.rpt` | Dynamic + static power by module (Low confidence without SAIF) |
| `drc.rpt` | DRC violations — build fails automatically if count > 0 |

`synth.tcl` includes automated post-implementation checks: BRAM count < 6 fails the build (8 RAMB36E1 expected for NUM_SYNAPSES=128), DRC violations > 0 fail the build, WNS < 0.1 ns prints a warning before programming.

---

## FPGA Target & Pin Map

| Property | Value |
|----------|-------|
| Board | Nexys A7-100T |
| Device | `xc7a100tcsg324-1` |
| Clock | E3 — 100 MHz crystal oscillator |
| Reset | C12 — CPU_RESET button, active-low |
| DVS x[2:0] | J15 / L16 / M13 (SW0–SW2) |
| DVS y[2:0] | R15 / R17 / T18 (SW3–SW5) |
| DVS polarity | U18 (SW6) |
| DVS valid | N17 (BTNC centre) |
| Window advance | M18 (BTNU up) |
| SPI weight load | C17 / D18 / E18 (PMOD JA) |
| UART TX | D4 — USB-UART bridge, 115,200 baud |
| Classification out | LED[15:0] |

Full constraint rationale (false-path decisions, rst_n hold strategy, dvs_ready DRC fix) is in [`docs/timing_strategy.md`](docs/timing_strategy.md).

---

## ASIC Migration Path

The RTL is written in Verilog-2001-compatible style with no FPGA primitives in the design proper. It passes Yosys synthesis without modification. The primary FPGA-specific element is BRAM18 inference in `synapse_memory.sv`, which must be replaced with an SRAM macro for SKY130.

See [`docs/scaling.md`](docs/scaling.md) for the full migration checklist and neuron/mesh scaling tables.

---

## Roadmap

- [ ] SAIF-based power measurement — annotate simulation toggles into Vivado `report_power` for accurate v2.1.0 power figure
- [ ] End-to-end inference demo — SPI weight load → DVS input → UART classification result on hardware
- [ ] AXI-Lite configuration interface (replace SPI weight loader)
- [ ] 4×4 mesh expansion — 1,024 neurons, 128 KB synaptic storage
- [ ] Coverage-driven verification (SystemVerilog functional coverage)
- [x] OpenLane / SKY130 synthesis pass (Yosys — no FPGA primitives in RTL)

---

## Documentation

| Document | Description |
|----------|-------------|
| [docs/architecture.md](docs/architecture.md) | Module responsibilities, parameters, external interfaces |
| [docs/timing_strategy.md](docs/timing_strategy.md) | XDC rationale, constraint decisions, known risks |
| [docs/scaling.md](docs/scaling.md) | Scaling neurons, mesh size, ASIC migration |
| [docs/ila_guide.md](docs/ila_guide.md) | ILA ChipScope debug setup |
| [docs/ila_bringup_guide.md](docs/ila_bringup_guide.md) | Board bring-up checklist |
| [docs/expected_outputs.md](docs/expected_outputs.md) | Reference simulation and synthesis outputs |
| [docs/sim_hardware_disclaimer.md](docs/sim_hardware_disclaimer.md) | What simulation validates vs what needs hardware |
| [CHANGELOG.md](CHANGELOG.md) | Full revision history with bug descriptions |

---

## Tech Stack

- **HDL**: SystemVerilog / Verilog-2001 compatible RTL
- **Simulation**: Verilator ≥5.0 (primary), Icarus Verilog ≥11 (X-propagation)
- **FPGA**: Vivado 2025.2, Artix-7 `xc7a100tcsg324-1`
- **ASIC**: OpenLane + SkyWater SKY130 (migration path)
- **Scripting**: Bash, Tcl, Python 3.10+

---

## Acknowledgements

Inspired by [tiny-gpu](https://github.com/adam-maj/tiny-gpu) — the clearest hardware architecture tutorial written.

Neuron model based on: Gerstner & Kistler (2002). *Spiking Neuron Models*. Cambridge University Press.

STDP rule based on: Bi & Poo (1998). Synaptic modifications in cultured hippocampal neurons. *Journal of Neuroscience*, 18(24).

---

## License

Apache 2.0. See [LICENSE](LICENSE).
