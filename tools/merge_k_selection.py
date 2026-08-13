#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/merge_k_selection.py
============================================================
Merge per-dataset k_selection.json shards (from P2a) into the
cross-dataset summary ALL_DATASETS_K_SELECTION.csv, per SPEC v2 §3.1
(必修3 in S4 fix).

Mirrors the merge contract of tools/merge_qc.py:
  - canonical column order (explicit, not dict insertion order)
  - row order = registry iteration order (NOT alphabetical)
  - fail fast on missing shards (no silent skip)

Usage:
  python tools/merge_k_selection.py --registry sample_registry.json \\
      --shards dir1 dir2 ... --out ALL_DATASETS_K_SELECTION.csv

Shard discovery: --shards directories are searched (non-recursively)
for files named k_selection.json.
============================================================
"""

import argparse
import json
import os
import sys

import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qc_schema  # noqa: E402

# Single source of truth: qc_schema.K_SELECTION_COLUMNS (必修D)
CANONICAL_COLUMNS = qc_schema.K_SELECTION_COLUMNS

NA = ""


def load_registry_order(path):
    with open(path, "r", encoding="utf-8") as fh:
        registry = json.load(fh)
    # datasets in registry iteration order (first occurrence per dataset)
    seen = []
    for s in registry:
        ds = s.split("/")[0]
        if ds not in seen:
            seen.append(ds)
    return seen


def find_shards(shard_dirs):
    found = {}
    for d in shard_dirs:
        if not os.path.isdir(d):
            sys.exit(f"shard directory not found: {d}")
        for name in sorted(os.listdir(d)):
            if name == "k_selection.json":
                p = os.path.join(d, name)
                with open(p, "r", encoding="utf-8") as fh:
                    data = json.load(fh)
                ds = data.get("dataset")
                if ds is None:
                    sys.exit(f"shard {p} lacks 'dataset' field")
                if ds in found:
                    sys.exit(f"duplicate k_selection for dataset {ds!r}: "
                             f"{found[ds]} and {p}")
                found[ds] = p
    return found


def main():
    ap = argparse.ArgumentParser(
        description="Merge per-dataset k_selection.json into ALL_DATASETS_K_SELECTION.csv")
    ap.add_argument("--registry", required=True,
                    help="sample_registry.json for row ordering")
    ap.add_argument("--shards", nargs="+", required=True,
                    help="directories containing k_selection.json")
    ap.add_argument("--out", required=True, help="merged CSV output path")
    args = ap.parse_args()

    registry_order = load_registry_order(args.registry)
    found = find_shards(args.shards)

    # fail fast: every registry dataset must have a shard
    missing = [d for d in registry_order if d not in found]
    if missing:
        sys.exit(f"missing k_selection.json for {len(missing)} dataset(s): "
                 f"{missing[:5]}{'...' if len(missing) > 5 else ''}")

    frames = []
    for ds in registry_order:
        shard_path = found[ds]
        with open(shard_path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        row = {}
        for col in CANONICAL_COLUMNS:
            if col not in data:
                # k_selection.json has NO optional fields — all 11 are
                # unconditionally produced by P2a.  A missing field can
                # only come from a stale/old-format JSON (e.g. the 6-field
                # version before 必修A fix).  Fail loud, do NOT silently NA.
                sys.exit(f"field '{col}' missing from {shard_path} "
                         f"(dataset {ds}); k_selection.json must contain "
                         f"all {len(CANONICAL_COLUMNS)} canonical fields")
            row[col] = data[col]
        frames.append(row)

    merged = pd.DataFrame(frames, columns=CANONICAL_COLUMNS)

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".",
                exist_ok=True)
    merged.to_csv(args.out, index=False, na_rep=NA)
    print(f"merged {len(merged)} datasets -> {args.out} "
          f"({len(CANONICAL_COLUMNS)} canonical columns)")


if __name__ == "__main__":
    main()
