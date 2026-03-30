# NeuraEdge v2.1.0 — Neuromorphic Edge Accelerator

> 2×2 mesh-NoC spiking neural network accelerator in SystemVerilog. Trace-based online STDP, credit-flow NoC, DVS event input, timing closure at 100 MHz on Artix-7 100T.

[![Simulation](https://img.shields.io/badge/sim-6%2F6%20passing-brightgreen)](#simulation)
[![WNS](https://img.shields.io/badge/WNS-%2B0.248%20ns-brightgreen)](#implementation-results)
[![Power](https://img.shields.io/badge/power-549%20mW-orange)](#implementation-results)
[![FPGA](https://img.shields.io/badge/FPGA-Artix--7%20100T-blue)](#target-platform)
[![ASIC](https://img.shields.io/badge/ASIC-SKY130%20path-blue)](#asic-migration)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

---

## Overview

NeuraEdge is a fully synthesisable neuromorphic inference accelerator implementing Leaky Integrate-and-Fire (LIF) neurons with online Spike-Timing-Dependent Plasticity (STDP) learning. The v2 design replaces the v1 single-cluster baseline with a parameterised 2×2 mesh of processing clusters, each containing 64 LIF neurons, a 4-bank BRAM synapse store, and a pipelined STDP engine. All four clusters operate in parallel, connected by a credit-based mesh NoC with deterministic X-then-Y dimension-order routing.

The project targets researchers and engineers studying neuromorphic hardware. Every engineering decision — including every significant bug found during development — is documented in [`CHANGELOG.md`](CHANGELOG.md).

---

## Authorship

All RTL modules (`neuraedge_top.sv`, `neuron_core.sv`, `spike_router.sv`, `synapse_memory.sv`, `learning_engine.sv`, `event_encoder.sv`) were designed and implemented from scratch. Verilator testbenches, Vivado TCL flows, and XDC constraints are hand-written. AI tools were used to accelerate implementation; RTL architecture and all micro-architectural decisions are the author's own.

[`CHANGELOG.md`](CHANGELOG.md) documents 20+ real bugs found and fixed across synthesis, simulation, and board bring-up.

---

## Design Highlights

- **256 LIF neurons** across 4 clusters, all updating in parallel every clock cycle — no time-multiplexing
- **32 KB banked synapse memory** — 4×RAMB36E1 per cluster, 128 synapses/neuron, parallel 4-bank access
- **Online STDP** — 3-stage pipelined learning engine with trace-based eligibility, runs concurrently with inference
- **Deadlock-free NoC** — X-then-Y DOR, credit-based flow control, sticky overflow detection
- **Activity-gated power** — `spikes_valid` and `clk_en` idle the learning datapath when the mesh is quiet
- **Full timing closure** — WNS +0.248 ns, 0 failing endpoints, post-route Vivado 2025.2

---

## Architecture Summary

```
DVS Event Stream
      │
  ┌───▼──────────────┐
  │  event_encoder   │  Maps (x,y,pol,ts) → AER packet → cluster address
  └───┬──────────────┘
      │ AER packet
  ┌───▼──────────────────────────────────────┐
  │         2×2 Credit-Based Mesh NoC        │
  │  ┌──────────┐  ┌──────────┐             │
  │  │ Cluster  │  │ Cluster  │  X-then-Y   │
  │  │ (0,0)    │  │ (1,0)    │  DOR        │
  │  ├──────────┤  ├──────────┤             │
  │  │ Cluster  │  │ Cluster  │             │
  │  │ (0,1)    │  │ (1,1)    │             │
  │  └──────────┘  └──────────┘             │
  └───┬──────────────────────────────────────┘
      │ spike_out[4 clusters][64 neurons]
  ┌───▼──────────────┐
  │ Output Classifier│  Iterative argmax → UART → LED
  └──────────────────┘

Per-Cluster Pipeline:
  spike_router → neuron_core → (spike_out)
                     ↑               ↓
              synapse_memory ← learning_engine
```

Each cluster instantiates: `spike_router` → `neuron_core` → `synapse_memory` ↔ `learning_engine`. See [`docs/architecture.md`](docs/architecture.md) for the full internal design specification.

---

## Implementation Results

All figures from Vivado 2025.2 post-route implementation, `xc7a100tcsg324-1`, 100 MHz, `NUM_SYNAPSES=128`.

| Metric | Result | Status |
|--------|--------|--------|
| Clock frequency | 100 MHz | — |
| Worst Negative Slack (WNS) | +0.248 ns | ✅ |
| Worst Hold Slack (WHS) | +0.061 ns | ✅ |
| Total Negative Slack (TNS) | 0 ps | ✅ |
| Failing timing endpoints | 0 | ✅ |
| DRC violations | 0 | ✅ |
| Slice LUTs | 21,570 / 63,400 (34%) | — |
| Slice FFs | 8,375 / 126,800 (6.6%) | — |
| Block RAM tiles | 32 × RAMB36E1 | — |
| DSPs | 0 | — |
| Total on-chip power | 549 mW (448 mW dynamic + 100 mW static) | — |

Reference reports: [`reports/timing.rpt`](reports/timing.rpt) · [`reports/utilisation.rpt`](reports/utilisation.rpt) · [`reports/power.rpt`](reports/power.rpt)

> **Note**: Power figures are confidence `Low` in Vivado without SAIF annotation. SAIF-based power characterisation is on the roadmap.

---

## Repository Layout

```
neuraedge/
├── rtl/                          # Synthesisable RTL (SystemVerilog)
│   ├── neuraedge_top.sv          # Top-level integration, SPI loader, UART, classifier
│   ├── neuraedge_top_ila.sv      # ILA debug wrapper (ChipScope probes)
│   ├── event_encoder.sv          # DVS (x,y,polarity,timestamp) → AER packet encoder
│   ├── spike_router.sv           # 5-port credit-based mesh router, X-then-Y DOR
│   ├── neuron_core.sv            # 64-neuron parallel LIF array, saturating arithmetic
│   ├── synapse_memory.sv         # 4-bank RAMB36E1 weight store, pipelined rd_valid
│   ├── learning_engine.sv        # 3-stage STDP pipeline, trace decay, clk_en gating
│   ├── noc_port.sv               # NoC port interface definition
│   └── neuraedge_sva.sv          # SVA assertion module (bound via sva_bind.sv)
├── tb/                           # Testbenches
│   ├── *.sv                      # SystemVerilog unit testbenches (Icarus compatible)
│   ├── tb_*.cpp                  # Verilator C++ wrappers (primary regression suite)
│   └── sva_bind.sv               # SVA bind module (enable with +define+SVA_ENABLE)
├── constraints/
│   └── neuraedge.xdc             # Nexys A7-100T pin constraints and timing exceptions
├── scripts/
│   ├── vivado/synth.tcl          # Synthesis + implementation + post-route checks
│   ├── vivado/synth_ila.tcl      # ILA variant with ChipScope debug cores
│   └── sim/run_sim.sh            # Verilator regression driver
├── docs/
│   ├── architecture.md           # Internal design specification (this document's companion)
│   ├── scaling.md                # Throughput, latency, parallelism, ASIC scalability
│   ├── timing_strategy.md        # XDC rationale, constraint decisions, known risks
│   ├── ila_guide.md              # ILA ChipScope setup and trigger configuration
│   └── expected_outputs.md       # Reference simulation and synthesis outputs
├── reports/                      # Committed post-route Vivado reports (v2.1.0)
├── software/
│   ├── train_nmnist.py           # N-MNIST SNN training pipeline (weight extraction)
│   ├── benchmark.py              # Throughput and energy benchmark
│   └── requirements.txt
├── Makefile                      # Targets: sim / synth / sim-iv / sim-wave / clean / help
├── CHANGELOG.md                  # Full engineering revision history
└── LICENSE                       # Apache 2.0
```

---

## Quick Start

### Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Verilator | ≥ 5.0 | Primary simulation |
| Icarus Verilog | ≥ 11 | X-propagation checks |
| make + g++ | any recent | Build toolchain |
| Vivado | 2025.2+ | FPGA synthesis and implementation |
| Python | ≥ 3.10 | Software utilities (optional) |

```bash
git clone https://github.com/anykrver/neuraedge-v2
cd neuraedge-v2
make sim          # Full Verilator regression (6/6 expected PASS)
make synth        # FPGA bitstream (requires Vivado in PATH)
```

---

## Simulation

```bash
make sim                       # Full regression — all 6 modules
make sim MOD=neuron_core       # Single module
make sim MOD=learning_engine
make sim MOD=spike_router
make sim-wave                  # Open GTKWave on first VCD
make sim-iv                    # Icarus — catches X-propagation Verilator masks
```

Expected regression output:

```
[PASS] neuron_core:     12/12 checks passed
[PASS] synapse_memory:  12/12 checks passed
[PASS] spike_router:    10/10 checks passed
[PASS] event_encoder:   6/6 checks passed
[PASS] learning_engine: 11/11 checks passed
[PASS] neuraedge_top:   integration test passed
ALL TESTS PASSED
```

See [`docs/expected_outputs.md`](docs/expected_outputs.md) for annotated reference output. For the boundary between simulation coverage and hardware-only validation, see [`docs/sim_hardware_disclaimer.md`](docs/sim_hardware_disclaimer.md).

---

## FPGA Build

```bash
make synth                                        # Standard build
make synth-ila                                    # With ILA ChipScope (~8 BRAM18 overhead)
make synth VIVADO=/opt/Xilinx/Vivado/2025.2/bin/vivado  # Custom Vivado path
```

`synth.tcl` includes automated post-implementation checks:
- BRAM count < 6 → build fails (8 RAMB36E1 expected for `NUM_SYNAPSES=128`)
- DRC violations > 0 → build fails
- WNS < 0.1 ns → warning printed before programming

---

## Target Platform

| Property | Value |
|----------|-------|
| Board | Nexys A7-100T |
| Device | `xc7a100tcsg324-1` |
| System clock | E3 — 100 MHz crystal oscillator |
| Reset | C12 — CPU_RESET button, active-low |
| DVS x\[2:0\] | J15 / L16 / M13 (SW0–SW2) |
| DVS y\[2:0\] | R15 / R17 / T18 (SW3–SW5) |
| DVS polarity | U18 (SW6) |
| DVS valid | N17 (BTNC centre) |
| Window advance | M18 (BTNU up) |
| SPI weight load | C17 / D18 / E18 (PMOD JA) |
| UART TX | D4 — USB-UART bridge, 115,200 baud 8N1 |
| Classification output | LED\[15:0\] |

Full constraint rationale is in [`docs/timing_strategy.md`](docs/timing_strategy.md).

---

## ASIC Migration

The RTL uses no FPGA primitives in the design proper. It passes Yosys synthesis without modification. The primary migration item is replacing `synapse_memory.sv` BRAM inference with a Sky130 SRAM macro. See [`docs/scaling.md`](docs/scaling.md) for the full migration checklist and area/power projections.

---

## Roadmap

| Item | Status |
|------|--------|
| SAIF-based power annotation | ☐ Planned |
| AXI-Lite configuration interface (replaces SPI weight loader) | ☐ Planned |
| Functional coverage closure (SVA coverpoints) | ☐ Planned |
| End-to-end N-MNIST demo: SPI load → DVS input → UART result | ☐ Planned |
| 4×4 mesh expansion (1,024 neurons, 128 KB synapse memory) | ☐ Planned |
| OpenLane / SKY130 synthesis pass | ✅ Done |

---

## Documentation Index

| Document | Contents |
|----------|----------|
| [docs/architecture.md](docs/architecture.md) | Block diagrams, pipeline, memory hierarchy, timing analysis |
| [docs/scaling.md](docs/scaling.md) | Throughput, latency, parallelism, ASIC scalability |
| [docs/timing_strategy.md](docs/timing_strategy.md) | XDC decisions, false-path rationale, hold margin strategy |
| [docs/ila_guide.md](docs/ila_guide.md) | ILA ChipScope setup and trigger configuration |
| [docs/expected_outputs.md](docs/expected_outputs.md) | Reference simulation and synthesis outputs |
| [CHANGELOG.md](CHANGELOG.md) | Engineering revision history — all bugs and fixes |

---

## References

Gerstner, W. & Kistler, W. (2002). *Spiking Neuron Models*. Cambridge University Press.

Bi, G. & Poo, M. (1998). Synaptic modifications in cultured hippocampal neurons. *Journal of Neuroscience*, 18(24), 10464–10472.

---

## License

Apache 2.0. See [LICENSE](LICENSE).
