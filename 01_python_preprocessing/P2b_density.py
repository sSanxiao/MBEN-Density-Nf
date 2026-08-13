#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
P2b_density.py
============================================================
Per-sample 5-estimator density computation (fan-out by sample).

Split from P2_density_calculation.py (original stage 2, lines
606-742).  The scientific logic — Voronoi/Delaunay density, KNN
density via BallTree, 5x5 Spearman correlation matrix, the NaN
truncation at the 1st percentile — is carried over VERBATIM; only
CLI parameter parsing, loop boundaries and output paths changed.

Usage (SPEC v2 §3.1):
  python P2b_density.py --sample <Dataset/Subname> --kfile k_selection.json --outdir .

  --sample <Dataset/Subname>  sample to process
  --registry <path>           sample_registry.json (default: $DATA_DIR)
  --kfile <path>              k_selection.json from P2a
  --indir <path>              P1 results root (default: $RESULTS_DIR/P1_Results)
  --outdir <path>             output root (default: $RESULTS_DIR/P2_Results)
============================================================
"""

import argparse
import json
import os
import sys
import time
import warnings

import numpy as np
import pandas as pd
from scipy.spatial import Voronoi, Delaunay
from scipy.stats import spearmanr
from sklearn.neighbors import NearestNeighbors
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.gridspec import GridSpec

warnings.filterwarnings("ignore", category=RuntimeWarning)


# --- functions carried verbatim from P2_density_calculation.py ---

def compute_voronoi_density(coords):
    """计算Voronoi密度 — verbatim from P2"""
    n = len(coords)
    density = np.full(n, np.nan)
    if n < 4:
        return density
    try:
        vor = Voronoi(coords)
    except Exception:
        return density
    for i in range(n):
        region_idx = vor.point_region[i]
        region = vor.regions[region_idx]
        if -1 in region or len(region) == 0:
            continue
        vertices = vor.vertices[region]
        x = vertices[:, 0]
        y = vertices[:, 1]
        area = 0.5 * np.abs(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1)))
        if area > 0:
            density[i] = 1.0 / area
    valid = density[~np.isnan(density)]
    if len(valid) > 0:
        p1 = np.percentile(valid, 1)
        density[density < p1] = np.nan
    return density


def compute_delaunay_density(coords):
    """计算Delaunay密度 — verbatim from P2"""
    n = len(coords)
    density = np.full(n, np.nan)
    if n < 4:
        return density
    try:
        tri = Delaunay(coords)
    except Exception:
        return density
    neighbor_distances = [[] for _ in range(n)]
    simplices = tri.simplices
    for simplex in simplices:
        for i in range(3):
            for j in range(i + 1, 3):
                pi, pj = simplex[i], simplex[j]
                dist = np.linalg.norm(coords[pi] - coords[pj])
                neighbor_distances[pi].append(dist)
                neighbor_distances[pj].append(dist)
    for i in range(n):
        if len(neighbor_distances[i]) > 0:
            mean_dist = np.mean(neighbor_distances[i])
            if mean_dist > 0:
                density[i] = 1.0 / mean_dist
    valid = density[~np.isnan(density)]
    if len(valid) > 0:
        p1 = np.percentile(valid, 1)
        density[density < p1] = np.nan
    return density


def plot_density_diagnostics(sample_name, coords, densities, method_names,
                             corr_matrix, save_path):
    """绘制样本密度诊断图 — verbatim from P2"""
    n_methods = len(method_names)
    fig = plt.figure(figsize=(4 * n_methods + 4, 10))
    gs = GridSpec(2, n_methods + 1, figure=fig, hspace=0.35, wspace=0.3)
    for i, (name, dens) in enumerate(zip(method_names, densities)):
        ax = fig.add_subplot(gs[0, i])
        valid = ~np.isnan(dens)
        if valid.sum() > 0:
            log_dens = np.log10(dens[valid] + 1e-20)
            vmin, vmax = np.percentile(log_dens, [2, 98])
            sc = ax.scatter(coords[valid, 0], coords[valid, 1],
                            c=log_dens, cmap="viridis", s=0.1, alpha=0.5,
                            vmin=vmin, vmax=vmax, rasterized=True)
            plt.colorbar(sc, ax=ax, shrink=0.6, label="log10(density)")
        ax.set_title(name, fontsize=9)
        ax.set_aspect("equal")
        ax.tick_params(labelsize=6)
    for i, (name, dens) in enumerate(zip(method_names, densities)):
        ax = fig.add_subplot(gs[1, i])
        valid = dens[~np.isnan(dens)]
        if len(valid) > 0:
            log_valid = np.log10(valid + 1e-20)
            ax.hist(log_valid, bins=50, color="steelblue", alpha=0.7, edgecolor="none")
        ax.set_xlabel("log10(density)", fontsize=8)
        ax.set_ylabel("Count", fontsize=8)
        ax.set_title(f"{name}\nN_valid={np.sum(~np.isnan(dens))}", fontsize=8)
        ax.tick_params(labelsize=6)
    ax_corr = fig.add_subplot(gs[1, n_methods])
    im = ax_corr.imshow(corr_matrix, cmap="RdYlGn", vmin=0.5, vmax=1.0)
    ax_corr.set_xticks(range(n_methods))
    ax_corr.set_yticks(range(n_methods))
    short_names = [n.replace("density_", "").replace("knn_", "K_") for n in method_names]
    ax_corr.set_xticklabels(short_names, fontsize=6, rotation=45, ha="right")
    ax_corr.set_yticklabels(short_names, fontsize=6)
    for ii in range(n_methods):
        for jj in range(n_methods):
            ax_corr.text(jj, ii, f"{corr_matrix[ii, jj]:.3f}",
                         ha="center", va="center", fontsize=6,
                         color="black" if corr_matrix[ii, jj] > 0.7 else "white")
    plt.colorbar(im, ax=ax_corr, shrink=0.6, label="Spearman ρ")
    ax_corr.set_title("Method correlation", fontsize=9)
    plt.suptitle(f"Density Diagnostics: {sample_name}", fontsize=13, fontweight="bold", y=0.99)
    plt.savefig(save_path, dpi=120, bbox_inches="tight")
    plt.close()


def main():
    ap = argparse.ArgumentParser(description="P2b: per-sample density computation")
    ap.add_argument("--sample", required=True,
                    help="sample ID (Dataset/Subname)")
    ap.add_argument("--registry", default=None,
                    help="sample_registry.json (default: $DATA_DIR)")
    ap.add_argument("--kfile", required=True,
                    help="k_selection.json from P2a (required: cannot derive "
                         "from flat Nextflow work-dir layout)")
    ap.add_argument("--metadata", default=None,
                    help="explicit cell_metadata.csv path (overrides --indir; "
                         "used in Nextflow work-dir consumption)")
    ap.add_argument("--indir", default=None,
                    help="P1 results root (default: $RESULTS_DIR/P1_Results; "
                         "ignored when --metadata is given)")
    ap.add_argument("--outdir", required=True,
                    help="output directory (required: per-sample, flat — "
                         "must not default to shared root to avoid clobbering)")
    args = ap.parse_args()

    # --- path resolution (SPEC v2 §2; Q2: defaults preserve P2's behaviour) ---
    data_dir = os.environ.get("DATA_DIR", "./data")
    results_dir = os.environ.get("RESULTS_DIR", "./results")
    registry_path = args.registry or os.path.join(data_dir, "sample_registry.json")
    p1_dir = args.indir or os.path.join(results_dir, "P1_Results")
    p2_dir = args.outdir

    with open(registry_path, "r") as f:
        registry = json.load(f)

    if args.sample not in registry:
        print(f"  ✗ --sample '{args.sample}' not in registry\n")
        sys.exit(1)

    sample_name = args.sample
    sample_info = registry[sample_name]
    dataset = sample_name.split("/")[0]
    sub_name = sample_name.split("/")[1]

    # load K values from --kfile (required, flat layout)
    with open(args.kfile, "r") as f:
        k_decision = json.load(f)

    k_aggr = k_decision["k_aggr_2nd_diff"]
    k_main = k_decision["k_main_piecewise"]
    k_cons = k_decision["k_cons_max_dist"]
    k_max = max(k_aggr, k_main, k_cons)

    print(f"\n[{sample_name}]")
    print(f"  K values: aggr={k_aggr}, main={k_main}, cons={k_cons}")

    # output path: flat to --outdir (required, SPEC §2)
    os.makedirs(p2_dir, exist_ok=True)

    # resolve cell_metadata: explicit --metadata or nested --indir derivation
    if args.metadata:
        meta_path = args.metadata
    else:
        meta_path = os.path.join(p1_dir, dataset, sub_name, "cell_metadata.csv")
    df = pd.read_csv(meta_path)
    coords = df[["x_centroid", "y_centroid"]].values
    n_cells = len(coords)
    t0 = time.time()

    # --- KNN density (verbatim L632-644) ---
    nn = NearestNeighbors(n_neighbors=k_max + 1, algorithm="ball_tree")
    nn.fit(coords)
    distances, _ = nn.kneighbors(coords)
    knn_densities = {}
    for k_val, col_name in [(k_aggr, "density_knn_aggr_2nd_diff"),
                             (k_main, "density_knn_main_piecewise"),
                             (k_cons, "density_knn_cons_max_dist")]:
        dist_k = distances[:, k_val].copy()
        dist_k[dist_k == 0] = np.finfo(float).eps
        knn_densities[col_name] = 1.0 / dist_k
    t_knn = time.time() - t0
    print(f"  KNN完成: {t_knn:.1f}s")

    # --- Voronoi (verbatim L648-653) ---
    t0 = time.time()
    density_voronoi = compute_voronoi_density(coords)
    t_vor = time.time() - t0
    n_valid_vor = np.sum(~np.isnan(density_voronoi))
    print(f"  Voronoi完成: {t_vor:.1f}s, 有效值: {n_valid_vor}/{n_cells} "
          f"({100 * n_valid_vor / n_cells:.1f}%)")

    # --- Delaunay (verbatim L656-661) ---
    t0 = time.time()
    density_delaunay = compute_delaunay_density(coords)
    t_del = time.time() - t0
    n_valid_del = np.sum(~np.isnan(density_delaunay))
    print(f"  Delaunay完成: {t_del:.1f}s, 有效值: {n_valid_del}/{n_cells} "
          f"({100 * n_valid_del / n_cells:.1f}%)")

    # --- output DataFrame (verbatim L664-676) ---
    out_df = pd.DataFrame({
        "cell_id": df["cell_id"].values,
        "x_centroid": df["x_centroid"].values,
        "y_centroid": df["y_centroid"].values,
        "density_knn_aggr_2nd_diff": knn_densities["density_knn_aggr_2nd_diff"],
        "density_knn_main_piecewise": knn_densities["density_knn_main_piecewise"],
        "density_knn_cons_max_dist": knn_densities["density_knn_cons_max_dist"],
        "density_voronoi": density_voronoi,
        "density_delaunay": density_delaunay,
    })
    out_df.to_csv(os.path.join(p2_dir, "cell_density.csv"), index=False)

    # --- 5x5 Spearman correlation (verbatim L678-708) ---
    method_names = [
        "density_knn_aggr_2nd_diff", "density_knn_main_piecewise",
        "density_knn_cons_max_dist", "density_voronoi", "density_delaunay",
    ]
    all_densities = [
        knn_densities["density_knn_aggr_2nd_diff"],
        knn_densities["density_knn_main_piecewise"],
        knn_densities["density_knn_cons_max_dist"],
        density_voronoi, density_delaunay,
    ]
    n_methods = len(method_names)
    corr_matrix = np.eye(n_methods)
    for i in range(n_methods):
        for j in range(i + 1, n_methods):
            valid = ~np.isnan(all_densities[i]) & ~np.isnan(all_densities[j])
            if valid.sum() > 10:
                rho, _ = spearmanr(all_densities[i][valid], all_densities[j][valid])
                corr_matrix[i, j] = rho
                corr_matrix[j, i] = rho
            else:
                corr_matrix[i, j] = np.nan
                corr_matrix[j, i] = np.nan

    rho_mv = corr_matrix[1, 3]
    rho_md = corr_matrix[1, 4]
    rho_aa = corr_matrix[0, 1]
    rho_mc = corr_matrix[1, 2]
    print(f"  相关性: KNN_main↔Vor={rho_mv:.3f}, KNN_main↔Del={rho_md:.3f}, "
          f"KNN_aggr↔main={rho_aa:.3f}, KNN_main↔cons={rho_mc:.3f}")

    # --- diagnostic plot (verbatim L711-715) ---
    plot_density_diagnostics(
        sample_name, coords, all_densities, method_names, corr_matrix,
        os.path.join(p2_dir, "density_diagnostics.png"))

    # --- QC (verbatim L718-741) ---
    qc_row = {
        "sample": sample_name,
        "dataset": dataset,
        "species": sample_info.get("species", ""),
        "condition": sample_info.get("condition", ""),
        "n_cells": n_cells,
        "k_aggr": k_aggr,
        "k_main": k_main,
        "k_cons": k_cons,
        "median_density_knn_main": float(np.median(knn_densities["density_knn_main_piecewise"])),
        "n_valid_voronoi": int(n_valid_vor),
        "n_valid_delaunay": int(n_valid_del),
        "pct_valid_voronoi": round(100 * n_valid_vor / n_cells, 1),
        "pct_valid_delaunay": round(100 * n_valid_del / n_cells, 1),
        "corr_knn_main_voronoi": round(rho_mv, 4),
        "corr_knn_main_delaunay": round(rho_md, 4),
        "corr_knn_aggr_main": round(rho_aa, 4),
        "corr_knn_main_cons": round(rho_mc, 4),
        "time_knn_s": round(t_knn, 1),
        "time_voronoi_s": round(t_vor, 1),
        "time_delaunay_s": round(t_del, 1),
    }
    qc_row_df = pd.DataFrame([qc_row])
    # single-sample mode: write density_qc.csv shard (not ALL_SAMPLES_P2_QC.csv)
    qc_row_df.to_csv(os.path.join(p2_dir, "density_qc.csv"), index=False)

    print(f"\nP2b 完成: {sample_name}")


if __name__ == "__main__":
    main()
