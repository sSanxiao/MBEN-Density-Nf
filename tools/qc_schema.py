#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/qc_schema.py
============================================================
Canonical column order and volatile-column constants for the
QC / summary tables of the thesis pipeline.

Single source of truth: docs/IO_CONTRACT_CHECKLIST.md §3 (P1 SPEC v2
§3.2 ruling Q3).  Full-mode writers, single-sample shards and
tools/merge_qc.py MUST all use these constants.  The R side mirrors
the same explicit lists in tools/fingerprint.R (no shared runtime
across languages; keep in sync).

Q5(a) ruling: the volatile/exclusion sets below are EXPLICIT
enumerations — no regex, no prefix matching.
============================================================
"""

# ------------------------------------------------------------
# Canonical column order per cross-sample summary table.
# Columns marked conditional in the checklist occupy a fixed
# position here; missing values are filled with NA on merge.
# ------------------------------------------------------------

CANONICAL_COLUMNS = {
    "ALL_SAMPLES_P1_QC.csv": [
        "sample_name", "species", "condition", "preservation",
        "data_quality_tier", "h5_path_type",
        "n_features_raw", "n_controls_removed", "n_genes_final",
        "n_cells_raw", "n_cells_removed", "n_cells_final",
        "nonzero_elements", "nonzero_fraction", "sparsity_pct",
        # conditional columns (fixed positions, NA when absent)
        "median_transcripts", "mean_transcripts",
        "median_cell_area", "median_nucleus_area",
    ],
    "ALL_SAMPLES_P2_QC.csv": [
        "sample", "dataset", "species", "condition", "n_cells",
        "k_aggr", "k_main", "k_cons",
        "median_density_knn_main",
        "n_valid_voronoi", "n_valid_delaunay",
        "pct_valid_voronoi", "pct_valid_delaunay",
        "corr_knn_main_voronoi", "corr_knn_main_delaunay",
        "corr_knn_aggr_main", "corr_knn_main_cons",
        "time_knn_s", "time_voronoi_s", "time_delaunay_s",
    ],
    "ALL_SAMPLES_R1_QC.csv": [
        "sample_name", "dataset", "species", "condition",
        "data_quality_tier", "n_genes", "n_cells",
        "median_nCount", "median_nFeature", "median_density_knn",
        "median_cell_area", "vor_na_count", "del_na_count",
        "ncount_tc_cor", "rds_size_mb",
    ],
    "ALL_SAMPLES_R2_QC.csv": [
        "sample_name", "dataset", "n_genes", "n_cells",
        "n_var_features", "n_pcs_selected", "n_pcs_elbow",
        "n_pcs_threshold", "cum_var_pct", "n_clusters",
        "residual_mean", "residual_sd", "time_seconds", "rds_size_mb",
    ],
    "ALL_SAMPLES_R3_SUMMARY.csv": [
        "sample_name", "dataset", "species", "condition",
        "n_genes", "n_cells",
        "n_sig_q005", "n_sig_q001", "n_pos_q005", "n_neg_q005",
        "pct_sig", "median_abs_rho", "max_abs_rho",
        "n_method_robust", "n_high_confidence", "n_K_sensitive",
        "n_not_significant", "top1_gene", "top1_rho", "time_seconds",
    ],
    "ALL_SAMPLES_R4_SUMMARY.csv": [
        "sample_name", "dataset", "species", "condition", "n_genes",
        "n_tier1", "n_tier1_pos", "n_tier1_neg",
        "n_tier2", "n_tier3", "n_not_sig",
        "n_top10pct", "n_top20pct",
        "median_abs_rho", "max_abs_rho",
        "top10pct_threshold", "top20pct_threshold",
        "top1_tier1_gene", "top1_tier1_rho",
    ],
    "ALL_SAMPLES_R6_SUMMARY.csv": [
        "sample_name", "dataset", "n_cells", "n_clusters",
        "n_clusters_valid", "n_tier1",
        "n_composition_driven", "n_regulation_present",
        "n_cluster_heterogeneous", "n_mixed",
        "cc_analyzed", "cc_s_genes_matched", "cc_g2m_genes_matched",
        "cc_rho_s", "cc_rho_g2m", "time_seconds",
    ],
}

# ------------------------------------------------------------
# Volatile columns: values that necessarily differ between two
# independent runs of the SAME code (elapsed time, file sizes).
# Excluded from fingerprint md5 computation, but still recorded in
# the fingerprint's "excluded" field (Q5(b)) so the exclusion set
# itself stays auditable.  EXPLICIT enumeration per table — do not
# use pattern matching here.
# ------------------------------------------------------------

VOLATILE_COLUMNS = {
    "ALL_SAMPLES_P1_QC.csv": [],
    "ALL_SAMPLES_P2_QC.csv": ["time_knn_s", "time_voronoi_s", "time_delaunay_s"],
    "ALL_SAMPLES_R1_QC.csv": ["rds_size_mb"],
    "ALL_SAMPLES_R2_QC.csv": ["time_seconds", "rds_size_mb"],
    "ALL_SAMPLES_R3_SUMMARY.csv": ["time_seconds"],
    "ALL_SAMPLES_R4_SUMMARY.csv": [],
    "ALL_SAMPLES_R6_SUMMARY.csv": ["time_seconds"],
}

# ------------------------------------------------------------
# Explicit per-table column TYPE (S3 closure 补2a ruling).
#
# The reader-side type inference differs between pandas and
# data.table::fread for an all-NA column: pandas -> float64
# (would land in "numeric"), fread -> logical (would land in
# "text").  Real outputs hit this (e.g. median_cell_area when every
# sample lacks cell_area; top1_tier1_gene when no gene is selected).
# To keep both languages structurally identical, the column TYPE is
# decided HERE by the canonical schema, not by the reader.  Writers
# must emit these columns with the declared type anyway; the
# fingerprinters compare the declared type's representation.
#
# A column is "numeric" if its values are numbers (or NA).  All other
# columns (categorical, filenames, keys, gene names, TRUE/FALSE flags)
# are "text".  Booleans are handled inside text via "TRUE"/"FALSE".
# If a column is not listed here at all, it defaults to "text"
# (safe: text is the generic catch-all and never mis-types a number
# as something else as long as the writer emits it consistently).
# ------------------------------------------------------------

NUMERIC_COLUMNS = {
    "ALL_SAMPLES_P1_QC.csv": [
        "n_features_raw", "n_controls_removed", "n_genes_final",
        "n_cells_raw", "n_cells_removed", "n_cells_final",
        "nonzero_elements", "nonzero_fraction", "sparsity_pct",
        "median_transcripts", "mean_transcripts",
        "median_cell_area", "median_nucleus_area",
    ],
    "ALL_SAMPLES_P2_QC.csv": [
        "n_cells", "k_aggr", "k_main", "k_cons",
        "median_density_knn_main",
        "n_valid_voronoi", "n_valid_delaunay",
        "pct_valid_voronoi", "pct_valid_delaunay",
        "corr_knn_main_voronoi", "corr_knn_main_delaunay",
        "corr_knn_aggr_main", "corr_knn_main_cons",
        "time_knn_s", "time_voronoi_s", "time_delaunay_s",
    ],
    "ALL_SAMPLES_R1_QC.csv": [
        "n_genes", "n_cells", "median_nCount", "median_nFeature",
        "median_density_knn", "median_cell_area",
        "vor_na_count", "del_na_count", "ncount_tc_cor",
        "rds_size_mb",
    ],
    "ALL_SAMPLES_R2_QC.csv": [
        "n_genes", "n_cells", "n_var_features", "n_pcs_selected",
        "n_pcs_elbow", "n_pcs_threshold", "cum_var_pct", "n_clusters",
        "residual_mean", "residual_sd", "time_seconds", "rds_size_mb",
    ],
    "ALL_SAMPLES_R3_SUMMARY.csv": [
        "n_genes", "n_cells", "n_sig_q005", "n_sig_q001",
        "n_pos_q005", "n_neg_q005", "pct_sig", "median_abs_rho",
        "max_abs_rho", "n_method_robust", "n_high_confidence",
        "n_K_sensitive", "n_not_significant", "top1_rho", "time_seconds",
    ],
    "ALL_SAMPLES_R4_SUMMARY.csv": [
        "n_genes", "n_tier1", "n_tier1_pos", "n_tier1_neg",
        "n_tier2", "n_tier3", "n_not_sig", "n_top10pct", "n_top20pct",
        "median_abs_rho", "max_abs_rho",
        "top10pct_threshold", "top20pct_threshold", "top1_tier1_rho",
    ],
    "ALL_SAMPLES_R6_SUMMARY.csv": [
        "n_cells", "n_clusters", "n_clusters_valid", "n_tier1",
        "n_composition_driven", "n_regulation_present",
        "n_cluster_heterogeneous", "n_mixed",
        "cc_analyzed", "cc_s_genes_matched", "cc_g2m_genes_matched",
        "cc_rho_s", "cc_rho_g2m", "time_seconds",
    ],
}

# ------------------------------------------------------------
# Single-sample shard file name -> logical summary table it belongs
# to (used to resolve canonical columns and volatile columns for
# shard files produced in --sample mode).
# ------------------------------------------------------------

SHARD_TO_TABLE = {
    "p1_qc.csv": "ALL_SAMPLES_P1_QC.csv",
    "density_qc.csv": "ALL_SAMPLES_P2_QC.csv",
    "r1_qc.csv": "ALL_SAMPLES_R1_QC.csv",
    "r2_qc.csv": "ALL_SAMPLES_R2_QC.csv",
    "r3_summary.csv": "ALL_SAMPLES_R3_SUMMARY.csv",
    "r4_summary.csv": "ALL_SAMPLES_R4_SUMMARY.csv",
    "r6_summary.csv": "ALL_SAMPLES_R6_SUMMARY.csv",
}

# ------------------------------------------------------------
# Files excluded from fingerprint comparison entirely (Q5 + SPEC
# §4.3): explicit name list for report files; extension rule only
# for figures, per SPEC "图件 (.png) 不参与校验".
# ------------------------------------------------------------

EXCLUDED_FILES = [
    "TIER_DECISION_REPORT.txt",
    "TIER_DECISION_REPORT.json",
    # P2a manifest intermediates (meta_<Dataset>.txt): two-column
    # sample -> cell_metadata.csv path lists.  Paths embed the mount
    # point (/out vs /tmp/.../new_single), so they differ by construction
    # between container and server — not scientific output.
    "meta_Fixture_Human.txt",
    "meta_Fixture_Mouse.txt",
]
EXCLUDED_EXTENSIONS = [".png"]

# ------------------------------------------------------------
# The five density columns (pipeline-wide contract, checklist §4.4).
# ------------------------------------------------------------

DENSITY_COLUMNS = [
    "density_knn_aggr_2nd_diff",
    "density_knn_main_piecewise",
    "density_knn_cons_max_dist",
    "density_voronoi",
    "density_delaunay",
]

# ------------------------------------------------------------
# ALL_DATASETS_K_SELECTION.csv canonical columns (必修D: single source
# of truth, aligned with original P2 dataset_k_decisions + dataset key;
# generated_by stays in k_selection.json only, NOT in the CSV).
# Mirrors original P2_density_calculation.py L507-518 + L567-568.
# ------------------------------------------------------------

K_SELECTION_COLUMNS = [
    "dataset",
    "k_aggr_2nd_diff",
    "k_main_piecewise",
    "k_cons_max_dist",
    "dist_aggr_um",
    "dist_main_um",
    "dist_cons_um",
    "bio_scale_aggr",
    "bio_scale_main",
    "bio_scale_cons",
    "n_samples",
]


def table_for(basename):
    """Resolve the logical summary table name for a file basename.

    Returns the table key (ALL_SAMPLES_*.csv) when the file is a
    summary table or a single-sample shard, else None.
    """
    if basename in CANONICAL_COLUMNS:
        return basename
    return SHARD_TO_TABLE.get(basename)


def volatile_for(basename):
    """Explicit volatile-column list applicable to this file (may be [])."""
    tbl = table_for(basename)
    if tbl is None:
        return []
    return list(VOLATILE_COLUMNS[tbl])


def numeric_for(basename):
    """Columns of this file that are declared numeric (补2a schema-ruled).

    Columns not listed default to text.  Returns [] for files that are
    neither a summary table nor a known shard.
    """
    tbl = table_for(basename)
    if tbl is None:
        return []
    return list(NUMERIC_COLUMNS[tbl])
