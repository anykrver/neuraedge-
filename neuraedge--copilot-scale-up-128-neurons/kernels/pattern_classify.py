#!/usr/bin/env python3
"""
pattern_classify.py — 4-class pattern recognition for the NeuraEdge 32-neuron chip
====================================================================================

Demonstrates how to train and simulate a spike-based pattern classifier using the
NeuraEdge neuromorphic architecture.  Four distinct spatial patterns are encoded as
rate-coded spike trains and classified by a small 2-layer SNN.

Network topology (32 neurons, matching neuraedge.sv):
  Input  : neurons 0-7   (8-pixel pattern, 4×1 → rate-encoded)
  Hidden : neurons 8-23  (16 hidden neurons)
  Output : neurons 24-27 (4 output neurons, one per class)
  Unused : neurons 28-31

Patterns (8 pixels, binary):
  Class 0 (horizontal lines) : [1,1,1,1, 0,0,0,0]
  Class 1 (vertical lines)   : [1,0,1,0, 1,0,1,0]
  Class 2 (diagonal)         : [1,0,0,0, 0,1,0,0]   (approx)
  Class 3 (checkerboard)     : [1,0,1,0, 0,1,0,1]

Usage:
  python3 kernels/pattern_classify.py                 # print weight table + sim
  python3 kernels/pattern_classify.py --train         # train weights + simulate
  python3 kernels/pattern_classify.py --simulate      # run simulation with defaults
  python3 kernels/pattern_classify.py --hex           # print $readmemh hex output
"""

import argparse
import numpy as np
import sys

# --------------------------------------------------------------------------
# Network topology
# --------------------------------------------------------------------------
N_NEURONS  = 32
N_INPUTS   = 8
N_HIDDEN   = 16
N_OUTPUT   = 4
N_CLASSES  = 4

N_IN_START  = 0
N_HID_START = 8
N_OUT_START = 24

# Q2.6 fixed-point parameters (matching hardware)
THRESHOLD   = 1.0
LEAK_FACTOR = 0xE6 / 256.0   # ≈ 0.898
V_RESET     = 0.0
REFRAC      = 4
T_MAX       = 150             # timesteps per inference

# Training hyperparameters
LEARNING_RATE = 0.01
N_EPOCHS      = 40
BATCH_SIZE    = 32

# --------------------------------------------------------------------------
# Four training patterns (binary 8-pixel images)
# --------------------------------------------------------------------------
PATTERNS = {
    0: np.array([1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0], dtype=np.float64),
    1: np.array([1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0], dtype=np.float64),
    2: np.array([1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0], dtype=np.float64),
    3: np.array([1.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 1.0], dtype=np.float64),
}
CLASS_NAMES = {0: "horizontal", 1: "vertical", 2: "diagonal", 3: "checkerboard"}


def float_to_q26(val: float) -> int:
    """Convert float to signed Q2.6 8-bit integer (range [-2.0, +1.984375])."""
    raw = int(round(val * 64))
    return max(-128, min(127, raw)) & 0xFF


def q26_to_float(w_int: int) -> float:
    """Convert Q2.6 unsigned byte back to signed float."""
    w_s = w_int if w_int < 128 else w_int - 256
    return w_s / 64.0


# --------------------------------------------------------------------------
# LIF simulation (two-layer SNN)
# --------------------------------------------------------------------------

def snn_forward(x: np.ndarray, W1: np.ndarray, W2: np.ndarray,
                T: int = T_MAX, rng: np.random.Generator = None,
                verbose: bool = False) -> tuple:
    """
    Rate-coded two-layer SNN forward pass.
    x  : (N_INPUTS,)   float pattern in [0, 1]
    W1 : (N_INPUTS, N_HIDDEN)  weight matrix (float, Q2.6 range)
    W2 : (N_HIDDEN,  N_OUTPUT) weight matrix (float, Q2.6 range)
    Returns (output_spike_counts, hidden_spike_counts) as integer arrays.
    """
    if rng is None:
        rng = np.random.default_rng(42)

    v_h = np.zeros(N_HIDDEN,  dtype=np.float64)
    v_o = np.zeros(N_OUTPUT,  dtype=np.float64)
    rc_h = np.zeros(N_HIDDEN, dtype=np.int32)
    rc_o = np.zeros(N_OUTPUT, dtype=np.int32)
    sc_h = np.zeros(N_HIDDEN, dtype=np.int32)
    sc_o = np.zeros(N_OUTPUT, dtype=np.int32)

    for t in range(T):
        # Encode input as Poisson spike train
        x_spk = (rng.random(N_INPUTS) < x).astype(np.float64)

        # Hidden layer
        i_h = x_spk @ W1                            # (N_HIDDEN,)
        for n in range(N_HIDDEN):
            if rc_h[n] > 0:
                v_h[n] = v_h[n] * LEAK_FACTOR
                rc_h[n] -= 1
            else:
                v_h[n] = max(0.0, v_h[n] * LEAK_FACTOR + i_h[n])
                if v_h[n] >= THRESHOLD:
                    sc_h[n] += 1
                    v_h[n]   = V_RESET
                    rc_h[n]  = REFRAC

        # Output layer
        h_spk = (sc_h > 0).astype(np.float64)  # use accumulated as proxy
        i_o   = (v_h >= THRESHOLD * 0.5) @ W2   # use sub-threshold signal
        for n in range(N_OUTPUT):
            if rc_o[n] > 0:
                v_o[n] = v_o[n] * LEAK_FACTOR
                rc_o[n] -= 1
            else:
                v_o[n] = max(0.0, v_o[n] * LEAK_FACTOR + i_o[n])
                if v_o[n] >= THRESHOLD:
                    sc_o[n] += 1
                    v_o[n]   = V_RESET
                    rc_o[n]  = REFRAC

        if verbose and t < 5:
            fired_h = [i for i in range(N_HIDDEN) if v_h[i] >= THRESHOLD * 0.5]
            fired_o = [i for i in range(N_OUTPUT) if v_o[i] >= THRESHOLD * 0.5]
            print(f"    t={t}: x_spk={x_spk.astype(int).tolist()} "
                  f"h_active={fired_h} o_active={fired_o}")

    return sc_o, sc_h


# --------------------------------------------------------------------------
# Weight training (gradient-free: random search / perceptron update)
# --------------------------------------------------------------------------

def train_weights(seed: int = 42) -> tuple:
    """
    Train W1 and W2 using a simplified perceptron-style update rule.
    For each training sample, if the wrong class fires most, adjust weights.
    Returns (W1, W2) as float arrays.
    """
    print("=== Pattern Classifier Weight Training ===")
    rng = np.random.default_rng(seed)

    # Xavier initialisation
    W1 = rng.normal(0, np.sqrt(2.0 / (N_INPUTS + N_HIDDEN)),
                    (N_INPUTS, N_HIDDEN))
    W2 = rng.normal(0, np.sqrt(2.0 / (N_HIDDEN + N_OUTPUT)),
                    (N_HIDDEN, N_OUTPUT))

    # Generate augmented training set with noise
    train_X, train_y = [], []
    for cls, pat in PATTERNS.items():
        for _ in range(200):
            noise = rng.normal(0, 0.1, N_INPUTS)
            x_noisy = np.clip(pat + noise, 0.0, 1.0)
            train_X.append(x_noisy)
            train_y.append(cls)
    train_X = np.array(train_X)
    train_y = np.array(train_y)

    N_train = len(train_y)
    best_acc = 0.0

    for epoch in range(N_EPOCHS):
        perm = rng.permutation(N_train)
        correct = 0
        for idx in perm:
            x = train_X[idx]
            y = train_y[idx]

            sc_o, sc_h = snn_forward(x, W1, W2, T=T_MAX // 3, rng=rng)
            pred = int(np.argmax(sc_o))

            if pred == y:
                correct += 1
            else:
                # Simple perceptron-style update
                lr = LEARNING_RATE
                # Strengthen correct path, weaken wrong path
                x_spk_approx = x * 0.5        # rough spike rate proxy
                h_approx     = x_spk_approx @ W1
                h_approx     = np.clip(h_approx, 0, 1)
                # Increase W2 for correct class
                W2[:, y]    += lr * h_approx
                # Decrease W2 for predicted (wrong) class
                W2[:, pred] -= lr * h_approx * 0.5
                # Update W1 via chain rule approximation
                W1 += lr * 0.1 * np.outer(x_spk_approx,
                                           W2[:, y] - W2[:, pred])
                # Clamp to Q2.6 float range
                W1 = np.clip(W1, -2.0, 127/64.0)
                W2 = np.clip(W2, -2.0, 127/64.0)

        acc = correct / N_train
        best_acc = max(best_acc, acc)
        if (epoch + 1) % 10 == 0:
            print(f"  Epoch {epoch+1:2d}/{N_EPOCHS}: train_acc={acc:.3f}")

    print(f"Best training accuracy: {best_acc:.3f}")
    return W1, W2


# --------------------------------------------------------------------------
# Evaluation
# --------------------------------------------------------------------------

def evaluate(W1: np.ndarray, W2: np.ndarray, n_trials: int = 50,
             noise: float = 0.1, seed: int = 0) -> None:
    """Evaluate the classifier on all 4 classes with noise."""
    rng = np.random.default_rng(seed)
    print("\n" + "=" * 60)
    print("  NeuraEdge 4-Class Pattern Classifier — Evaluation")
    print(f"  Trials per class: {n_trials},  Noise sigma: {noise}")
    print("=" * 60)

    total_correct = 0
    total_trials  = 0

    for cls in range(N_CLASSES):
        pat = PATTERNS[cls]
        correct = 0
        for _ in range(n_trials):
            x = np.clip(pat + rng.normal(0, noise, N_INPUTS), 0.0, 1.0)
            sc_o, _ = snn_forward(x, W1, W2, T=T_MAX, rng=rng)
            pred = int(np.argmax(sc_o))
            if pred == cls:
                correct += 1

        acc = correct / n_trials
        total_correct += correct
        total_trials  += n_trials
        status = "PASS" if acc >= 0.7 else "MARGINAL" if acc >= 0.5 else "FAIL"
        print(f"  Class {cls} ({CLASS_NAMES[cls]:12s}): "
              f"accuracy={acc:.2f}  [{correct}/{n_trials}]  {status}")

    overall = total_correct / total_trials
    print("=" * 60)
    print(f"  Overall accuracy: {overall:.2f}  [{total_correct}/{total_trials}]")
    status = "PASS" if overall >= 0.7 else "FAIL"
    print(f"  Result: {status}")
    if overall < 0.7:
        sys.exit(1)


# --------------------------------------------------------------------------
# Hex weight table output (for $readmemh in synapse_mem.sv)
# --------------------------------------------------------------------------

def build_weight_matrix_32(W1: np.ndarray, W2: np.ndarray) -> list:
    """Build full 32×32 weight matrix in Q2.6 for the 32-neuron chip."""
    W_full = [[0] * N_NEURONS for _ in range(N_NEURONS)]

    # Input → hidden (pre=0..7, post=8..23)
    for i in range(N_INPUTS):
        for j in range(N_HIDDEN):
            W_full[N_IN_START + i][N_HID_START + j] = float_to_q26(W1[i, j])

    # Hidden → output (pre=8..23, post=24..27)
    for i in range(N_HIDDEN):
        for j in range(N_OUTPUT):
            W_full[N_HID_START + i][N_OUT_START + j] = float_to_q26(W2[i, j])

    return W_full


def print_hex(W1: np.ndarray, W2: np.ndarray) -> None:
    """Print full 32×32 weight matrix in $readmemh format."""
    W_full = build_weight_matrix_32(W1, W2)
    print("// Pattern classifier weights for $readmemh (32×32, Q2.6)")
    print("// Each entry: W[pre][post] (row-major)")
    for pre in range(N_NEURONS):
        for post in range(N_NEURONS):
            print(f"{W_full[pre][post] & 0xFF:02x}")


def print_default_weight_table() -> None:
    """Print a hand-tuned weight example for the 4-class pattern network."""
    print("=" * 60)
    print("  NeuraEdge 4-Class Pattern Classifier — Example Weights")
    print("=" * 60)
    print("  Network: 8-input → 16-hidden → 4-output (32-neuron chip)")
    print()
    print("  Pattern definitions:")
    for cls, pat in PATTERNS.items():
        print(f"    Class {cls} ({CLASS_NAMES[cls]:12s}): {pat.astype(int).tolist()}")
    print()
    print("  Suggested ISA weight loading sequence:")
    print("    (Train with --train to get optimised weights)")
    print()
    # Show a few example connections
    examples = [
        (0, 8,  +0.5, "input-0 → hidden-8  (horizontal detector, excitatory)"),
        (4, 8,  -0.5, "input-4 → hidden-8  (bottom half inhibits horizontal)"),
        (1, 9,  +0.5, "input-1 → hidden-9  (vertical detector, alternating)"),
        (8, 24, +1.0, "hidden-8 → output-24 (horizontal class gate)"),
        (9, 25, +1.0, "hidden-9 → output-25 (vertical class gate)"),
    ]
    print(f"  {'Connection':<30} {'Float':>7}  {'Q2.6 hex':>10}")
    print("  " + "-" * 55)
    for pre, post, wf, desc in examples:
        wh = float_to_q26(wf)
        print(f"  N{pre}→N{post:<25} {wf:>+7.3f}     0x{wh:02X}   # {desc}")


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="NeuraEdge 4-class pattern classifier")
    parser.add_argument("--train",    action="store_true",
                        help="Train weights then simulate")
    parser.add_argument("--simulate", action="store_true",
                        help="Run simulation with default/trained weights")
    parser.add_argument("--hex",      action="store_true",
                        help="Output weight matrix in $readmemh hex format")
    parser.add_argument("--seed",     type=int, default=42,
                        help="Random seed (default: 42)")
    args = parser.parse_args()

    if args.train or args.simulate:
        W1, W2 = train_weights(seed=args.seed)
        evaluate(W1, W2, n_trials=50, noise=0.1, seed=args.seed)
        if args.hex:
            print_hex(W1, W2)
    elif args.hex:
        # Use zero weights as placeholder when no trained weights available
        W1 = np.zeros((N_INPUTS, N_HIDDEN))
        W2 = np.zeros((N_HIDDEN, N_OUTPUT))
        print_hex(W1, W2)
    else:
        print_default_weight_table()


if __name__ == "__main__":
    main()
