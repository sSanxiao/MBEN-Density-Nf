# ============================================================
# tools/r_env_probe.R — R 环境探针
#
# 在 R 相关 process 内调用，打印实际使用的 R 解释器版本、库路径与
# Seurat 版本。用于验证 standard profile 走的是 Windows 原生 R 4.5.2
# （而非 WSL 侧解释器，HANDOFF §1.3）。单独成文件是因为通过
# `Rscript -e` 内联时，表达式里的双引号会被 WSL→Windows 跨调用破坏。
# ============================================================

cat("R_VERSION:", R.version.string, "\n", sep=" ")
cat("LIBPATHS:", paste(.libPaths(), collapse=";"), "\n", sep=" ")
cat("SEURAT:", as.character(packageVersion("Seurat")), "\n", sep=" ")
