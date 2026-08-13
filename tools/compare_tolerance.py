#!/usr/bin/env python3
"""
compare_tolerance.py — Container vs host numerical equivalence checker.

Compares pipeline outputs from two directories using element-by-element
tolerance comparison for numeric columns (1e-6) and exact match for text
and structural elements.

Design (C4 rework):
  1. Import fingerprint module for KEY_COLUMNS, qc_schema for explicit
     column-type declarations (Q5(a): no prefix matching).
  2. Re-read CSV files from both directories; sort by key; compare
     numeric columns element-by-element (|Δ| < 1e-6 for all numeric,
     sum threshold scales with row count n).
  3. .rds fingerprints are loaded and compared (dim, cells_md5,
     features_md5, assay layer sums with tolerance, density md5).
  4. --self-test generates data where min/max/sum are identical but
     element-wise values differ beyond tolerance → must FAIL.

Usage:
    python tools/compare_tolerance.py <dir_a> <dir_b> [--verbose]
    python tools/compare_tolerance.py --self-test
"""

import json
import math
import os
import sys
import tempfile
from collections import defaultdict

import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qc_schema  # noqa: E402
from fingerprint import KEY_COLUMNS, _column_is_numeric  # noqa: E402

TOLERANCE = 1e-6


# ====================================================================
# column classification — explicit, no prefix matching (Q5(a))
# ====================================================================

def _classify_numeric_columns(df, basename):
    """Return set of column names that should be treated as numeric.

    For known summary tables: use qc_schema.numeric_for() (explicit).
    For unknown CSVs: use content-based detection via _column_is_numeric()
    (same logic as fingerprint.py).
    """
    declared = qc_schema.numeric_for(basename)
    if declared:
        return set(declared)

    # fallback: content-based detection
    numeric_cols = set()
    for col in df.columns:
        raw = [str(v) for v in df[col]]
        if _column_is_numeric(raw):
            numeric_cols.add(str(col))
    return numeric_cols


def _column_class(col):
    """P2 §3 column class: rho (correlation), count (integer count),
    p / q (p-value / adjusted p-value), other (everything else numeric).

    The equivalence standard is different per class (rho |Δ| < 1e-6,
    count must be exactly equal, gene/tier lists identical), so the
    observed max delta must be reported per class, not per raw type.
    """
    c = str(col)
    if c.startswith("rho_") or c.startswith("abs_rho") or c in (
            "top1_rho", "top1_tier1_rho", "max_abs_rho", "median_abs_rho"):
        return "rho"
    if c.startswith("n_") or c in (
            "vor_na_count", "del_na_count", "nonzero_elements"):
        return "count"
    if c.startswith("p_"):
        return "p"
    if c.startswith("q_"):
        return "q"
    return "other"


# ====================================================================
# fingerprint discovery
# ====================================================================

def load_fingerprints(root):
    """Walk root, load all fingerprint JSON files.

    Returns {relpath: fp_dict}.  Handles both per-file fingerprints and
    directory-level fingerprints (fingerprint_dir output).  Supports CSV,
    RDS, h5, and bytes type fingerprints.
    """
    fps = {}
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if not fn.endswith(".json"):
                continue
            full = os.path.join(dirpath, fn)
            try:
                with open(full, encoding="utf-8") as fh:
                    fp = json.load(fh)
            except (json.JSONDecodeError, OSError) as e:
                print(f"  WARNING: cannot read {full}: {e}")
                continue

            rel = os.path.relpath(full, root).replace("\\", "/")

            # fingerprint_dir produces a nested dict with "files" key.
            # fname is already relative to the fingerprint_dir root;
            # we use it directly (the JSON may be saved at any location).
            if isinstance(fp, dict) and "files" in fp:
                for fname, inner in fp["files"].items():
                    # File-level exclusion is boolean True (e.g. .png figures).
                    # A CSV's "excluded" field is a LIST of volatile columns,
                    # NOT a file-level flag — must not skip the whole file.
                    if inner.get("excluded") is True:
                        continue
                    fps[fname] = inner
            elif isinstance(fp, dict) and fp.get("type") in ("csv", "rds", "h5", "bytes"):
                if fp.get("excluded") is True:
                    continue
                fps[rel] = fp
    return fps


# ====================================================================
# CSV comparison — element-by-element
# ====================================================================

def _read_and_sort(path, key_cols):
    """Read CSV at path, sort by key_cols, return (df, keys_list)."""
    df = pd.read_csv(path)
    if len(key_cols) == 1:
        keys = [str(v) for v in df[key_cols[0]]]
    else:
        keys = ["\t".join(str(v) for v in row)
                for row in df[key_cols].itertuples(index=False)]
    order = sorted(range(len(df)), key=lambda i: keys[i])
    return df.iloc[order].reset_index(drop=True), [keys[i] for i in order]


def compare_csv(relpath, dir_a, dir_b, fp_a, fp_b):
    """Compare two CSV files element-by-element.

    Returns (issues: list, deltas: list).
    """
    issues = []
    deltas = []
    basename = os.path.basename(relpath)

    # resolve key columns
    key_cols = KEY_COLUMNS.get(basename, None)
    if key_cols is None:
        # try the parent summary table name
        for shard_name, table_name in qc_schema.SHARD_TO_TABLE.items():
            if shard_name in relpath:
                key_cols = KEY_COLUMNS.get(table_name)
                break
    if key_cols is None:
        # fallback: use first column
        key_cols = [fp_a.get("colnames", [None])[0]]
        if key_cols[0] is None:
            issues.append("cannot determine key column")
            return issues, deltas

    # read CSVs
    path_a = os.path.join(dir_a, relpath.replace("\\", "/"))
    path_b = os.path.join(dir_b, relpath.replace("\\", "/"))

    try:
        df_a, keys_a = _read_and_sort(path_a, key_cols)
    except Exception as e:
        issues.append(f"cannot read A: {e}")
        return issues, deltas
    try:
        df_b, keys_b = _read_and_sort(path_b, key_cols)
    except Exception as e:
        issues.append(f"cannot read B: {e}")
        return issues, deltas

    # structural checks
    if fp_a.get("n_rows") != fp_b.get("n_rows"):
        issues.append(f"n_rows: {fp_a.get('n_rows')} vs {fp_b.get('n_rows')}")
    if fp_a.get("n_cols") != fp_b.get("n_cols"):
        issues.append(f"n_cols: {fp_a.get('n_cols')} vs {fp_b.get('n_cols')}")
    if fp_a.get("colnames") != fp_b.get("colnames"):
        issues.append("colnames differ")

    cols_a = set(str(c) for c in fp_a.get("colnames", []))
    cols_b = set(str(c) for c in fp_b.get("colnames", []))

    # determine numeric columns
    num_cols = _classify_numeric_columns(df_a, basename)
    excluded_set = set(fp_a.get("excluded", [])) | set(key_cols)

    n_rows = len(df_a)

    # compare text columns via md5 (from fingerprint)
    text_a = fp_a.get("text", {})
    text_b = fp_b.get("text", {})
    for col in sorted(cols_a & cols_b):
        if col in num_cols or col in excluded_set:
            continue
        if col in text_a and col in text_b:
            if text_a[col].get("md5") != text_b[col].get("md5"):
                issues.append(f"text:{col}: md5 mismatch")
        elif col in text_a or col in text_b:
            issues.append(f"text:{col}: type mismatch (one side text)")

    # compare numeric columns element-by-element (vectorized)
    for col in sorted(cols_a & cols_b):
        if col not in num_cols or col in excluded_set:
            continue

        va = df_a[col]
        vb = df_b[col]

        # --- NA mismatch (vectorized) ---
        na_a = va.isna()
        na_b = vb.isna()
        na_mismatch_mask = na_a != na_b
        if na_mismatch_mask.any():
            i = int(na_mismatch_mask.idxmax())
            issues.append(
                f"numeric:{col}[{i}]: NA mismatch "
                f"({va.iloc[i]!r} vs {vb.iloc[i]!r})")
            # still compute max_delta on non-NA rows for diagnostics
            valid = ~na_a & ~na_b
        else:
            valid = ~na_a  # na_a == na_b, so either works

        n_valid = int(valid.sum())

        # --- element-wise delta (vectorized) ---
        # coerce to float; non-numeric values become NaN (already caught above)
        diff = (va.astype(float) - vb.astype(float)).abs()
        max_delta = float(diff.max()) if n_valid > 0 else 0.0

        # always record max_delta for diagnostics (whether pass or fail)
        if max_delta > 0 and not math.isnan(max_delta):
            deltas.append((col, "numeric", max_delta))

        # --- tolerance check ---
        exceed_mask = valid & (diff > TOLERANCE)
        if exceed_mask.any():
            i = int(exceed_mask.idxmax())
            fa = float(va.iloc[i])
            fb = float(vb.iloc[i])
            delta_i = abs(fa - fb)
            issues.append(
                f"numeric:{col}[{i}]: |{fa:.10f} - {fb:.10f}| = "
                f"{delta_i:.2e} > {TOLERANCE:.1e}")

        # --- sum sanity check: |Δ_sum| scales with n ---
        if n_valid > 0:
            sum_a = va.sum(skipna=True)
            sum_b = vb.sum(skipna=True)
            sum_diff = abs(float(sum_a) - float(sum_b))
            sum_threshold = n_valid * TOLERANCE
            if sum_diff > sum_threshold:
                issues.append(
                    f"numeric:{col}: sum |{sum_a:.10f} - {sum_b:.10f}| = "
                    f"{sum_diff:.2e} > {sum_threshold:.1e} (n={n_valid})")

    # columns missing from one side
    for col in sorted(cols_a - cols_b):
        issues.append(f"col:{col}: missing in B")
    for col in sorted(cols_b - cols_a):
        issues.append(f"col:{col}: missing in A")

    return issues, deltas


# ====================================================================
# RDS comparison
# ====================================================================

def compare_rds(relpath, fp_a, fp_b):
    """Compare two RDS fingerprints.

    Returns (issues: list, deltas: list).
    """
    issues = []
    deltas = []

    # dim
    if fp_a.get("dim") != fp_b.get("dim"):
        issues.append(f"dim: {fp_a.get('dim')} vs {fp_b.get('dim')}")

    # cells/features md5
    if fp_a.get("cells_md5") != fp_b.get("cells_md5"):
        issues.append("cells_md5 mismatch")
    if fp_a.get("features_md5") != fp_b.get("features_md5"):
        issues.append("features_md5 mismatch")

    # meta_colnames
    meta_a = fp_a.get("meta_colnames", [])
    meta_b = fp_b.get("meta_colnames", [])
    if list(meta_a) != list(meta_b):
        issues.append("meta_colnames differ")

    # assays
    assays_a = fp_a.get("assays", {})
    assays_b = fp_b.get("assays", {})
    for assay_name in sorted(set(assays_a.keys()) | set(assays_b.keys())):
        layers_a = assays_a.get(assay_name, {})
        layers_b = assays_b.get(assay_name, {})
        if assay_name not in assays_a:
            issues.append(f"assay:{assay_name}: missing in A")
            continue
        if assay_name not in assays_b:
            issues.append(f"assay:{assay_name}: missing in B")
            continue
        for layer_name in sorted(set(layers_a.keys()) | set(layers_b.keys())):
            la = layers_a.get(layer_name, {})
            lb = layers_b.get(layer_name, {})
            if layer_name not in layers_a:
                issues.append(f"assay:{assay_name}/{layer_name}: missing in A")
                continue
            if layer_name not in layers_b:
                issues.append(f"assay:{assay_name}/{layer_name}: missing in B")
                continue
            # nnz: exact match
            if la.get("nnz") != lb.get("nnz"):
                issues.append(
                    f"assay:{assay_name}/{layer_name}: nnz {la.get('nnz')} vs "
                    f"{lb.get('nnz')}")
            # sum: tolerance
            try:
                sa = float(la.get("sum", "NA"))
                sb = float(lb.get("sum", "NA"))
            except (ValueError, TypeError):
                issues.append(
                    f"assay:{assay_name}/{layer_name}: sum non-numeric")
                continue
            delta = abs(sa - sb)
            if delta > TOLERANCE:
                issues.append(
                    f"assay:{assay_name}/{layer_name}: sum |{sa:.10f} - "
                    f"{sb:.10f}| = {delta:.2e} > {TOLERANCE:.1e}")
            elif delta > 0:
                deltas.append((f"{assay_name}/{layer_name}", "rds_sum", delta))

    # density md5
    density_a = fp_a.get("density", {})
    density_b = fp_b.get("density", {})
    for dc in sorted(set(density_a.keys()) | set(density_b.keys())):
        if dc not in density_a:
            issues.append(f"density:{dc}: missing in A")
        elif dc not in density_b:
            issues.append(f"density:{dc}: missing in B")
        elif density_a[dc].get("md5") != density_b[dc].get("md5"):
            issues.append(f"density:{dc}: md5 mismatch")

    return issues, deltas


# ====================================================================
# h5 comparison
# ====================================================================

def compare_h5(relpath, fp_a, fp_b):
    """Compare two h5 fingerprints."""
    issues = []
    deltas = []

    for key in ("n_features", "n_cells", "data_nnz"):
        if fp_a.get(key) != fp_b.get(key):
            issues.append(f"{key}: {fp_a.get(key)} vs {fp_b.get(key)}")

    for key in ("features_md5", "cells_md5", "data_md5"):
        if fp_a.get(key) != fp_b.get(key):
            issues.append(f"{key} mismatch")

    # data_sum: tolerance
    try:
        sa = float(fp_a.get("data_sum", 0))
        sb = float(fp_b.get("data_sum", 0))
    except (ValueError, TypeError):
        issues.append("data_sum: non-numeric")
        return issues, deltas
    delta = abs(sa - sb)
    if delta > TOLERANCE:
        issues.append(
            f"data_sum: |{sa:.10f} - {sb:.10f}| = {delta:.2e} > {TOLERANCE:.1e}")
    elif delta > 0:
        deltas.append(("data_sum", "h5_data_sum", delta))

    return issues, deltas


# ====================================================================
# bytes comparison
# ====================================================================

def compare_bytes(relpath, fp_a, fp_b):
    """Compare two bytes-type fingerprints."""
    issues = []
    if fp_a.get("md5") != fp_b.get("md5"):
        issues.append("md5 mismatch")
    return issues, []


# ====================================================================
# dispatch
# ====================================================================

def compare_single(relpath, fp_a, fp_b, dir_a, dir_b):
    """Dispatch to the appropriate comparison function based on type."""
    ftype = fp_a.get("type", "")

    if ftype == "csv":
        return compare_csv(relpath, dir_a, dir_b, fp_a, fp_b)
    elif ftype == "rds":
        return compare_rds(relpath, fp_a, fp_b)
    elif ftype == "h5":
        return compare_h5(relpath, fp_a, fp_b)
    elif ftype == "bytes":
        return compare_bytes(relpath, fp_a, fp_b)
    else:
        return [f"unknown type: {ftype}"], []


# ====================================================================
# self-test: reverse verification
# ====================================================================

def self_test():
    """Generate data where min/max/sum are identical but element-wise
    values differ beyond tolerance → must FAIL.

    This proves that min/max/sum comparison is insufficient to guarantee
    element-by-element equivalence.
    """
    print("=== SELF-TEST: Reverse verification ===")
    print("Generating CSVs where min/max/sum match but values differ...")

    with tempfile.TemporaryDirectory() as tmpdir:
        dir_a = os.path.join(tmpdir, "A")
        dir_b = os.path.join(tmpdir, "B")
        os.makedirs(dir_a)
        os.makedirs(dir_b)

        # Create data: same min, max, sum; different internal values
        import numpy as np
        np.random.seed(42)

        n = 100
        # A: linear ramp from 0 to 1
        vals_a = np.linspace(0.0, 1.0, n)
        # B: perturb internal values in sum-preserving pairs,
        #    keep first and last element identical (same min/max)
        vals_b = vals_a.copy()
        for i in range(1, n - 2, 2):
            if i + 1 < n - 1:
                mid = (vals_b[i] + vals_b[i + 1]) / 2.0
                offset = TOLERANCE * 100  # 100x tolerance
                vals_b[i] = mid - offset
                vals_b[i + 1] = mid + offset

        # Verify min/max/sum are close
        print(f"  A: min={vals_a.min():.10f}  max={vals_a.max():.10f}  "
              f"sum={vals_a.sum():.10f}")
        print(f"  B: min={vals_b.min():.10f}  max={vals_b.max():.10f}  "
              f"sum={vals_b.sum():.10f}")
        sum_diff = abs(vals_a.sum() - vals_b.sum())
        print(f"  Sum diff: {sum_diff:.2e}")

        # Write CSVs
        df_a = pd.DataFrame({"gene": [f"G{i}" for i in range(n)],
                             "rho_value": vals_a})
        df_b = pd.DataFrame({"gene": [f"G{i}" for i in range(n)],
                             "rho_value": vals_b})
        df_a.to_csv(os.path.join(dir_a, "test.csv"), index=False)
        df_b.to_csv(os.path.join(dir_b, "test.csv"), index=False)

        # Generate fingerprints using fingerprint module
        from fingerprint import fingerprint_csv
        fp_a = fingerprint_csv(os.path.join(dir_a, "test.csv"))
        fp_b = fingerprint_csv(os.path.join(dir_b, "test.csv"))
        with open(os.path.join(dir_a, "fp.json"), "w") as f:
            json.dump({"files": {"test.csv": fp_a}}, f)
        with open(os.path.join(dir_b, "fp.json"), "w") as f:
            json.dump({"files": {"test.csv": fp_b}}, f)

        # Compare using min/max/sum only (old logic)
        print("\n  --- Old-style min/max/sum check ---")
        old_pass = True
        for k in ("min", "max", "sum"):
            va = fp_a["numeric"]["rho_value"][k]
            vb = fp_b["numeric"]["rho_value"][k]
            if va == vb:
                print(f"    {k}: {va} vs {vb} → EQUAL")
            else:
                print(f"    {k}: {va} vs {vb} → DIFFER")
                old_pass = False
        if old_pass:
            print("    RESULT: min/max/sum all match → would PASS (FALSE NEGATIVE!)")

        # Compare using element-by-element (new logic)
        print("\n  --- New element-by-element check ---")
        issues, _deltas = compare_csv(
            "test.csv", dir_a, dir_b, fp_a, fp_b)
        if issues:
            print(f"    RESULT: FAIL ({len(issues)} issues) — correctly detected!")
            for iss in issues:
                print(f"      - {iss}")
        else:
            print("    RESULT: PASS — BUG: should have detected differences!")

        # Now create test data that should PASS (within tolerance)
        print("\n  --- Within-tolerance test ---")
        vals_c = vals_a + np.random.uniform(-TOLERANCE * 0.5, TOLERANCE * 0.5, n)
        df_c = pd.DataFrame({"gene": [f"G{i}" for i in range(n)],
                             "rho_value": vals_c})
        dir_c = os.path.join(tmpdir, "C")
        os.makedirs(dir_c)
        df_c.to_csv(os.path.join(dir_c, "test.csv"), index=False)
        fp_c = fingerprint_csv(os.path.join(dir_c, "test.csv"))
        with open(os.path.join(dir_c, "fp.json"), "w") as f:
            json.dump({"files": {"test.csv": fp_c}}, f)

        issues_c, _ = compare_csv("test.csv", dir_a, dir_c, fp_a, fp_c)
        if not issues_c:
            print("    RESULT: PASS — correctly accepts within-tolerance data")
        else:
            print(f"    RESULT: FAIL ({len(issues_c)} issues) — BUG!")
            for iss in issues_c:
                print(f"      - {iss}")

        print("\n=== SELF-TEST COMPLETE ===")


# ====================================================================
# main
# ====================================================================

def main():
    if "--self-test" in sys.argv:
        self_test()
        return

    if len(sys.argv) < 3:
        print("Usage: python compare_tolerance.py <dir_a> <dir_b> [--verbose]")
        print("       python compare_tolerance.py --self-test")
        sys.exit(2)

    dir_a = os.path.abspath(sys.argv[1])
    dir_b = os.path.abspath(sys.argv[2])
    verbose = "--verbose" in sys.argv

    print(f"Loading fingerprints from {dir_a} ...")
    fps_a = load_fingerprints(dir_a)
    print(f"  {len(fps_a)} fingerprint entries")

    print(f"Loading fingerprints from {dir_b} ...")
    fps_b = load_fingerprints(dir_b)
    print(f"  {len(fps_b)} fingerprint entries")

    # Find common files
    common = sorted(set(fps_a.keys()) & set(fps_b.keys()))
    only_a = sorted(set(fps_a.keys()) - set(fps_b.keys()))
    only_b = sorted(set(fps_b.keys()) - set(fps_a.keys()))

    n_a = len(fps_a)
    n_b = len(fps_b)
    n_common = len(common)

    print(f"\n  Common: {n_common}  |  Only A: {len(only_a)}  |  "
          f"Only B: {len(only_b)}")
    if only_a:
        print(f"  Files only in A: {only_a}")
    if only_b:
        print(f"  Files only in B: {only_b}")

    # Guard against a "false PASS" from an empty or incomplete comparison.
    # An empty `common` set skips the compare loop, leaves fail_entries empty,
    # and used to exit 0.  A comparison that compares nothing — or leaves any
    # file on the smaller side without a counterpart — must never report PASS.
    if n_a == 0 or n_b == 0:
        print(f"\n  OVERALL: FAIL")
        print(f"  One side has no fingerprints (A={n_a}, B={n_b}); "
              f"nothing to compare.")
        sys.exit(1)

    if n_common == 0:
        print(f"\n  OVERALL: FAIL")
        print(f"  Common file set is empty (A={n_a}, B={n_b}); "
              f"no file was compared. Refusing to report PASS.")
        sys.exit(1)

    # `common` cannot exceed min(A, B); a shortfall against the smaller side
    # means the comparison is incomplete and a PASS would be misleading.
    min_side = min(n_a, n_b)
    if n_common < min_side:
        print(f"\n  OVERALL: FAIL")
        print(f"  Common={n_common} is smaller than the smaller side "
              f"({min_side}); comparison is incomplete "
              f"(A={n_a}, B={n_b}). Refusing to report PASS.")
        sys.exit(1)

    results = {"PASS": [], "FAIL": []}
    all_deltas = []
    summary_by_type = defaultdict(list)
    class_summary = defaultdict(list)

    for fname in common:
        fp_a = fps_a[fname]
        fp_b = fps_b[fname]
        issues, deltas = compare_single(fname, fp_a, fp_b, dir_a, dir_b)
        result_key = "PASS" if not issues else "FAIL"
        results[result_key].append((fname, issues))
        all_deltas.extend(deltas)
        for col, col_type, delta in deltas:
            summary_by_type[col_type].append((fname, col, delta))
            if col_type == "numeric":
                class_summary[_column_class(col)].append((fname, col, delta))

        if verbose:
            status = "OK" if result_key == "PASS" else "FAIL"
            print(f"  {status}  {fname}")
        elif result_key == "FAIL":
            print(f"  FAIL  {fname}")

    n_pass = len(results["PASS"])
    n_fail = len(results["FAIL"])
    print(f"\n{'='*60}")
    print(f"  Results: {n_pass} PASS / {n_fail} FAIL")
    print(f"  Total numeric deltas observed: {len(all_deltas)}")

    if summary_by_type:
        print(f"\n  Max absolute deltas by type:")
        for col_type, items in sorted(summary_by_type.items()):
            max_item = max(items, key=lambda x: x[2])
            print(f"    {col_type:15s}: max {max_item[2]:.2e}  "
                  f"({max_item[0]} / {max_item[1]})")

    # P2 §3 class breakdown: rho vs count vs p vs q vs other.
    # The standard differs per class, so the observed max delta must be
    # reported per class (not just per raw type).  Count columns are
    # expected to be bit-identical; a class absent from class_summary
    # means every column in it matched exactly (max delta = 0).
    print(f"\n  Max absolute delta by column class (P2 §3):")
    for cls in ("rho", "count", "p", "q", "other"):
        items = class_summary.get(cls, [])
        if items:
            max_fname, max_col, max_d = max(items, key=lambda x: x[2])
            print(f"    {cls:8s}: max {max_d:.2e}  "
                  f"({max_col} in {max_fname})")
        else:
            print(f"    {cls:8s}: max 0.00e+00  (exact match)")

    fail_entries = results["FAIL"]
    if fail_entries:
        print(f"\n  FAILED FILES:")
        for fname, issues in fail_entries:
            if not issues:
                continue
            print(f"    {fname}")
            for issue in issues:
                print(f"      - {issue}")

    if fail_entries:
        print(f"\n  OVERALL: FAIL")
        sys.exit(1)
    else:
        print(f"\n  OVERALL: PASS")
        sys.exit(0)


if __name__ == "__main__":
    main()
