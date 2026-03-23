# Scaling Guide — NeuraEdge

How to scale the neuron count, mesh size, target frequency, and migrate to ASIC.

---

## 1. Scaling the Neuron Count

Three parameters control neuron capacity: `NUM_NEURONS`, `NEURON_ADDR_W`, `NUM_SYNAPSES`.

The tile constraint must always be satisfied — it is enforced by `$fatal` at elaboration:

```
TILE_W * TILE_H * 2 <= 2^NEURON_ADDR_W

// Default (8×8 sensor, 2×2 mesh, TILE = 4×4):
4 * 4 * 2 = 32 <= 64 = 2^6  ✅
```

### Sensor / neuron scaling table

| DVS sensor | Mesh | `NEURON_ADDR_W` | Neurons/cluster | Total neurons | BRAM18 total |
|-----------|------|----------------|-----------------|---------------|--------------|
| 8×8 (demo) | 2×2 | 6 | 64 | 256 | 32 |
| 16×16 | 2×2 | 8 | 256 | 1,024 | 128 |
| 34×34 (DAVIS240C) | 4×4 | 10 | 1,024 | 16,384 | 512+ |

For a real 34×34 DVS sensor, update both RTL parameters and the Verilator overrides in `scripts/sim/run_sim.sh`:

```
NEURON_ADDR_W=10, SENSOR_W=34, SENSOR_H=34, NUM_NEURONS=1024
```

The shipped testbenches use the 8×8 demo config only and will need updated parameter overrides for larger configurations.

---

## 2. Scaling the Mesh

`NUM_COLS` and `NUM_ROWS` in `neuraedge_top.v` control mesh dimensions. The top-level generate loop instantiates `NUM_COLS * NUM_ROWS` router and neuron core pairs automatically.

### BRAM budget on Artix-7 100T (135 RAMB36 = 270 RAMB18 available)

| Mesh | Neurons/cluster | RAMB18 required | Artix-7 100T utilisation |
|------|----------------|-----------------|--------------------------|
| 2×2 | 64 | 32 | 12% |
| 4×4 | 64 | 128 | 47% |
| 4×4 | 256 | 512 | **exceeds device** |
| 2×2 | 256 | 128 | 47% |

A 4×4 mesh at 64 neurons/cluster (128 RAMB18) fits comfortably. Pushing to 256 neurons/cluster on a 4×4 mesh requires a larger device (e.g. Kintex-7 or UltraScale).

---

## 3. ASIC Migration (OpenLane / SKY130)

The RTL is written in Verilog-2001-compatible style. It passes Yosys synthesis without modification — no FPGA primitives appear in the design proper. The primary change required for ASIC is replacing BRAM18 inference in `synapse_memory.v` with SRAM macro instantiation.

### FPGA → ASIC element mapping

| Element | FPGA | ASIC replacement |
|---------|------|-----------------|
| `synapse_memory.v` | BRAM18 inference | SRAM macro (e.g. `sky130_sram_1kbyte_1rw`) |
| I/O standards | LVCMOS33 (XDC) | Padframe (`sky130_fd_io`) |
| Timing constraints | XDC (`constraints/neuraedge.xdc`) | SDC |
| Clock buffer | BUFG (inferred by Vivado) | Sky130 clock tree via OpenLane |

### Recommended migration steps

1. Replace `synapse_memory.v` BRAM inference block with an SRAM blackbox instantiation matching the Sky130 SRAM macro interface
2. Verify gate-level netlist: `yosys -p "read_verilog rtl/*.v; synth -flatten; write_verilog netlist.v"`
3. Translate `constraints/neuraedge.xdc` to SDC format
4. Run OpenLane with `neuraedge_top` as the top macro
5. Re-characterise timing closure — the STDP scan path critical path will differ in sky130 standard cells vs Artix-7 LUTs

---

## 4. Frequency Scaling

The current 100 MHz closure uses aggressive Vivado directives (see [`timing_strategy.md`](timing_strategy.md)). To push higher:

**Pipeline the STDP scan** — Insert a register stage between the weight read output and the weight update adder in `learning_engine.v`. This eliminates the critical path at the cost of one additional cycle of STDP update latency. Estimated improvement: ~130–150 MHz.

**Pipeline the LIF update** — `neuron_core.v` currently processes all 64 neurons in a single combinational pass (accumulate → compare → reset). Splitting this into two pipeline stages (accumulate | compare+reset) would allow ~150 MHz+ on Artix-7 with a single extra cycle of neuron update latency.

**Map weight arithmetic to DSP48E1** — The saturating add/subtract in `learning_engine.v` currently maps to LUT arithmetic. A DSP48E1 instantiation would reduce both the critical path and LUT count, at the cost of consuming DSP slices.
