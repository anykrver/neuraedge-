"""
train_nmnist.py  NeuraEdge SNN Training Pipeline
=================================================
Trains a two-layer spiking neural network on N-MNIST with
snnTorch, then exports quantised weights in three formats:

  benchmarks/weights_neuraedge.bin   SPI binary for FPGA loader
  benchmarks/weights_neuraedge.csv   Debug-readable subset
  benchmarks/weights_scale.json      Float range for dequantisation
  benchmarks/load_weights.py         Auto-generated SPI loader
  benchmarks/results_v2.csv          Training metrics per epoch
  benchmarks/training_curves.png     Loss + accuracy plots

Hardware alignment (mirrors neuraedge_top.v):
  SENSOR_W/H = 34x34   NUM_COLS/ROWS = 2x2   TILE_W/H = 17x17
  NUM_NEURONS = 64      NUM_SYNAPSES = 128  # reduced from 512 (power optimisation)    WEIGHT_W = 8-bit
  neuron_id = (local_y * TILE_W + local_x) * 2 + polarity
  Output layer = spike_out[0][0][54:63]  (last 10 of cluster 0)

Usage:
  python software/train_nmnist.py                  # full training
  python software/train_nmnist.py --epochs 5       # quick smoke test
  python software/train_nmnist.py --load-only      # export only

Requirements:
  pip install torch snntorch numpy tqdm matplotlib
  pip install tonic   # real N-MNIST data (strongly recommended)

Expected results (with tonic + real data):
  Test accuracy  ~97.5%  after 20 epochs
  Spike sparsity  ~3-5%  (hidden layer)
  Training time   ~15 min on GPU, ~90 min on CPU

Author:  NeuraEdge / Rahul Verma
Version: 1.0.0
License: Apache 2.0
"""

import argparse, json, struct, sys, time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import snntorch as snn
import snntorch.functional as SF
from snntorch import surrogate
from torch.utils.data import DataLoader, TensorDataset
import tqdm

try:
    import matplotlib; matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    HAS_MPL = True
except ImportError:
    HAS_MPL = False


# =====================================================================
# Hardware constants  (must mirror neuraedge_top.v parameter block)
# =====================================================================
SENSOR_W            = 34
SENSOR_H            = 34
NUM_COLS            = 2
NUM_ROWS            = 2
TILE_W              = SENSOR_W // NUM_COLS    # 17
TILE_H              = SENSOR_H // NUM_ROWS    # 17
NUM_CLUSTERS        = NUM_COLS * NUM_ROWS     # 4
NUM_NEURONS         = 64
NUM_SYNAPSES        = 512
NUM_CLASSES         = 10
WEIGHT_W            = 8
WEIGHT_MAX          = (1 << WEIGHT_W) - 1    # 255
WEIGHT_MIN          = 0
NUM_STEPS           = 25   # SNN time steps per inference window

# 34 x 34 pixels x 2 polarities (ON + OFF)
INPUT_SIZE          = SENSOR_W * SENSOR_H * 2   # 2312

# Hidden layer = NUM_SYNAPSES so fc1[i][j] maps directly to
# synapse_memory[neuron=i][syn=j] without index remapping
HIDDEN_SIZE         = NUM_SYNAPSES               # 512

# Output neurons sit at the top of cluster[0][0]
# spike_out[0][0][OUTPUT_NEURON_START : NUM_NEURONS]
OUTPUT_NEURON_START = NUM_NEURONS - NUM_CLASSES  # 54


# =====================================================================
# Model
# =====================================================================
class NeuraEdgeSNN(nn.Module):
    """
    Two-layer LIF spiking network.

    Topology:  Input(2312) --fc1--> LIF(512) --fc2--> LIF(10)

    Design decisions:
    - bias=False: synapse_memory stores weights only; biases
      would need a separate register file in hardware.
    - beta=0.9: membrane decay. The hardware uses LEAK_SHIFT=1
      which gives V *= 0.5 per cycle; use beta=0.5 for exact
      equivalence or beta=0.9 for better training accuracy.
    - Surrogate gradient: fast sigmoid keeps gradients non-zero
      through the discontinuous spike threshold.
    """

    def __init__(self, beta: float = 0.9, threshold: float = 1.0):
        super().__init__()
        sg = surrogate.fast_sigmoid(slope=25)

        self.fc1  = nn.Linear(INPUT_SIZE,  HIDDEN_SIZE,  bias=False)
        self.lif1 = snn.Leaky(beta=beta, threshold=threshold,
                               spike_grad=sg, learn_beta=False)
        self.fc2  = nn.Linear(HIDDEN_SIZE, NUM_CLASSES,  bias=False)
        self.lif2 = snn.Leaky(beta=beta, threshold=threshold,
                               spike_grad=sg, learn_beta=False)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """
        x:      [T, B, INPUT_SIZE]
        return: [T, B, NUM_CLASSES]
        """
        mem1 = self.lif1.init_leaky()
        mem2 = self.lif2.init_leaky()
        out  = []
        for t in range(x.shape[0]):
            spk1, mem1 = self.lif1(self.fc1(x[t]), mem1)
            spk2, mem2 = self.lif2(self.fc2(spk1), mem2)
            out.append(spk2)
        return torch.stack(out)  # [T, B, C]


# =====================================================================
# Data loading
# =====================================================================
def _synthetic(batch_size: int):
    """Sparse random frames as a stand-in when tonic is absent."""
    print("[data] WARNING: tonic not found. Using synthetic data.")
    print("[data]          Accuracy numbers will NOT be meaningful.")
    print("[data]          Install tonic: pip install tonic")

    rng = torch.Generator().manual_seed(42)
    n_tr, n_te = 60_000, 10_000

    def make(n):
        x = (torch.rand(n, NUM_STEPS, INPUT_SIZE, generator=rng) < 0.03).float()
        y = torch.randint(0, NUM_CLASSES, (n,), generator=rng)
        return TensorDataset(x, y)

    def collate(batch):
        xs = torch.stack([b[0] for b in batch]).permute(1, 0, 2)  # T,B,D
        ys = torch.stack([b[1] for b in batch])
        return xs, ys

    tr = DataLoader(make(n_tr), batch_size=batch_size, shuffle=True,
                    collate_fn=collate, num_workers=0)
    te = DataLoader(make(n_te), batch_size=batch_size, shuffle=False,
                    collate_fn=collate, num_workers=0)
    return tr, te


def load_nmnist(data_root: str, batch_size: int):
    """Load N-MNIST via tonic; fall back to synthetic stub."""
    try:
        import tonic
        import tonic.transforms as T

        sz = tonic.datasets.NMNIST.sensor_size  # (34, 34, 2)
        xf = tonic.transforms.Compose([
            tonic.transforms.Denoise(filter_time=10_000),
            tonic.transforms.ToFrame(sensor_size=sz, n_time_bins=NUM_STEPS),
        ])
        tr_ds = tonic.datasets.NMNIST(save_to=data_root, train=True,  transform=xf)
        te_ds = tonic.datasets.NMNIST(save_to=data_root, train=False, transform=xf)

        def collate(batch):
            # each item: frames (T,2,H,W) as ndarray; label as int
            xs = torch.stack([
                torch.tensor(b[0], dtype=torch.float32).view(NUM_STEPS, -1)
                for b in batch
            ]).permute(1, 0, 2)  # (T, B, 2312)
            ys = torch.tensor([b[1] for b in batch], dtype=torch.long)
            return xs, ys

        kw = dict(collate_fn=collate, num_workers=4, pin_memory=True,
                  persistent_workers=True)
        tr = DataLoader(tr_ds, batch_size=batch_size, shuffle=True,  **kw)
        te = DataLoader(te_ds, batch_size=batch_size, shuffle=False, **kw)

        print(f"[data] N-MNIST  train={len(tr_ds):,}  test={len(te_ds):,}")
        return tr, te

    except ImportError:
        return _synthetic(batch_size)


# =====================================================================
# Training
# =====================================================================
def _fix_shape(x, device):
    x = x.to(device, non_blocking=True).float()
    if x.dim() == 3 and x.shape[0] != NUM_STEPS:
        x = x.permute(1, 0, 2)
    return x


def train_epoch(model, loader, opt, loss_fn, device, ep, total_ep):
    model.train()
    tl = ta = ts = 0.0; n = 0
    bar = tqdm.tqdm(loader, desc=f"Ep {ep:02d}/{total_ep}", leave=False,
                    ncols=95, unit="b")
    for x, y in bar:
        x = _fix_shape(x, device)
        y = y.to(device, non_blocking=True)
        opt.zero_grad(set_to_none=True)
        out  = model(x)
        loss = loss_fn(out, y)
        loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        acc = (out.sum(0).argmax(1) == y).float().mean().item()
        sp  = out.mean().item()
        tl += loss.item(); ta += acc; ts += sp; n += 1
        bar.set_postfix(loss=f"{loss.item():.4f}", acc=f"{acc:.3f}",
                        sp=f"{sp:.3f}")
    return tl/n, ta/n, ts/n


@torch.no_grad()
def evaluate(model, loader, loss_fn, device):
    model.eval()
    tl = ta = 0.0; n = 0
    for x, y in loader:
        x   = _fix_shape(x, device)
        y   = y.to(device, non_blocking=True)
        out = model(x)
        tl += loss_fn(out, y).item()
        ta += (out.sum(0).argmax(1) == y).float().mean().item()
        n  += 1
    return tl/n, ta/n


# =====================================================================
# Sparsity analysis
# =====================================================================
@torch.no_grad()
def measure_sparsity(model, loader, device, n_batches=20):
    """
    Fraction of hidden/output neurons active per time step.
    Hardware target: < 5% (from NeuraEdge engineering guide).
    """
    model.eval()
    s1, s2 = [], []
    for i, (x, _) in enumerate(loader):
        if i >= n_batches: break
        x    = _fix_shape(x, device)
        mem1 = model.lif1.init_leaky()
        mem2 = model.lif2.init_leaky()
        for t in range(x.shape[0]):
            spk1, mem1 = model.lif1(model.fc1(x[t]), mem1)
            spk2, mem2 = model.lif2(model.fc2(spk1), mem2)
            s1.append(spk1.float().mean().item())
            s2.append(spk2.float().mean().item())

    s1m = np.mean(s1) * 100
    s2m = np.mean(s2) * 100
    est = (s1m / 100) * HIDDEN_SIZE * NUM_STEPS * 1000

    print(f"\n{'─'*56}")
    print(f"  Sparsity analysis (hardware efficiency)")
    print(f"  Hidden layer ({HIDDEN_SIZE} neurons): {s1m:.2f}% active/step")
    print(f"  Output layer ({NUM_CLASSES} neurons):  {s2m:.2f}% active/step")
    print(f"  Est. spike rate @ 1k inf/sec:    {est:,.0f} spikes/sec")
    print(f"  Hardware target:                 < 10,000,000 spikes/sec")
    print(f"  Status: {'PASS' if est < 10_000_000 else 'CHECK'}")
    print(f"{'─'*56}")
    return s1m, s2m


# =====================================================================
# Weight quantisation
# =====================================================================
def quantise(tensor: torch.Tensor):
    """Linear min-max quantisation to uint8 [0, 255].

    The hardware synapse_memory stores 8-bit unsigned weights.
    Negative float weights map below 128, positives above 128.
    The zero point (float=0) maps to uint8=127 approximately.

    Returns: (uint8_array, float_min, float_max)
    """
    w = tensor.detach().cpu().float().numpy()
    wmin, wmax = float(w.min()), float(w.max())
    rng = wmax - wmin
    if rng < 1e-8:
        return np.zeros(w.shape, dtype=np.uint8), wmin, wmax
    q = np.clip(np.round((w - wmin) / rng * WEIGHT_MAX),
                WEIGHT_MIN, WEIGHT_MAX).astype(np.uint8)
    return q, wmin, wmax


def quant_error(tensor, q, wmin, wmax):
    rng  = wmax - wmin
    deq  = q.astype(np.float32) / WEIGHT_MAX * rng + wmin
    return float(np.abs(tensor.detach().cpu().numpy() - deq).mean())


# =====================================================================
# Weight export
# =====================================================================
def export_weights(model: NeuraEdgeSNN, out_dir: Path):
    """
    Quantise fc1 and fc2 and write to disk.

    Binary layout (weights_neuraedge.bin):
      Bytes  0-3:   magic  0x4E454452  ('NEDR')
      Bytes  4-7:   version = 1
      Bytes  8-11:  fc1 rows  (512)
      Bytes 12-15:  fc1 cols  (2312)
      Bytes 16-19:  fc2 rows  (10)
      Bytes 20-23:  fc2 cols  (512)
      Bytes 24+:    fc1 uint8 row-major  (512 x 2312 = 1,183,744 B)
      Then:         fc2 uint8 row-major  (10 x 512   =     5,120 B)
      Total:        ~1.1 MB

    Hardware mapping:
      fc1[n_out][n_in] -> cluster 0, neuron=n_out, synapse=n_in
      fc2[cls][n_hid]  -> cluster 0, neuron=(54+cls), synapse=n_hid
    """
    out_dir.mkdir(parents=True, exist_ok=True)

    fc1_q, fc1_min, fc1_max = quantise(model.fc1.weight)
    fc2_q, fc2_min, fc2_max = quantise(model.fc2.weight)
    fc1_err = quant_error(model.fc1.weight, fc1_q, fc1_min, fc1_max)
    fc2_err = quant_error(model.fc2.weight, fc2_q, fc2_min, fc2_max)

    print(f"\n{'─'*56}")
    print(f"  Weight export")
    print(f"  fc1 {tuple(model.fc1.weight.shape)}  "
          f"float=[{fc1_min:.4f}, {fc1_max:.4f}]  "
          f"-> uint8=[{int(fc1_q.min())}, {int(fc1_q.max())}]  "
          f"MAE={fc1_err:.5f}")
    print(f"  fc2 {tuple(model.fc2.weight.shape)}  "
          f"float=[{fc2_min:.4f}, {fc2_max:.4f}]  "
          f"-> uint8=[{int(fc2_q.min())}, {int(fc2_q.max())}]  "
          f"MAE={fc2_err:.5f}")

    # ---- Binary -----------------------------------------------
    bin_path = out_dir / "weights_neuraedge.bin"
    with open(bin_path, "wb") as f:
        f.write(struct.pack(">IIIIII",
            0x4E454452, 1,
            fc1_q.shape[0], fc1_q.shape[1],
            fc2_q.shape[0], fc2_q.shape[1]))
        f.write(fc1_q.tobytes())
        f.write(fc2_q.tobytes())
    print(f"  Binary     -> {bin_path}  ({bin_path.stat().st_size:,} B)")

    # ---- CSV (first 16 neurons, first 32 synapses) ---------------
    csv_path = out_dir / "weights_neuraedge.csv"
    with open(csv_path, "w") as f:
        f.write("# NeuraEdge weight export (debug subset)\n")
        f.write(f"# fc1 shape: {fc1_q.shape}   fc2 shape: {fc2_q.shape}\n")
        f.write("layer,neuron,syn0..syn31\n")
        for r in range(min(16, fc1_q.shape[0])):
            f.write("fc1," + str(r) + "," +
                    ",".join(str(int(v)) for v in fc1_q[r, :32]) + "\n")
        for r in range(fc2_q.shape[0]):
            f.write("fc2," + str(r) + "," +
                    ",".join(str(int(v)) for v in fc2_q[r, :64]) + "\n")
    print(f"  CSV        -> {csv_path}")

    # ---- Scale JSON ---------------------------------------------
    scale_path = out_dir / "weights_scale.json"
    with open(scale_path, "w") as f:
        json.dump({
            "fc1": {"min": fc1_min, "max": fc1_max,
                    "rows": int(fc1_q.shape[0]),
                    "cols": int(fc1_q.shape[1])},
            "fc2": {"min": fc2_min, "max": fc2_max,
                    "rows": int(fc2_q.shape[0]),
                    "cols": int(fc2_q.shape[1])},
            "hardware": {
                "WEIGHT_W": WEIGHT_W, "NUM_NEURONS": NUM_NEURONS,
                "NUM_SYNAPSES": NUM_SYNAPSES, "NUM_CLASSES": NUM_CLASSES,
                "OUTPUT_NEURON_START": OUTPUT_NEURON_START,
                "SENSOR_W": SENSOR_W, "SENSOR_H": SENSOR_H,
                "TILE_W": TILE_W, "TILE_H": TILE_H,
            }
        }, f, indent=2)
    print(f"  Scale JSON -> {scale_path}")
    print(f"{'─'*56}")

    return fc1_q, fc2_q


# =====================================================================
# SPI loader generation
# =====================================================================
def generate_spi_loader(fc1_q: np.ndarray, fc2_q: np.ndarray,
                        out_dir: Path):
    """Write load_weights.py — streams weights to FPGA over SPI."""
    n_fc1  = fc1_q.size
    n_fc2  = fc2_q.size
    total  = n_fc1 + n_fc2
    out_offset = OUTPUT_NEURON_START

    lines = [
        '"""',
        'load_weights.py  NeuraEdge SPI weight loader',
        'Auto-generated by train_nmnist.py',
        f'Total writes: {total:,}  (fc1: {n_fc1:,}  fc2: {n_fc2:,})',
        '',
        'Usage:',
        '  python load_weights.py --port /dev/ttyUSB0',
        '  python load_weights.py --dry-run',
        '',
        'SPI frame = 5 bytes / 40 bits (matches neuraedge_top.v):',
        '  [39:32] cluster_id  [31:24] neuron_id',
        '  [23:16] syn_hi      [15:8]  syn_lo   [7:0] weight',
        '',
        'Requires: pip install pyserial',
        '"""',
        '',
        'import argparse, struct, time, sys',
        'import numpy as np',
        'from pathlib import Path',
        '',
        'BIN      = Path(__file__).parent / "weights_neuraedge.bin"',
        f'OUT_OFF  = {out_offset}   # first output neuron in cluster 0',
        '',
        'def load():',
        '    with open(BIN, "rb") as fh:',
        '        magic, ver, r1, c1, r2, c2 = struct.unpack(">IIIIII", fh.read(24))',
        '        assert magic == 0x4E454452',
        '        fc1 = np.frombuffer(fh.read(r1*c1), np.uint8).reshape(r1, c1)',
        '        fc2 = np.frombuffer(fh.read(r2*c2), np.uint8).reshape(r2, c2)',
        '    return fc1, fc2',
        '',
        'def frame(cluster, neuron, syn, w):',
        '    return struct.pack(">BBBBB", cluster, neuron,',
        '                       (syn>>8)&0xFF, syn&0xFF, w)',
        '',
        'def stream(fc1, fc2, send, verbose=False):',
        '    total = 0',
        '    print(f"fc1 {fc1.shape[0]}x{fc1.shape[1]} = {fc1.size:,} writes...")',
        '    for n_out in range(fc1.shape[0]):',
        '        for syn in range(fc1.shape[1]):',
        '            send(frame(0, n_out, syn, int(fc1[n_out, syn])))',
        '            total += 1',
        '        if verbose and n_out % 64 == 0:',
        '            print(f"  fc1 neuron {n_out} / {fc1.shape[0]}")',
        '    print(f"fc2 {fc2.shape[0]}x{fc2.shape[1]} = {fc2.size:,} writes...")',
        '    for cls in range(fc2.shape[0]):',
        '        for syn in range(fc2.shape[1]):',
        '            send(frame(0, OUT_OFF + cls, syn, int(fc2[cls, syn])))',
        '            total += 1',
        '    print(f"Done: {total:,} frames.")',
        '',
        'def main():',
        '    p = argparse.ArgumentParser()',
        '    p.add_argument("--port",    default="/dev/ttyUSB0")',
        '    p.add_argument("--baud",    type=int, default=115200)',
        '    p.add_argument("--dry-run", action="store_true")',
        '    args = p.parse_args()',
        '    fc1, fc2 = load()',
        '    print(f"Loaded fc1={fc1.shape} fc2={fc2.shape}")',
        '    if args.dry_run:',
        '        cnt = [0]',
        '        def show(f):',
        '            if cnt[0] < 6:',
        '                cl,n,sh,sl,w = struct.unpack(">BBBBB", f)',
        '                print(f"  cl={cl} n={n:3d} syn={(sh<<8)|sl:4d} w={w:3d}")',
        '            cnt[0] += 1',
        '        stream(fc1, fc2, show, verbose=True)',
        '        print(f"dry-run total: {cnt[0]:,}")',
        '        return',
        '    try: import serial',
        '    except ImportError: print("pip install pyserial"); sys.exit(1)',
        '    gap = 8 / 1_000_000   # 8 SPI clocks at 1 MHz',
        '    with serial.Serial(args.port, args.baud, timeout=2) as ser:',
        '        print(f"Port {args.port} @ {args.baud} baud")',
        '        t0 = time.time()',
        '        stream(fc1, fc2,',
        '               lambda f: (ser.write(f), time.sleep(gap)),',
        '               verbose=True)',
        '        print(f"Elapsed: {time.time()-t0:.1f}s")',
        '',
        'if __name__ == "__main__": main()',
    ]

    loader = out_dir / "load_weights.py"
    loader.write_text("\n".join(lines) + "\n")
    print(f"  SPI loader -> {loader}")
    return loader


# =====================================================================
# Plots
# =====================================================================
def save_plots(history, out_dir):
    if not HAS_MPL: return
    eps = range(1, len(history["train_acc"]) + 1)
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(12, 4))
    a1.plot(eps, history["train_loss"], label="Train")
    a1.plot(eps, history["test_loss"],  label="Test")
    a1.set(title="Loss", xlabel="Epoch"); a1.legend()
    a2.plot(eps, [x*100 for x in history["train_acc"]], label="Train")
    a2.plot(eps, [x*100 for x in history["test_acc"]],  label="Test")
    a2.set(title="Accuracy (%)", xlabel="Epoch"); a2.legend()
    plt.tight_layout()
    p = out_dir / "training_curves.png"
    plt.savefig(p, dpi=150); plt.close()
    print(f"[plot] {p}")


# =====================================================================
# CLI
# =====================================================================
def parse_args():
    p = argparse.ArgumentParser(
        description="NeuraEdge SNN training + weight export")
    p.add_argument("--epochs",     type=int,   default=20)
    p.add_argument("--batch-size", type=int,   default=256)
    p.add_argument("--lr",         type=float, default=5e-4)
    p.add_argument("--beta",       type=float, default=0.9)
    p.add_argument("--device",     default="auto",
                   choices=["auto","cpu","cuda","mps"])
    p.add_argument("--data-root",  default="./datasets")
    p.add_argument("--out-dir",    default="./benchmarks")
    p.add_argument("--checkpoint", default="./benchmarks/neuraedge_snn.pt")
    p.add_argument("--load-only",  action="store_true")
    p.add_argument("--no-export",  action="store_true")
    return p.parse_args()


def main():
    args    = parse_args()
    out_dir = Path(args.out_dir);  out_dir.mkdir(parents=True, exist_ok=True)
    ckpt    = Path(args.checkpoint)

    # device
    if args.device == "auto":
        device = (torch.device("cuda")  if torch.cuda.is_available() else
                  torch.device("mps")   if getattr(torch.backends,"mps",None)
                                           and torch.backends.mps.is_available()
                  else torch.device("cpu"))
    else:
        device = torch.device(args.device)

    sep = "=" * 56
    print(f"\n{sep}")
    print(f"  NeuraEdge SNN  -  N-MNIST training pipeline")
    print(sep)
    for k,v in [("Device",device),("Epochs",args.epochs),
                ("Batch",args.batch_size),("LR",args.lr),
                ("Beta",args.beta),("Input",INPUT_SIZE),
                ("Hidden",HIDDEN_SIZE),("Classes",NUM_CLASSES),
                ("Steps",NUM_STEPS)]:
        print(f"  {k:<10}: {v}")
    print(sep + "\n")

    model = NeuraEdgeSNN(beta=args.beta).to(device)
    n_p   = sum(p.numel() for p in model.parameters())
    print(f"[model] fc1={tuple(model.fc1.weight.shape)}  "
          f"fc2={tuple(model.fc2.weight.shape)}  "
          f"params={n_p:,}")

    if args.load_only:
        assert ckpt.exists(), f"Checkpoint not found: {ckpt}"
        model.load_state_dict(torch.load(ckpt, map_location=device))
        print(f"[model] Loaded: {ckpt}")

    else:
        train_dl, test_dl = load_nmnist(args.data_root, args.batch_size)
        opt  = torch.optim.Adam(model.parameters(), lr=args.lr)
        sched = torch.optim.lr_scheduler.CosineAnnealingLR(
                    opt, T_max=args.epochs, eta_min=1e-5)
        loss_fn = SF.ce_rate_loss()
        history = {k:[] for k in
                   ["train_loss","train_acc","test_loss","test_acc"]}
        best = 0.0;  t0 = time.time()

        print(f"{'─'*56}")
        for ep in range(1, args.epochs+1):
            trl, tra, sp = train_epoch(model, train_dl, opt, loss_fn,
                                       device, ep, args.epochs)
            tel, tea     = evaluate(model, test_dl, loss_fn, device)
            sched.step()
            [history[k].append(v) for k,v in
             zip(["train_loss","train_acc","test_loss","test_acc"],
                 [trl,tra,tel,tea])]
            mark = " ✓" if tea > best else ""
            print(f"  Ep {ep:02d}  tr={trl:.4f}/{tra:.4f}  "
                  f"te={tel:.4f}/{tea:.4f}  sp={sp:.3f}{mark}")
            if tea > best:
                best = tea
                torch.save(model.state_dict(), ckpt)

        print(f"{'─'*56}")
        print(f"[result] Best accuracy : {best*100:.2f}%  "
              f"(target 97.50%  "
              f"{'PASS' if best>=0.97 else 'needs more epochs'})")
        print(f"[result] Training time : {(time.time()-t0)/60:.1f} min")

        model.load_state_dict(torch.load(ckpt, map_location=device))
        measure_sparsity(model, test_dl, device)
        save_plots(history, out_dir)

        results = out_dir / "results_v2.csv"
        with open(results, "w") as f:
            f.write("epoch,train_loss,train_acc,test_loss,test_acc\n")
            for i,(a,b,c,d) in enumerate(zip(*history.values()),1):
                f.write(f"{i},{a:.6f},{b:.6f},{c:.6f},{d:.6f}\n")
        print(f"[results] {results}")

    if not args.no_export:
        fc1_q, fc2_q = export_weights(model, out_dir)
        generate_spi_loader(fc1_q, fc2_q, out_dir)

    print(f"\n{sep}")
    print(f"  Output files:  {out_dir.resolve()}")
    for fpath in sorted(out_dir.iterdir()):
        print(f"    {fpath.name:<38} {fpath.stat().st_size:>10,} B")
    print(sep + "\n")


if __name__ == "__main__":
    main()
