#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
P2a_select_k.py
============================================================
Per-dataset K-value selection (fan-in by dataset).

Split from P2_density_calculation.py (original stages 0+1, lines
408-573).  The scientific logic — K_CANDIDATES, the three elbow
detectors (2nd-diff / piecewise / max-distance), the sorted() K
reordering, the CV computation — is carried over VERBATIM; only CLI
parameter parsing, loop boundaries and output paths changed.

Usage (SPEC v2 §3.1):
  python P2a_select_k.py --dataset <Name> --metadata-list <manifest> --outdir .

  --dataset <Name>          dataset to select K for
  --registry <path>         sample_registry.json (default: $DATA_DIR)
  --metadata-list <path>    manifest: one cell_metadata.csv path per line
                            (overrides --indir; used in Nextflow work dir)
  --indir <path>            P1 results root (default: $RESULTS_DIR/P1_Results)
  --outdir <path>           output directory (flat; default: $RESULTS_DIR/P2_Results)
  --kfile-out <path>        k_selection.json output path (default: <outdir>/k_selection.json)
============================================================
"""

import argparse
import json
import os
import sys
import warnings

import numpy as np
import pandas as pd
from sklearn.neighbors import NearestNeighbors
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.gridspec import GridSpec

warnings.filterwarnings("ignore", category=RuntimeWarning)

# --- constants carried verbatim from P2_density_calculation.py ---
K_CANDIDATES = [5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 30, 35, 40, 45, 50]

BIO_SCALES = [
    (0, 10, "sub-cellular"),
    (10, 30, "direct contact (juxtacrine)"),
    (30, 200, "paracrine signaling"),
    (200, 1000, "tissue-level architecture"),
    (1000, float("inf"), "macro-scale"),
]


# --- functions carried verbatim ---

def classify_bio_scale(distance_um):
    for lo, hi, label in BIO_SCALES:
        if lo <= distance_um < hi:
            return label
    return "unknown"


def find_k_2nd_diff(cv_values, k_candidates):
    if len(cv_values) < 3:
        return k_candidates[0]
    first_diff = np.diff(cv_values)
    second_diff = np.diff(first_diff)
    idx = np.argmax(np.abs(second_diff))
    return k_candidates[idx + 1]


def find_k_piecewise(cv_values, k_candidates):
    k_arr = np.array(k_candidates, dtype=float)
    cv_arr = np.array(cv_values, dtype=float)
    n = len(k_arr)
    if n < 4:
        return k_candidates[n // 2]
    best_break = 2
    best_error = float("inf")
    for bp in range(2, n - 1):
        x_left = k_arr[:bp + 1]
        y_left = cv_arr[:bp + 1]
        if len(x_left) >= 2:
            coef_left = np.polyfit(x_left, y_left, 1)
            pred_left = np.polyval(coef_left, x_left)
            err_left = np.sum((y_left - pred_left) ** 2)
        else:
            err_left = 0
        x_right = k_arr[bp:]
        y_right = cv_arr[bp:]
        if len(x_right) >= 2:
            coef_right = np.polyfit(x_right, y_right, 1)
            pred_right = np.polyval(coef_right, x_right)
            err_right = np.sum((y_right - pred_right) ** 2)
        else:
            err_right = 0
        total_error = err_left + err_right
        if total_error < best_error:
            best_error = total_error
            best_break = bp
    return k_candidates[best_break]


def find_k_max_distance(cv_values, k_candidates):
    k_arr = np.array(k_candidates, dtype=float)
    cv_arr = np.array(cv_values, dtype=float)
    k_norm = (k_arr - k_arr.min()) / (k_arr.max() - k_arr.min() + 1e-12)
    cv_norm = (cv_arr - cv_arr.min()) / (cv_arr.max() - cv_arr.min() + 1e-12)
    distances = np.abs(k_norm + cv_norm - 1.0) / np.sqrt(2.0)
    idx = np.argmax(distances)
    return k_candidates[idx]


def plot_k_optimization(dataset_name, k_candidates, sample_cv_data,
                        mean_cv, k_aggr, k_main, k_cons, save_path):
    """绘制K值优化诊断图（四面板）— verbatim from P2"""
    fig = plt.figure(figsize=(20, 14))
    gs = GridSpec(2, 2, figure=fig, hspace=0.3, wspace=0.3)
    ax1 = fig.add_subplot(gs[0, 0])
    for sample_name, cv_vals in sample_cv_data.items():
        ax1.plot(k_candidates, cv_vals, "o-", alpha=0.3, markersize=3,
                 label=sample_name if len(sample_cv_data) <= 7 else None)
    ax1.plot(k_candidates, mean_cv, "k-", linewidth=2.5, label="Mean CV", zorder=10)
    ax1.axvline(k_aggr, color="red", linestyle="--", linewidth=1.5,
                label=f"2nd_diff K={k_aggr}")
    ax1.axvline(k_main, color="blue", linestyle="-", linewidth=2,
                label=f"Piecewise K={k_main}")
    ax1.axvline(k_cons, color="green", linestyle="--", linewidth=1.5,
                label=f"Max_dist K={k_cons}")
    ax1.set_xlabel("K value", fontsize=12)
    ax1.set_ylabel("CV (Coefficient of Variation)", fontsize=12)
    ax1.set_title(f"{dataset_name}: CV vs K", fontsize=14)
    ax1.legend(fontsize=8, loc="upper right")
    ax1.grid(True, alpha=0.3)
    ax2 = fig.add_subplot(gs[0, 1])
    ax2.set_xlabel("K value", fontsize=12)
    ax2.set_ylabel("Median k-th NN distance (µm)", fontsize=12)
    ax2.set_title(f"{dataset_name}: Physical Distance vs K", fontsize=14)
    ax2.text(0.5, 0.5, "See distance data in\nk_decision_table.csv",
             transform=ax2.transAxes, ha="center", va="center", fontsize=12, alpha=0.5)
    ax2.grid(True, alpha=0.3)
    ax3 = fig.add_subplot(gs[1, 0])
    first_diff = np.diff(mean_cv)
    k_mid = [(k_candidates[i] + k_candidates[i + 1]) / 2 for i in range(len(first_diff))]
    colors3 = ["red" if k_candidates[i + 1] == k_aggr else
               "blue" if k_candidates[i + 1] == k_main else
               "green" if k_candidates[i + 1] == k_cons else "gray"
               for i in range(len(first_diff))]
    ax3.bar(k_mid, first_diff, width=1.5, color=colors3, alpha=0.7)
    ax3.set_xlabel("K value (midpoint)", fontsize=12)
    ax3.set_ylabel("1st order difference (ΔCV)", fontsize=12)
    ax3.set_title(f"{dataset_name}: First Derivative of CV", fontsize=14)
    ax3.axhline(0, color="black", linewidth=0.5)
    ax3.grid(True, alpha=0.3)
    ax4 = fig.add_subplot(gs[1, 1])
    second_diff = np.diff(first_diff)
    k_mid2 = [(k_candidates[i + 1] + k_candidates[i + 2]) / 2
              for i in range(len(second_diff))]
    colors4 = ["red" if k_candidates[i + 1] == k_aggr else
               "blue" if k_candidates[i + 1] == k_main else
               "green" if k_candidates[i + 1] == k_cons else "gray"
               for i in range(len(second_diff))]
    ax4.bar(k_mid2, np.abs(second_diff), width=1.5, color=colors4, alpha=0.7)
    ax4.set_xlabel("K value (midpoint)", fontsize=12)
    ax4.set_ylabel("|2nd order difference|", fontsize=12)
    ax4.set_title(f"{dataset_name}: Second Derivative of CV (absolute)", fontsize=14)
    ax4.grid(True, alpha=0.3)
    plt.suptitle(f"K-value Optimization: {dataset_name}", fontsize=16, fontweight="bold", y=0.98)
    plt.savefig(save_path, dpi=150, bbox_inches="tight")
    plt.close()


def main():
    ap = argparse.ArgumentParser(description="P2a: per-dataset K-value selection")
    ap.add_argument("--dataset", required=True,
                    help="dataset name (e.g. Medulloblastoma_Human)")
    ap.add_argument("--registry", default=None,
                    help="sample_registry.json (default: $DATA_DIR)")
    ap.add_argument("--metadata-list", default=None,
                    help="manifest of cell_metadata.csv paths, one per line "
                         "(overrides --indir for Nextflow work-dir consumption)")
    ap.add_argument("--indir", default=None,
                    help="P1 results root (default: $RESULTS_DIR/P1_Results)")
    ap.add_argument("--outdir", required=True,
                    help="output directory, flat (required: per-dataset, "
                         "must not default to shared root to avoid clobbering)")
    ap.add_argument("--kfile-out", default=None,
                    help="k_selection.json path (default: <outdir>/k_selection.json)")
    args = ap.parse_args()

    # --- path resolution (SPEC v2 §2; Q2: defaults preserve P2's behaviour) ---
    data_dir = os.environ.get("DATA_DIR", "./data")
    results_dir = os.environ.get("RESULTS_DIR", "./results")
    registry_path = args.registry or os.path.join(data_dir, "sample_registry.json")
    p1_dir = args.indir or os.path.join(results_dir, "P1_Results")
    p2_dir = args.outdir
    kfile_out = args.kfile_out or os.path.join(p2_dir, "k_selection.json")

    with open(registry_path, "r") as f:
        registry = json.load(f)

    # filter to the requested dataset (P2 stage 0 grouping, verbatim logic)
    sample_list = [s for s in registry if s.split("/")[0] == args.dataset]
    if not sample_list:
        print(f"  ✗ dataset '{args.dataset}' not in registry\n")
        sys.exit(1)

    # --- resolve cell_metadata paths: explicit manifest or nested derivation ---
    if args.metadata_list:
        # two-column keyed format: Dataset/Subname<TAB>path (same as
        # P1c/R07-R09 manifest; Nextflow task completion order is not
        # guaranteed, so we pair by key, not by position)
        with open(args.metadata_list, "r", encoding="utf-8-sig") as f:
            manifest_map = {}
            for line in f:
                line = line.strip()
                if not line:
                    continue
                parts = line.split("\t")
                if len(parts) != 2:
                    print(f"  ✗ --metadata-list line malformed "
                          f"(need TAB-separated): {line}")
                    sys.exit(1)
                manifest_map[parts[0]] = parts[1]
        # validate: every sample in this dataset must have a manifest entry,
        # and no foreign keys allowed
        sample_set = set(sample_list)
        foreign = set(manifest_map) - sample_set
        if foreign:
            print(f"  ✗ --metadata-list contains keys not in dataset "
                  f"'{args.dataset}': {sorted(foreign)}\n")
            sys.exit(1)
        missing_keys = sample_set - set(manifest_map)
        if missing_keys:
            print(f"  ✗ --metadata-list missing entries for: "
                  f"{sorted(missing_keys)}\n")
            sys.exit(1)
        meta_paths = [manifest_map[s] for s in sample_list]
    else:
        meta_paths = [
            os.path.join(p1_dir, s.split("/")[0], s.split("/")[1], "cell_metadata.csv")
            for s in sample_list
        ]

    print("=" * 70)
    print(f"P2a: K值选择 — {args.dataset} ({len(sample_list)} 个样本)")
    print("=" * 70)

    os.makedirs(p2_dir, exist_ok=True)

    # --- stage 1: scan CV across K candidates (verbatim from P2 L436-474) ---
    sample_cv_dict = {}
    sample_dist_dict = {}

    for idx, sample_name in enumerate(sample_list):
        meta_path = meta_paths[idx]
        df = pd.read_csv(meta_path)
        coords = df[["x_centroid", "y_centroid"]].values
        n_cells = len(coords)

        k_max = max(K_CANDIDATES)
        nn = NearestNeighbors(n_neighbors=k_max + 1, algorithm="ball_tree")
        nn.fit(coords)
        distances, _ = nn.kneighbors(coords)

        cv_list = []
        dist_list = []
        for k in K_CANDIDATES:
            dist_k = distances[:, k]
            dist_k_safe = dist_k.copy()
            dist_k_safe[dist_k_safe == 0] = np.finfo(float).eps
            density_k = 1.0 / dist_k_safe
            cv = np.std(density_k) / np.mean(density_k) if np.mean(density_k) > 0 else 0
            median_dist = np.median(dist_k)
            cv_list.append(cv)
            dist_list.append(median_dist)

        sample_cv_dict[sample_name] = cv_list
        sample_dist_dict[sample_name] = dist_list
        print(f"  扫描完成: {sample_name} ({n_cells} cells)")

    # cross-sample mean CV (verbatim L477-482)
    cv_matrix = np.array(list(sample_cv_dict.values()))
    mean_cv = np.mean(cv_matrix, axis=0)
    dist_matrix = np.array(list(sample_dist_dict.values()))
    mean_dist = np.mean(dist_matrix, axis=0)

    # three-method K selection (verbatim L485-492, including sorted() reordering)
    k_aggr = find_k_2nd_diff(mean_cv, K_CANDIDATES)
    k_main = find_k_piecewise(mean_cv, K_CANDIDATES)
    k_cons = find_k_max_distance(mean_cv, K_CANDIDATES)
    k_sorted = sorted([k_aggr, k_main, k_cons])
    k_aggr, k_main, k_cons = k_sorted[0], k_sorted[1], k_sorted[2]

    idx_aggr = K_CANDIDATES.index(k_aggr)
    idx_main = K_CANDIDATES.index(k_main)
    idx_cons = K_CANDIDATES.index(k_cons)
    dist_aggr = mean_dist[idx_aggr]
    dist_main = mean_dist[idx_main]
    dist_cons = mean_dist[idx_cons]
    bio_aggr = classify_bio_scale(dist_aggr)
    bio_main = classify_bio_scale(dist_main)
    bio_cons = classify_bio_scale(dist_cons)

    # k_selection.json — aligns with original P2 dataset_k_decisions
    # (SPEC §3.1 example is illustrative, not the full contract; the
    # original 11-column ALL_DATASETS_K_SELECTION.csv is authoritative)
    k_decision = {
        "dataset": args.dataset,
        "k_aggr_2nd_diff": k_aggr,
        "k_main_piecewise": k_main,
        "k_cons_max_dist": k_cons,
        "dist_aggr_um": round(dist_aggr, 1),
        "dist_main_um": round(dist_main, 1),
        "dist_cons_um": round(dist_cons, 1),
        "bio_scale_aggr": bio_aggr,
        "bio_scale_main": bio_main,
        "bio_scale_cons": bio_cons,
        "n_samples": len(sample_list),
        "generated_by": "P2a",
    }
    with open(kfile_out, "w", encoding="utf-8") as f:
        json.dump(k_decision, f, indent=2)
        f.write("\n")

    print(f"\n  K值选择结果:")
    print(f"    Aggressive (2nd_diff):   K={k_aggr:3d}  →  {dist_aggr:.1f} µm  [{bio_aggr}]")
    print(f"    Main (piecewise):        K={k_main:3d}  →  {dist_main:.1f} µm  [{bio_main}]")
    print(f"    Conservative (max_dist): K={k_cons:3d}  →  {dist_cons:.1f} µm  [{bio_cons}]")
    print(f"  k_selection.json: {kfile_out}")

    # k_decision_table.csv (verbatim L526-540) — flat to --outdir
    k_table_rows = []
    for i, k in enumerate(K_CANDIDATES):
        row = {
            "K": k,
            "mean_CV": round(mean_cv[i], 6),
            "std_CV": round(np.std(cv_matrix[:, i]), 6),
            "mean_median_distance_um": round(mean_dist[i], 2),
            "is_aggr_2nd_diff": k == k_aggr,
            "is_main_piecewise": k == k_main,
            "is_cons_max_dist": k == k_cons,
        }
        k_table_rows.append(row)
    pd.DataFrame(k_table_rows).to_csv(
        os.path.join(p2_dir, "k_decision_table.csv"), index=False)

    # all_samples_knn_cv.csv (verbatim L543-549) — flat to --outdir
    cv_save = {"K": K_CANDIDATES}
    for sn, cv_vals in sample_cv_dict.items():
        cv_save[sn] = cv_vals
    cv_save["mean"] = mean_cv.tolist()
    pd.DataFrame(cv_save).to_csv(
        os.path.join(p2_dir, "all_samples_knn_cv.csv"), index=False)

    # diagnostic plot (verbatim L552-556) — flat to --outdir
    plot_k_optimization(
        args.dataset, K_CANDIDATES, sample_cv_dict,
        mean_cv, k_aggr, k_main, k_cons,
        os.path.join(p2_dir, "k_optimization_diagnostic.png"))

    print(f"\nP2a 完成: {args.dataset}")


if __name__ == "__main__":
    main()
