#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/make_fixture.py
============================================================
Generate the synthetic fixture dataset for all local verification
levels (P1 SPEC v2 §4.6).

Layout (2 datasets x 2-3 samples):
  Fixture_Human/Donor1   full optional columns          (2000 cells)
  Fixture_Human/Donor2   MISSING cell_area + controls   (2000 cells)
  Fixture_Human/Donor3   full optional columns          (2000 cells)
  Fixture_Mouse/MouseA   full optional columns          (2000 cells)
  Fixture_Mouse/MouseB   h5 in legacy "unknown" layout  (2000 cells)

Donor1+Donor3 provide two full-column samples for R01 dual-sample
fan-in verification (Donor2 excluded from R stage on Seurat 5.4.0
due to missing cell_area, but retained for P1-side conditional-column
coverage).

Per sample: cell_feature_matrix.h5 (10x "matrix" layout by default,
includes control features so P1b's filtering logic is exercised) +
cells.parquet.  Plus one sample_registry.json with the same field
structure as the real registry.

Design notes
------------
- Human genes are UPPERCASE (GENE001..GENE190), mouse genes are
  CamelCase (Gene001..Gene190): toupper() unification then yields a
  non-empty cross-species intersection, covering P1c's cross-species
  branch.  Two human datasets cover the within-species pairwise
  branch.  This is the maximum P1c branch coverage achievable within
  the SPEC-mandated 2-dataset budget.
- Donor2 lacks cell_area (and control-count columns) to exercise the
  conditional-column NA-fill merge contract (SPEC §3.2).
- ~2% of cells get transcript_counts < MIN_TRANSCRIPTS (=10) so P1b's
  empty-cell filter is exercised.
- Fixed seed: repeated generation produces byte-identical fixtures.
- Cell-count floor enforced at 1500 (SCTransform vst stability).

Usage:
  python tools/make_fixture.py [--outdir ./fixture_data] [--seed 20260811]
                               [--cells 2000] [--genes 200]
============================================================
"""

import argparse
import json
import os
import sys

import numpy as np
import pandas as pd
import scipy.sparse as sp
import h5py

MIN_CELLS_FLOOR = 1500
CONTROL_BLOCK = [
    "NegControlProbe_0001", "NegControlProbe_0002",
    "NegControlProbe_0003", "NegControlProbe_0004",
    "BLANK_0001", "BLANK_0002", "BLANK_0003",
    "DeprecatedCodeword_0001", "UnassignedCodeword_0001",
]  # + one antisense entry appended per species -> 10 controls


def build_gene_names(species, n_real):
    """Real gene names plus control features appended at the end."""
    if species == "human":
        genes = [f"GENE{i:03d}" for i in range(1, n_real + 1)]
        controls = CONTROL_BLOCK + ["antisense_GENE0001"]
    else:
        genes = [f"Gene{i:03d}" for i in range(1, n_real + 1)]
        controls = CONTROL_BLOCK + ["antisense_Gene0001"]
    return genes + controls, genes, controls


def make_barcodes(rng, n, subname):
    """Deterministic pseudo-10x barcodes; verified unique."""
    alphabet = np.array(list("ACGT"))
    codes = alphabet[rng.integers(0, 4, size=(n, 16))]
    barcodes = ["".join(row) + "-1" for row in codes]
    assert len(set(barcodes)) == n, f"barcode collision in {subname}"
    return barcodes


def make_coords(rng, n):
    """Clustered coordinates on a 1000x1000 um region: gives the
    KNN/Voronoi/Delaunay estimators non-trivial structure."""
    n_blobs = 8
    centers = rng.uniform(80, 920, size=(n_blobs, 2))
    assign = rng.integers(0, n_blobs, size=n)
    coords = centers[assign] + rng.normal(0, 60, size=(n, 2))
    coords = np.clip(coords, 0, 1000)
    return coords


def write_10x_h5(path, gene_names, barcodes, mat_csc):
    """Same 10x 'matrix' layout that P1b writes/reads."""
    gene_bytes = np.array(gene_names, dtype="S")
    barcode_bytes = np.array(barcodes, dtype="S")
    feature_type = np.array(["Gene Expression"] * len(gene_names), dtype="S")
    with h5py.File(path, "w") as f:
        g = f.create_group("matrix")
        g.create_dataset("data", data=mat_csc.data.astype(np.int32))
        g.create_dataset("indices", data=mat_csc.indices.astype(np.int64))
        g.create_dataset("indptr", data=mat_csc.indptr.astype(np.int64))
        g.create_dataset("shape", data=np.array(mat_csc.shape, dtype=np.int32))
        g.create_dataset("barcodes", data=barcode_bytes)
        feat = g.create_group("features")
        feat.create_dataset("name", data=gene_bytes)
        feat.create_dataset("id", data=gene_bytes)
        feat.create_dataset("feature_type", data=feature_type)
        feat.create_dataset("genome",
                            data=np.array(["unknown"] * len(gene_names), dtype="S"))


def write_unknown_h5(path, gene_names, barcodes, mat_csc):
    """Legacy 'unknown' layout consumed by P1b load_h5 fallback branch.

    Exercises P1b's dual-layout adaptation so h5_path_type is not
    constant across the fixture.
    """
    gene_bytes = np.array(gene_names, dtype="S")
    barcode_bytes = np.array(barcodes, dtype="S")
    with h5py.File(path, "w") as f:
        g = f.create_group("unknown")
        g.create_dataset("gene_names", data=gene_bytes)
        g.create_dataset("barcodes", data=barcode_bytes)
        g.create_dataset("data", data=mat_csc.data.astype(np.int32))
        g.create_dataset("indices", data=mat_csc.indices.astype(np.int64))
        g.create_dataset("indptr", data=mat_csc.indptr.astype(np.int64))
        g.create_dataset("shape", data=np.array(mat_csc.shape, dtype=np.int32))


def make_sample(outdir, dataset, subname, species, condition, panel,
                n_cells, n_real_genes, rng, drop_cell_area,
                h5_layout="matrix"):
    sample_dir = os.path.join(outdir, dataset, subname)
    os.makedirs(sample_dir, exist_ok=True)

    gene_names, real_genes, controls = build_gene_names(species, n_real_genes)
    n_features = len(gene_names)

    # sparse count matrix: ~5% nonzero entries, Poisson-distributed values
    mat = sp.random(n_features, n_cells, density=0.05, format="csc",
                    random_state=rng)
    mat.data = (rng.poisson(2.0, size=mat.data.shape) + 1).astype(np.int32)
    mat.eliminate_zeros()

    barcodes = make_barcodes(rng, n_cells, subname)
    coords = make_coords(rng, n_cells)

    # transcript_counts = full column sums (controls included), then
    # force ~2% of cells below the MIN_TRANSCRIPTS=10 filter threshold
    col_sums = np.asarray(mat.sum(axis=0)).ravel()
    transcript_counts = col_sums.astype(np.int64).copy()
    n_low = max(1, int(round(n_cells * 0.02)))
    low_idx = rng.choice(n_cells, size=n_low, replace=False)
    transcript_counts[low_idx] = rng.integers(0, 10, size=n_low)

    h5_writer = write_unknown_h5 if h5_layout == "unknown" else write_10x_h5
    h5_writer(os.path.join(sample_dir, "cell_feature_matrix.h5"),
              gene_names, barcodes, mat)

    df = pd.DataFrame({
        "cell_id": barcodes,
        "x_centroid": coords[:, 0].round(3),
        "y_centroid": coords[:, 1].round(3),
        "transcript_counts": transcript_counts,
    })
    if not drop_cell_area:
        df["cell_area"] = rng.uniform(40, 250, size=n_cells).round(2)
        df["nucleus_area"] = rng.uniform(20, 120, size=n_cells).round(2)
        df["control_probe_counts"] = rng.integers(0, 5, size=n_cells)
        df["control_codeword_counts"] = rng.integers(0, 3, size=n_cells)
    else:
        # SPEC §4.6: at least one sample lacks optional columns
        df["nucleus_area"] = rng.uniform(20, 120, size=n_cells).round(2)

    df.to_parquet(os.path.join(sample_dir, "cells.parquet"), index=False)

    return {
        "path": os.path.join(outdir, dataset, subname),
        "species": species,
        "condition": condition,
        "preservation": "FFPE",
        "panel_name": panel,
        "segmentation": "nuclei_expansion",
        "xoa_version": "fixture-v1",
        "data_quality_tier": "high",
        "data_source": "synthetic_fixture",
        "note": ("missing_cell_area_column" if drop_cell_area
                 else "fixture_sample"),
    }, n_features


def main():
    ap = argparse.ArgumentParser(description="Generate synthetic fixture dataset")
    ap.add_argument("--outdir", default="./fixture_data",
                    help="fixture root (default ./fixture_data)")
    ap.add_argument("--seed", type=int, default=20260811,
                    help="fixed random seed (fixture reproducibility)")
    ap.add_argument("--cells", type=int, default=2000,
                    help="cells per sample (floor 1500)")
    ap.add_argument("--genes", type=int, default=200,
                    help="features per sample including 10 controls")
    args = ap.parse_args()

    if args.cells < MIN_CELLS_FLOOR:
        sys.exit(f"--cells must be >= {MIN_CELLS_FLOOR} "
                 f"(SCTransform vst stability floor)")
    n_real = args.genes - 10
    if n_real < 50:
        sys.exit("--genes too small: need room for 10 control features")

    outdir = args.outdir
    os.makedirs(outdir, exist_ok=True)
    rng = np.random.default_rng(args.seed)

    registry = {}

    # Fixture_Human: 3 samples (Donor1/Donor3 full columns for R01
    # dual-sample fan-in; Donor2 missing cell_area for conditional-column
    # path coverage — but excluded from R stage on Seurat 5.4.0)
    for sub, drop in (("Donor1", False), ("Donor2", True), ("Donor3", False)):
        info, n_feat = make_sample(outdir, "Fixture_Human", sub, "human",
                                   "fixture_condition", "Fixture_Human_190",
                                   args.cells, n_real, rng, drop)
        registry[f"Fixture_Human/{sub}"] = info
        print(f"  Fixture_Human/{sub}: {n_feat} features x {args.cells} cells"
              f"{'  [no cell_area]' if drop else ''}")

    # Fixture_Mouse: 2 samples (CamelCase genes for cross-species branch);
    # MouseB uses the legacy "unknown" h5 layout to exercise P1b's
    # dual-layout branch (need 4b)
    info, n_feat = make_sample(outdir, "Fixture_Mouse", "MouseA", "mouse",
                               "fixture_condition", "Fixture_Mouse_190",
                               args.cells, n_real, rng, False)
    registry["Fixture_Mouse/MouseA"] = info
    print(f"  Fixture_Mouse/MouseA: {n_feat} features x {args.cells} cells")

    info, n_feat = make_sample(outdir, "Fixture_Mouse", "MouseB", "mouse",
                               "fixture_condition", "Fixture_Mouse_190",
                               args.cells, n_real, rng, False,
                               h5_layout="unknown")
    info["note"] = "unknown_h5_layout"
    registry["Fixture_Mouse/MouseB"] = info
    print(f"  Fixture_Mouse/MouseB: {n_feat} features x {args.cells} cells"
          f"  [unknown h5 layout]")

    reg_path = os.path.join(outdir, "sample_registry.json")
    with open(reg_path, "w", encoding="utf-8") as fh:
        json.dump(registry, fh, indent=2, ensure_ascii=False)
        fh.write("\n")

    print(f"\nFixture written to {os.path.abspath(outdir)}")
    print(f"  registry: {reg_path}")
    print(f"  seed={args.seed} cells={args.cells} features={args.genes}")
    print("  Run the pipeline with --registry pointing at this file.")


if __name__ == "__main__":
    main()
