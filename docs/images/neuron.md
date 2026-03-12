# Neuron Core

The fundamental compute unit of NeuraEdge is the **Leaky Integrate-and-Fire (LIF) neuron** — a digital abstraction of the essential electrical behaviour of a biological neuron.

## Biological Motivation

A biological neuron receives current from upstream synapses, integrates it on its membrane capacitance, and fires an action potential (spike) when the membrane voltage exceeds a threshold. The "leaky" aspect comes from the passive membrane resistance, which continuously drains charge back toward the resting potential.

## LIF Model

The LIF dynamics are expressed in two equations executed every clock cycle:

```
V[t+1] = (V[t] × λ) + I_syn[t]     ← leak + integrate

if V[t+1] >= V_threshold:
    emit spike
    V[t+1] = V_reset                ← fire + reset
```

| Symbol        | Meaning                                      | Default value     |
|---------------|----------------------------------------------|-------------------|
| `V[t]`        | Membrane potential (Q2.6 fixed-point)        | —                 |
| `λ`           | Leak factor (Q0.8, e.g. 0xE6 ≈ 0.9)         | `0xE6`            |
| `I_syn[t]`    | Total weighted synaptic input this timestep  | —                 |
| `V_threshold` | Firing threshold                             | `0x40` (1.0 Q2.6) |
| `V_reset`     | Reset potential after a spike                | `0x00` (0.0)      |

## Fixed-Point Arithmetic

NeuraEdge uses **Q2.6 fixed-point** (2 integer bits, 6 fractional bits) for membrane potential and a **Q0.8** representation for the leak factor. This keeps each neuron to approximately **28 LUTs** on an Artix-7 FPGA, making a 32-neuron array feasible on a low-cost development board.

The leak multiply is computed as:

```
v_leaked = (v_mem × LEAK_FACTOR) >> 8
```

A 16-bit intermediate product is used to avoid overflow before the right-shift.

## Refractory Period

After a spike is emitted the neuron enters a **refractory period** (`REFRAC_PERIOD` cycles, default 4). During refractory:
- The neuron cannot fire again.
- Leak is still applied each cycle.
- Incoming synaptic current is ignored.

This mirrors the biological absolute refractory period and prevents pathological runaway firing.

## Module Interface (`neuron.sv`)

```systemverilog
module neuron #(
    parameter [7:0] LEAK_FACTOR   = 8'hE6,  // ≈0.9 in Q0.8
    parameter [7:0] THRESHOLD     = 8'h40,  // 1.0 in Q2.6
    parameter [7:0] V_RESET       = 8'h00,  // 0.0
    parameter       REFRAC_PERIOD = 4
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              enable,       // freeze when 0
    input  logic signed [7:0] i_syn,        // signed Q2.6 synaptic current
    output logic        [7:0] v_mem,        // membrane potential (Q2.6)
    output logic              spike_out     // high for one cycle on firing
);
```

- `enable = 0` silences the neuron and freezes its membrane potential.
- `spike_out` is asserted for exactly **one clock cycle** per firing event.
- `rst_n` is active-low and clears all state including the refractory counter.

## Neuron Array (`neuron_array.sv`)

Individual neurons are instantiated in parallel inside `neuron_array.sv`. All `N` neurons receive their synaptic currents and advance their state in the **same clock cycle**, enabling fully parallel spike integration.

- **32-neuron baseline** (`neuraedge.sv`) — fits on a Basys 3 (Artix-7 35T).
- **128-neuron MNIST configuration** (`neuraedge_mnist.sv`) — requires a larger device or the Cmod A7-35T.

## Excitatory and Inhibitory Synapses

`i_syn` is a **signed** 8-bit value:

- Positive weight → excitatory synapse (pushes `V` toward threshold).
- Negative weight → inhibitory synapse (pushes `V` away from threshold).

Inhibitory connections are essential for implementing winner-take-all circuits used in classification output layers.

## Key Design Choices

| Choice | Rationale |
|--------|-----------|
| Q2.6 fixed-point | ~28 LUTs/neuron vs. ~200+ for single-precision float |
| Single-cycle fire check | No extra pipeline stage; spike visible next cycle |
| Refractory counter | Prevents sustained runaway firing; biologically motivated |
| Signed synaptic input | Enables inhibitory connections without separate subtract path |
