# ILA Debug Guide — NeuraEdge v2.5.0

Real-time signal capture on the Nexys A7 using Vivado's Integrated Logic Analyser (ILA).

---

## What you get

Four ILA debug cores embedded in the ILA bitstream, each capturing a different layer of the system:

| Core | Name | Trigger signal | Captures |
|------|------|---------------|----------|
| 0 | Spike activity | `enc_pkt_valid` rising | All 4 cluster spike vectors, DVS packet stream, event counter |
| 1 | STDP monitor | `le_we` rising | Weight address, old→new weight, LTP/LTD direction |
| 2 | Classifier | `result_valid` rising | Spike accumulators, predicted class, UART transmit |
| 3 | DVS encoder | `dvs_valid` rising | Raw DVS input, encoded packet, SPI loader state |

---

## Step 1 — Build the ILA bitstream

```bash
make synth-ila
```

This takes ~40 min. The key difference from `make synth` is `-flatten_hierarchy none` in `synth_design`. Without it, Vivado merges hierarchy during optimisation and internal signal paths become unreachable by name. It costs ~10–15% more LUTs but keeps every signal accessible for probing.

When complete, check `vivado_proj_ila/utilisation_ila.rpt`. Expected overhead vs non-ILA build:

| Resource | Without ILA | With ILA | Delta |
|----------|-------------|----------|-------|
| BRAM18 | 32 | 40 | +8 (capture buffers, 4 cores × depth=1024) |
| LUTs | ~2,150 | ~4,150 | +2K (probe muxes) |
| FFs | ~1,480 | ~2,480 | +1K |

If total BRAM18 exceeds 200 (74% of 270), reduce `C_DATA_DEPTH` in `scripts/vivado/synth_ila.tcl` from 1024 to 512.

---

## Step 2 — Program the board

**Tcl console:**

```tcl
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
set_property PROGRAM.FILE {vivado_proj_ila/neuraedge_ila.runs/impl_1/neuraedge_top.bit} $dev
set_property PROBES.FILE  {vivado_proj_ila/neuraedge_ila.runs/impl_1/neuraedge_top.ltx}  $dev
program_hw_devices $dev
```

**Or via GUI:** Hardware Manager → Auto Connect → right-click device → Program Device → select both `.bit` and `.ltx` files.

The `.ltx` file is essential. It maps probe indices to signal names. Without it, Hardware Manager shows `probe0[63:0]` instead of `spike_c00[63:0]`.

---

## Step 3 — ILA trigger setups

### ILA 0 — Spike activity

Goal: measure real spike rate and verify end-to-end DVS → neuron firing.

```
Trigger port:     probe5[1]  (enc_pkt_valid)
Trigger value:    1
Compare type:     == (level, not edge — use R for rising edge if trigger fires every cycle)
Trigger position: 512  (capture 512 samples before + 512 after)
Capture mode:     ALWAYS
```

What to look for:
- `probe5[1]` (`enc_pkt_valid`) pulsing = DVS events entering the NoC
- `probe0` (`spike_c00`) bits toggling 2–3 cycles after `enc_pkt_valid` = correct end-to-end latency
- If `probe0` never changes: check `probe5[0]` (`enc_fifo_overflow`) — if high, the encoder FIFO is full; slow DVS injection rate
- Spike rate estimate: `count_enc_pkt_valid_pulses / (1024 × 10 ns)`

### ILA 1 — STDP monitor

Goal: verify weight convergence direction after repeated stimulation.

```
Trigger port:     probe3  (le_we — weight write strobe)
Trigger value:    1
Trigger position: 0  (capture 1024 samples after each write)
```

What to look for:
- `probe2` (`le_wr_data`) trending upward = LTP (causal pairs — correct)
- `probe2` trending downward = LTD (anti-causal — also correct in unsupervised STDP)
- `probe0` and `probe1` cycling through 0→63 neuron addresses over 512 cycles = scan FSM working
- If `probe3` never asserts: neurons are not firing — check weight loading via ILA 3

### ILA 2 — Classifier output

Goal: verify N-MNIST classification matches the Python model.

```
Trigger port:     probe3[5]  (result_valid)
Trigger value:    1
Trigger position: 900  (capture 100 samples before result + 924 after)
```

What to look for:
- `probe2` (`infer_timer`) near `WINDOW_US = 1000` when `result_valid` pulses
- `probe3[4:1]` (`best_class`) = predicted digit 0–9
- `probe3[0]` (`uart_busy_mon`) asserts within 1 cycle of `result_valid`

### ILA 3 — DVS encoder / SPI loader

Goal: verify pixel events encode to the correct `neuron_id`.

```
Condition 1: probe3[1]  (dvs_valid)    == 1
Condition 2: probe3[5:0](spi_bit_cnt) == 39   (SPI frame complete)
Trigger operator: OR
```

Packet decode check — `enc_pkt_data[13:0]` should satisfy:

```
enc_pkt_data[13:12] = dst_col   = dvs_x / TILE_W
enc_pkt_data[11:10] = dst_row   = dvs_y / TILE_H
enc_pkt_data[5:0]   = neuron_id = (local_y * TILE_W + local_x) * 2 + polarity
```

---

## Step 4 — Automated capture

Run from the Vivado Tcl console to arm all four ILAs, wait for triggers, and export CSVs:

```tcl
source scripts/vivado/ila_capture_to_csv.tcl
```

Output files:
- `benchmarks/ila_spike_capture.csv`
- `benchmarks/ila_stdp_capture.csv`
- `benchmarks/ila_classifier_capture.csv`

---

## Step 5 — Feed into benchmark.py

The ILA CSVs export one row per clock cycle with columns named after probe signals. `benchmark.py` accepts the spike capture directly:

```bash
python software/benchmark.py \
  --sim-log benchmarks/ila_spike_capture.csv \
  --weights weights/best.pt
```

The `parse_spike_log()` function looks for `enc_pkt_valid` rising edges — the same interface as the Verilator simulation log. The reported spike rate is now a real hardware measurement at 100 MHz.

---

## Spike rate calculation

From the waveform: count `enc_pkt_valid` rising edges in the 1024-sample capture window.

```
spike_rate = edge_count / (1024 × 10 ns)
           = edge_count × 97,656 events/sec
```

For 10 pulses in 1024 samples: `10 × 97,656 ≈ 0.98 M events/sec`.

Target from the engineering spec: **> 1 M spikes/sec**. If below target, the bottleneck is usually encoder FIFO depth (increase to 8) or `WINDOW_US` being too short.

---

## Common problems

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| No ILA cores detected after programming | `.ltx` file not loaded | Re-run `make synth-ila` — it writes both `.bit` and `.ltx` |
| Probe names show as `probe0`, `probe1` | `.ltx` not associated | Hardware Manager → right-click device → Refresh Device → select `.ltx` |
| ILA triggers on every cycle | Trigger condition permanently true | Use rising-edge compare type `R` instead of level `== 1` |
| `enc_pkt_valid` never triggers | Router credits stuck at 0 | Check `enc_fifo_overflow`; reduce DVS rate or increase `FIFO_DEPTH` |
| WNS negative in ILA build but positive without | ILA probe mux congestion | Reduce `C_DATA_DEPTH` from 1024 to 256 in `synth_ila.tcl` |
