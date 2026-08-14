#!/usr/bin/env bash
# docker/push_ghcr.sh — 打 tag + 推送到 GitHub Container Registry (GHCR)。
#
# 【本机备用路径】首选由 .github/workflows/build-images.yml 构建并推送；
# 本脚本仅用于本机应急。注意本机代理可能导致大层上传 stall（曾实测中断）。
#
# 只做 docker tag + docker push，不包含任何登录逻辑或凭据。
# 登录由使用者在本机单独执行：
#   docker login ghcr.io -u <USERNAME> --password-stdin
#
# 安全提醒：push 完成后请执行 docker logout ghcr.io。
# PAT 以 base64 形式存于 ~/.docker/config.json，用完即登出并删除 token。
#
# 用法：
#   GHCR_OWNER=ssanxiao GHCR_REPO=mben-density-nf bash docker/push_ghcr.sh
#
# 环境变量（可覆盖，不硬编码到 push 命令里）：
#   REGISTRY     默认 ghcr.io
#   GHCR_OWNER   owner（GHCR 强制小写）
#   GHCR_REPO    仓库名（GHCR 强制小写）
#   TAG_DATE     不可变标签日期，默认今天 (YYYYMMDD)
#
# 每个镜像同时打「不可变版本标签」+ latest：
#   ghcr.io/<owner>/<repo>/thesis-python:3.7.10-<日期>        (+ latest)
#   ghcr.io/<owner>/<repo>/thesis-r:4.2.0-seurat-5.2.1-<日期>  (+ latest)

set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io}"
OWNER="${GHCR_OWNER:-ssanxiao}"
REPO="${GHCR_REPO:-mben-density-nf}"
TAG_DATE="${TAG_DATE:-$(date +%Y%m%d)}"

# GHCR 不接受大写 owner/repo，统一转小写
OWNER=$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')
REPO=$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')

BASE="$REGISTRY/$OWNER/$REPO"

PY_SRC="thesis-python:3.7.10"
PY_VER="3.7.10-$TAG_DATE"

R_SRC="thesis-r:4.2.0"
R_VER="4.2.0-seurat-5.2.1-$TAG_DATE"

echo "== 打 tag =="
docker tag "$PY_SRC" "$BASE/thesis-python:$PY_VER"
docker tag "$PY_SRC" "$BASE/thesis-python:latest"
docker tag "$R_SRC"  "$BASE/thesis-r:$R_VER"
docker tag "$R_SRC"  "$BASE/thesis-r:latest"

echo "== push =="
docker push "$BASE/thesis-python:$PY_VER"
docker push "$BASE/thesis-python:latest"
docker push "$BASE/thesis-r:$R_VER"
docker push "$BASE/thesis-r:latest"

echo "== 完成 =="
echo "$BASE/thesis-python:$PY_VER"
echo "$BASE/thesis-python:latest"
echo "$BASE/thesis-r:$R_VER"
echo "$BASE/thesis-r:latest"