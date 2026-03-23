# Timing Strategy — NeuraEdge v2.5.0

How timing closure was achieved at 100 MHz on Artix-7, and why each constraint is correct.

---

## 1. Clock Domain

NeuraEdge uses a **single synchronous clock domain** (`sys_clk`, 100 MHz, 10 ns period). There are no intentional CDC boundaries in the main processing path.

The SPI interface uses a 2-FF synchroniser on `spi_sclk` before edge detection. This is a metastability-tolerance measure, not a formal CDC domain crossing — `spi_sclk` is edge-detected inside `sys_clk` domain logic.

---

## 2. Critical Paths

Three paths drove the timing closure effort in v2.x:

| Path | Endpoint | Post-route slack | Notes |
|------|----------|-----------------|-------|
| STDP weight writeback | `learning_engine` weight update FF | WNS +0.112 ns | Long scan chain under heavy activity |
| Credit counter update | `spike_router` `rd_ptr_reg` | See `reports/timing_rd_ptr_D_*.rpt` | Targeted analysis available |
| `rst_n` hold | All FF reset pins | WHS +0.050 ns | Requires min/max input_delay |

---

## 3. Constraint Rationale

### 3.1 False paths on LED and UART outputs

`led[15:0]` and `uart_tx` are asynchronous debug outputs with no external clock relationship. Without false paths, Vivado analyses them through the OBUF and reports 1,852 failing endpoints (WNS –3.071 ns from this alone).

The correct fix is:

```tcl
set_false_path -to [get_ports {led[*]}]
set_false_path -to [get_ports uart_tx]
```

This is architecturally correct. Neither output has a setup/hold relationship to any external synchronous system — LEDs are human-readable status indicators, UART is an internally-clocked serial protocol.

### 3.2 `rst_n` input delay

`rst_n` is used as an asynchronous reset. The XDC applies both min and max input delay to give Vivado full hold/setup information on the reset network. `set_false_path -from` removes it from the data-path timing graph — reset pins are not data endpoints:

```tcl
set_false_path -from [get_ports rst_n]
set_input_delay -clock sys_clk -min 1.0 [get_ports rst_n]
set_input_delay -clock sys_clk -max 4.0 [get_ports rst_n]
```

In v2.3.0 only a single `set_input_delay` value was applied, which left Vivado with incomplete hold information. WHS was marginal at +0.105 ns. The min/max pair in v2.5.0 brings WHS to +0.050 ns with margin.

### 3.3 `dvs_ready` unpinned output

`dvs_ready` is an internal backpressure signal with no physical board pin on the Nexys A7. It is assigned `LVCMOS33` to suppress `NSTD-1` DRC errors, and `set_false_path -to` excludes it from timing analysis:

```tcl
set_property IOSTANDARD LVCMOS33 [get_ports dvs_ready]
set_false_path -to [get_ports dvs_ready]
set_property SEVERITY Warning [get_drc_checks UCIO-1]
```

`UCIO-1` severity is downgraded to Warning at project level so bitstream generation is not blocked by the intentionally unpinned port.

### 3.4 Implementation strategy

`scripts/vivado/synth.tcl` applies aggressive post-route optimisation directives to close the STDP scan path:

```tcl
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE      ExtraPostPlacementOpt [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE   AggressiveExplore     [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE       AggressiveExplore     [get_runs impl_1]
```

These directives add significant runtime (~40 min total) but were necessary to achieve WNS > 0 on the STDP scan chain.

---

## 4. Automated Post-Implementation Checks

`scripts/vivado/synth.tcl` runs three checks after routing and fails the build on violations:

| Check | Pass condition | Failure action |
|-------|---------------|----------------|
| BRAM count | BRAM18-equivalent ≥ 30 | `error` — build stops |
| DRC violations | Count == 0 | `error` — build stops |
| WNS guardband | WNS ≥ 0.3 ns | `puts WARNING` — build continues, but do not program |

The BRAM check guards against BRAM inference regressions. The v2.4.0 regression (0 BRAM inferred due to a reset on the output register) would have been caught by this check.

---

## 5. Known Risks

**STDP scan path** — Under maximum spike activity (all 64 neurons firing simultaneously), the learning engine scan creates the longest combinational chains. If pushing the clock beyond 100 MHz, pipeline a register stage between the weight read and weight update arithmetic in `learning_engine.v`. This adds one cycle of STDP latency per weight update but eliminates the critical path.

**SPI metastability** — The 2-FF synchroniser on `spi_sclk` is appropriate for board-level use at low SPI rates. It has not been characterised for MTBF at production volumes or high SPI clock frequencies.

**Routing congestion** — The 2×2 mesh with 4 active router instances can create localised congestion in the centre of the Artix-7 fabric. Check the Vivado implementation log for `CRITICAL WARNING [Route 35-*]` congestion messages before increasing resource utilisation.
