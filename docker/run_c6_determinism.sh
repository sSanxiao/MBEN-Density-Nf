#!/usr/bin/env bash
# ============================================================
# docker/run_c6_determinism.sh
# ------------------------------------------------------------
# C6 判决实验：同一容器内、同一份 R01 输出，把 R02 连续跑两次，
# 比对 n_clusters 与 .rds 指纹。
#
# 可证伪的命题：
#   H0「R02 存在未播种的随机路径」——若两次输出不一致，则 H0 成立，
#      需要继续定位是哪一步用了未播种 RNG（此时补 set.seed 才有意义）。
#   H1「R02 完全确定」——若两次输出字节一致，则 n_clusters 的容器 vs
#      服务器差异纯粹是数值差异被确定性放大（BLAS → vst 拟合 → 残差 →
#      PCA → SNN → Louvain 落入不同局部最优），补 set.seed 解决不了。
#
# 若两次 n_clusters 相同但 .rds 字节不同，则 R02「语义确定、字节不确定」，
# 同样说明 n_clusters 差异不是未播种 RNG 造成的。
# ============================================================
set -uo pipefail
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

REPO_HOST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_HOST="${REPO_HOST//\\//}"
: "${FIXTURE_DIR:?FIXTURE_DIR 未设置。C5/C6 的原始 fixture 保留在 Thesis_project 的 docker/c5_verify/；本 repo 可用 tools/make_fixture.py 就地生成。}"
FIXTURE_HOST="$FIXTURE_DIR"
C5_HOST="$REPO_HOST/docker/c5_verify"

FIXTURE_CT="/tmp/p1_verify_20260812_182813/fixture"
C5_CT="/c5"
REPO_CT="/repo"

R_IMG="thesis-r:4.2.0"
REGISTRY_CT="$C5_CT/container_out/registry_rstage.json"
DET_CT="$C5_CT/determinism"

SAMPLES="Fixture_Human/Donor1 Fixture_Human/Donor3 Fixture_Mouse/MouseA Fixture_Mouse/MouseB"

mkdir -p "$C5_HOST/determinism"

r_run() {
  docker run --rm \
    -v "$REPO_HOST:$REPO_CT" \
    -v "$FIXTURE_HOST:$FIXTURE_CT" \
    -v "$C5_HOST:$C5_CT" \
    -w "$REPO_CT" \
    -e DATA_DIR="$FIXTURE_CT" \
    -e RESULTS_DIR="$DET_CT" \
    "$R_IMG" "$@"
}

for SAMPLE in $SAMPLES; do
  SAFE="${SAMPLE//\//_}"
  INDIR="$C5_CT/container_out/r_${SAFE}_R01"
  for RUN in run1 run2; do
    OUTDIR="$DET_CT/${RUN}_${SAFE}"
    echo ""
    echo "=== $SAMPLE  $RUN ==="
    r_run Rscript 02_R_core_pipeline/R02_sctransform.R \
      --sample "$SAMPLE" \
      --registry "$REGISTRY_CT" \
      --indir "$INDIR" \
      --outdir "$OUTDIR"
  done
done

echo ""
echo "=== R02 判决实验运行完成 ==="
echo "输出目录: $C5_HOST/determinism"
