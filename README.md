# NeuraEdge

> A minimal neuromorphic chip design in SystemVerilog to learn how brain-inspired computing works from the ground up.

---

Modern neuromorphic processors like Intel's Loihi and IBM's TrueNorth are notoriously complex. While many resources exist for machine learning and neural networks in software, very few explain the actual **hardware** that could run them with 1000x better energy efficiency.

**NeuraEdge** is designed as an educational tool to help you understand neuromorphic computing fundamentals by stripping away production-grade complexity and focusing on the core ideas that make neuromorphic chips different from CPUs and GPUs.

Specifically, with the rise of edge AI and the limitations of von Neumann architectures, NeuraEdge focuses on highlighting the **general principles** of spike-based event-driven computation — the foundation of all neuromorphic hardware. With this motivation in mind, we cut out the majority of complexity involved in building a production-grade neuromorphic chip, and focus on the core elements that are critical to this class of hardware.

After understanding the fundamentals laid out in this project, you can explore the **advanced functionality** section to understand some of the most important optimizations made in production-grade neuromorphic chips that improve performance and energy efficiency.

---

## Overview

- [Background](#background)
- [Architecture](#architecture)
  - [Neuron Core](#neuron-core)
  - [Synaptic Memory](#synaptic-memory)
  - [Spike Router](#spike-router)
  - [STDP Learning Engine](#stdp-learning-engine)
  - [Event Scheduler](#event-scheduler)
  - [Global Memory Interface](#global-memory-interface)
- [Instruction Set Architecture (ISA)](#instruction-set-architecture)
- [Execution Model](#execution-model)
- [Spike Encoding](#spike-encoding)
- [Example Networks](#example-networks)
  - [XOR Classification](#xor-classification)
  - [Pattern Recognition](#pattern-recognition)
  - [MNIST Digit Recognition](#mnist-digit-recognition)
- [Setup & Simulation](#setup--simulation)
- [Advanced Functionality](#advanced-functionality)

---

## Background

### What makes a chip "neuromorphic"?

A neuromorphic chip is a processor designed to **mimic the architecture and operating principles of biological neural networks**. Unlike CPUs and GPUs which execute instructions on a clock cycle, neuromorphic chips are **event-driven** — they only perform computation when a neuron fires a spike.

This has a profound implication: **no spikes = zero power consumption**. Biological brains exploit this property to run on approximately 20 watts. A GPU running inference on a similar task might use 300W.

### Why is this hard?

Three fundamental challenges make neuromorphic hardware design difficult:

1. **Time is a first-class citizen.** Unlike matrix multiplication where order doesn't matter within a batch, spike timing encodes information. The *when* of a spike is as important as the *whether*.

2. **Memory and compute are entangled.** Synaptic weights (memory) live next to neuron cores (compute), breaking the classical separation of CPU and RAM that every programmer is familiar with.

3. **Learning is local.** Backpropagation requires global gradient information. Biological learning rules like STDP update weights using only local pre- and post-synaptic spike timing — this must be implemented in hardware.

### How NeuraEdge works

NeuraEdge implements a minimal but complete neuromorphic processing pipeline:

```
Spike Input → Encoder → Neuron Array → Spike Router → Output Decoder
                                ↕
                        Synaptic Memory (BRAM)
                                ↕
                        STDP Learning Engine
```

The chip processes input data encoded as spike trains, routes spikes through a network of Leaky Integrate-and-Fire (LIF) neurons connected by plastic synapses, and decodes output spike patterns into classification results.

---

## Architecture

NeuraEdge ships in **two configurations** — a 32-neuron XOR baseline and a 128-neuron MNIST classifier. Both share the same neuron core, STDP engine, encoder, and scheduler; they differ only in synaptic memory width and router pipeline depth.

```
neuraedge/
├── src/
│   ├── neuraedge.sv          # Top-level chip (32-neuron XOR baseline)
│   ├── neuraedge_mnist.sv    # Top-level chip (128-neuron MNIST)
│   ├── neuraedge_top.sv      # Basys 3 FPGA board wrapper
│   ├── neuron.sv             # LIF neuron core
│   ├── neuron_array.sv       # Parallel neuron array (N neurons)
│   ├── synapse_mem.sv        # Synaptic weight BRAM (32×32, single bank)
│   ├── synapse_mem_128.sv    # Synaptic weight BRAM (128×128, 4-bank)
│   ├── spike_router.sv       # AER event bus & routing (32-neuron)
│   ├── spike_router_128.sv   # Pipelined AER router (128-neuron)
│   ├── stdp.sv               # Spike-Timing-Dependent Plasticity
│   ├── scheduler.sv          # Event-driven dispatch
│   ├── encoder.sv            # Rate/temporal spike encoder
│   └── decoder.sv            # Argmax spike-count output decoder
├── tests/
│   ├── neuron_tb.sv          # Single neuron unit tests
│   ├── network_tb.sv         # XOR chip integration tests (9 phases)
│   └── mnist_tb.sv           # 128-neuron MNIST testbench (8 phases)
├── kernels/
│   ├── xor_network.py        # XOR spike-encoded simulation
│   ├── pattern_classify.py   # 4-class pattern recognition
│   └── mnist_train.py        # MNIST SNN training + weight export
├── weights/                  # Generated weight files (git-ignored)
└── README.md
```

### Top-Level Architecture Diagram

The 128-neuron MNIST configuration (`neuraedge_mnist.sv`):

```
┌─────────────────────────────────────────────────────────────────┐
│                         NeuraEdge Chip                          │
│                                                                 │
│  ┌──────────┐    ┌─────────────────────────────────────────┐   │
│  │  Spike   │    │             Neuron Array                 │   │
│  │ Encoder  │───▶│  [N0] [N1] [N2] ... [N127]              │   │
│  └──────────┘    │   LIF  LIF  LIF        LIF              │   │
│                  └──────────────┬───────────────────────────┘   │
│                                 │ Spike Events (AER)            │
│                  ┌──────────────▼──────────────────────────┐   │
│                  │           Spike Router                   │   │
│                  │   4-stage pipeline, 1 spike / 4 cycles   │   │
│                  └──────────────┬──────────────────────────┘   │
│                                 │                               │
│            ┌────────────────────┤                               │
│            │                   │                               │
│  ┌─────────▼──────┐  ┌─────────▼──────┐                       │
│  │  Synaptic Mem  │  │  STDP Engine   │                       │
│  │  4-bank BRAM   │  │  Δw = f(Δt)   │                       │
│  │ 128×128 × 8b   │  └────────────────┘                       │
│  └────────────────┘                                            │
│                                                                 │
│  ┌──────────┐    ┌────────────────┐                            │
│  │ Argmax   │◀───│   Scheduler    │                            │
│  │ Decoder  │    │ event dispatch │                            │
│  └──────────┘    └────────────────┘                            │
└─────────────────────────────────────────────────────────────────┘
```

The 32-neuron XOR baseline (`neuraedge.sv`) uses the same pipeline with a single-bank 32×32 BRAM and a simpler 4-state router FSM.

---

### Neuron Core

The fundamental compute unit of NeuraEdge is the **Leaky Integrate-and-Fire (LIF) neuron** — the biological neuron reduced to its essential electrical behaviour.

A biological neuron receives current from upstream synapses, integrates it on its membrane capacitance, and fires an action potential when voltage exceeds a threshold. The "leaky" aspect comes from the passive membrane resistance which continuously drains charge back toward rest.

In digital hardware, we implement this as:

```
V[t+1] = V[t] * λ + I_syn[t]     (integrate + leak)

if V[t+1] >= V_threshold:
    emit spike
    V[t+1] = V_reset              (fire + reset)
```

Where:
- `V[t]` — membrane potential (Q2.6 fixed-point)
- `λ` — leak factor (e.g. 0.9 = 10% leak per timestep)
- `I_syn[t]` — total weighted synaptic input this timestep
- `V_threshold` — firing threshold (e.g. 1.0)
- `V_reset` — reset potential after spike (e.g. 0.0)

**Why fixed-point?** Using Q2.6 fixed-point arithmetic (2 integer bits, 6 fractional bits) instead of 32-bit floating point reduces resource usage to approximately 28 LUTs per neuron on an Artix-7 FPGA — making a 32-neuron array feasible on a ~$150 development board.

```systemverilog
// neuron.sv — simplified
module neuron #(
    parameter LEAK_FACTOR = 8'b11100110, // ~0.9 in Q2.6
    parameter THRESHOLD   = 8'b01000000  // 1.0 in Q2.6
)(
    input  logic        clk, rst,
    input  logic [7:0]  i_syn,      // synaptic current input
    output logic        spike_out   // spike output
);
    logic [7:0] v_mem;              // membrane potential

    always_ff @(posedge clk) begin
        if (rst) begin
            v_mem     <= 8'b0;
            spike_out <= 1'b0;
        end else begin
            // Leak + integrate
            v_mem <= (v_mem * LEAK_FACTOR >> 6) + i_syn;

            // Fire + reset
            if (v_mem >= THRESHOLD) begin
                spike_out <= 1'b1;
                v_mem     <= 8'b0;
            end else begin
                spike_out <= 1'b0;
            end
        end
    end
endmodule
```

Each neuron maintains only its membrane potential as state — making it extremely lightweight. All neurons in the array run in parallel every clock cycle (32 in the XOR baseline, 128 in the MNIST configuration).

---

### Synaptic Memory

The synaptic weight matrix `W[i][j]` stores the connection strength from pre-synaptic neuron `i` to post-synaptic neuron `j`.

**32-neuron baseline (`synapse_mem.sv`):**
- 32×32 matrix of 8-bit weights = 1KB
- Single dual-port BRAM18K
- Single-cycle read latency
- Port A: read (spike router); Port B: write (config / STDP)

**128-neuron MNIST (`synapse_mem_128.sv`):**
- 128×128 matrix of 8-bit weights = 16KB
- 4 parallel BRAM instances (32 columns each) — reading all 128 post-synaptic weights simultaneously would require a 1,024-bit-wide port (128 × 8 bits), which is impractical from a single BRAM tile. Splitting across 4 banks (256-bit each) lets all four be read in the same clock cycle
- 2-cycle registered read pipeline
- Port A: wide read (pre-index → all 128 post-synaptic weights in one read); Port S: narrow read for STDP/host; Port B: write

```
128-Neuron Bank Layout:
  Bank 0: W[pre][0..31]    ← first 32 post-synaptic columns
  Bank 1: W[pre][32..63]
  Bank 2: W[pre][64..95]
  Bank 3: W[pre][96..127]  ← last 32 post-synaptic columns

All 4 banks read in parallel → 128 weights available after 2 cycles
```

```
Synapse Memory Layout:
Row    = Pre-synaptic neuron index  (which neuron is sending)
Column = Post-synaptic neuron index (which neuron is receiving)

W[0][0]  W[0][1]  W[0][2]  ...  W[0][31]   ← weights FROM neuron 0
W[1][0]  W[1][1]  W[1][2]  ...  W[1][31]   ← weights FROM neuron 1
...
W[31][0] W[31][1] W[31][2] ...  W[31][31]  ← weights FROM neuron 31
```

When neuron `i` fires a spike, the spike router reads row `i` from synaptic memory and distributes the weighted currents to all downstream neurons. This is the neuromorphic equivalent of a matrix-vector multiply — but triggered by events, not by a clock.

**Excitatory vs. Inhibitory synapses:** Weights can be positive (excitatory — push membrane toward threshold) or negative (inhibitory — push membrane away from threshold). This allows the network to implement winner-take-all circuits essential for classification.

---

### Spike Router

The spike router is the **central interconnect** of NeuraEdge. It implements an Address-Event Representation (AER) bus — the standard communication protocol in neuromorphic systems.

When a neuron fires, it places its address (neuron index) on the AER bus. The router:
1. Captures the firing address
2. Reads the corresponding row from synaptic memory
3. Delivers weighted currents to all target neurons within the same timestep
4. Forwards the event to the STDP engine for weight updates

**32-neuron router (`spike_router.sv`):** 4-state FSM (IDLE → ARBITRATE → READ\_MEM → ACCUMULATE), single-cycle BRAM read, processes each destination weight sequentially — 3 cycles per spike event.

**128-neuron router (`spike_router_128.sv`):** 5-state pipelined FSM that absorbs the 2-cycle BRAM read latency of the 4-bank memory:

```
FSM States:
  S_IDLE       → wait for spikes in timestep
  S_ARBITRATE  → priority-encode 128-bit spike vector, select lowest-index
  S_WAIT_RD1   → BRAM read cycle 1 (registered pipeline stage)
  S_WAIT_RD2   → BRAM read cycle 2 (data valid)
  S_ACCUMULATE → 128× saturating add: I_syn[j] += W[pre][j]
```

Throughput: **4 cycles per spike event**. At 10% firing rate (≈13 spikes/timestep) this adds ~52 cycles of routing overhead per timestep.

```
Spike Event from Neuron 5 (128-neuron):
  ┌─────────────────────────────────────────────┐
  │  AER Bus: addr=5, spike=1                   │
  │                                             │
  │  Cycle 0: ARBITRATE → select pre=5          │
  │  Cycle 1: WAIT_RD1  → BRAM read issued      │
  │  Cycle 2: WAIT_RD2  → data arriving         │
  │  Cycle 3: ACCUMULATE→ I_syn[0..127] updated │
  │                                             │
  │  STDP notified: pre_spike[5] = timestamp    │
  └─────────────────────────────────────────────┘
```

**Arbitration:** When multiple neurons fire in the same timestep, the router uses a priority encoder to process them one at a time (lowest index first). In production neuromorphic chips (e.g., Loihi), arbitration is one of the most complex subsystems — NeuraEdge uses a simple priority encoder for clarity.

---

### STDP Learning Engine

**Spike-Timing-Dependent Plasticity (STDP)** is the biologically-inspired learning rule that allows NeuraEdge to learn. Unlike backpropagation (which requires global error information), STDP uses only *local* information: the relative timing of pre- and post-synaptic spikes.

The rule is simple:
- If neuron A fires **before** neuron B, synapse A→B strengthens (**Long-Term Potentiation**)
- If neuron A fires **after** neuron B, synapse A→B weakens (**Long-Term Depression**)

Mathematically:

```
ΔW = A_+ × exp(-Δt / τ_+)   if Δt > 0   (pre before post → strengthen)
ΔW = A_- × exp(+Δt / τ_-)   if Δt < 0   (post before pre → weaken)

Where Δt = t_post - t_pre
```

In hardware, we approximate the exponential decay with a **lookup table** (32 entries) to avoid costly multiply operations:

```systemverilog
// stdp.sv — weight update logic
always_ff @(posedge clk) begin
    if (post_spike) begin
        delta_t = post_timestamp - pre_timestamp[pre_idx];
        if (delta_t > 0 && delta_t < WINDOW)
            W[pre_idx][post_idx] <= W[pre_idx][post_idx] + ltp_lut[delta_t];
        else if (delta_t < 0 && delta_t > -WINDOW)
            W[pre_idx][post_idx] <= W[pre_idx][post_idx] - ltd_lut[-delta_t];
    end
end
```

**NeuraEdge STDP parameters:**
- `A_+` = 0.01 (LTP amplitude)
- `A_-` = 0.012 (LTD amplitude, slightly stronger to prevent runaway potentiation)
- `τ_+` = `τ_-` = 20 timesteps (time constant)
- Learning window = ±40 timesteps

---

### Event Scheduler

The scheduler is the **brain of NeuraEdge** — it coordinates the execution of spike events across all neurons and manages the timestep clock.

Unlike a GPU scheduler that dispatches threads to cores, the NeuraEdge scheduler:
1. Advances the global simulation timestep
2. Polls all neurons for spike output
3. Queues spike events for the router
4. Throttles router throughput based on memory bandwidth
5. Signals STDP engine after each routing event

```
Timestep Loop:
┌──────────────────────────────────────────────────────┐
│  t = t + 1                                           │
│                                                      │
│  FOR each neuron n in 0..N-1:                        │
│    IF neuron[n].spike == 1:                          │
│      event_queue.push(n, timestamp=t)                │
│                                                      │
│  WHILE event_queue not empty:                        │
│    event = event_queue.pop()                         │
│    router.route(event)        ← read synapse row     │
│    stdp.update(event)         ← update weights       │
│                                                      │
│  neuron_array.update()        ← integrate all        │
└──────────────────────────────────────────────────────┘
```

**Why event-driven?** If most neurons are silent (typical in sparse spike codes), the scheduler skips them entirely. A 32-neuron network with 10% firing rate processes only ~3 events per timestep instead of 32 — achieving the power efficiency central to neuromorphic computing.

---

### Global Memory Interface

NeuraEdge is built to interface with an external host (FPGA fabric or SoC) for loading network configurations and reading results.

**Program memory** stores the initial synaptic weight matrix and neuron parameters:
- 8-bit addressability (256 configuration rows)
- Loaded once before inference begins
- Read-only during active spike processing

**Data memory** stores spike-encoded input patterns and output spike counts:
- 8-bit addressability
- Written by host before each inference
- Read by host after output layer converges

---

## Instruction Set Architecture

NeuraEdge implements a simple **9-instruction configuration ISA** for loading network parameters and controlling inference runs.

This ISA is used exclusively for setup and control — not for neuron computation (which is handled by the hardware datapath, not a stored program).

| Instruction  | Opcode | Description                            |
|--------------|--------|----------------------------------------|
| `LOAD_W`     | `0001` | Load synaptic weight W[i][j] = imm8    |
| `LOAD_V`     | `0010` | Load neuron threshold V_th[i] = imm8   |
| `LOAD_L`     | `0011` | Load leak factor λ[i] = imm8           |
| `SET_INPUT`  | `0100` | Set neuron i as input neuron           |
| `SET_OUTPUT` | `0101` | Set neuron i as output neuron          |
| `RUN`        | `0110` | Begin spike processing for T timesteps |
| `READ_S`     | `0111` | Read spike count of neuron i           |
| `RESET`      | `1000` | Reset all membrane potentials          |
| `HALT`       | `1001` | Stop processing                        |

**Instruction encoding (16-bit):**

```
 15      12  11       8   7        4   3        0
┌──────────┬──────────┬──────────┬──────────────┐
│  opcode  │  neuron  │  target  │   imm / op   │
│  [4 bits]│  [4 bits]│  [4 bits]│   [4 bits]   │
└──────────┴──────────┴──────────┴──────────────┘
```

**Example — Loading a network configuration:**

```asm
; Set neuron 0 and 1 as inputs
SET_INPUT  0
SET_INPUT  1

; Set neuron 6 and 7 as outputs
SET_OUTPUT 6
SET_OUTPUT 7

; Load excitatory weight from neuron 0 → neuron 2
LOAD_W  0  2  0x40     ; W[0][2] = 1.0 (Q2.6)

; Load inhibitory weight from neuron 6 → neuron 7
LOAD_W  6  7  0xC0     ; W[6][7] = -1.0 (Q2.6, inhibitory)

; Run for 100 timesteps
RUN  100

; Read output spike counts
READ_S  6
READ_S  7

HALT
```

---

## Execution Model

Understanding exactly how NeuraEdge processes a spike is key to understanding the whole chip. Each spike event goes through the following 5-stage pipeline:

### Stage 1: Encode
Input data (e.g., pixel intensities, sensor values) is converted into spike trains by the encoder. NeuraEdge supports two encoding schemes:

- **Rate coding:** Higher input value → higher spike frequency. Simple, robust, but slower (requires many timesteps to encode information).
- **Temporal coding:** Input value maps to the *latency* of the first spike. Faster and more energy-efficient.

```python
# Rate encoding example (Python simulation)
def rate_encode(value, max_rate=100, T=200):
    """Encode value as Poisson spike train over T timesteps"""
    rate = (value / 255.0) * max_rate
    spikes = np.random.poisson(rate / T, T).clip(0, 1)
    return spikes
```

### Stage 2: Integrate
Every active input neuron delivers spikes to its downstream neurons via synaptic connections. Each receiving neuron accumulates:

```
I_syn[j] = Σ_i ( spike[i] × W[i][j] )
```

This is computed in parallel across all neurons — every neuron integrates all incoming spikes simultaneously in one clock cycle.

### Stage 3: Fire
After integration, each neuron checks its membrane potential against its threshold. If `V >= V_threshold`, the neuron fires a spike and resets. This check happens combinatorially — no extra clock cycle needed.

### Stage 4: Route
The spike router captures all firing neurons (the "spike vector") and distributes their output weights to the next layer. This is the most bandwidth-intensive stage — in the 32-neuron baseline each spike reads one 32-byte row; in the 128-neuron MNIST configuration a pipelined 4-bank BRAM read delivers all 128 weights in 2 cycles.

### Stage 5: Learn (optional)
If STDP learning is enabled, the weight update engine computes `ΔW` for all synapse pairs involved in the current spike event. Weights are updated in-place in BRAM. During inference-only mode, this stage is bypassed entirely to save power.

---

## Spike Encoding

Spike encoding is the interface between the real world and the neuromorphic chip. NeuraEdge's encoder module (`encoder.sv`) supports both primary encoding schemes:

### Rate Coding

Information is encoded in the **firing frequency** of a neuron. A pixel with intensity 200/255 fires at ~78% of maximum rate; intensity 50/255 fires at ~20%.

```
Intensity = 200:   1 0 1 1 0 1 1 0 1 1   (high frequency)
Intensity = 50:    0 0 0 1 0 0 0 1 0 0   (low frequency)
```

**Pros:** Simple, noise-tolerant  
**Cons:** Requires many timesteps (typically 100–500) to reliably encode a value

### Temporal Coding (Time-to-First-Spike)

Information is encoded in the **latency** of the first spike. High-intensity inputs spike early; low-intensity inputs spike late.

```
Intensity = 255:   1 0 0 0 0 0 0 0 0 0   (spikes at t=1)
Intensity = 128:   0 0 0 0 1 0 0 0 0 0   (spikes at t=5)
Intensity = 0:     0 0 0 0 0 0 0 0 0 1   (spikes at t=10)
```

**Pros:** Only 1 spike per neuron — maximum energy efficiency  
**Cons:** More sensitive to noise; timing precision matters

NeuraEdge defaults to **rate coding** for robustness, but temporal coding can be selected at runtime via the `LOAD_ENC` configuration register.

---

## Example Networks

NeuraEdge ships with two reference networks that demonstrate the core capabilities of spike-based inference.

### XOR Classification

The XOR problem (output 1 only when inputs differ) cannot be solved by a single-layer perceptron. NeuraEdge solves it with a 3-layer spiking network: 2 inputs → 2 hidden → 1 output.

**Network topology:**

```
     Input Layer          Hidden Layer         Output Layer
    ┌───────────┐        ┌───────────┐        ┌───────────┐
    │  N0 (x1)  │──+──▶ │  N2 (AND) │──┐     │           │
    │           │  │    └───────────┘  ├──▶  │  N6 (XOR) │
    │  N1 (x2)  │──┘──▶ │  N3 (OR)  │──┘     │           │
    └───────────┘        └───────────┘        └───────────┘
                         (N4: inhibitory)
```

**Kernel (`kernels/xor_network.py`):**

```python
import numpy as np

# Input: (x1=1, x2=0) → expected XOR output = 1
inputs = [
    [1, 0],   # XOR = 1
    [0, 1],   # XOR = 1
    [1, 1],   # XOR = 0
    [0, 0],   # XOR = 0
]

# Rate-encode inputs as spike trains (T=100 timesteps)
T = 100
for x1, x2 in inputs:
    spikes_n0 = rate_encode(x1 * 255, T=T)
    spikes_n1 = rate_encode(x2 * 255, T=T)
    output_spikes = run_neuraedge(spikes_n0, spikes_n1, T=T)
    predicted = 1 if output_spikes > T * 0.3 else 0
    print(f"XOR({x1},{x2}) = {predicted}")
```

**Expected output:**
```
XOR(1,0) = 1  ✓
XOR(0,1) = 1  ✓
XOR(1,1) = 0  ✓
XOR(0,0) = 0  ✓
```

Accuracy: **100%** on all 4 XOR combinations.

---

### Pattern Recognition

A 4-class spike-based pattern recognition task using a 16-input → 8-hidden → 4-output network. Each class corresponds to a unique spatiotemporal spike pattern.

```
Class 0 (Vertical line):     Class 1 (Horizontal line):
  1 0 0 0                       1 1 1 1
  1 0 0 0                       0 0 0 0
  1 0 0 0                       0 0 0 0
  1 0 0 0                       0 0 0 0
```

After STDP training (500 timesteps), the network achieves >92% classification accuracy on held-out patterns.

---

### MNIST Digit Recognition

The 128-neuron configuration classifies handwritten digits from the MNIST dataset. This is the largest network NeuraEdge ships with, and is designed to fit on a Digilent Basys 3 board using only 4 of its 50 BRAM18K tiles.

**Network topology:**

```
  Input   : neurons 0–63    (64 inputs — 28×28 image avg-pooled to 7×7, zero-padded)
  Hidden  : neurons 64–117  (54 LIF neurons)
  Output  : neurons 118–127 (10 neurons, one per digit class 0–9)
```

**Input pre-processing — why 4×4 average pooling?**

784 raw MNIST pixels → 784 input neurons → 784×128 ≈ 100K synapses ≈ 98KB of weight storage. A Basys 3 has 50 BRAM18K tiles = 112.5KB total, leaving almost no room for anything else. Applying 4×4 average pooling first:

```
28×28 image  →  4×4 pool  →  7×7 feature map  →  zero-pad  →  64 inputs
```

The weight matrix shrinks to 128×128 = 16KB = 4 BRAMs (8% of the board).

**Three-step flow:**

```bash
# Step 1 — structural RTL simulation (zero weights, tests all FSMs)
make sim_mnist

# Step 2 — train the SNN, export Q2.6 hex weights
make train_mnist         # → weights/mnist_weights.hex

# Step 3 — validate fixed-point accuracy matches float baseline
make test_mnist_hw       # expected: ~90% on 1,000 test images
```

**Training script (`kernels/mnist_train.py`):**

Downloads MNIST, applies 4×4 average pooling, trains a two-layer SNN (64→54→10) using surrogate-gradient descent, then quantizes all weights to Q2.6 fixed-point and exports a flat hex file for `$readmemh`:

```python
# Load trained weights into RTL simulation
# Uncomment in synapse_mem_128.sv:
# $readmemh("weights/mnist_weights.hex", weight_mem);
```

**Resource utilisation on Basys 3 (Artix-7 xc7a35t):**

| Resource | 32-neuron XOR | 128-neuron MNIST |
|----------|---------------|-----------------|
| LUTs     | ~1,200  (4%)  | ~3,800  (11%)   |
| FFs      | ~800          | ~2,400          |
| BRAMs    | 1             | 4  (8%)         |
| DSPs     | 0             | 0               |
| Fmax     | ~180 MHz      | ~160 MHz        |
| Inference time | ~54 µs  | ~162 µs         |

---

## Setup & Simulation

### Requirements

- `iverilog` — Icarus Verilog 10+ (supports SystemVerilog 2012 natively with `-g2012`)
- `python3` — for kernel generation, MNIST training, and result visualisation
- `numpy` — required for all Python kernels (`pip install numpy`)
- (Optional) `sv2v` — SystemVerilog-to-Verilog converter for older tools
- (Optional) Xilinx Vivado for FPGA synthesis

### Install Icarus Verilog

```bash
# Ubuntu/Debian
sudo apt-get install iverilog

# macOS
brew install icarus-verilog
```

### Clone & Simulate

```bash
git clone https://github.com/anykrver/neuraedge-
cd neuraedge-

# Run all baseline tests (6 neuron unit tests + 13 network integration tests)
make all

# Run 128-neuron MNIST integration tests (16 structural tests, no weights needed)
make sim_mnist

# Run XOR Python simulation
make sim_python
```

### Available Make Targets

```
make sim_neuron     — Single LIF neuron unit tests   (6 tests)
make sim_network    — XOR chip integration tests     (13 tests)
make sim_mnist      — 128-neuron MNIST testbench     (16 tests)
make train_mnist    — Train SNN, export hex weights  (~10 min CPU)
make test_mnist_hw  — Validate Q2.6 quantised accuracy
make sim_python     — Run XOR Python LIF simulation
make wave_neuron    — neuron sim + GTKWave waveform viewer
make wave_network   — network sim + GTKWave waveform viewer
make clean          — Remove build/ directory
make help           — Show all targets
```

### MNIST Training & Validation

```bash
# Train the SNN on MNIST and export Q2.6 weights to weights/mnist_weights.hex
make train_mnist

# Validate that Q2.6 quantised weights match float accuracy
make test_mnist_hw
```

After training, uncomment the `$readmemh` line in `src/synapse_mem_128.sv` to load real weights into the RTL simulation:

```systemverilog
// In src/synapse_mem_128.sv — initial block:
$readmemh("weights/mnist_weights.hex", weight_mem);
```

Then re-run `make sim_mnist` to verify inference end-to-end.

### FPGA Synthesis (Xilinx Artix-7 / Basys 3)

```bash
# Open Vivado, create project targeting Digilent Basys 3 (xc7a35tcpg236-1)
# Add all files from src/ directory
# Set neuraedge_top.sv as top module (32-neuron XOR demo)
#   OR neuraedge_mnist.sv for 128-neuron MNIST
# Apply constraints from constraints/neuraedge_basys3.xdc
# Run Synthesis → Implementation → Generate Bitstream

# Board connections (neuraedge_top.sv):
#   SW[0]  = input x1         SW[1]  = input x2
#   BTNR   = run inference     BTNC   = reset
#   LED[0] = inference done    LED[1] = XOR result
#   LED[6] = heartbeat (1 Hz)  7-seg  = spike count
```

### Synthesis Results (32-neuron `neuraedge_top`, Artix-7 xc7a35t @ 100 MHz)

Post-implementation results from Vivado after the type-mismatch fix:

| Resource   | Used  | Available | Utilisation |
|------------|-------|-----------|-------------|
| LUTs       | 2,166 | 20,800    | 10.4%       |
| FFs        | 1,466 | 41,600    | 3.5%        |
| BRAM (18K) | 1     | 100       | 1.0%        |
| DSPs       | 0     | 90        | 0%          |

**Timing:** WNS = +1.181 ns at 100 MHz. Critical path is in the STDP weight update (10 logic levels, `t_spike_reg` through `CARRY4` to `mem_wdata_reg`). Well within margin.

---

## Advanced Functionality

The following features are found in production neuromorphic chips but are intentionally excluded from NeuraEdge for simplicity. Understanding them is the natural next step after mastering this project.

### Izhikevich Neuron Model
The LIF neuron cannot reproduce many biologically-observed firing patterns (bursting, chattering, resonance). The **Izhikevich model** adds a recovery variable that enables 20+ biologically realistic firing patterns while remaining computationally simple. It requires 2 state variables and 4 parameters per neuron instead of LIF's 1 state variable and 2 parameters.

### Axonal Conduction Delays
In biological brains, spikes take different amounts of time to travel along axons of varying length. Adding **programmable delay lines** to the spike router allows the chip to encode information in the *relative timing* between spikes — enabling much more powerful temporal processing.

### Multicompartment Neurons
Real neurons have complex dendritic trees that perform non-linear computations before the spike reaches the soma. Multi-compartment models can be implemented in hardware to gain significant representational power at moderate area cost.

### Homeostatic Plasticity
STDP alone is unstable — strong positive feedback can cause all neurons to either max out their firing rate or go completely silent. Homeostatic plasticity implements a slow negative feedback mechanism that keeps average firing rates near a target level, stabilizing long-term learning.

### On-Chip Learning with Inference
NeuraEdge separates learning and inference phases. Production chips like Intel's Loihi perform both simultaneously, with spike-triggered weight updates happening in real-time without interrupting inference. This requires careful arbitration of BRAM write ports and adds significant scheduling complexity.

### Warp-Style Neuron Batching
Like GPU warps processing multiple threads simultaneously, production neuromorphic chips process multiple neuron populations in a time-multiplexed fashion on fewer physical cores. This trades latency for area efficiency, enabling millions of neurons on a single chip.

---

## Project Motivation

This project was built to answer one question: **how do you actually build a chip that thinks like a brain?**

The software side of neuromorphic computing — spiking neural network frameworks like Norse, BindsNET, and Brian2 — is well-documented. But the hardware that would run these networks efficiently barely exists in open-source form.

NeuraEdge is a foundation. A minimal but real implementation that you can simulate, modify, synthesize, and learn from. Every design decision was made to favour clarity over performance.

The next step is yours.

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

## Acknowledgements

Inspired by [tiny-gpu](https://github.com/adam-maj/tiny-gpu) by Adam Majmudar — the clearest hardware architecture tutorial ever written.

Neuron model based on: Gerstner, W. & Kistler, W.M. (2002). *Spiking Neuron Models*. Cambridge University Press.

STDP rule based on: Bi, G. & Poo, M. (1998). Synaptic modifications in cultured hippocampal neurons. *Journal of Neuroscience*, 18(24), 10464–10472.
