# Expected Outputs — NeuraEdge v2.5.0

Reference outputs for simulation, synthesis, and hardware bring-up. Use these to verify your build is correct.

---

## 1. Simulation — Verilator regression (`make sim`)

```
============================================================
 NeuraEdge Simulation Gate  v2.0
============================================================

---- 1/6  neuron_core -----------------------------------------
[PASS] TEST  1: Post-reset membrane = 0
[PASS] TEST  2: Input integration: membrane increases
[PASS] TEST  3: Leak: membrane decreases each cycle without input
[PASS] TEST  4: Spike fires when membrane >= THRESHOLD
[PASS] TEST  5: Post-spike reset: membrane returns to 0
[PASS] TEST  6: Saturating add: no membrane wrap-around
[PASS] TEST  7: neuron_enable=0 freezes membrane
[PASS] TEST  8: neuron_enable toggle: membrane resumes on re-enable
[PASS] TEST  9: fire_count increments on each spike
[PASS] TEST 10: fire_count counts simultaneous multi-neuron fires
[PASS] TEST 11: fire_count saturates at 0xFFFFFFFF (no wrap)
[PASS] TEST 12: mem_debug reflects correct neuron membrane
Results: 12/12 passed

---- 2/6  synapse_memory --------------------------------------
[PASS] TEST  1: Post-reset read = 0 (all banks)
[PASS] TEST  2-5: Write/read back correct value (bank 0–3)
[PASS] TEST  6: RAW bypass: same-cycle write/read returns new data
[PASS] TEST  7: Weight clamping at MAX_WEIGHT (255)
[PASS] TEST  8: Weight clamping at MIN_WEIGHT (0)
[PASS] TEST  9: Parallel read: 4 banks return 4 weights in 1 cycle
Results: 9/9 passed

---- 3/6  spike_router ----------------------------------------
[PASS] TEST  1: Packet delivered to local port (same cluster)
[PASS] TEST  2: X-routing: forwarded East correctly
[PASS] TEST  3: X-routing: forwarded West correctly
[PASS] TEST  4: Y-routing: forwarded North correctly
[PASS] TEST  5: Y-routing: forwarded South correctly
[PASS] TEST  6: Credit flow: sender stalls when credits = 0
[PASS] TEST  7: Credit restores after receiver accepts packet
[PASS] TEST  8: FIFO overflow flag asserts when full
[PASS] TEST  9: Multi-hop: (0,0)→(1,1) via X-then-Y correct
[PASS] TEST 10: Simultaneous credit inc+dec handled correctly
[PASS] TEST 11: Border ports: credit always 1, no stall on mesh edge
Results: 11/11 passed

---- 4/6  event_encoder ---------------------------------------
[PASS] TEST  1: DVS event accepted and encoded
[PASS] TEST  2: Packet: dst_col, dst_row, neuron_id all correct
[PASS] TEST  3: ON polarity → even neuron_id
[PASS] TEST  4: OFF polarity → odd neuron_id (opponent encoding)
[PASS] TEST  5-6: FIFO depth and overflow flag
[PASS] TEST  7: dvs_ready deasserts when FIFO full
[PASS] TEST  8: window_advance flushes incomplete window
[PASS] TEST  9: WINDOW_MODE=1 gates events to discrete timestep
[PASS] TEST 10-11: events_accepted and events_dropped counters
[PASS] TEST 12: Back-to-back burst: 4 events, all accepted
[PASS] TEST 13-14: Tile boundary edge cases
Results: 14/14 passed

---- 5/6  learning_engine -------------------------------------
[PASS] TEST  1: Post-reset traces = 0, weights = 0
[PASS] TEST  2: LTP: pre before post → weight increases
[PASS] TEST  3: LTD: post before pre → weight decreases
[PASS] TEST  4: pre_trace decays each cycle
[PASS] TEST  5: post_trace decays each cycle
[PASS] TEST  6: Weight clamped at MAX_WEIGHT (no overflow)
[PASS] TEST  7: Weight clamped at MIN_WEIGHT (no underflow)
[PASS] TEST  8: Scan FSM: all NUM_SYNAPSES scanned per event
[PASS] TEST  9: BUG-9 regression: last synapse (NUM_SYNAPSES-1) updated
[PASS] TEST 10: Spike queue: simultaneous events queued correctly
[PASS] TEST 11: BUG-10 regression: queue count correct for any depth
[PASS] TEST 12-13: ltp_count and ltd_count increment correctly
[PASS] TEST 14: scan_active high during scan, low at idle
[PASS] TEST 15: BUG-5.4 regression: q_count net-delta no NBA race
Results: 15/15 passed

---- 6/6  neuraedge_top (integration) -------------------------
[PASS] TEST  1: Reset: all outputs deasserted
[PASS] TEST  2: DVS event injected, encoder accepts, router forwards
[PASS] TEST  3: Neuron receives spike input from router
[PASS] TEST  4: UART transmits class byte after WINDOW_US cycles
[PASS] TEST  5: LED output reflects cluster[0][0] spike_out[3:0]
[PASS] TEST  6: SPI weight load: neuron 0, syn 0, cluster 0
[PASS] TEST  7: SPI weight load: cluster select uses bitwise & mask
[PASS] TEST  8: LTP path: pre_spike asserted on router packet arrival
[PASS] TEST  9: pre_spike one-hot: correct neuron_id bit set
[PASS] TEST 10: STDP active: ltp_count advances after spike sequence
Results: 10/10 passed

============================================================
 ALL TESTS PASSED

 Next:  vivado -mode batch -source scripts/vivado/synth.tcl
============================================================
```

**Total: 71/71 passing.** If any module fails, check `sim/<module>.log` for the failing assertion.

---

## 2. Vivado Synthesis — Utilisation (`make synth`)

Expected from `vivado_proj/neuraedge.runs/impl_1/utilisation.rpt`:

```
+-------------------------+--------+-------+-----------+-------+
| Site Type               | Used   | Fixed | Available | Util% |
+-------------------------+--------+-------+-----------+-------+
| Slice LUTs              | ~2,150 |     0 |     63400 |  3.4% |
| Slice Registers (FFs)   | ~1,480 |     0 |    126800 |  1.2% |
+-------------------------+--------+-------+-----------+-------+

+----------------+------+-------+-----------+-------+
| Memory         | Used | Fixed | Available | Util% |
+----------------+------+-------+-----------+-------+
| RAMB36/FIFO    |    0 |     0 |       135 |  0.0% |
| RAMB18         |   32 |     0 |       270 | 11.9% |  ← 8 per cluster × 4
+----------------+------+-------+-----------+-------+

+-----------+------+-----------+-------+
| DSPs      | Used | Available | Util% |
+-----------+------+-----------+-------+
| DSP48E1   |    0 |       240 |  0.0% |
+-----------+------+-----------+-------+
```

**BRAM18 = 32 is the critical number.** If you see 0 BRAM or 8 BRAM, BRAM inference regressed — the build will automatically fail with `BRAM INFERENCE FAILED`. See the root cause section below.

---

## 3. Vivado Timing Summary

Expected from `vivado_proj/neuraedge.runs/impl_1/timing.rpt`:

```
--------------------------------
Design Timing Summary
--------------------------------
WNS (ns)  TNS (ns)  WHS (ns)  THS (ns)
--------  --------  --------  --------
+0.112    0.000     +0.050    0.000

All user specified timing constraints are met.
```

WNS ≥ 0 is required before programming the board. WNS < 0.3 ns triggers a warning from `synth.tcl` — the build succeeds but programming is discouraged without review.

---

## 4. Estimated Power

From `vivado_proj/neuraedge.runs/impl_1/power.rpt` (typical process, 25°C):

```
Dynamic power  : ~30–50 mW   (BRAMs switching + neuron compute)
Static power   : ~91 mW      (device quiescent, Artix-7 100T)
Total          : ~121–141 mW
```

Dynamic power scales with activity. At maximum spike rate (all neurons firing every cycle) it will be higher; at typical 5–10% firing rate it will be lower.

---

## 5. UART Output (Hardware)

After `WINDOW_US` clock cycles, the classifier transmits a 1-byte result over UART (115,200 8N1, pin D4):

```python
import serial
port = serial.Serial('/dev/ttyUSB0', 115200)
while True:
    b = port.read(1)
    print(f"Class prediction: {b[0]}")
```

With untrained (random) weights: random class output — expected. With N-MNIST trained weights loaded via SPI: target accuracy >85% on N-MNIST test set.

---

## 6. Root Cause Reference: BRAM Inference Regression (v2.4.0)

In v2.4.0, `synapse_memory.v` had reset logic on the BRAM output register:

```verilog
// BROKEN — reset on BRAM output register forces distributed RAM
always_ff @(posedge clk) begin
    if (!rst_n)
        rd_data <= 0;        // ← prevents BRAM18 inference
    else
        rd_data <= mem[rd_addr];
end
```

Vivado cannot map a register with synchronous reset to a BRAM18 output register — it falls back to distributed (LUT) RAM. Result: 0 BRAM18 inferred, 30,000+ LUTs used, design does not fit.

**v2.5.0 fix** — remove the reset on the output register:

```verilog
// CORRECT — BRAM18 output register has no reset
always_ff @(posedge clk) begin
    rd_data <= mem[rd_addr];   // BRAM initialises to 0 at power-on via bitstream
end
```

BRAM zero-initialisation at power-on is guaranteed by the Xilinx bitstream format — the explicit reset is unnecessary and harmful.
