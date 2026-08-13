#!/usr/bin/env Rscript
# ============================================================================
# tools/fingerprint.R
# ----------------------------------------------------------------------------
# Content fingerprinting for pipeline outputs (R side).
#
# Covers: .csv (data.table), .rds (Seurat objects per SPEC v2 §4.2), and raw
# bytes for small deterministic files.  .h5 files are fingerprinted by
# tools/fingerprint.py (Python side); this tool marks them "skipped".
#
# Serialization contract (P1 SPEC v2 §4.5 — MUST match tools/fingerprint.py):
#   - numbers formatted with sprintf("%.10f", x); NA -> "NA"
#   - values joined by "\n", UTF-8, no BOM, NO trailing newline
#   - md5 via tools::md5sum() on a tempfile (base package, no digest/openssl)
#
# Q5(b) ruling: every CSV fingerprint records an explicit "excluded" list
# (volatile columns skipped in md5 computation) while "colnames" still
# contains them.  Volatile sets below are EXPLICIT enumerations mirroring
# tools/qc_schema.py — no regex / prefix matching (Q5(a)).  KEEP IN SYNC
# with tools/qc_schema.py (single source of truth: checklist §3).
#
# Usage:
#   Rscript tools/fingerprint.R --file FILE [--out fp.json]
#   Rscript tools/fingerprint.R --dir DIR [--out fp.json]
# ============================================================================

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
})

# --- locate own directory so we can source config/args.R --------------------
.this_file <- sub("--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
if (length(.this_file) > 0) {
  .tools_dir <- normalizePath(dirname(.this_file), winslash = "/")
  .args_path <- file.path(dirname(.tools_dir), "config", "args.R")
  if (file.exists(.args_path)) source(.args_path)
}

# ============================================================================
# mirrored constants (sync with tools/qc_schema.py; drift is enforced by
# tools/test_infrastructure.py via --dump-constants)
# ============================================================================

CANONICAL_COLUMNS_R <- list(
  "ALL_SAMPLES_P1_QC.csv" = c(
    "sample_name", "species", "condition", "preservation",
    "data_quality_tier", "h5_path_type",
    "n_features_raw", "n_controls_removed", "n_genes_final",
    "n_cells_raw", "n_cells_removed", "n_cells_final",
    "nonzero_elements", "nonzero_fraction", "sparsity_pct",
    "median_transcripts", "mean_transcripts",
    "median_cell_area", "median_nucleus_area"),
  "ALL_SAMPLES_P2_QC.csv" = c(
    "sample", "dataset", "species", "condition", "n_cells",
    "k_aggr", "k_main", "k_cons",
    "median_density_knn_main",
    "n_valid_voronoi", "n_valid_delaunay",
    "pct_valid_voronoi", "pct_valid_delaunay",
    "corr_knn_main_voronoi", "corr_knn_main_delaunay",
    "corr_knn_aggr_main", "corr_knn_main_cons",
    "time_knn_s", "time_voronoi_s", "time_delaunay_s"),
  "ALL_SAMPLES_R1_QC.csv" = c(
    "sample_name", "dataset", "species", "condition",
    "data_quality_tier", "n_genes", "n_cells",
    "median_nCount", "median_nFeature", "median_density_knn",
    "median_cell_area", "vor_na_count", "del_na_count",
    "ncount_tc_cor", "rds_size_mb"),
  "ALL_SAMPLES_R2_QC.csv" = c(
    "sample_name", "dataset", "n_genes", "n_cells",
    "n_var_features", "n_pcs_selected", "n_pcs_elbow",
    "n_pcs_threshold", "cum_var_pct", "n_clusters",
    "residual_mean", "residual_sd", "time_seconds", "rds_size_mb"),
  "ALL_SAMPLES_R3_SUMMARY.csv" = c(
    "sample_name", "dataset", "species", "condition",
    "n_genes", "n_cells",
    "n_sig_q005", "n_sig_q001", "n_pos_q005", "n_neg_q005",
    "pct_sig", "median_abs_rho", "max_abs_rho",
    "n_method_robust", "n_high_confidence", "n_K_sensitive",
    "n_not_significant", "top1_gene", "top1_rho", "time_seconds"),
  "ALL_SAMPLES_R4_SUMMARY.csv" = c(
    "sample_name", "dataset", "species", "condition", "n_genes",
    "n_tier1", "n_tier1_pos", "n_tier1_neg",
    "n_tier2", "n_tier3", "n_not_sig",
    "n_top10pct", "n_top20pct",
    "median_abs_rho", "max_abs_rho",
    "top10pct_threshold", "top20pct_threshold",
    "top1_tier1_gene", "top1_tier1_rho"),
  "ALL_SAMPLES_R6_SUMMARY.csv" = c(
    "sample_name", "dataset", "n_cells", "n_clusters",
    "n_clusters_valid", "n_tier1",
    "n_composition_driven", "n_regulation_present",
    "n_cluster_heterogeneous", "n_mixed",
    "cc_analyzed", "cc_s_genes_matched", "cc_g2m_genes_matched",
    "cc_rho_s", "cc_rho_g2m", "time_seconds")
)

VOLATILE_COLUMNS_R <- list(
  "ALL_SAMPLES_P1_QC.csv"    = character(0),
  "ALL_SAMPLES_P2_QC.csv"    = c("time_knn_s", "time_voronoi_s", "time_delaunay_s"),
  "ALL_SAMPLES_R1_QC.csv"    = c("rds_size_mb"),
  "ALL_SAMPLES_R2_QC.csv"    = c("time_seconds", "rds_size_mb"),
  "ALL_SAMPLES_R3_SUMMARY.csv" = c("time_seconds"),
  "ALL_SAMPLES_R4_SUMMARY.csv" = character(0),
  "ALL_SAMPLES_R6_SUMMARY.csv" = c("time_seconds")
)

SHARD_TO_TABLE_R <- list(
  "p1_qc.csv"      = "ALL_SAMPLES_P1_QC.csv",
  "density_qc.csv" = "ALL_SAMPLES_P2_QC.csv",
  "r1_qc.csv"      = "ALL_SAMPLES_R1_QC.csv",
  "r2_qc.csv"      = "ALL_SAMPLES_R2_QC.csv",
  "r3_summary.csv" = "ALL_SAMPLES_R3_SUMMARY.csv",
  "r4_summary.csv" = "ALL_SAMPLES_R4_SUMMARY.csv",
  "r6_summary.csv" = "ALL_SAMPLES_R6_SUMMARY.csv"
)

# declared-numeric columns per table (补2a ruling: column type is decided
# by the schema, NOT by reader inference — pandas vs fread infer an all-NA
# column differently).  Mirrors qc_schema.NUMERIC_COLUMNS; drift is enforced
# by tools/test_infrastructure.py via --dump-constants.
NUMERIC_COLUMNS_R <- list(
  "ALL_SAMPLES_P1_QC.csv" = c(
    "n_features_raw", "n_controls_removed", "n_genes_final",
    "n_cells_raw", "n_cells_removed", "n_cells_final",
    "nonzero_elements", "nonzero_fraction", "sparsity_pct",
    "median_transcripts", "mean_transcripts",
    "median_cell_area", "median_nucleus_area"),
  "ALL_SAMPLES_P2_QC.csv" = c(
    "n_cells", "k_aggr", "k_main", "k_cons",
    "median_density_knn_main",
    "n_valid_voronoi", "n_valid_delaunay",
    "pct_valid_voronoi", "pct_valid_delaunay",
    "corr_knn_main_voronoi", "corr_knn_main_delaunay",
    "corr_knn_aggr_main", "corr_knn_main_cons",
    "time_knn_s", "time_voronoi_s", "time_delaunay_s"),
  "ALL_SAMPLES_R1_QC.csv" = c(
    "n_genes", "n_cells", "median_nCount", "median_nFeature",
    "median_density_knn", "median_cell_area",
    "vor_na_count", "del_na_count", "ncount_tc_cor", "rds_size_mb"),
  "ALL_SAMPLES_R2_QC.csv" = c(
    "n_genes", "n_cells", "n_var_features", "n_pcs_selected",
    "n_pcs_elbow", "n_pcs_threshold", "cum_var_pct", "n_clusters",
    "residual_mean", "residual_sd", "time_seconds", "rds_size_mb"),
  "ALL_SAMPLES_R3_SUMMARY.csv" = c(
    "n_genes", "n_cells", "n_sig_q005", "n_sig_q001",
    "n_pos_q005", "n_neg_q005", "pct_sig", "median_abs_rho",
    "max_abs_rho", "n_method_robust", "n_high_confidence",
    "n_K_sensitive", "n_not_significant", "top1_rho", "time_seconds"),
  "ALL_SAMPLES_R4_SUMMARY.csv" = c(
    "n_genes", "n_tier1", "n_tier1_pos", "n_tier1_neg",
    "n_tier2", "n_tier3", "n_not_sig", "n_top10pct", "n_top20pct",
    "median_abs_rho", "max_abs_rho",
    "top10pct_threshold", "top20pct_threshold", "top1_tier1_rho"),
  "ALL_SAMPLES_R6_SUMMARY.csv" = c(
    "n_cells", "n_clusters", "n_clusters_valid", "n_tier1",
    "n_composition_driven", "n_regulation_present",
    "n_cluster_heterogeneous", "n_mixed",
    "cc_analyzed", "cc_s_genes_matched", "cc_g2m_genes_matched",
    "cc_rho_s", "cc_rho_g2m", "time_seconds")
)

# key columns per file (explicit map; fallback = first column)
KEY_COLUMNS_R <- list(
  "density_gene_correlations.csv" = "gene",
  "filtered_density_genes.csv"    = "gene",
  "cell_density.csv"              = "cell_id",
  "cell_metadata.csv"             = "cell_id",
  "sample_density_profile.csv"    = "gene",
  "dataset_consistency.csv"       = "gene",
  "cell_state_coupling.csv"       = "gene",
  "cluster_density_profile.csv"   = "cluster",
  "cell_cycle_density.csv"        = "sample_name",
  "gene_level_comparison.csv"     = "gene",
  "comparison_summary.csv"        = "dataset_A",
  "ALL_SAMPLES_P1_QC.csv"         = "sample_name",
  "ALL_SAMPLES_P2_QC.csv"         = "sample",
  "ALL_SAMPLES_R1_QC.csv"         = "sample_name",
  "ALL_SAMPLES_R2_QC.csv"         = "sample_name",
  "ALL_SAMPLES_R3_SUMMARY.csv"    = "sample_name",
  "ALL_SAMPLES_R4_SUMMARY.csv"    = "sample_name",
  "ALL_SAMPLES_R6_SUMMARY.csv"    = "sample_name",
  "ALL_SAMPLES_R7_PROFILE.csv"    = "sample_name",
  "ALL_DATASETS_R7_CONSISTENCY.csv" = "dataset",
  "ALL_COMPARISONS_R8_SUMMARY.csv"  = c("dataset_A", "dataset_B"),
  "per_sample_signal_profile.csv"   = "sample",
  "signature_auc_per_sample.csv"    = "sample",
  "reproducibility_summary.csv"     = "comparison_type",
  "global_density_gene_landscape.csv" = c("gene_original", "dataset"),
  "global_gene_summary.csv"         = "gene_upper",
  "ALL_DATASETS_K_SELECTION.csv"    = "dataset",
  "k_decision_table.csv"            = "K",
  "all_samples_knn_cv.csv"          = "K",
  "p1_qc.csv"      = "sample_name",
  "density_qc.csv" = "sample",
  "r1_qc.csv"      = "sample_name",
  "r2_qc.csv"      = "sample_name",
  "r3_summary.csv" = "sample_name",
  "r4_summary.csv" = "sample_name",
  "r6_summary.csv" = "sample_name"
)

EXCLUDED_FILES_R <- c("TIER_DECISION_REPORT.txt", "TIER_DECISION_REPORT.json")
EXCLUDED_EXTENSIONS_R <- c(".png")

DENSITY_COLUMNS_R <- c(
  "density_knn_aggr_2nd_diff", "density_knn_main_piecewise",
  "density_knn_cons_max_dist", "density_voronoi", "density_delaunay"
)

# ALL_DATASETS_K_SELECTION.csv canonical columns (必修D: mirror of
# qc_schema.K_SELECTION_COLUMNS; drift enforced by T4 --dump-constants)
K_SELECTION_COLUMNS_R <- c(
  "dataset", "k_aggr_2nd_diff", "k_main_piecewise", "k_cons_max_dist",
  "dist_aggr_um", "dist_main_um", "dist_cons_um",
  "bio_scale_aggr", "bio_scale_main", "bio_scale_cons", "n_samples"
)

# ============================================================================
# serialization helpers (mirror tools/fingerprint.py exactly)
# ============================================================================

md5_of_joined <- function(vals) {
  # join by "\n", UTF-8, no trailing newline; md5 via tools::md5sum
  f <- tempfile()
  on.exit(unlink(f), add = TRUE)
  con <- file(f, open = "wb")
  writeBin(charToRaw(enc2utf8(paste(vals, collapse = "\n"))), con)
  close(con)
  unname(tools::md5sum(f))
}

fmt_num_r <- function(x) {
  # NA -> "NA"; else %.10f
  ifelse(is.na(x), "NA", sprintf("%.10f", x))
}

fmt_text_r <- function(x) {
  ifelse(is.na(x), "NA", as.character(x))
}

sequential_sum_r <- function(vals) {
  # left-to-right accumulation in identical order on both sides
  acc <- 0
  for (v in vals) acc <- acc + v
  acc
}

# --- content-based numeric detection (补2 regression fix, 方案 B) ----
# Same rule as tools/fingerprint.py _parse_numeric_str / _column_is_numeric.
# A value is numeric iff the ORIGINAL string parses as a finite number
# (optional sign, sci notation, decimal).  '', 'NA', 'NaN', 'Inf',
# booleans, gene names -> text.  An all-empty/all-NA column is TEXT on
# both sides (not numeric) — the pandas-fread inference divergence no
# longer applies because we judge the raw string, not the reader dtype.
parse_numeric_str_r <- function(val) {
  if (is.na(val) || is.null(val)) return(FALSE)
  s <- trimws(as.character(val))
  if (s == "" || toupper(s) == "NA") return(FALSE)
  # suppressWarnings: non-numeric strings return NA via as.double
  f <- suppressWarnings(as.double(s))
  if (is.na(f)) return(FALSE)
  if (is.infinite(f)) return(FALSE)
  TRUE
}

column_is_numeric_r <- function(raw_values) {
  # ALL non-empty values parse as numbers -> numeric; else text.
  # An all-empty column -> text (not numeric), same as Python side.
  non_empty <- raw_values[!is.na(raw_values) &
                          !(tolower(trimws(as.character(raw_values))) %in%
                            c("", "na", "nan"))]
  if (length(non_empty) == 0L) return(FALSE)
  all(vapply(non_empty, parse_numeric_str_r, logical(1)))
}

table_for_r <- function(basename) {
  if (!is.null(VOLATILE_COLUMNS_R[[basename]])) return(basename)
  SHARD_TO_TABLE_R[[basename]]
}

volatile_for_r <- function(basename) {
  tbl <- table_for_r(basename)
  if (is.null(tbl)) return(character(0))
  VOLATILE_COLUMNS_R[[tbl]]
}

numeric_for_r <- function(basename) {
  tbl <- table_for_r(basename)
  if (is.null(tbl)) return(character(0))
  NUMERIC_COLUMNS_R[[tbl]]
}

is_excluded_file_r <- function(basename) {
  if (basename %in% EXCLUDED_FILES_R) return(TRUE)
  tolower(tools::file_ext(basename)) %in% sub("^\\.", "", EXCLUDED_EXTENSIONS_R)
}

# ============================================================================
# CSV fingerprint
# ============================================================================

fingerprint_csv <- function(path) {
  basename <- basename(path)
  dt <- fread(path)
  colnames_v <- names(dt)
  n_rows <- nrow(dt)
  n_cols <- ncol(dt)

  # explicit volatile exclusion (Q5); refuse on drift
  excluded <- volatile_for_r(basename)
  for (cc in excluded) {
    if (!(cc %in% colnames_v)) {
      stop(sprintf("volatile column '%s' declared for %s but absent from file columns; refusing to fingerprint",
                   cc, basename))
    }
  }

  # key columns (explicit map, fallback first column)
  key_cols <- KEY_COLUMNS_R[[basename]]
  if (is.null(key_cols)) key_cols <- colnames_v[1]
  for (k in key_cols) {
    if (!(k %in% colnames_v)) stop(sprintf("key column '%s' not found in %s", k, basename))
  }

  # build row keys; sort by radix (byte/codepoint order; ASCII keys assumed,
  # matches Python codepoint sort on the other side)
  if (length(key_cols) == 1L) {
    keys <- fmt_text_r(dt[[key_cols]])
  } else {
    keys <- fmt_text_r(dt[[key_cols[1]]])
    for (k in key_cols[-1]) keys <- paste0(keys, "\t", fmt_text_r(dt[[k]]))
  }
  ord <- order(keys, method = "radix")

  fp <- list(
    file = basename,
    type = "csv",
    n_rows = n_rows,
    n_cols = n_cols,
    colnames = I(as.list(colnames_v)),
    key_column = paste(key_cols, collapse = "+"),
    key_md5 = md5_of_joined(sort(keys, method = "radix")),
    numeric = list(),
    text = list(),
    excluded = I(as.list(excluded))
  )

  declared_numeric <- numeric_for_r(basename)
  for (col in colnames_v) {
    if (col %in% key_cols || col %in% excluded) {
      # excluded (volatile) columns stay in "colnames" and in the
      # "excluded" record, but never enter md5/statistics (Q5)
      next
    }
    v <- dt[[col]]
    # content-based verdict (补2 regression fix, 方案 B); same rule as
    # the Python side.  The old per-table declaration only covered 7
    # summary tables and left 30+ scientific CSVs as text.
    raw_vals <- as.character(v)
    is_num <- column_is_numeric_r(raw_vals)
    has_non_empty <- any(!is.na(raw_vals) &
                         !(tolower(trimws(raw_vals)) %in% c("", "na", "nan")))
    # assertion: declared-numeric must match content UNLESS entirely
    # empty/NA (a declared-numeric column that happens to be all-NA is
    # still numeric, with NA min/max/sum).
    if (col %in% declared_numeric && has_non_empty && !is_num &&
        !(col %in% key_cols)) {
      stop(sprintf("column '%s' declared numeric in qc_schema for %s but content is not numeric; refusing to fingerprint",
                   col, basename))
    }
    if (col %in% declared_numeric && !has_non_empty) {
      is_num <- TRUE
    }
    if (is_num) {
      vals <- v[ord]
      ser_vals <- fmt_num_r(vals)
      non_na <- vals[!is.na(vals)]
      if (length(non_na) > 0) {
        fp$numeric[[col]] <- list(
          md5 = md5_of_joined(ser_vals),
          min = fmt_num_r(min(non_na)),
          max = fmt_num_r(max(non_na)),
          sum = fmt_num_r(sequential_sum_r(non_na))
        )
      } else {
        fp$numeric[[col]] <- list(md5 = md5_of_joined(ser_vals),
                                  min = "NA", max = "NA", sum = "NA")
      }
    } else {
      vals <- fmt_text_r(v[ord])
      fp$text[[col]] <- list(md5 = md5_of_joined(vals))
    }
  }
  fp
}

# ============================================================================
# RDS fingerprint (SPEC v2 §4.2)
# ============================================================================

fingerprint_rds <- function(path) {
  suppressPackageStartupMessages(library(Seurat))
  obj <- readRDS(path)

  fp <- list(
    file = basename(path),
    type = "rds",
    dim = as.list(dim(obj)),
    cells_md5 = md5_of_joined(sort(colnames(obj), method = "radix")),
    features_md5 = md5_of_joined(sort(rownames(obj), method = "radix")),
    assays = list(),
    meta_colnames = I(as.list(colnames(obj@meta.data))),
    density = list(),
    # explicit exclusion record (Q5-style auditability): @commands and any
    # timestamp fields are never fingerprinted
    excluded = as.list(c("@commands", "timestamps"))
  )

  for (a in Assays(obj)) {
    assay_obj <- obj[[a]]
    layers <- Layers(assay_obj)
    fp$assays[[a]] <- list()
    for (l in layers) {
      m <- GetAssayData(obj, assay = a, layer = l)
      if (inherits(m, "sparseMatrix")) {
        nnz <- length(Matrix::which(m != 0))
      } else {
        nnz <- sum(m != 0)
      }
      fp$assays[[a]][[l]] <- list(
        sum = sprintf("%.10f", sum(m)),
        nnz = nnz
      )
    }
  }

  meta <- obj@meta.data
  for (dc in DENSITY_COLUMNS_R) {
    if (dc %in% colnames(meta)) {
      fp$density[[dc]] <- list(md5 = md5_of_joined(fmt_num_r(meta[[dc]])))
    }
  }
  fp
}

# ============================================================================
# dispatch
# ============================================================================

fingerprint_file_r <- function(path) {
  basename <- basename(path)
  if (is_excluded_file_r(basename)) {
    return(list(file = basename, excluded = TRUE,
                reason = "volatile/figure output (SPEC §4.3 + Q5)"))
  }
  ext <- tolower(tools::file_ext(basename))
  if (ext == "csv") return(fingerprint_csv(path))
  if (ext == "rds") return(fingerprint_rds(path))
  if (ext %in% c("h5", "h5ad")) {
    return(list(file = basename, type = "h5", skipped = TRUE,
                reason = "use tools/fingerprint.py for .h5 files"))
  }
  # deterministic small files: raw bytes md5 (cross-language identical)
  list(file = basename, type = "bytes",
       size = as.integer(file.size(path)),
       md5 = unname(tools::md5sum(path)),
       excluded = list())
}

fingerprint_dir_r <- function(root) {
  rel <- sort(list.files(root, recursive = TRUE))
  files <- list()
  excluded_rel <- c()
  for (r in rel) {
    fp <- fingerprint_file_r(file.path(root, r))
    files[[r]] <- fp
    if (isTRUE(fp$excluded)) excluded_rel <- c(excluded_rel, r)
  }
  list(root = normalizePath(root, winslash = "/"),
       files = files,
       excluded = as.list(excluded_rel))
}

# ============================================================================
# main
# ============================================================================

main <- function() {
  if (!exists("parse_args")) stop("config/args.R could not be sourced")
  args <- parse_args(defaults = list(file = NULL, dir = NULL, out = NULL))

  # constants-drift lock: dump mirrored constants as JSON for the test
  # suite to compare against tools/qc_schema.py
  # (parse_args keeps the literal key "dump-constants" from the CLI)
  if (isTRUE(args[["dump-constants"]])) {
    dump <- list(
      CANONICAL_COLUMNS = lapply(CANONICAL_COLUMNS_R, as.list),
      VOLATILE_COLUMNS = lapply(VOLATILE_COLUMNS_R, function(v)
        if (length(v) == 0L) I(list()) else as.list(v)),
      NUMERIC_COLUMNS = lapply(NUMERIC_COLUMNS_R, function(v)
        if (length(v) == 0L) I(list()) else as.list(v)),
      K_SELECTION_COLUMNS = as.list(K_SELECTION_COLUMNS_R),
      SHARD_TO_TABLE = as.list(SHARD_TO_TABLE_R),
      EXCLUDED_FILES = as.list(EXCLUDED_FILES_R)
    )
    cat(toJSON(dump, auto_unbox = TRUE), "\n")
    return(invisible(NULL))
  }

  file_arg <- if (isTRUE(args$file)) NULL else args$file
  dir_arg  <- if (isTRUE(args$dir))  NULL else args$dir
  out_arg  <- if (isTRUE(args$out))  NULL else args$out

  if (!is.null(dir_arg)) {
    fp <- fingerprint_dir_r(dir_arg)
  } else if (!is.null(file_arg)) {
    fp <- fingerprint_file_r(file_arg)
  } else {
    stop("provide --file <path> or --dir <path>")
  }

  txt <- toJSON(fp, auto_unbox = TRUE, pretty = TRUE)
  if (!is.null(out_arg)) {
    writeLines(txt, out_arg)
    cat("fingerprint written to", out_arg, "\n")
  } else {
    cat(txt, "\n")
  }
}

main()
