#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/merge_qc.py
============================================================
Merge single-sample QC shards (*_qc.csv / r*_summary.csv produced in
--sample mode) into the cross-sample summary table
(ALL_SAMPLES_*.csv equivalent), per SPEC v2 §3.2 (ruling Q3).

Hard requirements implemented here:
  (a) Column order comes from the EXPLICIT canonical constant in
      qc_schema.py — never from dict/DataFrame insertion order.
      Conditional columns occupy fixed positions; missing -> NA.
  (b) Row order follows the registry iteration order — NOT
      alphabetical.  Shards are re-indexed onto the registry key
      sequence; every registry sample MUST have a shard (fail fast,
      no silent skipping — mirrors the Q4(a/b) validation ethos).

Usage:
  python tools/merge_qc.py --table ALL_SAMPLES_R3_SUMMARY.csv \
      --registry sample_registry.json --shards dir1 dir2 ... \
      --out merged.csv

Shard discovery: the --shards directories are searched (non-
recursively) for files whose basename maps to the target table via
qc_schema.SHARD_TO_TABLE (e.g. r3_summary.csv -> ALL_SAMPLES_R3_SUMMARY.csv).
============================================================
"""

import argparse
import json
import os
import sys

import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qc_schema  # noqa: E402

NA = ""  # fwrite/read_csv round-trips NA as empty field; keep pandas default


def load_registry_order(path):
    """Registry keys in file order (insertion order preserved by both
    json.load and jsonlite::fromJSON — checklist §2)."""
    with open(path, "r", encoding="utf-8") as fh:
        registry = json.load(fh)
    return list(registry.keys())


def find_shards(table, shard_dirs):
    """Map shard file -> sample_name.

    A shard's sample is identified by its single data row's sample
    column (sample_name or sample, per canonical key).  Duplicates or
    unmappable shards are errors.
    """
    shard_basenames = {b for b, t in qc_schema.SHARD_TO_TABLE.items()
                       if t == table}
    key_col = "sample_name" if "sample_name" in qc_schema.CANONICAL_COLUMNS[table] \
        else "sample"

    found = {}
    for d in shard_dirs:
        if not os.path.isdir(d):
            sys.exit(f"shard directory not found: {d}")
        for name in sorted(os.listdir(d)):
            if name not in shard_basenames:
                continue
            path = os.path.join(d, name)
            df = pd.read_csv(path)
            if len(df) != 1:
                sys.exit(f"shard {path} must contain exactly one row, "
                         f"got {len(df)}")
            if key_col not in df.columns:
                sys.exit(f"shard {path} lacks key column {key_col!r}")
            sample = str(df[key_col].iloc[0])
            if sample in found:
                sys.exit(f"duplicate shard for sample {sample!r}: "
                         f"{found[sample]} and {path}")
            found[sample] = path
    return found, key_col


def main():
    ap = argparse.ArgumentParser(description="Merge single-sample QC shards")
    ap.add_argument("--table", required=True,
                    help="logical table name, e.g. ALL_SAMPLES_R3_SUMMARY.csv")
    ap.add_argument("--registry", required=True,
                    help="sample_registry.json for row ordering")
    ap.add_argument("--shards", nargs="+", required=True,
                    help="directories containing shard files")
    ap.add_argument("--out", required=True, help="merged CSV output path")
    args = ap.parse_args()

    if args.table not in qc_schema.CANONICAL_COLUMNS:
        sys.exit(f"unknown table {args.table!r}; expected one of "
                 f"{sorted(qc_schema.CANONICAL_COLUMNS)}")

    canonical = qc_schema.CANONICAL_COLUMNS[args.table]
    registry_order = load_registry_order(args.registry)
    found, key_col = find_shards(args.table, args.shards)

    # (b) row order = registry iteration order; every sample required
    missing = [s for s in registry_order if s not in found]
    if missing:
        sys.exit(f"missing shards for {len(missing)} registry sample(s): "
                 f"{missing[:5]}{'...' if len(missing) > 5 else ''}")

    frames = []
    for sample in registry_order:
        df = pd.read_csv(found[sample])
        # restrict to canonical columns; absent -> NA (Q3(a))
        row = {}
        for col in canonical:
            if col in df.columns:
                row[col] = df[col].iloc[0]
            else:
                row[col] = pd.NA
        frames.append(row)

    merged = pd.DataFrame(frames, columns=canonical)

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".",
                exist_ok=True)
    merged.to_csv(args.out, index=False, na_rep=NA)
    print(f"merged {len(merged)} samples -> {args.out} "
          f"({len(canonical)} canonical columns)")


if __name__ == "__main__":
    main()
