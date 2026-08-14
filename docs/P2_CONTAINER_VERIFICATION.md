> **迁移说明**：本文档原为 `docker/README.md`，迁入 `mben-density-nf` 时改写路径引用。
> 文中所有 `docker/c5_verify/` 路径指向的验证产物（fixture、container_out、verify_out、
> fp_*.json、p1_verify.tar.gz 等）因体积较大，保留在 `Thesis_project` 仓库，未迁入本 repo。
> 本 repo 可用 `tools/make_fixture.py` 就地生成等价 fixture。

# docker/ — 容器化环境与 C5 数值等价验证

本目录是 P2（容器化）阶段的交付物。两个镜像已在 C2/C3 构建并验证：

| 镜像 | 基底 | 用途 |
|---|---|---|
| `thesis-python:3.7.10` | `python:3.7-slim` | P1b / P2a / P2b |
| `thesis-r:4.2.0` | `rocker/r-ver:4.2.0` | R01–R04 |

---

## 1. C5 前置条件（必须遵守）

1. **fixture 与服务器同一份**。本机 fixture 目录为
   `[Thesis_project] docker/c5_verify/p1_verify_20260812_182813/fixture`，是从服务器
   `/tmp/p1_verify_20260812_182813/fixture` 整体拷贝而来（经
   `p1_verify.tar.gz` 下载），**不在容器内重新生成**，两边比对的是同一份数据。
2. **R 阶段使用排除 Donor2 的子集 registry**（Obs 17：R01 在缺 `cell_area`
   的 Donor2 上于 QC 段崩溃，Seurat 5.2.1 与 5.4.0 行为一致）。P 阶段仍用完整
   registry（保留 Donor2 的条件列路径覆盖）。
3. **P1c 排除**（Obs 16：fixture 只有 1 个 Human dataset，必然触发
   `human_common` 未定义的 UnboundLocalError）。I 项判定显式排除 P1c，不修改
   被测脚本（硬约束 1）。
4. **对照为服务器最近一次 `run_server_verification.sh` 的产物**：
   `[Thesis_project] docker/c5_verify/p1_verify_20260812_182813/verify_out/new_single`。

---

## 2. fixture 身份（fingerprint）

对 fixture 本身取指纹（`fingerprint.py --dir`），作为「两边同一份」的可审计证据：

```bash
python tools/fingerprint.py --dir \
  [Thesis_project] docker/c5_verify/p1_verify_20260812_182813/fixture \
  --out [Thesis_project] docker/c5_verify/fp_fixture.json
```

关键身份（完整见 `[Thesis_project] docker/c5_verify/fp_fixture.json`）：

| 文件 | md5 |
|---|---|
| `sample_registry.json` | `64c95e6a0d8165398c63644d4f656f03` |
| `Fixture_Human/Donor1/cells.parquet` | `76a062c1b1856ab29e44143f4951069f` |
| `Fixture_Human/Donor2/cells.parquet` | `24d67c639d7f713bbeee97e3ef90340b` |
| `Fixture_Human/Donor3/cells.parquet` | `06158f25c9178ed985a629a817f32b63` |
| `Fixture_Mouse/MouseA/cells.parquet` | `16b32ac9a9aeef6ba1336bb6bdd728e4` |
| `Fixture_Mouse/MouseB/cells.parquet` | `fe32cec2a0b72ab0d96fb1e542718a60` |

`Fixture_Mouse/MouseB` 为 legacy `unknown` h5 布局（跨物种双布局分支）。
fixture 5 样本 × 2000 cells × 200 features，固定种子。

---

## 3. I 项 — 容器内跑通 fixture

执行命令：

```bash
bash docker/run_c5_fixture.sh
```

脚本做四件事（P1c 不参与）：

- P1b per-sample（5 样本，完整 registry）
- P2a per-dataset（2 数据集）
- P2b per-sample（5 样本）
- R01→R04 per-sample（4 样本 = 排除 Donor2，子集 registry）

输出根：`[Thesis_project] docker/c5_verify/container_out`。

结果：全部 stage 完成，产物齐全（P1b/P2a/P2b 各 5/2/5 份，R01–R04 各 4 份）。
无 stage 崩溃；Donor2 的 R 阶段、P1c 按前置条件 2/3 显式排除。

---

## 4. J 项 — 容器 vs 服务器数值容差比对

执行命令（本机 Python，pandas 2.x）：

```bash
python tools/compare_tolerance.py \
  [Thesis_project] docker/c5_verify/container_out \
  [Thesis_project] docker/c5_verify/p1_verify_20260812_182813/verify_out/new_single
```

> **工具修正**：初版 `compare_tolerance.py` 的 `load_fingerprints` 误把 CSV
> 指纹里的「易变列」列表（`excluded`，如 `time_seconds`/`rds_size_mb`）当成
> 文件级排除标志，导致 `r1_qc.csv`/`r2_qc.csv`/`r3_summary.csv`/`density_qc.csv`
> 被整文件跳过（漏掉 `n_clusters`、`residual_mean` 的真实差异）。已改为仅当
> `excluded is True` 时跳过文件；`fingerprint.py` 的目录级 `excluded` 清单同样修正。

修正后结果：**46 PASS / 19 FAIL**（`OVERALL: FAIL`）。

19 个 FAIL 的构成：

| 类别 | 数量 | 说明 |
|---|---|---|
| `meta_Fixture_*.txt` | 2 | P2a manifest 绝对路径差异（已加入 `EXCLUDED_FILES`，见 §6） |
| R02 `.rds`（SCT） | 4 | `SCT/counts` 与 `SCT/data` 层 sum 差异 |
| R02 `r2_qc.csv` | 4 | `n_clusters`、`residual_mean` 差异 |
| R03/R04 科学 CSV | 8 | `rho`/`p`/`q` 浮点差异 |
| Donor3 R01 `.rds` | 1 | `density_voronoi` md5 差异（量级 9.33e-12，可忽略） |

### max delta by column class（P2 §3）

| 类 | 标准 | 观测 max |Δ| | 位置 |
|---|---|---|---|---|
| **rho** | `\|Δρ\| < 1e-6` | **1.09e-04** | `rho_voronoi` in `r_Fixture_Human_Donor3_R03/density_gene_correlations.csv` |
| **count** | 必须完全相等 | **2.00e+00** | `n_clusters` in `r_Fixture_Mouse_MouseA_R02/r2_qc.csv`（11 vs 13） |
| p | — | 3.75e-03 | `p_voronoi` in 同上 Donor3 R03 |
| q | — | 4.93e-03 | `q_delaunay` in 同上 Donor3 R03 |
| other | — | 3.00e-04 | `residual_mean` in `r_Fixture_Mouse_MouseA_R02/r2_qc.csv` |

### 根因（必修 1 结论）

**「density_voronoi 近并列秩交换」机制被证伪**：

- `density_voronoi` / `density_delaunay` 相邻值差 `< 1e-9` 的并列对 = **0**；
  所有密度列容器 vs 服务器的 rank 差 = **0**（排序完全一致）。
- `rho_knn_*` 最大偏差（~9.5e-5）**并不小于** `rho_voronoi`（1.05e-4），
  与「只有 voronoi/delaunay 受影响」的预测矛盾。

真实来源在 **R02（SCTransform + 聚类）**，证据：

- `n_clusters` 不一致：Donor1 12→11、Donor3 13→14、MouseA 11→13、MouseB 11→12。
- `residual_mean` 不一致：1.2816→1.2817、1.2830→1.2832、1.2810→1.2813、
  1.2802→1.2804（量级 1e-4～3e-4）。
- `SCT/counts` 与 `SCT/data` 层 sum 不一致（R02 `.rds`）。

R03 的 Spearman 是对 **SCT 残差**与密度做秩相关；密度秩稳定（rank_diff=0），
因此 rho 差异来自 **SCT 残差秩的翻转**（残差近并列处），而非密度。SCTransform
/聚类的非确定性源于**容器 OpenBLAS 与服务器 BLAS 不同 + 聚类步未固定随机种子**
（R02 无 `set.seed`，见 `SUMMARY.txt`），正是 `P2_CONTAINER_SPEC.md` §0.1 预警的
「环境差异 vs 随机性」无法分离的情形。

### 语义等价（必修 2 结论）

`filtered_density_genes.csv`（R04 输出）逐样本核对：

- **gene 集合**：容器 vs 服务器 **完全相同**（`key_md5` 一致）。
- **tier / convergence / sig_\* 分类列**：**完全相同**（md5 一致）。
- **无阈值翻转基因**：fixture 最小 q = 0.0846（Donor1），距 0.05 阈值 0.0346，
  远大于 q 最大偏差 4.93e-03，故 q<0.01/0.05 过滤结果不翻转。

即：在 fixture 上，**基因集合与分类标签一致**（直接判据 PASS）。但 **R02 的
`n_clusters` 不一致（12 vs 11 等）是更上游、更实质的语义差异**，先于 R03/R04
存在，需在 K 项（同机对照）下判断是否为容器效应。

---

## 5. C6 结果

### 5.1 renv pin（已更正：原 pin 从未生效）

`Dockerfile.r` 的 renv 源原想**显式 pin 到 1.2.4**，但第一版写法无效：

```dockerfile
# 无效：install.packages() 没有 version 形参，实参被 ... 吞掉
RUN R -e 'install.packages("renv", version = "1.2.4", repos = "https://cloud.r-project.org")'
```

关键发现：RSPM 快照 2026-08-01 提供的是 renv **1.2.3**，它无法解析 Seurat 的
`fastDummies` 依赖（`dependency 'fastDummies' is not available`）；C3 实际用的是
滚动 CRAN 上的 renv **1.2.4**，能正确解析。当初误以为 `version = "1.2.4"` 是 pin，
**实际从未生效**——只是该快照恰好提供 1.2.4，换个快照日期就会漂移。已更正为真正的 pin：

```dockerfile
RUN R -e 'install.packages("remotes", repos = "https://cloud.r-project.org")' \
 && R -e 'remotes::install_version("renv", version = "1.2.4", repos = "https://cloud.r-project.org")' \
 && R -e 'stopifnot(packageVersion("renv") == package_version("1.2.4"))'
```

末行断言让 pin 失效时在当层立即失败，而非拖到最终门禁。此问题由 H 门禁间接暴露
（虽本次实际被 Matrix 的格式问题拦下）。

重 build 成功，H 项关键包版本不变：
`renv 1.2.4 / Seurat 5.2.1 / SeuratObject 5.0.2 / Matrix 1.6-4 / sctransform 0.4.1 /
fastDummies 1.7.5`。

> 「为什么门禁必须在 CI 里真跑」的两个实例（代码看着完全正确、只有真跑才暴露）：
>
> 1. **文件生命周期**：拆层后 `/tmp/renv.lock` 被 Layer 1 的 `rm -rf /tmp/*` 删除，
>    Layer 2 无法打开。已修：lockfile 移到 `/opt/renv.lock`。
> 2. **类型语义**：`as.character(packageVersion("Matrix"))` 把 `1.6-4` 归一化为
>    `1.6.4`，与 lockfile 原文 `1.6-4` 字符串比较必然失败。已修：改用
>    `package_version` 对象比较（R 把 - 与 . 视为等价分隔符）。

> **可复现性缺口：hdf5r 不在 renv.lock。** hdf5r 是 Seurat 的 Suggests
> （R01_build_seurat.R 的 `Read10X_h5` 动态加载），`sessionInfo()` 不列出，
> 服务器 `renv::snapshot()` 未捕获。其版本（1.3.12）由 RSPM 快照日期
> （2026-08-01）间接固定，改快照日期即可能漂移。容器用独立
> `install.packages("hdf5r", repos=快照)` 安装；H 门禁的 `extra = c(renv, hdf5r)`
> 硬编码为可接受例外（二者确实不在 lockfile 中）。

### 5.2 判决实验（完成）—— R02 确定性

在同一个容器内、用同一份 R01 输出，把 R02 连续跑两次（4 样本，见
`run_c6_determinism.sh`）。

结果：**n_clusters 与聚类标签两次完全一致**（Donor1 12/12、Donor3 13/13、
MouseA 11/11、MouseB 11/11，`idents identical=TRUE`）；但 `.rds` 字节不同——
RNA/counts、SCT/counts、SCT/data 的 sum 到 10 位小数完全一致，差异在更低位的
浮点末位，不在指纹的 sum 级。

结论：**不存在影响 n_clusters 的未播种 RNG**。n_clusters 的容器 vs 服务器差异
是数值差异（BLAS）被确定性放大（vst 拟合 → 残差 → PCA → SNN → Louvain 落入
不同局部最优）。**补 set.seed 解决不了 n_clusters 问题**（§11.2 的 set.seed
不能让人误以为补了种子就好了）。

可证伪说明：若两次 n_clusters 不同，则证明存在未播种路径，需定位到具体步骤；
实测两次 n_clusters 相同，该命题被排除。

### 5.3 第一个分歧点（完成）

RNA/counts 层 sum 容器 vs 服务器**完全一致**（Donor1 55744=55744、Donor3
55348=55348、MouseA 55506=55506、MouseB 55168=55168）。SCT/counts 与 SCT/data
层 sum 开始分歧（Donor1 SCT/counts 53296 vs 53306 等）。

结论：第一个数值分歧点精确锁定在 **SCTransform 的 vst 拟合本身**，不是上游
（RNA/counts 来自同一份 h5，完全一致）。

### 5.4 K 项（未完成，客观阻碍）

- 服务器 Docker 1.13.1（2017）且当前用户无 daemon 权限（`/var/run/docker.sock`
  permission denied）；无 singularity/apptainer。
- 建议解法（均需服务器管理员配合）：
  (a) 将用户加入 docker 组；
  (b) Docker 1.13.1 只支持 schema v2 manifest，无法直接拉取 Docker 29 构建的
      OCI 镜像，需 `DOCKER_BUILDKIT=0` 构建 + `docker save | gzip → scp →
      docker load` 传输；
  (c) 或安装 apptainer。
- **J 项最终结论仍标注「未完成，待 K 项」**。

---

## 6. 其它修正

- `meta_Fixture_*.txt`（P2a manifest 中间产物，含绝对路径）加入
  `tools/qc_schema.py` 的 `EXCLUDED_FILES`，不再参与指纹比对。
- `tools/compare_tolerance.py` 与 `tools/fingerprint.py` 的 `excluded` 语义修正
  （文件级 `True` vs 列级 list），见 §4 顶部。
