#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/fingerprint_merged.py
============================================================
为一个目录生成「合并指纹」JSON，供 compare_tolerance.py 使用。

compare_tolerance.py 的 load_fingerprints() 只按相对路径 key 对齐，且
compare_csv 会从磁盘重读 CSV。因此一个目录必须同时具备：
  - Python 侧指纹（h5 / csv / bytes，rds 标记 skipped）
  - R 侧指纹（rds / csv / bytes，h5 标记 skipped）
两者合并后，h5 取 Python、rds 取 R、csv/bytes 取 Python（契约一致）。

用法：
  python tools/fingerprint_merged.py <dir> --out <dir>/fp_merged.json \
      --python D:/python3.9.13/python.exe --rscript D:/R-4.5.2/bin/Rscript.exe
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def run(cmd):
    subprocess.run(cmd, check=True)


def merge(py_path, r_path):
    with open(py_path, encoding="utf-8") as fh:
        py = json.load(fh)
    with open(r_path, encoding="utf-8") as fh:
        r = json.load(fh)

    py_files = py.get("files", {})
    r_files = r.get("files", {})

    merged = {"root": py.get("root"), "files": {}, "excluded": []}
    for k in sorted(set(py_files) | set(r_files)):
        p = py_files.get(k)
        rv = r_files.get(k)

        # R 提供权威 rds 指纹；否则用 Python（h5/csv/bytes）。skipped 标记不算。
        if rv is not None and rv.get("type") == "rds" and rv.get("skipped") is not True:
            fp = rv
        elif p is not None:
            fp = p
        elif rv is not None:
            fp = rv
        else:
            continue

        if fp.get("excluded") is True:
            merged["excluded"].append(k)
            continue
        merged["files"][k] = fp

    return merged


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--out", required=True)
    ap.add_argument("--python", default=sys.executable)
    ap.add_argument("--rscript", default="Rscript")
    args = ap.parse_args()

    d = os.path.abspath(args.dir)
    with tempfile.TemporaryDirectory() as td:
        fp_py = os.path.join(td, "fp_py.json")
        fp_r = os.path.join(td, "fp_r.json")
        run([args.python, os.path.join(HERE, "fingerprint.py"),
             "--dir", d, "--out", fp_py])
        run([args.rscript, os.path.join(HERE, "fingerprint.R"),
             "--dir", d, "--out", fp_r])
        merged = merge(fp_py, fp_r)

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(merged, fh, sort_keys=True, indent=1, ensure_ascii=False)

    n = len(merged["files"])
    print(f"merged fingerprint written to {args.out} ({n} files, "
          f"{len(merged['excluded'])} excluded)")


if __name__ == "__main__":
    main()
