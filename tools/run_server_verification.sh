#!/usr/bin/env bash
# ============================================================
# run_server_verification.sh
# P1 收尾 · 服务器端补验（bioinfo-lab, CentOS 7 / R 4.2.0 / Python 3.7.10）
#
# 用法：
#   cd /path/to/Scripts_New      # 或你放重构分支的目录
#   bash run_server_verification.sh
#
# 可选环境变量：
#   REPO_DIR        重构分支所在目录（默认：脚本所在目录）
#   RSCRIPT         Rscript 路径（默认 /home/toolkit/local/bin/Rscript）
#   PYTHON          python 路径（默认 /usr/bin/python3）
#   REAL_REGISTRY   真实 sample_registry.json 路径（用于缺口 #7 核查；
#                   不设则跳过该项）
#   REAL_RESULTS    真实 RESULTS_DIR（用于 Obs 4/5 取证；不设则跳过）
#   OUTDIR          输出目录（默认 /tmp/p1_verify_<时间戳>）
#
# 本脚本只读代码，不修改任何被测脚本。
# 所有输出写入 $OUTDIR，结束时打包成 tar.gz 供 scp 回本机。
# ============================================================

set -u   # 未定义变量报错；不设 -e：本脚本设计为失败后继续

# ---------- 路径解析 ----------
SCRIPT_SELF="$0"
SCRIPT_DIR=$(cd "$(dirname "$SCRIPT_SELF")" && pwd)
REPO_DIR="${REPO_DIR:-$SCRIPT_DIR}"
RSCRIPT="${RSCRIPT:-/home/toolkit/local/bin/Rscript}"
PYTHON="${PYTHON:-/usr/bin/python3}"
STAMP=$(date +%Y%m%d_%H%M%S)
OUTDIR="${OUTDIR:-/tmp/p1_verify_${STAMP}}"
LOGDIR="$OUTDIR/logs"
SUMMARY="$OUTDIR/SUMMARY.txt"

mkdir -p "$LOGDIR"

# ---------- 输出helper ----------
RESULTS_LINES=""

say() { echo "$@" | tee -a "$SUMMARY"; }
hdr() {
    say ""
    say "============================================================"
    say "$1"
    say "============================================================"
}
note() {
    RESULTS_LINES="${RESULTS_LINES}$1
"
}

hdr "P1 服务器端补验  ${STAMP}"
say "REPO_DIR   : $REPO_DIR"
say "RSCRIPT    : $RSCRIPT"
say "PYTHON     : $PYTHON"
say "OUTDIR     : $OUTDIR"

cd "$REPO_DIR" || { say "!! 无法进入 REPO_DIR"; exit 1; }

# ============================================================
# 0. 前置检查
# ============================================================
hdr "0. 前置检查"

PREFLIGHT_OK=true

if [ -x "$RSCRIPT" ]; then
    say "R      : $("$RSCRIPT" --version 2>&1 | head -1)"
else
    say "!! Rscript 不存在或不可执行: $RSCRIPT"
    say "   提示: 服务器上 R 在 /home/toolkit/local/bin/R，Rscript 应在同目录"
    PREFLIGHT_OK=false
fi

if [ -x "$PYTHON" ]; then
    say "Python : $("$PYTHON" -V 2>&1)"
else
    say "!! python 不存在: $PYTHON"
    PREFLIGHT_OK=false
fi

# 关键文件是否就位（确认重构分支已 scp 上来）
MISSING_FILES=""
for f in tools/verify_equivalence.sh tools/test_infrastructure.py \
         tools/make_fixture.py tools/fingerprint.py tools/fingerprint.R \
         tools/qc_schema.py config/args.R \
         01_python_preprocessing/P1b_data_loading.py \
         01_python_preprocessing/P2a_select_k.py \
         02_R_core_pipeline/R01_build_seurat.R; do
    [ -f "$f" ] || MISSING_FILES="${MISSING_FILES} $f"
done
if [ -n "$MISSING_FILES" ]; then
    say "!! 缺少重构分支文件:${MISSING_FILES}"
    say "   请先把 refactor/p1-qoder 分支的内容 scp 到 $REPO_DIR"
    PREFLIGHT_OK=false
else
    say "重构分支文件: 齐全"
fi

# Python 包
"$PYTHON" - <<'PYEOF' 2>&1 | tee -a "$SUMMARY"
import sys
mods = ["numpy", "pandas", "scipy", "sklearn", "matplotlib", "h5py", "pyarrow"]
missing = []
for m in mods:
    try:
        mod = __import__(m)
        v = getattr(mod, "__version__", "?")
        sys.stdout.write("  py %-12s %s\n" % (m, v))
    except Exception:
        missing.append(m)
        sys.stdout.write("  py %-12s ABSENT\n" % m)
if missing:
    sys.stdout.write("  !! missing python packages: %s\n" % ", ".join(missing))
PYEOF

# R 包
if [ -x "$RSCRIPT" ]; then
    "$RSCRIPT" -e '
pkgs <- c("Seurat","SeuratObject","Matrix","data.table","jsonlite",
          "ggplot2","ggrepel","ggridges","gridExtra","pheatmap",
          "scales","viridis","matrixStats")
for (p in pkgs) {
  v <- tryCatch(as.character(packageVersion(p)), error=function(e) "ABSENT")
  cat(sprintf("  R  %-14s %s\n", p, v))
}' 2>&1 | tee -a "$SUMMARY"
fi

if ! $PREFLIGHT_OK; then
    say ""
    say "前置检查未通过，后续步骤将大概率失败。仍继续执行以收集诊断信息。"
fi

# ============================================================
# 1. set.seed 现状（只读报告，不修改代码）
# ============================================================
hdr "1. set.seed 现状（P0 Step 4 遗留项）"
say "说明: 本脚本不修改代码。以下仅报告 R01-R09 顶部是否已有显式 set.seed。"
say "      进 P2 容器化之前需要补齐，否则容器内 BLAS 变化导致的数值差异"
say "      无法与随机性区分。"
say ""
SEED_MISSING=""
for f in 02_R_core_pipeline/R0[1-9]_*.R; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    if grep -q "set\.seed(" "$f"; then
        say "  $b : 有 set.seed"
    else
        say "  $b : 无 set.seed   <-- 需补"
        SEED_MISSING="${SEED_MISSING} $b"
    fi
done
if grep -q "seed\.use" 02_R_core_pipeline/R02_sctransform.R 2>/dev/null; then
    say "  R02 SCTransform seed.use : 已显式指定"
else
    say "  R02 SCTransform seed.use : 未显式指定（依赖默认 1448145）<-- 需补"
fi
note "1. set.seed 缺失:${SEED_MISSING:- 无}"

# ============================================================
# 2. 缺口 #7：真实 22 样本是否都有 cell_area
# ============================================================
hdr "2. 缺口 #7 — 真实样本的 cell_area 列核查"
if [ -z "${REAL_REGISTRY:-}" ]; then
    say "SKIPPED — 未设置 REAL_REGISTRY。"
    say "  设置方式示例:"
    say "    REAL_REGISTRY=/path/to/Scripts_New/sample_registry.json \\"
    say "      bash run_server_verification.sh"
    note "2. cell_area 核查: SKIPPED (未设 REAL_REGISTRY)"
else
    "$PYTHON" - "$REAL_REGISTRY" > "$LOGDIR/gap7_cell_area.log" 2>&1 <<'PYEOF'
import json, os, sys
reg_path = sys.argv[1]
with open(reg_path) as fh:
    reg = json.load(fh)
print("registry: %s  (%d samples)" % (reg_path, len(reg)))
try:
    import pyarrow.parquet as pq
except Exception as e:
    sys.stdout.write("cannot import pyarrow: %s\n" % e)
    sys.exit(1)
missing = []
unreadable = []
for name, info in reg.items():
    p = os.path.join(info.get("path", ""), "cells.parquet")
    if not os.path.exists(p):
        unreadable.append((name, "cells.parquet not found"))
        continue
    try:
        cols = list(pq.ParquetFile(p).schema.names)
    except Exception as e:
        unreadable.append((name, str(e)))
        continue
    has = "cell_area" in cols
    print("  %-42s cell_area=%s  nucleus_area=%s" %
          (name, has, "nucleus_area" in cols))
    if not has:
        missing.append(name)
print("")
print("RESULT: %d/%d samples have cell_area" % (len(reg) - len(missing), len(reg)))
if missing:
    print("MISSING cell_area: %s" % ", ".join(missing))
if unreadable:
    print("UNREADABLE:")
    for n, e in unreadable:
        print("  %s : %s" % (n, e))
PYEOF
    tail -n 12 "$LOGDIR/gap7_cell_area.log" | tee -a "$SUMMARY"
    G7=$(grep "^RESULT:" "$LOGDIR/gap7_cell_area.log" 2>/dev/null | head -1)
    note "2. cell_area 核查: ${G7:-见 logs/gap7_cell_area.log}"
fi

# ============================================================
# 3. 生成 fixture
# ============================================================
hdr "3. 生成 fixture"
FIXTURE="$OUTDIR/fixture"
if "$PYTHON" tools/make_fixture.py --outdir "$FIXTURE" \
        > "$LOGDIR/make_fixture.log" 2>&1; then
    say "OK — fixture 生成成功: $FIXTURE"
    grep -E "Fixture_" "$LOGDIR/make_fixture.log" | tee -a "$SUMMARY"
    note "3. fixture 生成: OK"
    FIXTURE_OK=true
else
    say "FAIL — fixture 生成失败，日志尾部:"
    tail -n 15 "$LOGDIR/make_fixture.log" | sed 's/^/  | /' | tee -a "$SUMMARY"
    say ""
    say "  常见原因: scipy 1.7.3 的 sparse.random 对 numpy Generator 的支持，"
    say "            或 pandas 1.3.5 的 to_parquet。请把上面日志一并带回。"
    note "3. fixture 生成: FAIL (见 logs/make_fixture.log)"
    FIXTURE_OK=false
fi

# ============================================================
# 4. 测试套件基线（环境健康判定）
# ============================================================
hdr "4. 测试套件 test_infrastructure.py"
say "说明: 这是环境健康判定基准。若此处不是 18/18，"
say "      后续 verify_equivalence 的失败需先归因到环境。"
say ""
if RSCRIPT="$RSCRIPT" "$PYTHON" tools/test_infrastructure.py \
        > "$LOGDIR/test_infrastructure.log" 2>&1; then
    TS_RESULT=$(grep -E "tests passed" "$LOGDIR/test_infrastructure.log" | tail -1)
    say "OK — ${TS_RESULT:-passed}"
    note "4. 测试套件: ${TS_RESULT:-PASS}"
else
    TS_RESULT=$(grep -E "tests passed" "$LOGDIR/test_infrastructure.log" | tail -1)
    say "FAIL — ${TS_RESULT:-see log}"
    grep -E "^\[(PASS|FAIL)\]" "$LOGDIR/test_infrastructure.log" | tee -a "$SUMMARY"
    note "4. 测试套件: FAIL — ${TS_RESULT:-见 logs/test_infrastructure.log}"
fi

# ============================================================
# 5. verify_equivalence.sh（缺口 #1-#6 的主力）
# ============================================================
hdr "5. verify_equivalence.sh — 验收 A-F"
if $FIXTURE_OK; then
    VERIFY_OUT="$OUTDIR/verify_out"
    mkdir -p "$VERIFY_OUT"
    RSCRIPT="$RSCRIPT" PYTHON="$PYTHON" \
    DATA_DIR="$FIXTURE" RESULTS_DIR="$VERIFY_OUT" \
        bash tools/verify_equivalence.sh > "$LOGDIR/verify_equivalence.log" 2>&1
    VE_EC=$?
    say "退出码: $VE_EC"
    say ""
    say "---- A-F 汇总 ----"
    sed -n '/Criterion/,/PASS:.*SKIP:.*FAIL:/p' "$LOGDIR/verify_equivalence.log" \
        | tee -a "$SUMMARY"
    say ""
    say "---- Stage Failures ----"
    sed -n '/Stage Failures/,/^$/p' "$LOGDIR/verify_equivalence.log" \
        | head -40 | tee -a "$SUMMARY"
    VE_LINE=$(grep -E "^PASS: [0-9]" "$LOGDIR/verify_equivalence.log" | tail -1)
    note "5. verify_equivalence: ${VE_LINE:-见 logs/verify_equivalence.log}"
else
    say "SKIPPED — fixture 未生成成功"
    note "5. verify_equivalence: SKIPPED (fixture 失败)"
fi

# ============================================================
# 6. Observation 15 — R12 语法错误与历史版本
# ============================================================
hdr "6. Observation 15 — R12_close_gaps.R"
R12="02_R_core_pipeline/R12_close_gaps.R"
if [ -f "$R12" ] && [ -x "$RSCRIPT" ]; then
    if "$RSCRIPT" -e "invisible(parse('$R12'))" \
            > "$LOGDIR/r12_parse.log" 2>&1; then
        say "parse: OK — 仓库中的 R12 语法正常"
        note "6. R12 parse: OK"
    else
        say "parse: FAIL — 确认存在语法错误"
        tail -n 5 "$LOGDIR/r12_parse.log" | sed 's/^/  | /' | tee -a "$SUMMARY"
        note "6. R12 parse: FAIL (Obs 15 确认)"
    fi
    if [ -d .git ]; then
        say ""
        say "R12 的提交历史（最近 10 条）:"
        git log --oneline -10 -- "$R12" 2>/dev/null | sed 's/^/  /' | tee -a "$SUMMARY"
        say "  提示: 找一个 parse 通过的历史版本，用"
        say "        git show <sha>:$R12 > /tmp/R12_old.R  再 parse 一次"
    fi
else
    say "SKIPPED — 文件或 Rscript 不可用"
    note "6. R12 parse: SKIPPED"
fi

# ============================================================
# 7. Observation 4 / 5 取证（论文层面，非重构）
# ============================================================
hdr "7. Observation 4 / 5 取证"
if [ -z "${REAL_RESULTS:-}" ]; then
    say "SKIPPED — 未设置 REAL_RESULTS（真实 RESULTS_DIR）。"
    say "  这两条与重构无关，是论文结论层面的取证："
    say "    Obs 4: R07 的 composition/regulation 统计是否恒为 NA"
    say "    Obs 5: R09 的 MB_RL_SIG 是否实际等同 15 基因先验集"
    note "7. Obs 4/5 取证: SKIPPED (未设 REAL_RESULTS)"
else
    "$PYTHON" - "$REAL_RESULTS" > "$LOGDIR/obs45_evidence.log" 2>&1 <<'PYEOF'
import os, sys, csv
root = sys.argv[1]

def head_cols(path, n=3):
    with open(path, newline="", encoding="utf-8", errors="replace") as fh:
        r = csv.reader(fh)
        rows = []
        for i, row in enumerate(r):
            rows.append(row)
            if i >= n:
                break
    return rows

print("=== Obs 4: R07 composition/regulation ===")
found = False
for dirpath, dirnames, filenames in os.walk(os.path.join(root, "R7_Results")):
    for fn in filenames:
        if fn.endswith(".csv"):
            p = os.path.join(dirpath, fn)
            try:
                rows = head_cols(p, 1)
            except Exception as e:
                print("  %s : unreadable (%s)" % (fn, e)); continue
            if not rows:
                continue
            cols = rows[0]
            hit = [c for c in cols
                   if "composition" in c or "regulation" in c or "effect" in c]
            if hit:
                found = True
                print("  %s -> %s" % (fn, hit))
                # count non-empty in those columns
                with open(p, newline="", encoding="utf-8",
                          errors="replace") as fh:
                    dr = csv.DictReader(fh)
                    counts = dict((c, 0) for c in hit)
                    total = 0
                    for rec in dr:
                        total += 1
                        for c in hit:
                            v = (rec.get(c) or "").strip()
                            if v not in ("", "NA", "nan"):
                                counts[c] += 1
                    for c in hit:
                        print("     %-28s non-NA %d / %d" % (c, counts[c], total))
if not found:
    print("  (未找到含 composition/regulation/effect 的 R7 输出)")

print("")
print("=== Obs 5: R09 tier / MB_RL_SIG ===")
r9 = os.path.join(root, "R9_Results")
if not os.path.isdir(r9):
    print("  R9_Results 不存在")
else:
    for dirpath, dirnames, filenames in os.walk(r9):
        for fn in sorted(filenames):
            p = os.path.join(dirpath, fn)
            if fn.endswith((".txt", ".json")):
                print("  --- %s (前 40 行) ---" % fn)
                try:
                    with open(p, encoding="utf-8", errors="replace") as fh:
                        for i, line in enumerate(fh):
                            if i >= 40:
                                break
                            print("    " + line.rstrip())
                except Exception as e:
                    print("    unreadable: %s" % e)
PYEOF
    tail -n 40 "$LOGDIR/obs45_evidence.log" | tee -a "$SUMMARY"
    note "7. Obs 4/5 取证: 见 logs/obs45_evidence.log"
fi

# ============================================================
# 8. 汇总与打包
# ============================================================
hdr "8. 汇总"
say ""
printf '%s' "$RESULTS_LINES" | tee -a "$SUMMARY"
say ""
say "完整日志: $LOGDIR"

TARBALL="/tmp/p1_verify_${STAMP}.tar.gz"
tar czf "$TARBALL" -C "$(dirname "$OUTDIR")" "$(basename "$OUTDIR")" \
    --exclude='fixture' --exclude='verify_out/*/[A-Z]*_Results' 2>/dev/null \
    || tar czf "$TARBALL" -C "$(dirname "$OUTDIR")" "$(basename "$OUTDIR")" 2>/dev/null

if [ -f "$TARBALL" ]; then
    say ""
    say "已打包: $TARBALL  ($(du -h "$TARBALL" 2>/dev/null | cut -f1))"
    say "取回方式（在本机执行）:"
    say "  scp -P <port> <user>@<server>:$TARBALL ."
else
    say ""
    say "打包失败，请手动取回 $OUTDIR"
fi

say ""
say "=== 完成 ==="
