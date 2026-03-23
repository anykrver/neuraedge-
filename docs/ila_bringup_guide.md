# ILA Board Bring-up Guide — NeuraEdge v2.5.0

Step-by-step oscilloscope and Hardware Manager procedure for the Nexys A7-100T. Follow this after programming `neuraedge_top_ila.bit` for the first time.

---

## Prerequisites

- Nexys A7-100T powered via USB or external supply
- Vivado 2024.x open on host PC
- `neuraedge_top_ila.bit` and `neuraedge_top_ila.ltx` built (run `make synth-ila`)
- USB JTAG cable connected
- (Optional) USB-UART cable on D4 for classification output

---

## Step 1 — Program the board

In the Vivado Tcl console:

```tcl
open_hw_manager
connect_hw_server
open_hw_target

# Associate probes file BEFORE programming
set_property PROBES.FILE \
  {vivado_proj_ila/neuraedge_ila.runs/impl_1/neuraedge_top_ila.ltx} \
  [get_hw_devices xc7a100t_0]

set_property PROGRAM.FILE \
  {vivado_proj_ila/neuraedge_ila.runs/impl_1/neuraedge_top_ila.bit} \
  [get_hw_devices xc7a100t_0]

program_hw_devices [get_hw_devices xc7a100t_0]
refresh_hw_device  [get_hw_devices xc7a100t_0]
```

Two ILA dashboards appear: `hw_ila_1` (datapath) and `hw_ila_2` (STDP).

---

## Step 2 — Confirm the encoder is receiving events

Goal: prove DVS events are reaching the chip before testing anything else.

**Trigger setup in `hw_ila_1`:**
1. Trigger on `probe4[0]` (`enc_pkt_valid`) == `1`
2. Trigger position: 10% (capture what happens just after first event)
3. Click **Run trigger**

**Send a test event** via Python:

```python
# inject_test_event.py
import serial, struct

port = serial.Serial('/dev/ttyUSB0', 115200, timeout=1)
# DVS event: x=5, y=3, polarity=1, timestamp=0
x, y, pol, ts = 5, 3, 1, 0
pkt = struct.pack('>I', (x << 23) | (y << 17) | (pol << 16) | ts)
port.write(pkt)
```

**Expected waveform:**

```
probe4[0]  (enc_pkt_valid):    _____|‾|___
probe4[14:1](enc_pkt_data):    ----<PKT>--
probe5[16:1](enc_events_acc):  0 → 1
probe5[0]  (enc_fifo_ov):      stays 0
```

If `enc_pkt_valid` never asserts: the DVS bridge is not generating events. Check that the Python injection script is running and the UART port is correct.

If `enc_fifo_ov` pulses: events are arriving faster than the router can drain them. Reduce DVS event rate or increase `FIFO_DEPTH` in `event_encoder.v`.

---

## Step 3 — Confirm spike propagation

Goal: prove events reach `neuron_core` and trigger spikes.

**Trigger setup:**
1. Trigger on `probe0` (`spike_out[0][0]`) != `64'h0000000000000000`
2. Trigger position: 50%
3. Click **Run trigger**

**Send a burst of events to drive neuron 0 above threshold:**

```python
# burst_test.py — pixel (0,0) ON → tile (0,0) → neuron_id=1 → cluster[0][0]
for i in range(50):
    send_dvs_event(x=0, y=0, pol=1, ts=i * 100)
```

**Expected waveform:**

```
probe0 (spike_out[0][0]):
  cycles 0–N:  0x0000000000000000   (integrating)
  cycle  N+1:  0x0000000000000002   (neuron 1 fired, bit 1 set)
  cycle  N+2:  0x0000000000000000   (reset — 1-cycle pulse)
```

The spike must be exactly 1 clock cycle wide. If it is wider, the reset path in `neuron_core.v` is not asserting correctly.

---

## Step 4 — Verify NoC routing (multi-cluster)

Goal: prove a packet for tile (1,0) routes East and fires a neuron in cluster[1][0], not cluster[0][0].

**Trigger setup:**
1. Trigger on `probe1` (`spike_out[1][0]`) != `0`
2. Send pixel event: `x=17, y=0, pol=1` — TILE_W=4 maps `x≥4` into tile column 1 of a 4×4 tile grid... adjust `x` to land in the correct tile for your `SENSOR_W` / mesh config

**Expected waveform:**

```
probe0 (spike_out[0][0]):  stays 0x0   ← no spurious fire
probe1 (spike_out[1][0]):  pulses      ← correct cluster fired
```

If `probe0` fires instead: DOR routing is broken. The packet src/dst comparison in `spike_router.v` is failing — return to simulation with `make sim MOD=spike_router` and add `$display` to `route_packet` before returning to hardware.

---

## Step 5 — Verify UART classification output

Goal: confirm a classification byte transmits after each inference window.

**Trigger setup:**
1. Trigger on `probe6[0]` (`uart_tx`) **falling edge** (start bit)
2. Trigger position: 5% (capture almost the entire UART frame)
3. Click **Run trigger**
4. Assert `window_advance = 1` (BTNU button) to close the inference window

**Expected waveform:**

```
probe6 (uart_tx):
  ‾‾‾‾‾‾‾|_____|‾|___|‾‾|_____|‾‾‾
          S  D0  D1 D2  D3    Stop
```

S = start bit (low), D0–D7 = 8-bit class ID, Stop = high.

At 100 MHz with `UART_CLK_DIV=868`, each bit is 8.68 µs. A full 10-bit frame is 86.8 µs. The default ILA capture window (1024 samples × 10 ns = 10.24 µs) shows approximately the start bit and first 1–2 data bits. Increase `C_DATA_DEPTH` to 16384 to capture the full frame.

**Cross-check on the host:**

```python
import serial
port = serial.Serial('/dev/ttyUSB0', 115200)
while True:
    b = port.read(1)
    print(f"Class prediction: {b[0]}")
```

---

## Step 6 — Verify STDP weight updates (`hw_ila_2`)

Goal: confirm the learning engine is writing weights during live inference.

**Trigger setup in `hw_ila_2`:**
1. Trigger on `probe0` (`le_we`) == `1`
2. Click **Run trigger**
3. Send a DVS event burst that causes a spike

**Expected waveform:**

```
probe0 (le_we):         ___|‾|____|‾|____|‾|___   ← weight writes
probe1 (le_wr_neuron):  ---<N>----<N>----<N>---   ← neuron being updated
probe2 (le_wr_syn):     000  001  002  003  004    ← synapse scan 0→511
probe3 (le_wr_data):    ---<W0>--<W1>--<W2>---    ← updated weight values
```

`le_wr_syn` must advance by 1 each clock cycle for 512 cycles (one full scan per neuron). If it jumps non-sequentially, the scan FSM in `learning_engine.v` has a bug — return to simulation with `make sim MOD=learning_engine`.

---

## Common bring-up failures

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `enc_pkt_valid` never fires | UART-DVS bridge not running | Check Python injection script |
| `spike_out` never fires | Weights all zero (not loaded) | Run SPI weight loading via `software/train_nmnist.py` |
| `spike_out` fires every cycle | Threshold too low | Increase `THRESHOLD` parameter in `synth_ila.tcl` generics |
| All neurons fire simultaneously | Membrane not resetting | Check `neuron_core.v` reset path |
| `enc_fifo_ov` pulses | Event rate too high | Reduce DVS rate or increase `FIFO_DEPTH` |
| UART tx never falls | Classifier not triggering | Check `infer_timer` in `neuraedge_top.v` |
| Wrong cluster fires | DOR routing incorrect | Verify `CUR_COL`/`CUR_ROW` parameters match instance position |
| `le_we` never fires | No post-spike in cluster | Check weight loading and threshold |
