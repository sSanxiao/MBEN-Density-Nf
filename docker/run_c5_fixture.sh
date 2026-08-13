#!/usr/bin/env bash
# ============================================================
# docker/run_c5_fixture.sh
# ------------------------------------------------------------
# C5 (I 项): 在两个容器内跑通 fixture（P1b→P2a→P2b→R01→R04），
# 与服务器 /tmp/p1_verify_20260812_182813/verify_out/new_single 对照。
#
# 前置条件（用户指定，必须遵守）：
#   1. fixture 与服务器同一份（md5 已核对一致），不做本地重新生成。
#   2. R 阶段使用排除 Donor2 的子集 registry（Obs 17）。
#      P 阶段使用完整 registry（Donor2 覆盖条件列路径）。
#   3. P1c 不参与本脚本（Obs 16：单 Human dataset 必然 UnboundLocalError）。
#   4. 对照为服务器最近一次 run_server_verification.sh 的 verify_out。
#
# 挂载约定（容器内路径）：
#   /repo   = 仓库根（pipeline 脚本）
#   /tmp/p1_verify_20260812_182813/fixture = fixture（与 registry path 字段一致）
#   /out    = 容器输出根
# ============================================================
set -uo pipefail
# 防止 Git Bash (MSYS2) 把 /repo /out 等容器内 POSIX 路径转成 D:/Git/... 
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

REPO_HOST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_HOST="${REPO_HOST//\\//}"                      # Windows 反斜杠 -> 正斜杠
: "${FIXTURE_DIR:?FIXTURE_DIR 未设置。C5/C6 的原始 fixture 保留在 Thesis_project 的 docker/c5_verify/；本 repo 可用 tools/make_fixture.py 就地生成。}"
FIXTURE_HOST="$FIXTURE_DIR"
OUT_HOST="$REPO_HOST/docker/c5_verify/container_out"

FIXTURE_CT="/tmp/p1_verify_20260812_182813/fixture"
OUT_CT="/out"
REPO_CT="/repo"

PY_IMG="thesis-python:3.7.10"
R_IMG="thesis-r:4.2.0"

R_STAGE_EXCLUDE="Fixture_Human/Donor2"

mkdir -p "$OUT_HOST"

# ------------------------------------------------------------
# 生成 R 阶段子集 registry（排除 Donor2）
# ------------------------------------------------------------
R_REGISTRY_CT="$OUT_CT/registry_rstage.json"
python - "$FIXTURE_HOST/sample_registry.json" "$R_STAGE_EXCLUDE" "$OUT_HOST/registry_rstage.json" <<'PYEOF'
import sys, json
full_reg = sys.argv[1]
exclude_key = sys.argv[2]
out_path = sys.argv[3]
with open(full_reg) as f:
    reg = json.load(f)
reg.pop(exclude_key, None)
with open(out_path, 'w') as f:
    json.dump(reg, f, indent=2)
print("R-stage subset registry written: %d samples (1 excluded)" % len(reg))
PYEOF

SAMPLES="Fixture_Human/Donor1 Fixture_Human/Donor2 Fixture_Human/Donor3 Fixture_Mouse/MouseA Fixture_Mouse/MouseB"

py_run() {
  docker run --rm \
    -v "$REPO_HOST:$REPO_CT" \
    -v "$FIXTURE_HOST:$FIXTURE_CT" \
    -v "$OUT_HOST:$OUT_CT" \
    -w "$REPO_CT" \
    -e DATA_DIR="$FIXTURE_CT" \
    -e RESULTS_DIR="$OUT_CT" \
    "$PY_IMG" "$@"
}

r_run() {
  docker run --rm \
    -v "$REPO_HOST:$REPO_CT" \
    -v "$FIXTURE_HOST:$FIXTURE_CT" \
    -v "$OUT_HOST:$OUT_CT" \
    -w "$REPO_CT" \
    -e DATA_DIR="$FIXTURE_CT" \
    -e RESULTS_DIR="$OUT_CT" \
    "$R_IMG" "$@"
}

# ------------------------------------------------------------
# 3a. P1b per-sample（全部 5 样本）
# ------------------------------------------------------------
echo "=== 3a: P1b per-sample ==="
for SAMPLE in $SAMPLES; do
  SAFE_NAME="${SAMPLE//\//_}"
  echo "  P1b $SAMPLE -> /out/$SAFE_NAME"
  py_run python 01_python_preprocessing/P1b_data_loading.py \
    --registry "$FIXTURE_CT/sample_registry.json" \
    --sample "$SAMPLE" \
    --outdir "$OUT_CT/$SAFE_NAME"
done

# ------------------------------------------------------------
# 3b. P2a per-dataset（每个数据集一个 k_selection.json）
# ------------------------------------------------------------
echo "=== 3b: P2a per-dataset ==="
for DATASET in Fixture_Human Fixture_Mouse; do
  MANIFEST_CT="$OUT_CT/meta_${DATASET}.txt"
  : > "$OUT_HOST/meta_${DATASET}.txt"
  for SAMPLE in $SAMPLES; do
    D="${SAMPLE%%/*}"
    if [ "$D" = "$DATASET" ]; then
      SAFE_NAME="${SAMPLE//\//_}"
      printf '%s\t%s\n' "$SAMPLE" "$OUT_CT/$SAFE_NAME/cell_metadata.csv" >> "$OUT_HOST/meta_${DATASET}.txt"
    fi
  done
  echo "  P2a $DATASET -> /out/p2a_$DATASET"
  py_run python 01_python_preprocessing/P2a_select_k.py \
    --dataset "$DATASET" \
    --registry "$FIXTURE_CT/sample_registry.json" \
    --metadata-list "$MANIFEST_CT" \
    --outdir "$OUT_CT/p2a_${DATASET}"
done

# ------------------------------------------------------------
# 3c. P2b per-sample（全部 5 样本）
# ------------------------------------------------------------
echo "=== 3c: P2b per-sample ==="
for SAMPLE in $SAMPLES; do
  SAFE_NAME="${SAMPLE//\//_}"
  DATASET="${SAMPLE%%/*}"
  echo "  P2b $SAMPLE"
  py_run python 01_python_preprocessing/P2b_density.py \
    --sample "$SAMPLE" \
    --registry "$FIXTURE_CT/sample_registry.json" \
    --kfile "$OUT_CT/p2a_${DATASET}/k_selection.json" \
    --metadata "$OUT_CT/$SAFE_NAME/cell_metadata.csv" \
    --outdir "$OUT_CT/$SAFE_NAME"
done

# ------------------------------------------------------------
# 3d. R01-R04 per-sample（排除 Donor2）
# ------------------------------------------------------------
echo "=== 3d: R01-R04 per-sample ==="
for SAMPLE in $SAMPLES; do
  if [ "$SAMPLE" = "$R_STAGE_EXCLUDE" ]; then
    echo "  [SKIP] $SAMPLE (Obs 17)"
    continue
  fi
  SAFE_NAME="${SAMPLE//\//_}"
  R_INDIR="$OUT_CT/$SAFE_NAME"
  for r in R01_build_seurat R02_sctransform R03_density_gene_correlation R04_filter_density_genes; do
    R_PREFIX="${r%%_*}"
    R_OUTDIR="$OUT_CT/r_${SAFE_NAME}_${R_PREFIX}"
    echo "  $r $SAMPLE"
    r_run Rscript "02_R_core_pipeline/${r}.R" \
      --sample "$SAMPLE" \
      --registry "$R_REGISTRY_CT" \
      --indir "$R_INDIR" \
      --outdir "$R_OUTDIR"
    R_INDIR="$R_OUTDIR"
  done
done

echo ""
echo "=== 容器内 fixture 运行完成 ==="
echo "输出目录: $OUT_HOST"
