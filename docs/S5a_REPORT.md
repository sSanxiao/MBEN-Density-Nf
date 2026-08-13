# S5a 模式横扫表

> 对 R01–R04 每个脚本的模式性改动逐项说明「适用/不适用/已应用」。
> 不适用的给理由。

## 横扫表

| 改动项 | R01 | R02 | R03 | R04 |
|---|---|---|---|---|
| `source("config/args.R")` | 已应用 | 已应用 | 已应用 | 已应用 |
| `--sample` 支持 | 已应用 | 已应用 | 已应用 | 已应用 |
| `--registry` 缺省保持 $DATA_DIR | 已应用 | 已应用 | 已应用 | 已应用 |
| `--indir` 覆盖上游目录 | 已应用（P1_DIR + P2_DIR 同时覆盖） | 已应用（R1_DIR） | 已应用（R2_DIR） | 已应用（R3_DIR） |
| `--outdir` 必需（单样本模式） | 已应用 | 已应用 | 已应用 | 已应用 |
| `--outdir` 缺省（全量模式） | 已应用（$RESULTS_DIR/R1_Results） | 已应用（$RESULTS_DIR/R2_Results） | 已应用（$RESULTS_DIR/R3_Results） | 已应用（$RESULTS_DIR/R4_Results） |
| 扁平输出（单样本模式） | 已应用（rds + qc 到 --outdir 根） | 已应用（rds + 图 + qc 到 --outdir 根） | 已应用（csv + summary 到 --outdir 根） | 已应用（csv + 图 + summary 到 --outdir 根） |
| 嵌套输出（全量模式） | 已应用（{D}/{S}/ 保持不变） | 已应用 | 已应用 | 已应用 |
| 分片写入（单样本模式） | 已应用（r1_qc.csv） | 已应用（r2_qc.csv） | 已应用（r3_summary.csv） | 已应用（r4_summary.csv） |
| 不写 ALL_SAMPLES_*（单样本模式） | 已应用 | 已应用 | 已应用 | 已应用 |
| ALL_SAMPLES_* 保留（全量模式） | 已应用 | 已应用 | 已应用 | 已应用 |
| manifest 带键 | 不适用（per-sample 脚本，输入是上游 rds/csv，不需 manifest） | 不适用（同 R01） | 不适用（同 R01） | 不适用（同 R01） |
| 输入路径扁平推导（单样本模式） | 已应用（`file.path(P1_DIR, "filtered_matrix.h5")`） | 已应用（`file.path(R1_DIR, "<Subname>_seurat.rds")`） | 已应用（`file.path(R2_DIR, "<Subname>_seurat_R2.rds")`） | 已应用（`file.path(R3_DIR, "density_gene_correlations.csv")`） |
| fail-fast：缺样本报错 | 已应用（`stop("--sample not in registry")`） | 已应用 | 已应用 | 已应用 |
| fail-fast：缺 --outdir 报错 | 已应用（`stop("--outdir is required")`） | 已应用 | 已应用 | 已应用 |
| 科学逻辑不变 | 已应用（CreateSeuratObject/min.cells=0 等原样保留） | 已应用（SCTransform/PCA/UMAP/聚类参数原样） | 已应用（Spearman/FDR/收束标签原样） | 已应用（tier 阈值/分级逻辑原样） |

## R01 输出文件名

R01 输出 `<Subname>_seurat.rds`（无 `_R1` 后缀），按 Q1 裁决以代码为准，未改名。

## 验证层级

本机 R 4.5.2 + Seurat 5.4.0。按 L3 组织。

**已知 Seurat 5.4.0 API 变更**（如实报告，不修代码）：
- R01 全量模式在 fixture 的 Donor2（缺 `cell_area` 列）上崩溃：`seurat_obj$cell_area` 在 Seurat 5.4.0 上访问不存在的 meta.data 列时报错而非返回 NULL。旧版 Seurat 返回 NULL，`median(NULL, na.rm=TRUE)` 返回 NA。这是旧代码在新版本上的 API 变更问题，非改造引入。真实 22 样本都有 `cell_area`，不受影响。
- Donor1（有 `cell_area`）全量模式与单样本模式均跑通。

## 跨环节验证

### 接缝用例：P2b 扁平 → R01 --sample

- P1b `--sample` 扁平输出 + P2b `--metadata` 扁平输出 → 同一 work dir
- R01 `--sample --indir <work_dir> --outdir <out>` 消费扁平产物
- R01 产出 `Donor1_seurat.rds` + `r1_qc.csv`
- **R01 rds 指纹：单样本 == 全量 ✓**

### 四级链条端到端指纹比对

| Stage | 产物 | 单样本 vs 全量指纹 |
|---|---|---|
| R01 | `Donor1_seurat.rds` | **True** ✓ |
| R02 | `Donor1_seurat_R2.rds` | **True** ✓（@commands 排除在 SCTransform+FindNeighbors+RunUMAP 累积后仍有效） |
| R03 | `density_gene_correlations.csv` | **True** ✓ |
| R04 | `filtered_density_genes.csv` | **True** ✓ |

### T13 seed 修复

`seed = abs(hash(sname))` 改为 `100 + idx` 固定整数（Python 字符串哈希跨进程随机化）。

## 持久化测试套件（T14/T15）

S5a 补充轮新增两条持久化测试用例（`tools/test_infrastructure.py` T14/T15），测试套件 15/15 通过。

### T14：P2b→R01 接缝（持久化）

- 生成 fixture → P1b `--sample` 扁平 → P2a `--metadata-list` → P2b `--metadata` 扁平 → R01 `--sample --indir --outdir`
- 断言 R01 产出 `Donor1_seurat.rds` + `r1_qc.csv`
- **falsifies**：R01 单样本模式输入路径不匹配 P2b 扁平输出布局

### T15：R01→R04 四级链条（持久化）

- T14 产出基础上 → R02 → R03 → R04 单样本链条
- 同时跑全量模式（环境变量驱动）作对照
- 断言 R03/R04 的 CSV 指纹单样本 == 全量
- **falsifies**：任何 stage 的单样本输出路径或内容偏离全量模式

### 反向验证（T14_REV / T15_REV）

| 用例 | 反向验证方式 | 结果 |
|---|---|---|
| T14 | 把 R01 单样本输入路径改回嵌套推导（buggy），指向扁平 work dir → R01 找不到文件 → 跳过 → 无 rds | **FAIL** ✓ |
| T15 | R03 `--indir` 指向不存在路径 → 无 R2 rds → 跳过 → 无 CSV | **FAIL** ✓ |

## 已知验证缺口

### (a) R 阶段等价验证的实际样本覆盖

R01–R04 的单样本 vs 全量指纹比对**只覆盖了 Donor1**（有 `cell_area`）。Donor2（缺 `cell_area`）在 R01 全量模式上因 Seurat 5.4.0 API 变更崩溃（见 Observation 17），未进入比对。因此验收 A/B 在 R 阶段的样本覆盖为 1/4（fixture 的 4 个样本中只有 Donor1 跑通）。

### (b) 条件列 NA 路径在 R 侧未执行

Donor2 的 `cell_area` 缺失 → R01 QC 收集的 `median(seurat_obj$cell_area, na.rm=TRUE)` 在 Seurat 5.4.0 上崩溃 → **条件列 NA 路径（`median_cell_area` 为 NA → 分片 → merge_qc NA 补齐）在 R 侧一次都没执行过**。Python 侧的 merge_qc NA 补齐有 T7/T8 覆盖，但 R 侧的 NA 产出→分片→合并全链条未验证。

### (c) 该缺口需在目标环境补验

上述缺口需在目标环境（R 4.2.0 + Seurat 5.2.1，`$` 访问不存在列返回 NULL）补验，**不得通过修改代码规避**（硬约束 1）。

"真实 22 样本都有 `cell_area`"是**未验证推测**——真实数据不在本机，无法核实。即使属实，条件列 NA 路径仍需在目标环境用缺列 fixture 验证。

## Observations（只报告不修）

16. P1c 的 `human_common` 在人只有 1 个 dataset 时未定义 → UnboundLocalError（L325）。既有 bug，非改造引入。〔代码走查〕
17. R01 L323 的 `seurat_obj$cell_area` 在 Seurat 5.4.0 上访问不存在的 meta.data 列时报错（`'cell_area' not found in this Seurat object`），旧版 Seurat 返回 NULL。这是 Seurat 5.4.0 API 变更，非改造引入。R02–R04 不存在同类 `$` 访问可选 meta.data 列的写法（R02 的 `$x_centroid`/`$y_centroid`/`$seurat_clusters` 均为 R01/R02 自身产出的必需列；R03/R04 读 CSV 不直接 `$` 访问 Seurat 对象）。〔Seurat 5.4.0 解释器实证〕
