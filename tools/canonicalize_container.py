#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/canonicalize_container.py
============================================================
把 run_c5_fixture.sh 的扁平容器输出目录，映射成与 Nextflow 发布结构
（P3_NEXTFLOW_SPEC §4）一致的「统一结构」，使两侧可以用
compare_tolerance.py 按相对路径对齐后直接比对。

显式对应表（container_out  ->  canonical）：

  <SAFE>/filtered_matrix.h5             -> P1_Results/<Dataset>/<Subname>/filtered_matrix.h5
  <SAFE>/cell_metadata.csv              -> P1_Results/<Dataset>/<Subname>/cell_metadata.csv
  <SAFE>/p1_qc.csv                      -> P1_Results/<Dataset>/<Subname>/p1_qc.csv
  <SAFE>/cell_density.csv               -> P2_Results/<Dataset>/<Subname>/cell_density.csv
  <SAFE>/density_qc.csv                 -> P2_Results/<Dataset>/<Subname>/density_qc.csv
  p2a_<Dataset>/k_selection.json        -> P2_Results/<Dataset>/k_selection.json
  p2a_<Dataset>/k_decision_table.csv    -> P2_Results/<Dataset>/k_decision_table.csv
  p2a_<Dataset>/all_samples_knn_cv.csv  -> P2_Results/<Dataset>/all_samples_knn_cv.csv
  r_<SAFE>_R01/<Sub>_seurat.rds         -> R1_Results/<Dataset>/<Subname>/<Sub>_seurat.rds
  r_<SAFE>_R01/r1_qc.csv                -> R1_Results/<Dataset>/<Subname>/r1_qc.csv
  r_<SAFE>_R02/<Sub>_seurat_R2.rds      -> R2_Results/<Dataset>/<Subname>/<Sub>_seurat_R2.rds
  r_<SAFE>_R02/r2_qc.csv                -> R2_Results/<Dataset>/<Subname>/r2_qc.csv
  r_<SAFE>_R03/density_gene_correlations.csv -> R3_Results/<Dataset>/<Subname>/density_gene_correlations.csv
  r_<SAFE>_R03/r3_summary.csv           -> R3_Results/<Dataset>/<Subname>/r3_summary.csv
  r_<SAFE>_R04/filtered_density_genes.csv -> R4_Results/<Dataset>/<Subname>/filtered_density_genes.csv
  r_<SAFE>_R04/r4_summary.csv           -> R4_Results/<Dataset>/<Subname>/r4_summary.csv

其中 <SAFE> = <Dataset>_<Subname>（斜杠换下划线）。Dataset/Subname 的拆分不靠
字符串猜测，而是从 sample_registry.json 的 key（本身就是 <Dataset>/<Subname>）读入，
避免 <Dataset> 内含下划线（Fixture_Human）导致的歧义。

被跳过（非流水线产物 / 易变输出）：*.png、meta_*.txt、registry_rstage.json。
"""
import argparse
import json
import os
import shutil
import sys

# <SAFE> 目录内、按 basename 归到 P1 vs P2 阶段的显式清单
P1_SAMPLE_FILES = {"filtered_matrix.h5", "cell_metadata.csv", "p1_qc.csv"}
P2_SAMPLE_FILES = {"cell_density.csv", "density_qc.csv"}

# p2a_<Dataset> 目录内（P2A，dataset 级 fan-in 产物）
P2A_FILES = {"k_selection.json", "k_decision_table.csv", "all_samples_knn_cv.csv"}

# r_<SAFE>_R0N 目录内，按阶段归到 R{N}_Results
R_STAGE_FILES = {
    "R01": {"r1_qc.csv"},
    "R02": {"r2_qc.csv"},
    "R03": {"density_gene_correlations.csv", "r3_summary.csv"},
    "R04": {"filtered_density_genes.csv", "r4_summary.csv"},
}
# R01 输出 <Sub>_seurat.rds；R02 输出 <Sub>_seurat_R2.rds（靠目录阶段区分）
R_STAGE_RDS = {
    "R01": "_seurat.rds",
    "R02": "_seurat_R2.rds",
}


def load_registry(reg_path):
    with open(reg_path, encoding="utf-8") as fh:
        reg = json.load(fh)
    # key: <Dataset>/<Subname> -> SAFE name
    safe_of = {k: k.replace("/", "_") for k in reg}
    return reg, safe_of


def canonical_target(rel, reg, safe_of):
    """Return canonical relative path for a container_out rel path, or None if skip."""
    parts = rel.replace("\\", "/").split("/")
    if len(parts) < 2:
        return None
    head = parts[0]
    base = os.path.basename(rel)

    # P2A dataset 级目录
    if head.startswith("p2a_"):
        if base in P2A_FILES:
            dataset = head[len("p2a_"):]
            return f"P2_Results/{dataset}/{base}"
        return None

    # R 阶段目录 r_<SAFE>_R0N
    if head.startswith("r_") and "_R0" in head:
        for stage in ("R01", "R02", "R03", "R04"):
            if head.endswith(stage):
                safe = head[: -(len(stage) + 1)][2:]  # strip 'r_' prefix and '_R0N'
                # resolve safe -> Dataset/Subname via registry
                sample = None
                for k, s in safe_of.items():
                    if s == safe:
                        sample = k
                        break
                if sample is None:
                    return None
                dataset, sub = sample.split("/", 1)
                prefix = stage.replace("0", "")
                if base in R_STAGE_FILES[stage]:
                    return f"{prefix}_Results/{dataset}/{sub}/{base}"
                if stage in R_STAGE_RDS and base.endswith(R_STAGE_RDS[stage]):
                    return f"{prefix}_Results/{dataset}/{sub}/{base}"
                return None
        return None

    # per-sample 目录 <SAFE>（P1B + P2B 共享同一目录）
    sample = None
    for k, s in safe_of.items():
        if s == head:
            sample = k
            break
    if sample is None:
        return None
    dataset, sub = sample.split("/", 1)
    if base in P1_SAMPLE_FILES:
        return f"P1_Results/{dataset}/{sub}/{base}"
    if base in P2_SAMPLE_FILES:
        return f"P2_Results/{dataset}/{sub}/{base}"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("container_out")
    ap.add_argument("dest")
    ap.add_argument("--registry", required=True)
    args = ap.parse_args()

    reg, safe_of = load_registry(args.registry)

    os.makedirs(args.dest, exist_ok=True)
    n_copied = 0
    n_skipped = 0
    mapping_rows = []

    for dirpath, _dirnames, filenames in os.walk(args.container_out):
        dirnames_sorted = sorted(_dirnames)
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, args.container_out).replace("\\", "/")
            target = canonical_target(rel, reg, safe_of)
            if target is None:
                n_skipped += 1
                continue
            dst = os.path.join(args.dest, target.replace("/", os.sep))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(full, dst)
            n_copied += 1
            mapping_rows.append(f"  {rel}  ->  {target}")

    print("=== container_out -> canonical 映射表 ===")
    for row in mapping_rows:
        print(row)
    print(f"\n  copied: {n_copied}  |  skipped: {n_skipped}")
    print(f"  dest: {os.path.abspath(args.dest)}")


if __name__ == "__main__":
    main()
