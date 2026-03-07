#!/usr/bin/env python3
"""
xor_network.py — XOR network for NeuraEdge neuromorphic chip
Simulates a 6-neuron LIF network implementing the XOR function.

Redesigned topology (matches hardware testbench):
  N0, N1 = inputs
  N3     = OR  hidden  (fires when EITHER input fires)
  N4     = inhibitory  (fires only when BOTH inputs fire simultaneously)
  N5     = XOR output
  N2     = unused placeholder

  N0→N3: +1.0   N1→N3: +1.0   (N3 fires when any input fires)
  N0→N4: +0.5   N1→N4: +0.5   (N4 fires only when BOTH inputs fire: 0.5+0.5=1.0)
  N3→N5: +1.2   N4→N5: -2.0   (net = +1.2-2.0 = -0.8 → N5 silent when both fire)

XOR result: N5 spike count > 5 over T_MAX timesteps.

Usage:
  python3 xor_network.py             # print weight table and ISA commands
  python3 xor_network.py --simulate  # run software LIF simulation for all 4 XOR cases
  python3 xor_network.py --hex       # output weight matrix as hex for $readmemh
"""

import argparse
import numpy as np
import sys

# --------------------------------------------------------------------------
# Network topology (redesigned — N4 driven directly from inputs)
# --------------------------------------------------------------------------
N_NEURONS = 6

# (src, dst, weight_float, weight_q26_hex)
WEIGHTS = [
    (0, 3, +1.000, 0x40),   # N0 → N3 (OR hidden, +1.0)
    (1, 3, +1.000, 0x40),   # N1 → N3 (OR hidden, +1.0)
    (0, 4, +0.500, 0x20),   # N0 → N4 (inhibitory accumulation, +0.5)
    (1, 4, +0.500, 0x20),   # N1 → N4 (fires only when both: 0.5+0.5=1.0)
    (3, 5, +1.200, 0x4D),   # N3 → N5 (XOR output drive, +1.2)
    (4, 5, -2.000, 0x80),   # N4 → N5 (strong inhibition, -2.0; 0x80 signed=-128)
]

# Q2.6 parameters (matching hardware)
LEAK_FACTOR   = 0xE6 / 256.0  # = 230/256 ≈ 0.898 — hardware: v_leaked = v * 0xE6 >> 8
THRESHOLD     = 0x40 / 64.0   # = 1.0
V_RESET       = 0.0
REFRAC_PERIOD = 4
T_MAX         = 150


def q26_to_float(hex_val: int) -> float:
    """Convert signed Q2.6 hex byte to float."""
    if hex_val >= 0x80:
        return (hex_val - 256) / 64.0
    return hex_val / 64.0


def float_to_q26(val: float) -> int:
    """Convert float to signed Q2.6 8-bit (clamped)."""
    raw = int(round(val * 64))
    raw = max(-128, min(127, raw))
    return raw & 0xFF


def build_weight_matrix():
    W = np.zeros((N_NEURONS, N_NEURONS), dtype=np.float32)
    for src, dst, wf, _ in WEIGHTS:
        W[src, dst] = wf
    return W


def lif_simulate(x1: float, x2: float, T: int = T_MAX, verbose: bool = False):
    """
    Software LIF simulation for T timesteps.
    x1, x2: input spike probability in [0.0, 1.0].
    Returns: spike count per neuron.

    Key timing note: spikes from timestep t are routed and arrive as
    synaptic currents at timestep t+1 (matches hardware pipeline).
    When both N0 and N1 fire at timestep t, BOTH N3 and N4 fire at t+1,
    and their effects on N5 are accumulated together → net -0.8 → N5 silent.
    """
    W = build_weight_matrix()

    v = np.zeros(N_NEURONS, dtype=np.float64)
    spike_count = np.zeros(N_NEURONS, dtype=int)
    refrac = np.zeros(N_NEURONS, dtype=int)
    last_spikes = np.zeros(N_NEURONS, dtype=bool)

    rng = np.random.default_rng(seed=42)

    for t in range(T):
        # --- Build synaptic currents (from previous timestep's spikes) ---
        i_syn = np.zeros(N_NEURONS, dtype=np.float64)

        # Input spikes: directly inject into input neurons
        if rng.random() < x1:
            i_syn[0] += THRESHOLD      # direct threshold injection
        if rng.random() < x2:
            i_syn[1] += THRESHOLD

        # Route previous spikes through weight matrix
        for n_src in range(N_NEURONS):
            if last_spikes[n_src]:
                for n_dst in range(N_NEURONS):
                    i_syn[n_dst] += W[n_src, n_dst]

        # --- Update each neuron ---
        current_spikes = np.zeros(N_NEURONS, dtype=bool)
        for n in range(N_NEURONS):
            if refrac[n] > 0:
                # Refractory: apply leak only, no integration
                v[n] = v[n] * LEAK_FACTOR
                refrac[n] -= 1
            else:
                # Leak + integrate
                v[n] = v[n] * LEAK_FACTOR + i_syn[n]
                # Clamp at 0 (no sub-threshold underflow)
                if v[n] < 0.0:
                    v[n] = 0.0
                # Fire check
                if v[n] >= THRESHOLD:
                    current_spikes[n] = True
                    spike_count[n] += 1
                    v[n] = V_RESET
                    refrac[n] = REFRAC_PERIOD

        if verbose and any(current_spikes):
            fired = [i for i in range(N_NEURONS) if current_spikes[i]]
            print(f"  t={t:3d}: spikes={fired}  v={v}")

        last_spikes = current_spikes

    return spike_count


def print_weight_table():
    print("=" * 62)
    print("  NeuraEdge XOR Network Weight Table")
    print("  (Redesigned: N4 driven directly from inputs)")
    print("=" * 62)
    print(f"  {'Connection':<12} {'Float':>8}  {'Q2.6 Hex':>10}  {'Signed Dec':>12}")
    print("-" * 62)
    for src, dst, wf, wh in WEIGHTS:
        signed_dec = wh if wh < 0x80 else wh - 256
        print(f"  N{src}→N{dst}        {wf:>+8.3f}     0x{wh:02X}        {signed_dec:>+6d}")
    print("=" * 62)
    print()
    print("ISA Configuration Commands (cfg_weight_wr sequence):")
    print("-" * 62)
    for src, dst, wf, wh in WEIGHTS:
        addr = (src << 5) | dst
        print(f"  WEIGHT_WR addr=0x{addr:03X} ({src:2d},{dst:2d})"
              f" data=0x{wh:02X}  # N{src}→N{dst}: {wf:+.3f}")


def print_hex_file():
    """Output full 32×32 weight matrix in hex format for $readmemh."""
    W_full = [[0] * 32 for _ in range(32)]
    for src, dst, wf, wh in WEIGHTS:
        W_full[src][dst] = wh

    print("// Weight matrix for $readmemh (32x32, row-major, signed Q2.6)")
    print("// Each row = outgoing weights for one source neuron")
    for src in range(32):
        for dst in range(32):
            print(f"{W_full[src][dst]:02x}")


def run_simulation():
    print("=" * 60)
    print("  NeuraEdge XOR Network — LIF Simulation")
    print(f"  Parameters: LEAK_FACTOR={LEAK_FACTOR:.5f}, THRESH={THRESHOLD:.3f}, T={T_MAX}")
    print("=" * 60)
    all_pass = True
    cases = [(0.0, 0.0, 0), (1.0, 0.0, 1), (0.0, 1.0, 1), (1.0, 1.0, 0)]
    for x1, x2, expected in cases:
        counts = lif_simulate(x1, x2, T=T_MAX)
        result = 1 if counts[5] > 5 else 0
        status = "PASS" if result == expected else "FAIL"
        print(f"  XOR({int(x1)},{int(x2)}) = {result}  [expected {expected}] {status}"
              f"  (N5 spikes: {counts[5]}, N3: {counts[3]}, N4: {counts[4]})")
        if result != expected:
            all_pass = False
    print("=" * 60)
    if all_pass:
        print("  All XOR cases CORRECT [PASS]")
    else:
        print("  Some XOR cases FAILED [FAIL]")
        sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="NeuraEdge XOR network utility")
    parser.add_argument("--simulate", action="store_true",
                        help="Run software LIF simulation for all XOR cases")
    parser.add_argument("--hex", action="store_true",
                        help="Output weight matrix as hex file for $readmemh")
    args = parser.parse_args()

    if args.simulate:
        run_simulation()
    elif args.hex:
        print_hex_file()
    else:
        print_weight_table()
