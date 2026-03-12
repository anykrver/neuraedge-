# Encoder

The encoder is the **interface between the real world and the neuromorphic chip**. It converts raw numerical input values (e.g., pixel intensities, sensor readings) into sequences of binary spikes that the neuron array can process.

## Why Spike Encoding?

Neuromorphic hardware does not operate on floating-point vectors. Instead it processes *events* — discrete voltage pulses called spikes. The encoder's job is to translate a conventional digital value (0–255) into a pattern of spikes spread across time that carries the same information.

NeuraEdge supports two biologically-motivated encoding strategies, selectable at runtime via the `mode` input.

## Rate Coding (`mode = 0`)

Information is encoded in the **firing frequency** of a neuron. A high-intensity input generates spikes frequently; a low-intensity input generates them rarely.

```
Intensity = 200:   1 0 1 1 0 1 1 0 1 1   (high frequency, ~78% rate)
Intensity =  50:   0 0 0 1 0 0 0 1 0 0   (low frequency,  ~20% rate)
Intensity =   0:   0 0 0 0 0 0 0 0 0 0   (silent)
```

### Implementation

An 8-bit **Galois LFSR** (polynomial x⁸ + x⁶ + x⁵ + x⁴ + 1, seed `0xAC`) produces pseudo-random values. Each input channel fires if its LFSR sample is *less than* the raw input magnitude:

```
spike[i] = 1   if  lfsr_sample < raw_input[i]
spike[i] = 0   otherwise
```

This gives `P(spike) ≈ raw_input / 256`, producing a statistically correct Poisson-like rate code. The LFSR advances by one step per input channel per `run` pulse, so each channel sees an independent (but deterministic) pseudo-random stream.

**Pros:** Simple and noise-tolerant — the information is distributed across many timesteps.  
**Cons:** Requires many timesteps (typically 100–500) to reliably encode a value; latency is high.

## Temporal Coding (`mode = 1`) — Time-to-First-Spike

Information is encoded in the **latency** of the first spike. A high-intensity input fires early; a low-intensity input fires late or not at all within the encoding window.

```
Intensity = 255:   1 0 0 0 0 0 0 0 0 0   (spikes at t = 0)
Intensity = 128:   0 0 0 0 1 0 0 0 0 0   (spikes at t ≈ 127)
Intensity =   0:   0 0 0 0 0 0 0 0 0 1   (spikes at t = 255)
```

### Implementation

The latency for input channel `i` is computed as:

```
t_latency[i] = 255 - raw_input[i]
```

Each channel fires exactly **once per run** when `timestep >= t_latency[i]`. A `temporal_fired` flag vector prevents the channel from firing again in the same run. The flag vector is cleared at `timestep == 0`.

**Pros:** Only 1 spike per input per run — maximum energy efficiency; faster inference.  
**Cons:** More sensitive to noise; timing precision matters; requires monotonic timestep advancement.

## Module Interface (`encoder.sv`)

```systemverilog
module encoder #(
    parameter N_INPUTS = 2,    // number of input channels
    parameter DATA_W   = 8     // input value bit width
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  run,                       // pulse: trigger one encode step
    input  logic [DATA_W-1:0]     raw_input [N_INPUTS-1:0], // 0..255 input magnitudes
    input  logic [15:0]           timestep,                  // current global timestep
    input  logic                  mode,                      // 0 = rate, 1 = temporal
    output logic [N_INPUTS-1:0]   spike_out                  // encoded spikes this cycle
);
```

- `run` is a single-cycle pulse issued by the **Scheduler** once per timestep (in state `S_ENCODE`).
- `spike_out` is valid on the cycle *after* `run` is asserted (registered output).
- `rst_n` resets the LFSR to its seed and clears all `temporal_fired` flags.

## Encoding Comparison

| Property              | Rate coding          | Temporal coding         |
|-----------------------|----------------------|-------------------------|
| Information carrier   | Spike frequency      | Time of first spike     |
| Spikes per input/run  | Many (~rate × T)     | Exactly 1               |
| Minimum timesteps     | 100–500 for accuracy | 1–255 per input value   |
| Noise tolerance       | High                 | Lower                   |
| Energy cost           | Higher (more spikes) | Minimal (one spike)     |
| Hardware implementation | LFSR comparison    | Latency counter + flag  |

## Default Behaviour

NeuraEdge defaults to **rate coding** (`mode = 0`) for robustness. Temporal coding can be selected at runtime by asserting `mode = 1` before issuing `cfg_run`.

## LFSR Details

The 8-bit Galois LFSR uses the feedback polynomial:

```
x⁸ + x⁶ + x⁵ + x⁴ + 1   (source comment: taps 8,6,5,4)
```

The left-shift implementation XORs bits `s[7]`, `s[5]`, `s[4]`, and `s[3]` (0-indexed from LSB) into the new LSB each step:

```systemverilog
lfsr_step = {s[6:0], s[7] ^ s[5] ^ s[4] ^ s[3]};
```

The `lfsr_chain` generate block pre-computes `N_INPUTS + 1` successive LFSR values combinationally each cycle, so all channels are sampled from different points in the pseudo-random sequence without multi-cycle overhead. The LFSR advances by `N_INPUTS` steps atomically on each `run` pulse.

```systemverilog
// Combinational chain — N_INPUTS steps computed in one cycle
assign lfsr_chain[0] = lfsr;                          // current state
assign lfsr_chain[i] = lfsr_step(lfsr_chain[i-1]);    // each step

// At run posedge: advance state by N_INPUTS steps
lfsr <= lfsr_chain[N_INPUTS];
```
