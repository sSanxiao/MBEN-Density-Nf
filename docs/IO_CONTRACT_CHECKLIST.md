# P1 重构 · I/O 契约核对表（S1 + S2 完整版）

> 依据 SPEC v2。覆盖 Scope B 全部 12 个脚本（11 个改造对象 + 只读源 `P2_density_calculation.py`）。
> 状态：**S2 交付，待确认**。确认后进入 S3（基础设施）。
> 约定：正文中文；代码、路径、字段名英文。每条 Observation 注明验证方式。

---

## 0. 裁决记录（已生效）

| 编号 | 裁决 |
|---|---|
| Q1 | 方案 A。R01 全量与单样本模式一律输出 `<Subname>_seurat.rds`（无 `_R1` 后缀），R02 输入不变。v1 §3 的 `_R1.rds` 记入 Observations「规格勘误」。 |
| Q2 | 不采纳改缺省。`--registry` 一律新增为**覆盖手段**，缺省保持各脚本现有行为（P1b/P1c 读脚本自身目录，R01–R09 读 `$DATA_DIR`，P2 读 `$DATA_DIR`）。两处不一致记入 Observations。 |
| Q3 | 缺列补 NA，且：(a) 定义显式 canonical 列顺序常量，全量模式与分片合并共用；(b) 合并行序 = registry 迭代顺序，不是字母序。由 `tools/merge_qc.py` 实现，新增验收项 E。 |
| 更正 | 移除 S1 版 R03 观察 1（空 list 索引赋值）——已在 R 4.5.2 解释器实证为误报：`x <- list(); for (i in 1:5) x[[i]] <- i*10` 正常，前置位自动补 NULL。 |
| Q4 | 批准：单个 `--manifest`、两列格式不变、按 basename 归类；dataset/全局级输入走 `--indir`。**附强制校验**（S5 实现时不得沿用"静默跳过"习惯）：(a) 无法归类的 basename → 立即报错退出；(b) 某必需类型条目数为 0 → 立即报错退出；(c) 运行开始打印各类型条目数与样本覆盖情况。 |
| Q5 | 批准，附两条约束：(a) 排除集必须是**显式枚举的常量列表**，禁止正则/前缀匹配（如 `time.*`），防止误伤待比对列；(b) 指纹 JSON 必须含 `"excluded": [...]` 字段，且 `colnames` 仍包含被排除列——排除集本身可比对，列消失或排除集被悄悄扩大都能被发现。R09 的 `TIER_DECISION_REPORT.txt/.json` 与 `.png` 一并排除并记入 excluded。 |
| Q6 | 允许补装，但**只装 viridis 与 pheatmap**（不运行整个 `setup/install_deps.R`，防止连带升级 Seurat 等已装包）。装完在报告中记录版本。 |
| F 重述 | 仓库无 `renv.lock`/`requirements.txt`（Observation 13）。验收项 F 改为：`git diff` 显示 `setup/install_deps.R` 未被修改，且所有流水线脚本（P1*、P2*、R0*）未新增任何 `install.packages` / 新包 `library()` / `pip install` 调用。Q6 的补装属本机环境准备，不计入 F。 |
| Obs 边界 | Observation 4（R06→R07 列名不匹配）与 Observation 5（R09 tier 值匹配失效）属科学逻辑问题：按硬约束 1/2 只报告不修，S3–S7 任何环节不得规避或补偿，fixture 设计也不得为绕开这两处做特殊处理。 |

---

## 1. 运行环境与验证能力（已实测）

| 项 | 结果 |
|---|---|
| R | `D:\R-4.5.2\bin\Rscript.exe`，R 4.5.2（不在 PATH；所有调用经环境变量 `RSCRIPT`，缺省 `Rscript`） |
| R 包（已装） | Seurat 5.4.0、SeuratObject 5.3.0、Matrix 1.7.4、data.table 1.18.2.1、jsonlite 2.0.0、ggplot2 4.0.2、ggrepel 0.9.6、gridExtra 2.3、**viridis 0.6.5、pheatmap 1.0.13**（S3 期间按 Q6 裁决补装，仅这两个，未运行完整 install_deps.R） |
| R 包（缺失） | harmony 也缺失，但 Scope B 不用 |
| Python | 3.9.13；numpy 2.0.2、pandas 2.3.3、h5py 3.14.0、scipy 1.13.1、sklearn 1.5.1、matplotlib 3.9.2、pyarrow 21.0.0（`read_parquet` 引擎可用） |
| 依赖清单文件 | **仓库中不存在 `renv.lock` 与 `requirements.txt`**（Glob 确认）。验收项 F 只能表述为「未新增依赖、未改动 setup/install_deps.R」 |

**确定性探针（解释器实测）**：同一简化链（Normalize→PCA→FindNeighbors→FindClusters→RunUMAP）在两个独立 Rscript 进程中聚类标签与 UMAP 嵌入的 md5 完全一致。完整 SCTransform 链的确定性待 S6 在 fixture 上复核。

**L3 评估**：除 R05/R06 因缺 viridis/pheatmap 受阻外，其余 R 脚本依赖齐全（见 §10-Q6）。

---

## 2. 全局目录约定与 registry 不一致（原样保留）

| 环境变量 | 缺省 | 用途 |
|---|---|---|
| `DATA_DIR` | `./data` | Xenium 原始数据 + R 侧 registry |
| `RESULTS_DIR` | `./results` | 所有阶段输出根 |
| `EXTDATA_DIR` | `./external_data` | Scope B 不涉及 |

**registry 定位（不统一，按 Q2 裁决原样保留，只加 `--registry` 覆盖）**：

| 脚本 | 缺省 registry 位置 |
|---|---|
| `P1b`、`P1c` | `SCRIPT_DIR/sample_registry.json`（脚本自身目录） |
| `P2`（及新建 P2a/P2b）、`R01`–`R09` | `$DATA_DIR/sample_registry.json` |

**输出目录布局**（全量模式，改造后不变）：
`$RESULTS_DIR/{P1,P2,R1..R9}_Results/{Dataset}/{Subname}/…`，跨样本汇总表写在各 `*_Results/` 根。
例外：R05 输出按图类分子目录 `R5_Results/{scatter_plots,heatmaps,lollipop,spatial}/`；R08 有 `R8_Results/pairwise_comparisons/{A}_vs_{B}/`。

**registry JSON 迭代顺序**：Python `json.load` 与 R `jsonlite::fromJSON` 均保持文件内插入顺序——这是 Q3(b)「registry 迭代顺序」的实现基础，两侧一致。

---

## 3. QC 表 canonical 列顺序（merge_qc.py 契约，§3.2 落实方案）

跨语言无法共享同一个运行时常量，因此：**下表是唯一的列序事实来源**；Python 侧（P1b 全量模式、`merge_qc.py`）通过 `tools/qc_schema.py` 的同一常量共享；R 侧全量模式按此表顺序构造 `data.frame`（现有代码顺序已与此表一致，改造时冻结）。

| 表 | canonical 列顺序（★=条件列，缺失补 NA） | 易变列（指纹排除，见 §6） |
|---|---|---|
| `ALL_SAMPLES_P1_QC.csv` | sample_name, species, condition, preservation, data_quality_tier, h5_path_type, n_features_raw, n_controls_removed, n_genes_final, n_cells_raw, n_cells_removed, n_cells_final, nonzero_elements, nonzero_fraction, sparsity_pct, ★median_transcripts, ★mean_transcripts, ★median_cell_area, ★median_nucleus_area | 无 |
| `ALL_SAMPLES_P2_QC.csv` | sample, dataset, species, condition, n_cells, k_aggr, k_main, k_cons, median_density_knn_main, n_valid_voronoi, n_valid_delaunay, pct_valid_voronoi, pct_valid_delaunay, corr_knn_main_voronoi, corr_knn_main_delaunay, corr_knn_aggr_main, corr_knn_main_cons, time_knn_s, time_voronoi_s, time_delaunay_s | time_knn_s, time_voronoi_s, time_delaunay_s |
| `ALL_SAMPLES_R1_QC.csv` | sample_name, dataset, species, condition, data_quality_tier, n_genes, n_cells, median_nCount, median_nFeature, median_density_knn, median_cell_area, vor_na_count, del_na_count, ncount_tc_cor, rds_size_mb | rds_size_mb |
| `ALL_SAMPLES_R2_QC.csv` | sample_name, dataset, n_genes, n_cells, n_var_features, n_pcs_selected, n_pcs_elbow, n_pcs_threshold, cum_var_pct, n_clusters, residual_mean, residual_sd, time_seconds, rds_size_mb | time_seconds, rds_size_mb |
| `ALL_SAMPLES_R3_SUMMARY.csv` | sample_name, dataset, species, condition, n_genes, n_cells, n_sig_q005, n_sig_q001, n_pos_q005, n_neg_q005, pct_sig, median_abs_rho, max_abs_rho, n_method_robust, n_high_confidence, n_K_sensitive, n_not_significant, top1_gene, top1_rho, time_seconds | time_seconds |
| `ALL_SAMPLES_R4_SUMMARY.csv` | sample_name, dataset, species, condition, n_genes, n_tier1, n_tier1_pos, n_tier1_neg, n_tier2, n_tier3, n_not_sig, n_top10pct, n_top20pct, median_abs_rho, max_abs_rho, top10pct_threshold, top20pct_threshold, top1_tier1_gene, top1_tier1_rho | 无 |
| `ALL_SAMPLES_R6_SUMMARY.csv` | sample_name, dataset, n_cells, n_clusters, n_clusters_valid, n_tier1, n_composition_driven, n_regulation_present, n_cluster_heterogeneous, n_mixed, cc_analyzed, cc_s_genes_matched, cc_g2m_genes_matched, cc_rho_s, cc_rho_g2m, time_seconds | time_seconds |

**行顺序**：一律 registry 迭代顺序（合并时按 registry 键重排分片，不是字母序）。
**单样本分片文件名**（`--sample` 模式）：`p1_qc.csv`、`density_qc.csv`（P2b，旧 P2 本来就逐样本写它）、`r1_qc.csv`、`r2_qc.csv`、`r3_summary.csv`、`r4_summary.csv`、`r6_summary.csv`。分片 = 同列序单行表。

---

## 4. 逐 stage 契约

### 4.1 P1b_data_loading.py（346 行，per-sample）

**读**：registry（缺省 `SCRIPT_DIR`）；每样本 `{registry.path}/cell_feature_matrix.h5`（自动适配 `matrix/` 与 `unknown/` 两种 HDF5 布局）+ `cells.parquet`（必需列 `cell_id, x_centroid, y_centroid`；可选列 `transcript_counts, cell_area, nucleus_area, control_probe_counts, control_codeword_counts`）。

**写（全量）**：`$RESULTS_DIR/P1_Results/{D}/{S}/filtered_matrix.h5`（标准 10x，`matrix/features/{name,id,feature_type,genome}`）、`cell_metadata.csv`；根级 `ALL_SAMPLES_P1_QC.csv`（列见 §3）。

**关键常量**：`MIN_TRANSCRIPTS = 10`；6 个 `CONTROL_PREFIXES`。

**单样本模式**：输出扁平写到 `--outdir`（`filtered_matrix.h5`、`cell_metadata.csv`、`p1_qc.csv`），不写 `ALL_SAMPLES_P1_QC.csv`。
**改造要点**：阶段 0（对照探查打印）在 `--sample` 模式下只对该样本执行；科学过滤逻辑（对照识别、对齐、空细胞过滤）逐字保留。

### 4.2 P1c_gene_intersection.py（316 行，fan-in/cohort，无 --sample）

**读**：registry（缺省 `SCRIPT_DIR`）；全部样本的 `P1_Results/{D}/{S}/filtered_matrix.h5`（只取基因名列表）。

**写**：`P1_Results/Gene_Intersection/` 下条件性输出——`pairwise_intersection_matrix_mouse.csv`、`pairwise_intersection_matrix_human.csv`、`pairwise_intersection_percent_human.csv`、`common_genes_mouse.txt`、`common_genes_human.txt`、`common_genes_cross_species.txt`、`unique_genes_per_dataset.csv`、`preview_internal_comparison.csv`（仅当存在 ≥2 个 Brain_Human_Preview 样本）、`cross_species_pairwise.csv`、`full_intersection_report.txt`（**无时间戳**，内容确定性）。哪些文件产出取决于物种构成（fixture 设计须注意，见 §10-Q4 备注）。

**改造要点**：加 `--registry/--indir/--outdir` 覆盖；`Brain_Human_Preview` 特判（L178、L216）属科学逻辑，原样保留。

### 4.3 P2_density_calculation.py（633 行，只读源 → 拆 P2a/P2b）

**读**：registry（`$DATA_DIR`）；`P1_Results/{D}/{S}/cell_metadata.csv`（仅 `cell_id, x_centroid, y_centroid`）。

**拆分边界（§8 详述）**：
- 阶段 0（L408–416）分组 → 两边各留一份（P2a 按 `--dataset` 过滤，P2b 按 `--sample` 取 dataset）
- 阶段 1（L430–573）→ **P2a_select_k.py**
- 阶段 2（L606–742）→ **P2b_density.py**
- 阶段 3（L751–752 汇总写 `ALL_SAMPLES_P2_QC.csv`）→ 全量模式保留在 P2b 的无 `--sample` 分支

**写（全量）**：`P2_Results/{D}/KNN_Optimization/{k_decision_table.csv, all_samples_knn_cv.csv, k_optimization_diagnostic.png}`；`P2_Results/ALL_DATASETS_K_SELECTION.csv`；`P2_Results/{D}/{S}/{cell_density.csv(8列), density_diagnostics.png, density_qc.csv}`；`P2_Results/ALL_SAMPLES_P2_QC.csv`。

`cell_density.csv` 列：`cell_id, x_centroid, y_centroid, density_knn_aggr_2nd_diff, density_knn_main_piecewise, density_knn_cons_max_dist, density_voronoi, density_delaunay`。

### 4.4 R01_build_seurat.R（276 行，per-sample）

**读**：registry（`$DATA_DIR`）；`P1_Results/{D}/{S}/filtered_matrix.h5`（`Read10X_h5`）+ `cell_metadata.csv`（`fread`，按 Seurat 细胞顺序 `match`）；`P2_Results/{D}/{S}/cell_density.csv`。
**合并列**：meta 5 列（`x_centroid, y_centroid, transcript_counts, cell_area, nucleus_area`）+ 5 列密度 + registry 6 字段（`species, condition, preservation, panel_name, segmentation, data_quality_tier`）+ `dataset` + `sample_name`。
**写**：`R1_Results/{D}/{S}/<Subname>_seurat.rds`（**无 `_R1` 后缀，Q1 裁决**）；`R1_Results/ALL_SAMPLES_R1_QC.csv`。
**单样本模式**：`<Subname>_seurat.rds` + `r1_qc.csv` 扁平写出。
**科学常量**：`CreateSeuratObject(min.cells=0, min.features=0)`，不做过滤。

### 4.5 R02_sctransform.R（397 行，per-sample）

**读**：registry；`R1_Results/{D}/{S}/<Subname>_seurat.rds`。
**科学常量**：`SCTransform(variable.features.n=min(3000,n_genes), return.only.var.genes=FALSE)`；`MAX_PCS_COMPUTE=50`；`auto_select_pcs` 二阶差分+1% 阈值取大；`RunUMAP(dims=1:n_pcs)`；`FindNeighbors/FindClusters(resolution=0.8)`。
**写**：`R2_Results/{D}/{S}/<Subname>_seurat_R2.rds` + 图件（`elbow_plot.png`、`umap_clusters.png`、`umap_density.png`、`umap_ncount.png`、`spatial_clusters.png`）；`R2_Results/ALL_SAMPLES_R2_QC.csv`。
**注意**：Seurat 5.4.0 的 RunUMAP 缺省已切换为 UWOT（运行时有 warning，行为确定），新旧同环境跑，不影响 A/B 对比。

### 4.6 R03_density_gene_correlation.R（403 行，per-sample）

**读**：registry；`R2_Results/{D}/{S}/<Subname>_seurat_R2.rds`（取 `GetAssayData(assay="SCT", layer="data")`）。
**写**：`R3_Results/{D}/{S}/density_gene_correlations.csv`（26 列：`gene` + 每方法 `rho_/p_/n_cells_/q_/sig_` ×5 + `convergence`；按 `-abs(rho_knn_main)` 降序）；`R3_Results/ALL_SAMPLES_R3_SUMMARY.csv`。
**科学常量**：`n_valid<10` 返回全 NA；批 100；FDR=BH；双阈值 0.01/0.05；收束标签五值。

### 4.7 R04_filter_density_genes.R（360 行，per-sample）

**读**：registry；`R3_Results/{D}/{S}/density_gene_correlations.csv`。
**写**：`R4_Results/{D}/{S}/filtered_density_genes.csv`（31 列 = R3 26 列 + `abs_rho_main, tier, top_10_pct, top_20_pct, direction`；按 `-abs_rho_main` 降序）+ 3 张诊断图；`R4_Results/ALL_SAMPLES_R4_SUMMARY.csv`。
**科学常量**：`RHO_TIER1=0.10, RHO_TIER2=0.05, Q_TIER1=0.01, Q_TIER2=0.05`；tier 四级级联赋值。

### 4.8 R05_visualization.R（241 行，per-sample + 跨样本图）

**读**：registry；`R4_Results/{D}/{S}/filtered_density_genes.csv` + `R2_Results/{D}/{S}/<Subname>_seurat_R2.rds`。
**写**：仅图件，`R5_Results/{lollipop,scatter_plots}/`（逐样本）、`R5_Results/heatmaps/`（按 dataset 聚合）、`R5_Results/spatial/`（`SPATIAL_TARGETS` 硬编码 6 个真实样本-基因对）。
**单样本模式**：只产 lollipop + scatter（tier1 top3）；heatmaps/spatial 留在全量模式。**图件不参与指纹校验**。

### 4.9 R06_cell_state_coupling.R（342 行，per-sample）

**读**：registry；`R2_Results/{D}/{S}/<Subname>_seurat_R2.rds` + `R4_Results/{D}/{S}/filtered_density_genes.csv`。
**写**：`R6_Results/{D}/{S}/` 下 `cluster_density_profile.csv`（必写）、`cell_state_coupling.csv`（条件：有 tier1 且有效 cluster）、`cell_cycle_density.csv`（条件：Tirosh 匹配 ≥5）、图件；`R6_Results/ALL_SAMPLES_R6_SUMMARY.csv`。
**科学常量**：`MIN_CELLS_PER_CLUSTER=100`、`COMPOSITION_THRESHOLD=0.5`、`MIN_CC_GENES=5`；effect 四标签判定。
**注意**：`CellCycleScoring` 走 `AddModuleScore`（确定性分箱，无随机抽样），同输入同输出。

### 4.10 R07_sample_integration.R（320 行，fan-in）

**读**（registry 驱动的路径构造 + `file.exists` 检查，非目录扫描）：每样本 `R3 …/density_gene_correlations.csv`、`R4 …/filtered_density_genes.csv`、`R6 …/cell_state_coupling.csv`（可选）。
**写**：`R7_Results/{D}/{S}/sample_density_profile.csv`；`R7_Results/{D}/dataset_consistency.csv`（列含 `rho_<D>_<S>` 动态列）；`R7_Results/ALL_SAMPLES_R7_PROFILE.csv`、`ALL_DATASETS_R7_CONSISTENCY.csv`。
**科学常量**：`CONSISTENCY_THRESHOLD=0.5`。

### 4.11 R08_cross_dataset_comparison.R（532 行，fan-in）

**读**：每样本 R3/R4 csv（registry 驱动）；`R7_Results/{D}/dataset_consistency.csv`。`P1_INTERSECTION_DIR` 定义于 L27 但**全文未使用**（Observation）。
**写**：`R8_Results/pairwise_comparisons/{A}_vs_{B}/{gene_level_comparison.csv, comparison_summary.csv, rho_scatter.png}`；根级 `ALL_COMPARISONS_R8_SUMMARY.csv`、`global_density_gene_landscape.csv`、`global_gene_summary.csv`。`cross_species_comparisons/` 目录被创建但**从不写入**（跨物种比较也落到 pairwise_comparisons，Observation）。
**科学常量**：`MIN_SHARED_GENES=50`；同物种直接比、跨物种大写统一；Fisher `alternative="greater"`。

### 4.12 R09_tier_decision.R（637 行，fan-in）

**读**：每样本 `R3 …/density_gene_correlations.csv`（列名用 grep 探测）；MB 样本的 R4 csv；`R7_Results/ALL_DATASETS_R7_CONSISTENCY.csv`；`R8_Results/ALL_COMPARISONS_R8_SUMMARY.csv`；每样本 `R2 …/<Subname>_seurat_R2.rds`。
**写**：`R9_Results/per_sample_signal_profile.csv`、`reproducibility_summary.csv`（条件）、`signature_auc_per_sample.csv`（**带断点续跑缓存**：文件已存在则读入并跳过已完成样本）、`TIER_DECISION_REPORT.txt` / `.json`（**内嵌 `format(Sys.time())` / `generated_at` 时间戳**）。
**科学常量**：3 个 signature 基因集、`DENSITY_PCTL_LOW/HIGH=0.20/0.80`、AUC 阈值 0.75/0.65、Tier 判定规则。

---

## 5. 跨 stage 接口核对（源码行号为证）

| 接口 | 上游写 | 下游读 | 一致 |
|---|---|---|---|
| P1b→P1c | `P1_Results/{D}/{S}/filtered_matrix.h5` | P1c L109 | ✅ |
| P1b→P2 | `…/cell_metadata.csv` | P2 L442/625 | ✅ |
| P2→R01 | `P2_Results/{D}/{S}/cell_density.csv` | R01 L76 | ✅ |
| R01→R02 | `<Subname>_seurat.rds` | R02 L239–240 | ✅ |
| R02→R03/R05/R06/R09 | `<Subname>_seurat_R2.rds` | R03 L212、R05 L166、R06 L62、R09 L418 | ✅ |
| R03→R04 | `density_gene_correlations.csv` | R04 L76 | ✅ |
| R04→R05/R06/R07/R08/R09 | `filtered_density_genes.csv` | R05 L165、R06 L64、R07 L69、R08 L82、R09 L246 | ✅ |
| R06→R07 | `cell_state_coupling.csv` | R07 L77 | ⚠️ 文件名对上但**列名对不上**（Obs-4） |
| R07→R08/R09 | `dataset_consistency.csv` / `ALL_DATASETS_R7_CONSISTENCY.csv` | R08 L90、R09 L155 | ✅ |
| R08→R09 | `ALL_COMPARISONS_R8_SUMMARY.csv` | R09 L166 | ✅ |

---

## 6. 指纹与易变字段（fingerprint.{R,py} 设计输入）

1. **易变列**：`time_seconds, rds_size_mb, elapsed_s, time_knn_s, time_voronoi_s, time_delaunay_s` 在两次运行间必然不同。**若不排除，验收 A（重构前后全量指纹 100% 相同）在原理上不可能通过**——A 比的是两次独立运行的产物。建议：指纹工具内置 `VOLATILE_COLUMNS` 常量，逐列排除（见 §10-Q5）。
2. **内嵌时间戳的非 CSV 产物**：R09 的 `TIER_DECISION_REPORT.txt/.json`。建议与 `.png` 一样排除出指纹对比。
3. **序列化约定（SPEC §4.5）**：数值 `%.10f`、`\n` 连接、UTF-8 无 BOM、无结尾多余换行；R 侧 `tools::md5sum()` 走临时文件，Python 侧 `hashlib.md5`。
4. **NA 处理**：md5 序列化时 NA 统一记为字符串 `"NA"`（两侧一致）；`min/max/sum` 用 na.rm 语义。
5. **.rds 指纹**：`dim`、`cells_md5`、`features_md5`、每 assay 每 layer 的 `sum`/非零元数、`meta_colnames`、5 列 density 各自 md5；排除 `@commands` 与时间戳。注意 Seurat 5.4.0 是 Assay5/layer 结构，`fingerprint.R` 用 `Layers()` 枚举。

---

## 7. R07–R09 文件发现逻辑（--manifest 改造依据）

三者均**不是目录扫描**，而是「registry 迭代 + `file.path({R3,R4,R6,R7,R8}_DIR, D, S, 固定文件名)` + `file.exists` 检查」。这与 SPEC §3.3 的表述（"扫描目录"）不同，记入 Observations。

`--manifest` 改造要点：
- 每行 `<Dataset/Subname>\t<file path>`（SPEC 格式）。
- 每个脚本需要**多类**输入（R07 需 R3+R4+R6 三类；R09 需 R3+R4+R2-rds）。由于各类文件名唯一（`density_gene_correlations.csv` / `filtered_density_genes.csv` / `cell_state_coupling.csv` / `*_seurat_R2.rds`），**单个 manifest 内按 basename 归类**即可满足 SPEC 行格式（见 §10-Q4）。
- dataset 级/全局级输入（R07 的 `dataset_consistency.csv` 是 R07 自己产的；R09 读的 R7/R8 汇总表）不属于 per-sample manifest，仍由 `--indir` 定位。
- 无 `--manifest` 时完全走旧路径构造逻辑（硬约束 3）。

---

## 8. P2 拆分边界（P2a/P2b 依据）

**P2a_select_k.py**（搬运阶段 1，按 `--dataset` 单个执行）：
- 输入：`--indir`（P1 输出根）+ registry（筛出该 dataset 的样本）
- 计算：每样本 BallTree `n_neighbors=max(K_CANDIDATES)+1=51` → 逐 K 的 CV（`np.std/np.mean(1/dist_k)`，0 距离替换 `eps`）与中位距离；跨样本 `mean_cv`；三方法选 K；**`sorted()` 重排使 aggr≤main≤cons**（L491–492，科学逻辑原样保留）
- 输出：`k_selection.json`（SPEC §3.1 schema）、`k_decision_table.csv`、`all_samples_knn_cv.csv`、`k_optimization_diagnostic.png`
- 共享函数原样复制：`K_CANDIDATES`、`BIO_SCALES`、`classify_bio_scale`、`find_k_2nd_diff`、`find_k_piecewise`、`find_k_max_distance`、`plot_k_optimization`

**P2b_density.py**（搬运阶段 2，按 `--sample` 单个执行）：
- 输入：`cell_metadata.csv`（`--indir` 或扁平传入）+ `--kfile k_selection.json`
- 计算：BallTree `n_neighbors=max(3K)+1`（与原阶段 2 一致）；三列 KNN 密度；Voronoi（开放多边形 NaN + 1% 分位截断）；Delaunay（平均边长倒数 + 1% 截断）；5×5 Spearman 相关矩阵
- 输出：`cell_density.csv`、`density_qc.csv`、`density_diagnostics.png`
- 全量模式（无 `--sample`）：遍历 registry + 阶段 3 汇总，与原 P2 逐字节等价

**确定性**：P2 全程无随机源（BallTree/Voronoi/Delaunay 均确定），验收 D 可直接比指纹。

---

## 9. Observations（只报告不修；每条注明验证方式）

**规格勘误**
1. v1 §3 表格 R01 输出写 `<Subname>_seurat_R1.rds`，代码实为 `<Subname>_seurat.rds`（R01:253、R02:240 互证）。已按 Q1 裁决以代码为准。〔代码走查〕

**疑似 bug / 不一致**
2. registry 缺省位置不一致：P1b/P1c 读脚本目录，P2/R01–R09 读 `$DATA_DIR`。按 Q2 原样保留。〔代码走查〕
3. P1b 阶段 0：`gene_names.index(gn)` 返回**首个**匹配位置，重名 feature 会检查错误的 mask 位，且 O(n²)。〔解释器实证：`['GeneA','BLANK_x','GeneA'].index('GeneA') == 0`〕
4. R06→R07 列名对不上：R07 期望 `effect_class, n_clusters_analyzed, n_reg_clusters`，R06 实际写 `effect_label, n_clusters_tested, n_clusters_sig`。交集仅 `gene, median_within_rho` → R07 的 R6 合并永远只并入 1 个非键列，composition/regulation 统计恒为 NA。〔解释器实证：`intersect()` 结果 2/5〕
5. R09 的 MB tier1 提取匹配条件 `tier == "tier1" | tier == "1"`，而 R04 写的是 `tier1_strict` → 自动筛选永远空集，`MB_RL_SIG` 实际恒等于 15 基因先验集。成功分支的先验集是 15 基因，else 分支的回退集是 11 基因，两者长度与内容不同；失效仅在日志中以计数形式体现（R09:268 打印「自动筛 0 + 先验 15」），未触发任何告警或中止。〔解释器实证：4 个真实 tier 值 0 个匹配〕
6. R09 断点续跑缓存用 `split(cached, cached$sample)` 重建 `partC_rows`，split 按字母序重排 → 缓存命中场景下 `signature_auc_per_sample.csv` 行序变为字母序，与 registry 序不一致（首次全跑不受影响）。〔split 字母序行为已在解释器实证；R09 缓存场景未实际触发〕
7. R08 `P1_INTERSECTION_DIR` 定义后从未使用（dead code）；SPEC §3 表称 R08 输入含 "P1… 输出"，实际不读。〔grep 全文实证〕
8. R08 `cross_species_comparisons/` 目录被创建但从不写入；跨物种比较结果同样写入 `pairwise_comparisons/`。〔代码走查〕
9. QC 汇总表含运行时长/文件大小列（见 §6-1），跨运行不可复现。〔代码走查〕
10. R02/R03/R04/R05/R06/R07/R08/R09 对缺文件样本 `next` 跳过但仍写汇总表，下游无法从汇总表发现缺样；`do.call(rbind, list())` 在全跳过时报错。〔代码走查〕
11. R03 变量名 `residuals` 取自 `layer="data"`；实测该层取值范围 min=0、mean≈1.13（非负、非零中心），是 SCT 校正后 data 而非统计学残差（scale.data 层才含负残差）。语义疑点，不影响行为。〔解释器实证（data 层统计）〕
12. P1c docstring 未列出 `cross_species_pairwise.csv`（实际会写）。〔代码走查〕
13. 仓库不存在 `renv.lock` / `requirements.txt`（SPEC 验收项 F 的对象）；依赖声明实际载体是 `setup/install_deps.R`。〔文件系统 Glob 实证〕
14. SPEC §3.3 称 R07–R09 "扫描目录发现文件"，实际是 registry 驱动的路径构造（见 §7）。〔代码走查〕
15. `R12_close_gaps.R`（Scope B 之外，不动）在 L479 有预先存在的语法错误（`unexpected 'else'`），该脚本当前无法通过 `parse()`。Scope B 全部 9 个 R 脚本 parse 通过。〔R 4.5.2 解释器 parse() 实证〕

---

## 10. 待确认问题（S3 前置）

**Q4（manifest 形态）**：R07–R09 各自需要多类 per-sample 输入。建议：单个 `--manifest`，行格式不变（`<Dataset/Subname>\t<path>`），脚本按 basename 归类；dataset/全局级输入仍走 `--indir`。可否？
**Q5（指纹排除集）**：验收 A 是"两次独立运行"对比，`time_seconds/rds_size_mb/elapsed_s/time_*_s` 与 R09 的 `.txt/.json` 时间戳产物、`.png` 必须排除出指纹对比，否则 A 原理上不可能通过。建议按 §6 执行，可否？
**Q6（缺失包）**：R05/R06 需要 viridis/pheatmap（已在 `setup/install_deps.R` 声明，本机缺失，不属于新增依赖）。是否允许我运行 `setup/install_deps.R` 补装（只装缺的），还是接受 R05/R06 验证缺口并在报告中注明？
**fixture 备注（S3 已定稿）**：fixture 为 2 dataset × 2 样本（Fixture_Human: Donor1/Donor2；Fixture_Mouse: MouseA/MouseB）。Donor2 缺 `cell_area`（Q3 条件列）；MouseB 的 h5 用 `unknown` 布局，覆盖 P1b 双布局适配分支（h5_path_type 不再恒定）。P1c 分支覆盖实况（2 dataset 预算下的最大化）：同 dataset 内多样本一致性检查（Donor1/2、MouseA/B 基因列表相同 → "完全一致"分支）；dataset 级两两交集矩阵**不产生**（每物种只有 1 个 dataset，`len>=2` 分支不触发）；`cross_species_pairwise.csv` 产生（Fixture_Mouse × Fixture_Human 大写统一交集 = 190 基因）；`unique_genes_per_dataset.csv` 产生；`full_intersection_report.txt` 产生。未覆盖：`pairwise_intersection_matrix_{human,mouse}.csv`、`common_genes_{human,mouse}.txt`、`common_genes_cross_species.txt`、`preview_internal_comparison.csv`——均为 ≥2 同物种 dataset 或 Brain_Human_Preview 专属分支，超出 fixture 预算，S6 报告中如实列出。

---

## 11. S3 交付记录（含修订）

已交付：`config/args.R`、`tools/qc_schema.py`、`tools/fingerprint.py`、`tools/fingerprint.R`、`tools/merge_qc.py`、`tools/make_fixture.py`、`tools/test_infrastructure.py`。

**修订轮（首版不通过后）**：
1. **必修 1**：两侧指纹循环实际跳过 excluded 列（首版仅声明、未真正排除）。
2. **必修 2**：新增持久化测试套件 `tools/test_infrastructure.py`（6 用例，每条注明可证伪什么）：T1 易变列隔离（5 张含易变列的表 × 双实现各自自比）、T2 非易变列敏感性、T3 跨语言一致、T4 常量漂移锁、T5 excluded 审计、T6 漂移拒绝。
3. **必修 3**：`fingerprint.R --dump-constants` 输出 `CANONICAL_COLUMNS / VOLATILE_COLUMNS / SHARD_TO_TABLE / EXCLUDED_FILES` JSON，T4 断言其与 `qc_schema.py` 完全相等。
4. **需处理 4**：fixture 增加 `Fixture_Mouse/MouseB`（`unknown` h5 布局），P1b 双布局分支已实测覆盖（见 §10 fixture 备注）。
5. **观察 5**：确认 P1b 写出 int32（P1b_data_loading.py:235），`fingerprint_h5` 保留 `str(int(v))` 并加非整型 dtype 防御分支（改走 `fmt_num`）。

**fixture 定稿**：2 dataset × 2 样本（Fixture_Human: Donor1/Donor2；Fixture_Mouse: MouseA/MouseB），2000 细胞 × 200 features，固定种子，两次生成字节级一致（registry path 前缀除外）。回归基线：`test_infrastructure.py` 6/6 通过（该数字为 fixture 定稿时的用例数；测试套件后续扩充至 18 条，见 docs/S5b_REPORT.md），`fingerprint.R` parse OK。

**S3 收尾轮（补 1–3）**：
1. **补 1（.rds/.h5 指纹进测试套件）**：新增 T9（.rds）、T10（.h5）。T9 用同一段构造代码独立运行两次产出两个 Seurat 对象（`@commands$time.stamp` 必然不同），断言指纹逐字一致；反向用例改 counts 层一个值必须使指纹改变。T10 用同一 fixture 代码分别生成 matrix / unknown 两种布局各两次，断言指纹一致。均注明 falsifies。
2. **补 2（NA 与非精确小数）**：(a) **实证**：全 NA 数值列在 pandas 推断为 `float64`（进 numeric）、data.table::fread 推断为 `logical`（进 text）——同一文件两侧 JSON 结构不同，真实场景必然发生（全样本缺 cell_area 时的 `median_cell_area`、无基因入选时的 `top1_tier1_gene`）。**裁决**：按建议由 `qc_schema.NUMERIC_COLUMNS`（R 侧镜像 `NUMERIC_COLUMNS_R`）显式声明每列类型，两侧不再依赖读取端推断；未声明列默认 text。新增 T7（全 NA 声明数值列两侧均进 numeric 且 min/max/sum=NA）、T8（部分 NA + `0.12345678901234` / `-1e-11` / `1e8+0.05` / `2/3` 等非精确值跨语言 `%.10f` 一致）。(b)(c) 并入 T8。
3. **补 3（T6 收紧）**：R 侧断言 stderr 含 `refusing to fingerprint`（而非仅非零退出码，避免缺包/路径错误判通过）；Python 侧断言 `ValueError` 消息含 `refusing to fingerprint`（而非仅异常类型）。
4. **契约更新**：`--dump-constants` 现输出五组常量（新增 `NUMERIC_COLUMNS`），T4 断言范围随之扩展。

**回归基线（S3 收尾后）**：`tools/test_infrastructure.py` **10/10 通过**；`fingerprint.py` / `qc_schema.py` / `test_infrastructure.py` Python 语法 OK；`fingerprint.R` parse OK。
