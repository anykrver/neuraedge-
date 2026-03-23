# Simulation vs Hardware Disclaimer

What the Verilator / Icarus testbenches validate, what they cannot, and how to validate the rest on hardware.

---

## What simulation validates

| Feature | Simulator | Status |
|---------|-----------|--------|
| LIF neuron dynamics (leak, integrate, fire, reset) | Verilator + Icarus | ✅ Verified |
| Saturating addition (no membrane wrap-around) | Verilator + Icarus | ✅ Verified |
| 4-bank BRAM flat addressing and RAW bypass | Verilator | ✅ Verified |
| X-then-Y DOR routing (deadlock-freedom by construction) | Verilator + Icarus | ✅ Verified |
| Credit-based flow control (net-delta formula) | Verilator | ✅ Verified |
| Round-robin arbitration (`rr_select` function) | Verilator | ✅ Verified |
| DVS → spike packet encoding (`neuron_id` formula) | Verilator + Icarus | ✅ Verified |
| Tile constraint assertion (`TILE_W*TILE_H*2 <= 2^NEURON_ADDR_W`) | Verilator | ✅ Verified |
| STDP trace accumulation and decay | Verilator + Icarus | ✅ Verified |
| STDP scan FSM (all 512 synapses, no off-by-one) | Verilator | ✅ Verified |
| `q_count` net-delta (no NBA race on simultaneous enqueue/dequeue) | Icarus | ✅ Verified |
| `fire_count` popcount (no NBA race on simultaneous fires) | Icarus | ✅ Verified |
| SPI 40-bit weight loading protocol | Verilator | ✅ Verified |
| UART 8N1 transmitter (115,200 baud, `CLK_DIV=868`) | Verilator | ✅ Verified |
| BRAM array zero-initialisation (Icarus portable) | Icarus | ✅ Verified |

**Why run both simulators?** Verilator is faster and stricter about synthesisability. Icarus propagates X-values correctly — it will catch reset bugs and NBA race conditions that Verilator masks with `--x-initial 0`.

---

## What simulation does NOT validate

| Feature | Why simulation cannot cover it | How to validate |
|---------|--------------------------------|-----------------|
| Timing closure (WNS ≥ 0 at 100 MHz) | Requires place-and-route | Check `timing.rpt` after `make synth` |
| BRAM primitive inference | Requires post-synthesis netlist | Check `utilisation.rpt`: BRAM18 should be 32 |
| SPI electrical compliance (CPOL/CPHA, hold times) | Board-level measurement | Oscilloscope on PMOD JA pins during weight loading |
| UART signal integrity at 115,200 baud | Electrical, not behavioural | USB-UART analyser or oscilloscope on D4 |
| SPI `sclk` metastability | Physical phenomenon | 2-FF synchroniser present in RTL; verify MTBF for your SPI rate |
| Power and thermal limits | Requires hardware | Vivado `power.rpt` + on-board measurement |
| Routing congestion | Place-and-route specific | Check Vivado implementation log for `[Route 35-*]` warnings |
| BRAM initialisation at FPGA power-on | Bitstream attribute | BRAM default-to-zero guaranteed by Xilinx bitstream format |

---

## Simulation-only parameters (demo configuration)

The shipped testbenches use the 8×8 demo configuration to satisfy the tile constraint:

```
TILE_W * TILE_H * 2 = 4 * 4 * 2 = 32 <= 64 = 2^NEURON_ADDR_W  ✅
```

For a real 34×34 DVS sensor, set `NEURON_ADDR_W=10`, `SENSOR_W=34`, `SENSOR_H=34` in both the RTL parameters and the Verilator overrides in `scripts/sim/run_sim.sh`. This configuration is not covered by the shipped testbenches.

---

## Running both simulators

```bash
# Verilator — primary regression (all 6 modules)
make sim

# Icarus Verilog — X-propagation and NBA race checks
make sim-iv
```

Both must pass before running `make synth`. The CI check in `scripts/sim/run_sim.sh` exits with code 1 if any test reports `[FAIL]`, blocking progression to the synthesis step.
