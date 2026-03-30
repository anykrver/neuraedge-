# NeuraEdge Architecture

Module responsibilities, parameters, and external interfaces for NeuraEdge v2.1.0.

---

## 1. System Overview

NeuraEdge is a mesh-based spiking neural network accelerator with online trace-based STDP learning. All core logic runs in a single `sys_clk` domain at 100 MHz.

Primary pipeline:

![NeuraEdge top-level architecture](neuraedge-architecture.svg)

---

## 2. Top-Level Parameters (`rtl/neuraedge_top.v`)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `NUM_COLS`, `NUM_ROWS` | `2`, `2` | Mesh dimensions |
| `NUM_NEURONS` | `64` | Neurons per cluster |
| `NUM_SYNAPSES` | `512` | Synapses per neuron |
| `WEIGHT_W` | `8` | Synaptic weight bit width |
| `MEM_WIDTH` | `8` | Neuron membrane datapath width |
| `THRESHOLD` | `200` | LIF firing threshold |
| `LEAK_SHIFT` | `1` | Membrane leak right shift (50% per cycle) |
| `A_PLUS`, `A_MINUS` | `4`, `2` | STDP LTP / LTD magnitudes |
| `TRACE_INCR`, `TRACE_DECAY` | `16`, `3` | Trace increment and decay shift |
| `MAX_WEIGHT`, `MIN_WEIGHT` | `255`, `0` | Weight saturation bounds |
| `SENSOR_W`, `SENSOR_H` | `8`, `8` | Input DVS sensor dimensions |
| `NEURON_ADDR_W` | `6` | Neuron address bits (supports up to 64 neurons) |
| `TIMESTAMP_W` | `20` | DVS timestamp width in bits |
| `WINDOW_US`, `WINDOW_MODE` | `1000`, `0` | Time-windowing period and enable |
| `NUM_CLASSES` | `10` | Classification output classes |
| `UART_CLK_DIV` | `868` | UART baud rate divider (115,200 baud at 100 MHz) |

**Tile constraint** — enforced by `$fatal` at elaboration:

```
TILE_W * TILE_H * 2 <= 2^NEURON_ADDR_W
// Default: 4 * 4 * 2 = 32 <= 64 = 2^6  ✅
```

---

## 3. External Interfaces

| Interface | Signals | Description |
|-----------|---------|-------------|
| Clock / reset | `clk`, `rst_n` | 100 MHz system clock; active-low reset |
| DVS event input | `dvs_x[2:0]`, `dvs_y[2:0]`, `dvs_polarity`, `dvs_timestamp[19:0]`, `dvs_valid`, `dvs_ready`, `window_advance` | DVS-style event stream with backpressure |
| SPI weight load | `spi_sclk`, `spi_mosi`, `spi_cs_n` | 40-bit SPI weight loading protocol |
| Output / debug | `uart_tx`, `led[15:0]` | UART classification result (115,200 8N1); status LEDs |

---

## 4. Module Responsibilities

### 4.1 `event_encoder.v`

Converts DVS event tuples `(x, y, polarity, timestamp)` into 32-bit AER packets for injection into the mesh.

- Computes `dst_col = x / TILE_W`, `dst_row = y / TILE_H`, `neuron_id = (local_y * TILE_W + local_x) * 2 + polarity`
- Supports optional time-windowing (`WINDOW_MODE=1`, `WINDOW_US=1000`) — holds events until `window_advance` or timer expires
- Tracks `events_accepted` and `events_dropped` counters
- Applies backpressure via `pkt_ready`; asserts `enc_fifo_overflow` when FIFO full

### 4.2 `spike_router.v`

5-port mesh NoC router (N / S / E / W / local) with credit-based flow control and X-then-Y dimension-order routing.

- **Routing policy**: X mismatch → route in X direction first; then Y. Deadlock-free by construction.
- **Credits**: each port tracks downstream FIFO availability; only forwards when credit > 0
- Per-port round-robin arbitration; local FIFO overflow indicator
- Parameterised via `PACKET_W`, `FIFO_DEPTH`, `CUR_COL`, `CUR_ROW`

![NeuraEdge NoC routing and router FSM](neuraedge-noc.svg)

**FSM states**: `IDLE → ARBITRATE → WAIT_RD1 → WAIT_RD2 → ACCUMULATE`
**Throughput**: 4 cycles per spike event

### 4.3 `neuron_core.v`

Vectorised LIF neuron array — 64 neurons updated in parallel each clock cycle.

```
V[t+1] = (V[t] >> LEAK_SHIFT) + I_syn[t]

if V[t+1] >= THRESHOLD:
    spike_out[n] = 1
    V[t+1] = 0
```

- `neuron_enable` input gates updates (freeze for power gating)
- `fire_count` — cumulative spike count (saturates at `0xFFFFFFFF`, no wrap)
- `mem_debug[n]` — exposes membrane potential of neuron n for observability
- Reset-safe; parameter guards prevent out-of-range configurations at synthesis

### 4.4 `synapse_memory.v`

4-bank BRAM weight store — all 512 synapses for one pre-neuron readable in a single cycle.

```
Bank 0: W[pre][synapses   0–127]
Bank 1: W[pre][synapses 128–255]
Bank 2: W[pre][synapses 256–383]
Bank 3: W[pre][synapses 384–511]
```

- `NUM_BANKS=4`, 8-bit weights, 32 KB per cluster, 128 KB total
- Port A: wide parallel read (inference); Port B: narrow write (STDP / SPI loader)
- RAW bypass: same-cycle write/read returns new data
- Reset logic intentionally absent from the BRAM output register — required for correct BRAM18 inference on Artix-7

### 4.5 `learning_engine.v`

Trace-based STDP update engine. Accepts pre / post spike vectors from `neuron_core`, reads current weights from `synapse_memory`, and writes back updated weights.

```
On pre-spike  [i]:  W[i][j] -= A_MINUS * post_trace[j]   // LTD
On post-spike [j]:  W[i][j] += A_PLUS  * pre_trace[i]    // LTP

Traces update every cycle:
  pre_trace[i]  += TRACE_INCR on pre-spike,  >> TRACE_DECAY decay
  post_trace[j] += TRACE_INCR on post-spike, >> TRACE_DECAY decay
```

- Weights saturate to `[MIN_WEIGHT, MAX_WEIGHT]`
- `SPIKE_QUEUE_D` — small event queue for burst smoothing
- Exposes `ltp_count`, `ltd_count`, `scan_active` for UART / ILA observability

---

## 5. Timing Snapshot

Post-route, Vivado 2024.x, `xc7a100tcsg324-1`, 100 MHz:

| Metric | Value |
|--------|-------|
| WNS | +0.248 ns |
| TNS | 0.000 ns |
| WHS | +0.050 ns |
| THS | 0.000 ns |
| Critical path | `learning_engine` STDP weight update scan |

Single clock domain throughout; no intentional CDC. The SPI interface uses a 2-FF synchroniser on `spi_sclk` — this is a metastability-tolerance measure, not a formal CDC boundary.

Reference report: [`reports/timing_summary_postchange.rpt`](../reports/timing_summary_postchange.rpt)

---

## 6. Memory Footprint

| Scope | Calculation | Size |
|-------|-------------|------|
| One cluster | 64 neurons × 512 synapses × 8 bits | 32 KB |
| Full design (4 clusters) | 4 × 32 KB | 128 KB |
| BRAM18 usage | 8 RAMB18 per cluster × 4 clusters | **32 RAMB18** |

Physical BRAM18 count is verified automatically by `scripts/vivado/synth.tcl` — the build fails if fewer than 30 RAMB18 are inferred.

---

## 7. FPGA-to-ASIC Notes

The RTL is written in Verilog-2001-compatible style with no FPGA primitives in the design proper.

| Element | FPGA | ASIC replacement |
|---------|------|-----------------|
| `synapse_memory.v` | BRAM18 inference | SRAM macro (e.g. `sky130_sram_1kbyte`) |
| I/O standards | LVCMOS33 | Padframe (`sky130_fd_io`) |
| Timing constraints | XDC | SDC |
| Clock buffer | BUFG (implicit) | Sky130 clock tree synthesis |

See [`scaling.md`](scaling.md) for the full migration checklist.

---

## 8. Known Architectural Tradeoffs

- **STDP scan latency** — Under maximum activity (all 64 neurons firing), the learning engine creates the longest sequential paths in the design. Pipelining the scan is the first step to exceed 100 MHz.
- **Throughput vs area** — The design favours clarity and deterministic behaviour over maximum throughput. The NoC processes one spike event at a time per router instance; a pipelined router would increase throughput but complicate verification.
- **Debug observability** — ILA probes, UART telemetry, and LED outputs are optimised for FPGA bring-up. These should be stripped or gated for ASIC area and power targets.
