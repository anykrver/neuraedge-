#!/usr/bin/env python3
"""
benchmark.py — NeuraEdge Performance Benchmarking
==================================================

Measures and reports all primary NeuraEdge performance metrics:

  Metric             Unit         Method
  ─────────────────  ───────────  ──────────────────────────────────
  Spikes/second      M spikes/s   Parse simulation .log spike count
  Inference latency  ms           Time-steps × clock period
  Spike sparsity     %            Mean active neurons / time step
  NMNIST accuracy    %            Model forward pass on test set
  Weight sparsity    %            Fraction of near-zero weights
  Energy/inference   mJ           Estimated from spike count × cost/spike

Outputs:
  benchmarks/results_vX.csv  — machine-readable results
  benchmarks/results_vX.txt  — human-readable summary table
  Console table              — immediate printout

Usage:
  # Full benchmark (requires trained weights + simulation log):
  python software/benchmark.py

  # Model-only (no sim log needed):
  python software/benchmark.py --model-only

  # Parse a specific simulation log:
  python software/benchmark.py --sim-log simulation/neuron_core.log

  # Load specific weights:
  python software/benchmark.py --weights weights/best.pt

Author:   NeuraEdge / Rahul Verma
Version:  1.0.0
License:  Apache 2.0
"""

import argparse
import csv
import re
import sys
import time
from pathlib import Path
from datetime import datetime

import numpy as np
import torch

# ---- Optional imports (graceful degradation) ----------------
try:
    import snntorch as snn
    import snntorch.functional as SF
    HAS_SNNTORCH = True
except ImportError:
    HAS_SNNTORCH = False

try:
    import tonic
    from torch.utils.data import DataLoader
    HAS_TONIC = True
except ImportError:
    HAS_TONIC = False

try:
    from tqdm import tqdm
    HAS_TQDM = True
except ImportError:
    tqdm = lambda x, **kw: x  # noqa: E731
    HAS_TQDM = False


# ============================================================
# Hardware constants (must match RTL parameters)
# ============================================================
HW = dict(
    CLK_MHZ       = 100,          # FPGA clock frequency
    NUM_NEURONS   = 64,           # neurons per cluster
    NUM_CLUSTERS  = 4,            # NUM_COLS × NUM_ROWS
    ENERGY_PJ_SPIKE = 8.5,       # rough ASIC estimate only — NOT measured on this hardware
                                 # (Vivado power.rpt: 0.448W dynamic at 100MHz; per-spike figure
                                 #  depends on activity factor and is ~10-100x higher on FPGA)
    ENERGY_PJ_LEAK  = 0.2,       # pJ per neuron per cycle (quiescent)
)

CLK_NS      = 1000 / HW["CLK_MHZ"]   # 10 ns per cycle
CLK_MS      = CLK_NS / 1e6           # seconds per cycle

N_INPUT     = 34 * 34 * 2            # 2312
N_HIDDEN    = 512
N_OUTPUT    = 10
NUM_STEPS   = 25                      # default SNN time steps


# ============================================================
# 1. Simulation log parser
# ============================================================

def parse_spike_log(log_path: str) -> dict:
    """
    Parse a Verilator simulation log for spike events.

    Expected format (from tb_neuron_core.cpp):
      SPIKE at t=<integer>

    Returns dict with:
      spike_count   — total spikes observed
      sim_ns        — total simulation time (ns)
      spikes_per_sec — computed rate
    """
    log_path = Path(log_path)
    if not log_path.exists():
        return {"error": f"Log not found: {log_path}"}

    spike_times = []
    with open(log_path) as f:
        for line in f:
            m = re.search(r"SPIKE\s+at\s+t=(\d+)", line)
            if m:
                spike_times.append(int(m.group(1)))

    if len(spike_times) < 2:
        return {
            "spike_count": len(spike_times),
            "sim_ns": 0,
            "spikes_per_sec": 0,
        }

    sim_ns = spike_times[-1] - spike_times[0]
    if sim_ns == 0:
        return {"spike_count": len(spike_times), "sim_ns": 0, "spikes_per_sec": 0}

    rate = len(spike_times) / (sim_ns * 1e-9)

    return {
        "spike_count":    len(spike_times),
        "sim_ns":         sim_ns,
        "spikes_per_sec": rate,
        "spikes_per_sec_M": rate / 1e6,
    }


# ============================================================
# 2. Model-based metrics (accuracy + sparsity)
# ============================================================

def compute_model_metrics(
    model,
    test_loader,
    device: torch.device,
    num_steps: int = NUM_STEPS,
) -> dict:
    """Compute test accuracy, inference latency, and spike sparsity."""

    if not HAS_SNNTORCH:
        return {"error": "snntorch not installed"}

    model.eval()
    correct     = 0
    total       = 0
    total_spikes = 0
    total_units  = 0
    latencies    = []

    with torch.no_grad():
        for data, targets in tqdm(test_loader, desc="Benchmarking",
                                   leave=False, unit="batch"):
            data    = data.permute(1, 0, 2, 3, 4).to(device)
            targets = targets.to(device)

            t0 = time.perf_counter()
            spk_out, _ = model(data, num_steps=num_steps)
            t1 = time.perf_counter()

            latencies.append((t1 - t0) / targets.size(0) * 1000)  # ms/sample

            pred    = spk_out.sum(0).argmax(1)
            correct += (pred == targets).sum().item()
            total   += targets.size(0)

            total_spikes += spk_out.sum().item()
            T, B, N = spk_out.shape
            total_units  += T * B * N

    accuracy    = 100.0 * correct / total
    sparsity    = 100.0 * total_spikes / total_units
    latency_ms  = float(np.mean(latencies))

    # Hardware-equivalent latency: num_steps × clk_period
    hw_latency_ms = num_steps * CLK_NS / 1e6

    return {
        "accuracy_pct":     accuracy,
        "sparsity_pct":     sparsity,
        "sw_latency_ms":    latency_ms,
        "hw_latency_ms":    hw_latency_ms,
        "total_spikes":     int(total_spikes),
        "total_samples":    total,
    }


# ============================================================
# 3. Weight analysis
# ============================================================

def analyse_weights(model) -> dict:
    """Compute weight statistics and sparsity."""
    fc1 = model.fc1.weight.detach().float().cpu().numpy().flatten()
    fc2 = model.fc2.weight.detach().float().cpu().numpy().flatten()
    all_w = np.concatenate([fc1, fc2])

    near_zero   = np.abs(all_w) < 0.01
    w_sparsity  = 100.0 * near_zero.sum() / len(all_w)

    return {
        "total_weights":  len(all_w),
        "weight_min":     float(all_w.min()),
        "weight_max":     float(all_w.max()),
        "weight_mean":    float(all_w.mean()),
        "weight_std":     float(all_w.std()),
        "weight_sparsity_pct": w_sparsity,
        "fc1_l1_norm":    float(np.abs(fc1).mean()),
        "fc2_l1_norm":    float(np.abs(fc2).mean()),
    }


# ============================================================
# 4. Energy estimate
# ============================================================

def estimate_energy(
    spike_metrics: dict,
    model_metrics: dict,
    num_steps:     int = NUM_STEPS,
) -> dict:
    """
    Estimate energy per inference on FPGA hardware.

    Model:
      E_spike   = N_spikes × energy_per_spike (pJ)
      E_quiesc  = N_neurons × N_steps × energy_per_leak (pJ)
      E_total   = E_spike + E_quiesc

    Reference: Loihi 2 ~ 1 nJ/spike, TrueNorth ~26 pJ/synaptic op.
    NeuraEdge Artix-7 estimate: ~8.5 pJ/spike (from Vivado power report).
    """
    if "error" in model_metrics:
        return {"error": "Model metrics unavailable"}

    total_neurons = HW["NUM_NEURONS"] * HW["NUM_CLUSTERS"]
    spikes_per_inf = model_metrics["total_spikes"] / max(1, model_metrics["total_samples"])

    e_spike_pj  = spikes_per_inf * HW["ENERGY_PJ_SPIKE"]
    e_quiesc_pj = total_neurons  * num_steps * HW["ENERGY_PJ_LEAK"]
    e_total_pj  = e_spike_pj + e_quiesc_pj
    e_total_nj  = e_total_pj / 1000.0
    e_total_uw  = e_total_nj / (model_metrics["hw_latency_ms"] * 1e-3) * 1e-3

    return {
        "spikes_per_inference": spikes_per_inf,
        "energy_spike_pJ":     e_spike_pj,
        "energy_quiesc_pJ":    e_quiesc_pj,
        "energy_total_pJ":     e_total_pj,
        "energy_total_nJ":     e_total_nj,
        "avg_power_uW":        e_total_uw,
    }


# ============================================================
# 5. Report formatting
# ============================================================

SEPARATOR = "=" * 60

def print_report(
    sim:    dict,
    model:  dict,
    weight: dict,
    energy: dict,
    version: str,
):
    print(f"\n{SEPARATOR}")
    print(f" NeuraEdge Benchmark Report  {version}")
    print(f"{SEPARATOR}\n")

    print("── Simulation (Verilator) ──────────────────────────")
    if "error" in sim:
        print(f"  {sim['error']}")
    else:
        print(f"  Spikes observed:    {sim['spike_count']:,}")
        print(f"  Simulation time:    {sim['sim_ns']:,} ns")
        print(f"  Spike rate:         {sim.get('spikes_per_sec_M', 0):.2f} M spikes/sec")

    print("\n── Model (Python/snnTorch) ─────────────────────────")
    if "error" in model:
        print(f"  {model['error']}")
    else:
        print(f"  Test accuracy:      {model['accuracy_pct']:.2f}%")
        print(f"  Spike sparsity:     {model['sparsity_pct']:.2f}%")
        print(f"  SW latency:         {model['sw_latency_ms']:.2f} ms/sample")
        print(f"  HW latency (est.):  {model['hw_latency_ms']:.3f} ms  "
              f"({NUM_STEPS} steps × {CLK_NS:.0f} ns)")

    print("\n── Weights ─────────────────────────────────────────")
    if "error" not in weight:
        print(f"  Total weights:      {weight['total_weights']:,}")
        print(f"  Range:              [{weight['weight_min']:.4f}, {weight['weight_max']:.4f}]")
        print(f"  Mean ± std:         {weight['weight_mean']:.4f} ± {weight['weight_std']:.4f}")
        print(f"  Weight sparsity:    {weight['weight_sparsity_pct']:.1f}%  (|w| < 0.01)")

    print("\n── Energy (FPGA estimate, Artix-7) ─────────────────")
    if "error" not in energy:
        print(f"  Spikes/inference:   {energy['spikes_per_inference']:.1f}")
        print(f"  Spike energy:       {energy['energy_spike_pJ']:.1f} pJ")
        print(f"  Quiescent energy:   {energy['energy_quiesc_pJ']:.1f} pJ")
        print(f"  Total energy:       {energy['energy_total_nJ']:.3f} nJ/inference")
        print(f"  Avg power (est.):   {energy['avg_power_uW']:.1f} µW")

    print(f"\n{SEPARATOR}")
    print(" Targets vs. Actuals")
    print(f"{SEPARATOR}")

    def row(name, target, actual, unit, hi_is_good=True):
        if actual is None:
            status = "—"
        else:
            status = "✓" if (actual >= target if hi_is_good else actual <= target) else "✗"
        print(f"  {name:<22} target: {target:>8} {unit:<12}"
              f"actual: {actual if actual is not None else 'n/a'!s:>8} {unit:<12}  {status}")

    acc    = model.get("accuracy_pct")
    sparse = model.get("sparsity_pct")
    lat    = model.get("hw_latency_ms")
    rate   = sim.get("spikes_per_sec_M")
    pwr    = energy.get("avg_power_uW")

    row("Test accuracy",    95.0,  round(acc, 2) if acc else None,    "%")
    row("Spike sparsity",    5.0,  round(sparse, 2) if sparse else None, "%",  hi_is_good=False)
    row("HW latency",       10.0,  round(lat, 3) if lat else None,    "ms",   hi_is_good=False)
    row("Spike rate",        1.0,  round(rate, 2) if rate else None,  "M/s")
    row("Avg power",       100.0,  round(pwr, 1) if pwr else None,    "µW",   hi_is_good=False)

    print()


def save_csv(
    sim:    dict,
    model:  dict,
    weight: dict,
    energy: dict,
    version: str,
    out_dir: Path,
):
    out_dir.mkdir(parents=True, exist_ok=True)
    csv_path = out_dir / f"results_{version}.csv"

    rows = [
        ["metric",              "value",  "unit"],
        ["accuracy",            model.get("accuracy_pct", ""),     "%"],
        ["sparsity",            model.get("sparsity_pct", ""),     "%"],
        ["hw_latency",          model.get("hw_latency_ms", ""),    "ms"],
        ["sw_latency",          model.get("sw_latency_ms", ""),    "ms"],
        ["spike_rate_sim",      sim.get("spikes_per_sec_M", ""),   "M/s"],
        ["spike_count_sim",     sim.get("spike_count", ""),        ""],
        ["total_weights",       weight.get("total_weights", ""),   ""],
        ["weight_sparsity",     weight.get("weight_sparsity_pct",""), "%"],
        ["energy_nJ",           energy.get("energy_total_nJ", ""),"nJ"],
        ["avg_power_uW",        energy.get("avg_power_uW", ""),    "µW"],
        ["spikes_per_inference",energy.get("spikes_per_inference",""),""],
        ["timestamp",           datetime.now().isoformat(),        ""],
    ]

    with open(csv_path, "w", newline="") as f:
        csv.writer(f).writerows(rows)

    print(f"Results CSV: {csv_path}")
    return csv_path


# ============================================================
# Main
# ============================================================

def parse_args():
    p = argparse.ArgumentParser(
        description="NeuraEdge performance benchmark",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--weights",     default="weights/best.pt",
                   help="Path to trained .pt checkpoint")
    p.add_argument("--sim-log",     default="simulation/neuron_core.log",
                   help="Verilator simulation log with SPIKE events")
    p.add_argument("--data-dir",    default="datasets/nmnist")
    p.add_argument("--output-dir",  default="benchmarks")
    p.add_argument("--version",     default="v2",
                   help="Version tag for output filenames")
    p.add_argument("--batch-size",  type=int, default=256)
    p.add_argument("--num-steps",   type=int, default=25)
    p.add_argument("--model-only",  action="store_true",
                   help="Skip sim log parsing")
    p.add_argument("--no-cuda",     action="store_true")
    return p.parse_args()


def main():
    args   = parse_args()
    device = torch.device(
        "cuda" if torch.cuda.is_available() and not args.no_cuda else "cpu"
    )
    out_dir = Path(args.output_dir)

    print(f"\n{'='*60}")
    print(f" NeuraEdge Benchmark  version={args.version}")
    print(f" Device: {device}")
    print(f"{'='*60}\n")

    # ---- 1. Parse simulation log ----------------------------
    sim_metrics = {}
    if not args.model_only:
        print(f"Parsing simulation log: {args.sim_log}")
        sim_metrics = parse_spike_log(args.sim_log)
        if "error" not in sim_metrics:
            print(f"  Spikes: {sim_metrics['spike_count']:,}  "
                  f"Rate: {sim_metrics.get('spikes_per_sec_M', 0):.2f} M/s")
    else:
        sim_metrics = {"note": "model-only mode"}

    # ---- 2. Load model + test data --------------------------
    model_metrics  = {}
    weight_metrics = {}
    energy_metrics = {}

    if HAS_SNNTORCH and HAS_TONIC:
        weights_path = Path(args.weights)
        if weights_path.exists():
            print(f"\nLoading model: {weights_path}")

            # Import model class from training script
            sys.path.insert(0, str(Path(__file__).parent))
            try:
                from train_nmnist import (
                    NeuraEdgeSNN,
                    make_nmnist_transform,
                )
                model = NeuraEdgeSNN(beta=0.5, threshold=1.0, dropout=0.0)
                ckpt  = torch.load(weights_path, map_location=device)
                model.load_state_dict(ckpt["model_state_dict"])
                model = model.to(device)
                print(f"  Best accuracy (from ckpt): "
                      f"{ckpt.get('best_acc', '?'):.2f}%")

                # Test dataset
                transform   = make_nmnist_transform(args.num_steps)
                test_ds     = tonic.datasets.NMNIST(
                    save_to=args.data_dir, train=False, transform=transform)
                test_loader = DataLoader(
                    test_ds, batch_size=args.batch_size,
                    shuffle=False, num_workers=4)

                print("\nRunning model evaluation ...")
                model_metrics  = compute_model_metrics(
                    model, test_loader, device, args.num_steps)
                weight_metrics = analyse_weights(model)
                energy_metrics = estimate_energy(
                    sim_metrics, model_metrics, args.num_steps)

            except Exception as e:
                print(f"  Warning: model evaluation failed — {e}")
                model_metrics = {"error": str(e)}
        else:
            print(f"\nNo weights found at {weights_path}")
            print("  Run train_nmnist.py first, or pass --weights PATH")
            model_metrics = {"error": f"Weights not found: {weights_path}"}
    else:
        missing = []
        if not HAS_SNNTORCH: missing.append("snntorch")
        if not HAS_TONIC:    missing.append("tonic")
        model_metrics = {"error": f"Missing: {', '.join(missing)}"}

    # ---- 3. Report ------------------------------------------
    print_report(sim_metrics, model_metrics, weight_metrics,
                 energy_metrics, args.version)
    save_csv(sim_metrics, model_metrics, weight_metrics,
             energy_metrics, args.version, out_dir)


if __name__ == "__main__":
    main()
