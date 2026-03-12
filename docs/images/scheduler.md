# Scheduler

The scheduler is the **control brain of NeuraEdge**. It is a 10-state finite state machine (FSM) that drives the entire spike-processing pipeline, advancing a global timestep counter and issuing single-cycle control pulses to all other modules.

## Responsibilities

1. Accept a `cfg_run` pulse from the host to start an inference run.
2. Advance the global `timestep` counter from `0` to `cfg_t_max - 1`.
3. Issue `enc_run` to trigger the encoder each timestep.
4. Assert `neu_enable_all` to let neurons integrate and fire.
5. Latch the spike vector after neurons have settled.
6. Enable the router and wait for `route_done`.
7. Optionally trigger STDP learning and wait for `stdp_done`.
8. Assert `done` when the final timestep completes.

## FSM State Diagram

```
          cfg_run
            │
   S_RESET ─┴──▶ S_IDLE ──────────────────────────────────────┐
                    │ cfg_run                                   │
                    ▼                                           │
                S_ENCODE   enc_run ← 1                         │
                    │                                           │
                    ▼                                           │
              S_INTEGRATE  neu_enable_all ← 1                  │
                    │                                           │
                    ▼                                           │
                S_FIRE     (neu_enable_all high → neurons integrate + threshold check) │
                    │                                           │
                    ▼                                           │
                S_LATCH    capture spike_vector                 │
                    │                                           │
                    ▼                                           │
                S_ROUTE    router_enable ← 1 until route_done  │
                    │                                           │
                    ▼                                           │
                S_LEARN    stdp_run ← 1 until stdp_done        │
                    │       (skipped if stdp_enable = 0)        │
                    ▼                                           │
               S_ADVANCE   timestep ← timestep + 1             │
                    │                                           │
                    ├── timestep < cfg_t_max ──▶ S_ENCODE      │
                    │                                           │
                    └── timestep >= cfg_t_max ──▶ S_DONE ──────┘
                                                  done ← 1
```

## State Descriptions

| State        | Actions                                                          | Next state                      |
|--------------|------------------------------------------------------------------|---------------------------------|
| `S_RESET`    | Clear timestep and done flag                                     | `S_IDLE`                        |
| `S_IDLE`     | Wait for `cfg_run` pulse; clear `done` on new run                | `S_ENCODE` when `cfg_run = 1`   |
| `S_ENCODE`   | Assert `enc_run` for one cycle                                   | `S_INTEGRATE`                   |
| `S_INTEGRATE`| Assert `neu_enable_all` for one cycle                            | `S_FIRE`                        |
| `S_FIRE`     | Neurons integrate (enable seen at posedge); spikes generated     | `S_LATCH`                       |
| `S_LATCH`    | Capture `spike_vector` into `spike_latch`; assert `capture_spikes` | `S_ROUTE`                    |
| `S_ROUTE`    | Enable router; skip if `spike_latch == 0`; wait for `route_done` | `S_LEARN`                      |
| `S_LEARN`    | Assert `stdp_run`; skip if `stdp_enable = 0`; wait for `stdp_done` | `S_ADVANCE`                  |
| `S_ADVANCE`  | Increment `timestep`; decide whether run is complete             | `S_ENCODE` or `S_DONE`          |
| `S_DONE`     | Assert `done`; return to `S_IDLE`                                | `S_IDLE`                        |

## Timing Details

All control signals are registered (non-blocking assignments). The pipeline is offset by one cycle to allow signals to propagate:

```
Cycle  State        Control signal asserted   Visible at
─────  ───────────  ────────────────────────  ──────────────────
  0    S_ENCODE     enc_run ← 1               S_INTEGRATE posedge
  1    S_INTEGRATE  neu_enable_all ← 1        S_FIRE posedge
  2    S_FIRE       (encoder saw run=1 here)   spike_vector valid after posedge
  3    S_LATCH      spike_latch ← spike_vector S_ROUTE posedge
  4    S_ROUTE      router_enable ← 1         router active
```

## Energy Optimisations

The scheduler implements two zero-cost power savings:

- **Sparse spike skip:** In `S_ROUTE`, if `spike_latch == 0` (no neurons fired), the router is never enabled and the FSM advances immediately to `S_LEARN`. This is the key source of neuromorphic energy efficiency — silent timesteps cost almost nothing.

- **STDP bypass:** In `S_LEARN`, if `stdp_enable = 0`, the weight update engine is never triggered and the FSM skips directly to `S_ADVANCE`. This halves the per-timestep cycle count during inference-only mode.

## Module Interface (`scheduler.sv`)

```systemverilog
module scheduler #(
    parameter N_NEURONS = 32
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               cfg_run,          // pulse: start new inference run
    input  logic [15:0]        cfg_t_max,         // number of timesteps per run
    input  logic               stdp_enable,       // 1 = enable STDP weight updates

    input  logic [N_NEURONS-1:0] spike_vector,    // live spikes from neuron array
    input  logic                 route_done,       // router finished this timestep
    input  logic                 stdp_done,        // STDP engine finished

    output logic               enc_run,            // pulse: trigger encoder
    output logic               neu_enable_all,     // 1 = enable all neurons
    output logic               router_enable,      // 1 = enable spike router
    output logic               stdp_run,           // pulse: trigger STDP update
    output logic               capture_spikes,     // pulse: spike_latch is valid

    output logic [N_NEURONS-1:0] spike_latch_out,  // stable latched spike vector
    output logic [15:0]        timestep,            // current global timestep
    output logic               done                 // asserted after last timestep
);
```

## Key Design Choices

| Choice | Rationale |
|--------|-----------|
| Registered (non-blocking) control signals | Avoids combinational glitches; pipeline offset is predictable |
| `done` stays asserted until next `cfg_run` | Host can poll `done` without missing it |
| `spike_latch` buffer | Decouples the router from the neuron array; neurons can begin next cycle while router works |
| Skip-on-silence | Core neuromorphic optimisation: sparse activity → low average power |
