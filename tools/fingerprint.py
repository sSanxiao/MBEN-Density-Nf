#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/fingerprint.py
============================================================
Content fingerprinting for pipeline outputs (Python side).

Covers: .csv (pandas), .h5 (10x-format produced by P1b), and raw
bytes for small deterministic files (e.g. k_selection.json).
.rds files are fingerprinted by tools/fingerprint.R (R side).

Serialization contract (P1 SPEC v2 §4.5, must match the R tool):
  - numbers formatted with %.10f, joined by "\n"
  - missing values serialized as the literal string "NA"
  - booleans serialized as "TRUE" / "FALSE"
  - UTF-8, no BOM, no trailing newline after the last element
  - md5 via hashlib.md5

Q5(b) ruling: every CSV fingerprint records an explicit "excluded"
list (volatile columns skipped in md5 computation) while "colnames"
still contains them, so the exclusion set itself stays auditable.
Volatile sets are EXPLICIT enumerations imported from qc_schema.py
(no regex / prefix matching, Q5(a)).

Usage:
  python tools/fingerprint.py FILE [--out fp.json]
  python tools/fingerprint.py --dir DIR [--out fp.json]
============================================================
"""

import argparse
import hashlib
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qc_schema  # noqa: E402


# ------------------------------------------------------------
# serialization helpers (must mirror tools/fingerprint.R)
# ------------------------------------------------------------

def fmt_num(x):
    """%.10f formatting; NA -> 'NA'. Mirrors R sprintf('%.10f', x)."""
    if x is None:
        return "NA"
    try:
        xf = float(x)
    except (TypeError, ValueError):
        return "NA"
    if math.isnan(xf):
        return "NA"
    return f"{xf:.10f}"


def fmt_text(v):
    """String serialization for text columns."""
    if v is None:
        return "NA"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, float) and math.isnan(v):
        return "NA"
    # numpy bool_ / NA handling
    try:
        import numpy as np
        if isinstance(v, (np.bool_,)):
            return "TRUE" if bool(v) else "FALSE"
    except ImportError:
        pass
    return str(v)


def md5_of_joined(values):
    """md5 of values joined by '\\n' (no trailing newline), UTF-8."""
    payload = "\n".join(values).encode("utf-8")
    return hashlib.md5(payload).hexdigest()


def sequential_sum(vals):
    """Left-to-right double accumulation (cross-language safe).

    Both sides accumulate in identical order, so results are
    bit-identical. vals must already be NA-free.
    """
    acc = 0.0
    for v in vals:
        acc += float(v)
    return acc


# ------------------------------------------------------------
# key column resolution (explicit map, checklist §4)
# ------------------------------------------------------------

KEY_COLUMNS = {
    "density_gene_correlations.csv": ["gene"],
    "filtered_density_genes.csv": ["gene"],
    "cell_density.csv": ["cell_id"],
    "cell_metadata.csv": ["cell_id"],
    "sample_density_profile.csv": ["gene"],
    "dataset_consistency.csv": ["gene"],
    "cell_state_coupling.csv": ["gene"],
    "cluster_density_profile.csv": ["cluster"],
    "cell_cycle_density.csv": ["sample_name"],
    "gene_level_comparison.csv": ["gene"],
    "comparison_summary.csv": ["dataset_A"],
    "ALL_SAMPLES_P1_QC.csv": ["sample_name"],
    "ALL_SAMPLES_P2_QC.csv": ["sample"],
    "ALL_SAMPLES_R1_QC.csv": ["sample_name"],
    "ALL_SAMPLES_R2_QC.csv": ["sample_name"],
    "ALL_SAMPLES_R3_SUMMARY.csv": ["sample_name"],
    "ALL_SAMPLES_R4_SUMMARY.csv": ["sample_name"],
    "ALL_SAMPLES_R6_SUMMARY.csv": ["sample_name"],
    "ALL_SAMPLES_R7_PROFILE.csv": ["sample_name"],
    "ALL_DATASETS_R7_CONSISTENCY.csv": ["dataset"],
    "ALL_COMPARISONS_R8_SUMMARY.csv": ["dataset_A", "dataset_B"],
    "per_sample_signal_profile.csv": ["sample"],
    "signature_auc_per_sample.csv": ["sample"],
    "reproducibility_summary.csv": ["comparison_type"],
    "global_density_gene_landscape.csv": ["gene_original", "dataset"],
    "global_gene_summary.csv": ["gene_upper"],
    "ALL_DATASETS_K_SELECTION.csv": ["dataset"],
    "k_decision_table.csv": ["K"],
    "all_samples_knn_cv.csv": ["K"],
    # single-sample shards carry the same key as their parent table
    "p1_qc.csv": ["sample_name"],
    "density_qc.csv": ["sample"],
    "r1_qc.csv": ["sample_name"],
    "r2_qc.csv": ["sample_name"],
    "r3_summary.csv": ["sample_name"],
    "r4_summary.csv": ["sample_name"],
    "r6_summary.csv": ["sample_name"],
}


def is_numeric_series(s):
    import numpy as np
    import pandas as pd
    return pd.api.types.is_numeric_dtype(s) and not pd.api.types.is_bool_dtype(s)


def _parse_numeric_str(val):
    """Language-agnostic numeric parse (补2 regression fix, 方案 B).

    Returns True iff val (the ORIGINAL string as read from CSV) parses
    as a finite number under a strict, cross-language rule:
      - optional sign, scientific notation, decimal point
      - rejects '', 'NA', 'NaN', 'Inf', booleans, anything non-numeric
    Both Python and R use the SAME rule (see is_numeric_column_value in
    fingerprint.R), so an all-NA column resolves identically as text
    on both sides — the pandas-fread inference divergence no longer
    applies because we judge the raw string, not the reader's dtype.
    """
    if val is None:
        return False
    s = str(val).strip()
    if s == "" or s.upper() == "NA":
        return False
    try:
        f = float(s)
    except (TypeError, ValueError):
        return False
    # Inf/NaN as text (they don't round-trip via %.10f meaningfully)
    if math.isinf(f) or math.isnan(f):
        return False
    return True


def _column_is_numeric(raw_values):
    """A column is numeric iff ALL non-empty values parse as numbers
    (补2 regression fix, 方案 B).  An all-empty/all-NA column is TEXT
    on both sides (not numeric)."""
    non_empty = [v for v in raw_values if v is not None
                 and str(v).strip().lower() not in ("", "na", "nan")]
    if not non_empty:
        return False
    return all(_parse_numeric_str(v) for v in non_empty)


def fingerprint_csv(path):
    import pandas as pd

    basename = os.path.basename(path)
    df = pd.read_csv(path)
    colnames = [str(c) for c in df.columns]
    n_rows, n_cols = df.shape

    # explicit volatile exclusion for summary/shard tables (Q5)
    excluded = qc_schema.volatile_for(basename)
    for c in excluded:
        if c not in colnames:
            # exclusion set must never silently shrink or drift
            raise ValueError(
                f"volatile column {c!r} declared for {basename} but absent "
                f"from file columns; refusing to fingerprint"
            )

    # key columns (explicit map, fallback = first column)
    key_cols = KEY_COLUMNS.get(basename, [colnames[0]])
    for k in key_cols:
        if k not in colnames:
            raise ValueError(f"key column {k!r} not found in {basename}")

    # build row keys and sort order (codepoint order; matches R radix)
    if len(key_cols) == 1:
        keys = [fmt_text(v) for v in df[key_cols[0]]]
    else:
        keys = ["\t".join(fmt_text(v) for v in row)
                for row in df[key_cols].itertuples(index=False)]
    order = sorted(range(n_rows), key=lambda i: keys[i])
    key_sorted = [keys[i] for i in order]

    fp = {
        "file": basename,
        "type": "csv",
        "n_rows": int(n_rows),
        "n_cols": int(n_cols),
        "colnames": colnames,
        "key_column": "+".join(key_cols),
        "key_md5": md5_of_joined(sorted(keys)),
        "numeric": {},
        "text": {},
        "excluded": excluded,
    }

    excluded_set = set(excluded)
    # column type is decided by CONTENT, not by reader inference or a
    # per-table declaration (补2 regression fix, 方案 B).  pandas and
    # data.table infer an all-NA column differently (float64 vs logical);
    # a per-table NUMERIC_COLUMNS declaration (旧方案) only covered 7
    # summary tables and left 30+ scientific CSVs degraded to text with
    # str()/as.character() precision divergence.  Now: a column is numeric
    # iff ALL non-empty raw-string values parse as finite numbers (same
    # rule on both sides); all-empty/NA columns are text on both sides.
    declared_numeric = set(qc_schema.numeric_for(basename))
    for col in colnames:
        if col in key_cols or col in excluded_set:
            # excluded (volatile) columns stay in "colnames" and in the
            # "excluded" record, but never enter md5/statistics (Q5)
            continue
        s = df[col]
        raw = [str(v) for v in s]
        is_num = _column_is_numeric(raw)
        has_non_empty = any(
            v is not None and str(v).strip().lower() not in ("", "na", "nan")
            for v in raw)
        # assertion: for summary tables with a declaration, the
        # content-based verdict must match — UNLESS the column is
        # entirely empty/NA (a declared-numeric column that happens to
        # be all-NA is still numeric, with NA min/max/sum).
        if (col in declared_numeric and has_non_empty and not is_num
                and col not in key_cols):
            raise ValueError(
                f"column {col!r} declared numeric in qc_schema for "
                f"{basename} but content is not numeric; refusing to "
                f"fingerprint")
        # declared-numeric all-NA columns -> numeric (min/max/sum = NA)
        if col in declared_numeric and not has_non_empty:
            is_num = True
        if is_num:
            vals = [s.iloc[i] for i in order]
            ser_vals = [fmt_num(v) for v in vals]
            non_na = [float(v) for v in vals if pd.notna(v)]
            if non_na:
                fp["numeric"][col] = {
                    "md5": md5_of_joined(ser_vals),
                    "min": fmt_num(min(non_na)),
                    "max": fmt_num(max(non_na)),
                    "sum": fmt_num(sequential_sum(non_na)),
                }
            else:
                fp["numeric"][col] = {
                    "md5": md5_of_joined(ser_vals),
                    "min": "NA", "max": "NA", "sum": "NA",
                }
        else:
            vals = [fmt_text(s.iloc[i]) for i in order]
            fp["text"][col] = {"md5": md5_of_joined(vals)}

    return fp


def fingerprint_h5(path):
    import numpy as np
    import h5py

    basename = os.path.basename(path)
    with h5py.File(path, "r") as f:
        top = list(f.keys())
        if "matrix" in top:
            layout = "matrix"
            gpath = "matrix/features/name"
            bpath = "matrix/barcodes"
            dpath = "matrix/data"
        elif "unknown" in top:
            layout = "unknown"
            gpath = "unknown/gene_names"
            bpath = "unknown/barcodes"
            dpath = "unknown/data"
        else:
            raise ValueError(f"unrecognized h5 layout in {basename}: {top}")

        genes = [g.decode("utf-8") if isinstance(g, bytes) else str(g)
                 for g in f[gpath][:]]
        barcodes = [b.decode("utf-8") if isinstance(b, bytes) else str(b)
                    for b in f[bpath][:]]
        data = f[dpath][:]
        shape = tuple(int(x) for x in f["matrix/shape" if layout == "matrix"
                                        else "unknown/shape"][:])

    return {
        "file": basename,
        "type": "h5",
        "layout": layout,
        "n_features": int(shape[0]),
        "n_cells": int(shape[1]),
        "features_md5": md5_of_joined(sorted(genes)),
        "cells_md5": md5_of_joined(sorted(barcodes)),
        "data_sum": float(np.sum(data)),
        "data_nnz": int(len(data)),
        # md5 over stored values in CSC storage order; P1b writes int32
        # counts (verified P1b_data_loading.py write_10x_h5), but stay
        # dtype-defensive: non-integer dtypes serialize via %.10f
        "data_md5": md5_of_joined(
            [str(int(v)) for v in data]
            if np.issubdtype(np.asarray(data).dtype, np.integer)
            else [fmt_num(v) for v in data]),
        "excluded": [],
    }


def fingerprint_bytes(path):
    with open(path, "rb") as fh:
        payload = fh.read()
    return {
        "file": os.path.basename(path),
        "type": "bytes",
        "size": len(payload),
        "md5": hashlib.md5(payload).hexdigest(),
        "excluded": [],
    }


def is_excluded_file(basename):
    if basename in qc_schema.EXCLUDED_FILES:
        return True
    _, ext = os.path.splitext(basename)
    return ext.lower() in [e.lower() for e in qc_schema.EXCLUDED_EXTENSIONS]


def fingerprint_file(path):
    basename = os.path.basename(path)
    if is_excluded_file(basename):
        return {"file": basename, "excluded": True,
                "reason": "volatile/figure output (SPEC §4.3 + Q5)"}
    _, ext = os.path.splitext(basename)
    ext = ext.lower()
    if ext == ".csv":
        return fingerprint_csv(path)
    if ext in (".h5", ".h5ad"):
        return fingerprint_h5(path)
    if ext == ".rds":
        return {"file": basename, "type": "rds", "skipped": True,
                "reason": "use tools/fingerprint.R for .rds files"}
    # any other deterministic small file: raw bytes
    return fingerprint_bytes(path)


def fingerprint_dir(root):
    result = {"root": os.path.abspath(root), "files": {}, "excluded": []}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            fp = fingerprint_file(full)
            result["files"][rel] = fp
            # Only FILE-level exclusions (boolean True, e.g. .png figures)
            # belong in this list.  A CSV's "excluded" is a LIST of volatile
            # columns, not a file-level flag.
            if fp.get("excluded") is True:
                result["excluded"].append(rel)
    return result


def main():
    ap = argparse.ArgumentParser(description="Pipeline output fingerprinting (Python side)")
    ap.add_argument("path", nargs="?", help="file to fingerprint")
    ap.add_argument("--dir", help="directory to fingerprint recursively")
    ap.add_argument("--out", help="write JSON here instead of stdout")
    args = ap.parse_args()

    if args.dir:
        fp = fingerprint_dir(args.dir)
    elif args.path:
        fp = fingerprint_file(args.path)
    else:
        ap.error("provide a file path or --dir")

    text = json.dumps(fp, sort_keys=True, indent=2, ensure_ascii=False)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
        print(f"fingerprint written to {args.out}")
    else:
        print(text)


if __name__ == "__main__":
    main()
