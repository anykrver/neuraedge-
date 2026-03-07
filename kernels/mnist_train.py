#!/usr/bin/env python3
"""
mnist_train.py — MNIST SNN training and weight export for NeuraEdge 128-neuron chip
=================================================================================

Network architecture:
  Input  : 64 neurons   (7×7 average-pooled 28×28 image, zero-padded to 64)
  Hidden : 54 neurons   (neurons 64-117)
  Output : 10 neurons   (neurons 118-127, one per digit class 0-9)
  Total  : 128 neurons  (128×128 weight matrix = 16KB)

Training method:
  Converts MNIST labels to spike-rate targets, then trains with a simplified
  rate-coded SNN using numpy-based gradient approximation (surrogate gradient
  via piece-wise linear derivative of the membrane step function).
  No PyTorch required — only numpy and urllib.

Weight export:
  Weights are quantised to Q2.6 fixed-point (8-bit signed) and written as a
  flat hex file (one byte per line) for $readmemh in synapse_mem_128.sv.
  File layout: row-major, mem[pre*128 + post] = W[pre][post].

Usage:
  python3 kernels/mnist_train.py                  # train and export (default)
  python3 kernels/mnist_train.py --epochs 20      # train for 20 epochs
  python3 kernels/mnist_train.py --validate-only  # validate existing weights
  python3 kernels/mnist_train.py --simulate       # run float simulation only
  python3 kernels/mnist_train.py --hex-only       # dump weights/mnist_weights.hex
"""

import argparse
import os
import struct
import sys
import urllib.request
import gzip
import numpy as np

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------
SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT    = os.path.dirname(SCRIPT_DIR)
WEIGHTS_DIR  = os.path.join(REPO_ROOT, "weights")

W1_PATH      = os.path.join(WEIGHTS_DIR, "mnist_weights_w1.npy")  # input→hidden
W2_PATH      = os.path.join(WEIGHTS_DIR, "mnist_weights_w2.npy")  # hidden→output
HEX_PATH     = os.path.join(WEIGHTS_DIR, "mnist_weights.hex")

# --------------------------------------------------------------------------
# Network topology
# --------------------------------------------------------------------------
N_NEURONS    = 128
N_INPUTS     = 64     # 7×7 pooled image, zero-padded
N_HIDDEN     = 54     # neurons 64-117
N_OUTPUT     = 10     # neurons 118-127 (one per digit class)

# Q2.6 fixed-point parameters
THRESHOLD    = 1.0
LEAK_FACTOR  = 0xE6 / 256.0   # ≈ 0.898
V_RESET      = 0.0
REFRAC       = 4
T_SIM        = 50              # timesteps per inference

# Training hyperparameters
LEARNING_RATE = 0.002
BATCH_SIZE    = 64
N_EPOCHS      = 10             # default epochs (fast)

# --------------------------------------------------------------------------
# MNIST data loader (downloads on first run, caches locally)
# --------------------------------------------------------------------------
MNIST_BASE = "https://storage.googleapis.com/cvdf-datasets/mnist/"
MNIST_FILES = {
    "train_images": "train-images-idx3-ubyte.gz",
    "train_labels": "train-labels-idx1-ubyte.gz",
    "test_images":  "t10k-images-idx3-ubyte.gz",
    "test_labels":  "t10k-labels-idx1-ubyte.gz",
}
DATA_CACHE = os.path.join(REPO_ROOT, "build", "mnist_cache")


def _download_mnist():
    """Download MNIST files if not already cached."""
    os.makedirs(DATA_CACHE, exist_ok=True)
    for key, fname in MNIST_FILES.items():
        dest = os.path.join(DATA_CACHE, fname)
        if not os.path.exists(dest):
            url = MNIST_BASE + fname
            print(f"  Downloading {fname} ...", end="", flush=True)
            try:
                urllib.request.urlretrieve(url, dest)
                print(" done")
            except Exception as e:
                print(f" FAILED ({e})")
                return False
    return True


def _load_idx(path: str) -> np.ndarray:
    """Parse IDX binary format (works for images and labels)."""
    with gzip.open(path, "rb") as f:
        magic = struct.unpack(">I", f.read(4))[0]
        dtype_map = {0x08: np.uint8, 0x09: np.int8, 0x0B: np.int16,
                     0x0C: np.int32, 0x0D: np.float32, 0x0E: np.float64}
        dtype = dtype_map[(magic >> 8) & 0xFF]
        ndims = magic & 0xFF
        dims  = [struct.unpack(">I", f.read(4))[0] for _ in range(ndims)]
        data  = np.frombuffer(f.read(), dtype=dtype).reshape(dims)
    return data


def load_mnist(download: bool = True):
    """Return (train_X, train_y, test_X, test_y) with images normalised to [0,1]."""
    if download and not all(
        os.path.exists(os.path.join(DATA_CACHE, v)) for v in MNIST_FILES.values()
    ):
        if not _download_mnist():
            print("Could not download MNIST. Using synthetic data for demo.")
            return _synthetic_mnist()

    try:
        train_X = _load_idx(os.path.join(DATA_CACHE, MNIST_FILES["train_images"]))
        train_y = _load_idx(os.path.join(DATA_CACHE, MNIST_FILES["train_labels"]))
        test_X  = _load_idx(os.path.join(DATA_CACHE, MNIST_FILES["test_images"]))
        test_y  = _load_idx(os.path.join(DATA_CACHE, MNIST_FILES["test_labels"]))
    except Exception as e:
        print(f"Could not load MNIST cache ({e}). Using synthetic data for demo.")
        return _synthetic_mnist()

    train_X = train_X.astype(np.float32) / 255.0
    test_X  = test_X.astype(np.float32) / 255.0
    return train_X, train_y.astype(np.int32), test_X, test_y.astype(np.int32)


def _synthetic_mnist():
    """Generate small synthetic dataset when MNIST is unavailable."""
    rng = np.random.default_rng(42)
    n_train, n_test = 1000, 200
    train_X = rng.random((n_train, 28, 28), dtype=np.float32)
    train_y = rng.integers(0, 10, n_train, dtype=np.int32)
    test_X  = rng.random((n_test, 28, 28), dtype=np.float32)
    test_y  = rng.integers(0, 10, n_test,  dtype=np.int32)
    print("  Using synthetic MNIST (1000 train, 200 test) — accuracy will be ~10%")
    return train_X, train_y, test_X, test_y

# --------------------------------------------------------------------------
# Pre-processing: 4×4 average pooling → 7×7 → zero-pad to 64
# --------------------------------------------------------------------------

def pool_and_pad(images: np.ndarray) -> np.ndarray:
    """
    28×28 → 7×7 via 4×4 average pooling → flatten and zero-pad to 64.
    Returns float array of shape (N, 64).
    """
    N = images.shape[0]
    # Reshape to (N, 7, 4, 7, 4) and average over the 4×4 windows
    pooled = images.reshape(N, 7, 4, 7, 4).mean(axis=(2, 4))  # (N, 7, 7)
    flat   = pooled.reshape(N, 49)                               # (N, 49)
    padded = np.zeros((N, N_INPUTS), dtype=np.float32)
    padded[:, :49] = flat
    return padded                                                # (N, 64)

# --------------------------------------------------------------------------
# Rate-coded spike simulation (single timestep)
# --------------------------------------------------------------------------

def rate_encode_batch(x: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """
    x: (B, N_INPUTS) floats in [0,1].
    Returns bool spike matrix of shape (B, N_INPUTS).
    P(spike) = x[i] (Bernoulli each timestep).
    """
    return rng.random(x.shape, dtype=np.float32) < x

# --------------------------------------------------------------------------
# LIF neuron simulation — single forward pass (T timesteps)
# --------------------------------------------------------------------------

def snn_forward(x: np.ndarray,
                W1: np.ndarray, W2: np.ndarray,
                T: int = T_SIM, rng: np.random.Generator = None
                ) -> tuple:
    """
    Rate-coded two-layer SNN forward pass.

    x  : (B, N_INPUTS)  — input pixel intensities [0,1]
    W1 : (N_INPUTS, N_HIDDEN)  — float weights
    W2 : (N_HIDDEN, N_OUTPUT)  — float weights
    Returns: (output_rates, h_spikes_avg, x_spikes_avg)
      output_rates: (B, N_OUTPUT) — mean output spike rate over T steps
    """
    if rng is None:
        rng = np.random.default_rng(42)

    B = x.shape[0]
    v_h = np.zeros((B, N_HIDDEN),  dtype=np.float64)
    v_o = np.zeros((B, N_OUTPUT),  dtype=np.float64)
    rc_h = np.zeros((B, N_HIDDEN), dtype=np.int32)
    rc_o = np.zeros((B, N_OUTPUT), dtype=np.int32)
    sc_o = np.zeros((B, N_OUTPUT), dtype=np.float64)  # output spike count
    sc_h = np.zeros((B, N_HIDDEN), dtype=np.float64)  # hidden spike count

    last_h = np.zeros((B, N_HIDDEN), dtype=bool)
    last_x = np.zeros((B, N_INPUTS),  dtype=bool)

    for t in range(T):
        # --- Input encoding ---
        x_spikes = rng.random(x.shape) < x  # (B, N_INPUTS)

        # --- Hidden layer: i_syn = x_spikes @ W1 ---
        i_h = x_spikes.astype(np.float64) @ W1          # (B, N_HIDDEN)
        v_h = v_h * LEAK_FACTOR + i_h
        v_h = np.clip(v_h, 0.0, None)                   # floor at 0
        v_h = np.where(rc_h > 0, v_h * LEAK_FACTOR, v_h)  # refractory: leak only

        fire_h = (v_h >= THRESHOLD) & (rc_h == 0)
        sc_h  += fire_h.astype(np.float64)
        v_h    = np.where(fire_h, V_RESET, v_h)
        rc_h   = np.where(fire_h, REFRAC, np.maximum(0, rc_h - 1))

        # --- Output layer: i_syn = fire_h @ W2 ---
        i_o = fire_h.astype(np.float64) @ W2             # (B, N_OUTPUT)
        v_o = v_o * LEAK_FACTOR + i_o
        v_o = np.clip(v_o, 0.0, None)
        v_o = np.where(rc_o > 0, v_o * LEAK_FACTOR, v_o)

        fire_o = (v_o >= THRESHOLD) & (rc_o == 0)
        sc_o  += fire_o.astype(np.float64)
        v_o    = np.where(fire_o, V_RESET, v_o)
        rc_o   = np.where(fire_o, REFRAC, np.maximum(0, rc_o - 1))

        last_h = fire_h
        last_x = x_spikes

    output_rates = sc_o / T  # mean firing rate per output neuron
    h_rates      = sc_h / T
    return output_rates, h_rates, last_x

# --------------------------------------------------------------------------
# Surrogate gradient training (one mini-batch)
# --------------------------------------------------------------------------

def snn_train_batch(x: np.ndarray, y: np.ndarray,
                    W1: np.ndarray, W2: np.ndarray,
                    lr: float, rng: np.random.Generator) -> tuple:
    """
    One gradient-descent step on a mini-batch.
    Uses MSE loss between output rates and one-hot targets.
    Surrogate gradient: piecewise linear derivative ≈ sigmoid derivative.
    Returns (W1_new, W2_new, batch_loss, batch_acc).
    """
    B = x.shape[0]

    # One-hot targets: target rate for correct class = 0.5, others = 0.05
    target = np.full((B, N_OUTPUT), 0.05, dtype=np.float64)
    for b in range(B):
        target[b, y[b]] = 0.5

    # Forward pass (using rate approximation for faster gradients)
    out_rates, h_rates, _ = snn_forward(x, W1, W2, T=T_SIM, rng=rng)

    # MSE loss
    loss = 0.5 * np.mean((out_rates - target) ** 2)
    acc  = (np.argmax(out_rates, axis=1) == y).mean()

    # Backprop through output layer (surrogate: d_rate/d_v ≈ 1 for v near thresh)
    d_out  = (out_rates - target) / B           # (B, N_OUTPUT)
    # Gradient w.r.t. W2: h_rates.T @ d_out
    grad_W2 = h_rates.T @ d_out                 # (N_HIDDEN, N_OUTPUT)

    # Backprop to hidden layer
    d_hidden = d_out @ W2.T                     # (B, N_HIDDEN)
    # Surrogate: clip gradient to avoid explosion
    d_hidden = np.clip(d_hidden, -1.0, 1.0)
    grad_W1  = x.T @ (h_rates * d_hidden)       # (N_INPUTS, N_HIDDEN)

    W1 = W1 - lr * grad_W1
    W2 = W2 - lr * grad_W2

    # Clip weights to Q2.6 float representable range [-2.0, 1.984375]
    W1 = np.clip(W1, -2.0, 127/64.0)
    W2 = np.clip(W2, -2.0, 127/64.0)

    return W1, W2, loss, acc

# --------------------------------------------------------------------------
# Training loop
# --------------------------------------------------------------------------

def train(n_epochs: int = N_EPOCHS, seed: int = 42) -> tuple:
    """Train the two-layer SNN and return (W1, W2)."""
    print("\n=== NeuraEdge MNIST SNN Training ===")
    print(f"Architecture: {N_INPUTS} input → {N_HIDDEN} hidden → {N_OUTPUT} output")
    print(f"Epochs: {n_epochs},  Batch: {BATCH_SIZE},  T_sim: {T_SIM}")

    train_X, train_y, test_X, test_y = load_mnist(download=True)
    print(f"Dataset: {train_X.shape[0]} train, {test_X.shape[0]} test images")

    # Pre-process images
    train_X_pool = pool_and_pad(train_X)
    test_X_pool  = pool_and_pad(test_X)

    rng = np.random.default_rng(seed)

    # Xavier initialisation
    W1 = rng.normal(0, np.sqrt(2.0 / (N_INPUTS  + N_HIDDEN)),
                    (N_INPUTS,  N_HIDDEN)).astype(np.float64)
    W2 = rng.normal(0, np.sqrt(2.0 / (N_HIDDEN + N_OUTPUT)),
                    (N_HIDDEN, N_OUTPUT)).astype(np.float64)

    N_train = train_X_pool.shape[0]
    best_val_acc = 0.0

    for epoch in range(n_epochs):
        # Shuffle training data
        perm = rng.permutation(N_train)
        train_X_sh = train_X_pool[perm]
        train_y_sh = train_y[perm]

        epoch_loss, epoch_acc = 0.0, 0.0
        n_batches = N_train // BATCH_SIZE

        for bi in range(n_batches):
            xb = train_X_sh[bi*BATCH_SIZE:(bi+1)*BATCH_SIZE]
            yb = train_y_sh[bi*BATCH_SIZE:(bi+1)*BATCH_SIZE]
            W1, W2, bloss, bacc = snn_train_batch(xb, yb, W1, W2, LEARNING_RATE, rng)
            epoch_loss += bloss
            epoch_acc  += bacc

        epoch_loss /= n_batches
        epoch_acc  /= n_batches

        # Quick validation (first 500 test images)
        val_out, _, _ = snn_forward(test_X_pool[:500], W1, W2,
                                    T=T_SIM, rng=np.random.default_rng(0))
        val_acc = (np.argmax(val_out, axis=1) == test_y[:500]).mean()
        best_val_acc = max(best_val_acc, val_acc)
        print(f"  Epoch {epoch+1:2d}/{n_epochs}: "
              f"loss={epoch_loss:.4f}  train_acc={epoch_acc:.3f}  "
              f"val_acc(500)={val_acc:.3f}")

    print(f"\nBest validation accuracy: {best_val_acc:.3f}")
    return W1, W2

# --------------------------------------------------------------------------
# Q2.6 quantisation
# --------------------------------------------------------------------------

def float_to_q26(val: float) -> int:
    """Convert float to signed Q2.6 8-bit integer (range -2.0 to +1.984375)."""
    raw = int(round(val * 64))
    return max(-128, min(127, raw)) & 0xFF  # two's complement unsigned


def build_weight_matrix(W1: np.ndarray, W2: np.ndarray) -> np.ndarray:
    """
    Build the full 128×128 Q2.6 weight matrix for synapse_mem_128.
    Layout:
      W_full[pre, post] where pre,post in 0..127
      W1[i, j] → W_full[i,         64+j]   (input neuron i → hidden neuron 64+j)
      W2[i, j] → W_full[64+i,     118+j]   (hidden neuron 64+i → output 118+j)
    """
    W_full = np.zeros((N_NEURONS, N_NEURONS), dtype=np.int32)

    # Input → hidden weights (pre=0..63, post=64..117)
    for i in range(N_INPUTS):
        for j in range(N_HIDDEN):
            W_full[i, 64 + j] = float_to_q26(W1[i, j])

    # Hidden → output weights (pre=64..117, post=118..127)
    for i in range(N_HIDDEN):
        for j in range(N_OUTPUT):
            W_full[64 + i, 118 + j] = float_to_q26(W2[i, j])

    return W_full


def export_hex(W_full: np.ndarray, path: str):
    """
    Write weight matrix as hex file for $readmemh.
    Memory layout: mem[pre*128 + post] = W_full[pre][post]
    (matches synapse_mem_128: mem[{pre[6:0], post[6:0]}])
    """
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("// NeuraEdge MNIST weights — Q2.6 signed 8-bit\n")
        f.write("// Format: mem[pre*128+post] — use $readmemh(\"mnist_weights.hex\", mem)\n")
        for pre in range(N_NEURONS):
            for post in range(N_NEURONS):
                f.write(f"{W_full[pre, post] & 0xFF:02x}\n")
    print(f"  Wrote {N_NEURONS*N_NEURONS} entries → {path}")

# --------------------------------------------------------------------------
# Validation with Q2.6 quantised weights
# --------------------------------------------------------------------------

def validate_q26(W_full: np.ndarray, test_X: np.ndarray, test_y: np.ndarray,
                 n_samples: int = 1000) -> float:
    """Run SNN inference with Q2.6 weights and compute accuracy."""
    test_X_pool = pool_and_pad(test_X[:n_samples])
    test_y_s    = test_y[:n_samples]

    # Reconstruct float weights from Q2.6 quantisation
    def q26_to_float(w_int):
        """Convert Q2.6 two's complement byte back to float."""
        w_s = w_int if w_int < 128 else w_int - 256
        return w_s / 64.0

    W1_q = np.array([[q26_to_float(W_full[i, 64+j])
                      for j in range(N_HIDDEN)]
                     for i in range(N_INPUTS)], dtype=np.float64)
    W2_q = np.array([[q26_to_float(W_full[64+i, 118+j])
                      for j in range(N_OUTPUT)]
                     for i in range(N_HIDDEN)], dtype=np.float64)

    rng = np.random.default_rng(0)
    out_rates, _, _ = snn_forward(test_X_pool, W1_q, W2_q, T=T_SIM, rng=rng)
    acc = (np.argmax(out_rates, axis=1) == test_y_s).mean()
    return acc

# --------------------------------------------------------------------------
# Main entry point
# --------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="NeuraEdge MNIST SNN training and weight export")
    parser.add_argument("--epochs",        type=int, default=N_EPOCHS,
                        help="Training epochs (default: 10)")
    parser.add_argument("--validate-only", action="store_true",
                        help="Validate existing weights without retraining")
    parser.add_argument("--simulate",      action="store_true",
                        help="Run float simulation and report accuracy")
    parser.add_argument("--hex-only",      action="store_true",
                        help="Export hex file from existing .npy weights")
    parser.add_argument("--seed",          type=int, default=42,
                        help="Random seed")
    args = parser.parse_args()

    os.makedirs(WEIGHTS_DIR, exist_ok=True)

    if args.hex_only:
        if not (os.path.exists(W1_PATH) and os.path.exists(W2_PATH)):
            print("Error: weight files not found. Run without --hex-only first.")
            sys.exit(1)
        W1 = np.load(W1_PATH)
        W2 = np.load(W2_PATH)
        W_full = build_weight_matrix(W1, W2)
        export_hex(W_full, HEX_PATH)
        return

    if args.validate_only:
        if not (os.path.exists(W1_PATH) and os.path.exists(W2_PATH)):
            print("Error: weight files not found. Run without --validate-only first.")
            sys.exit(1)
        W1 = np.load(W1_PATH)
        W2 = np.load(W2_PATH)
        W_full = build_weight_matrix(W1, W2)
        _, _, test_X, test_y = load_mnist()
        acc = validate_q26(W_full, test_X, test_y, n_samples=1000)
        print(f"\nQ2.6 quantised accuracy (1000 test samples): {acc*100:.1f}%")
        return

    # Full training + export
    W1, W2 = train(n_epochs=args.epochs, seed=args.seed)

    # Save float weights
    np.save(W1_PATH, W1)
    np.save(W2_PATH, W2)
    print(f"  Saved float weights → {W1_PATH}, {W2_PATH}")

    # Build and export Q2.6 weight matrix
    W_full = build_weight_matrix(W1, W2)
    export_hex(W_full, HEX_PATH)

    # Validate Q2.6 accuracy
    _, _, test_X, test_y = load_mnist()
    acc_q26 = validate_q26(W_full, test_X, test_y, n_samples=1000)
    print(f"\nQ2.6 quantised accuracy (1000 test): {acc_q26*100:.1f}%")
    print("\nNext step: load weights into RTL simulation")
    print("  1. Uncomment $readmemh in synapse_mem_128.sv")
    print("  2. make sim_mnist")


if __name__ == "__main__":
    main()
