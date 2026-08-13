# S5b 模式横扫表与验证报告

## 横扫表（按 per-sample / fan-in 分组）

### Per-sample 组（R05/R06，改法同 R01–R04）

| 改动项 | R05 | R06 |
|---|---|---|
| `source("config/args.R")` | 已应用 | 已应用 |
| `--sample` 支持 | 已应用 | 已应用 |
| `--registry` 缺省保持 $DATA_DIR | 已应用 | 已应用 |
| `--indir` 覆盖上游目录 | 已应用（R2_DIR + R4_DIR 同时覆盖） | 已应用（R2_DIR + R4_DIR 同时覆盖） |
| `--outdir` 必需（单样本模式） | 已应用 | 已应用 |
| `--outdir` 缺省（全量模式） | 已应用（$RESULTS_DIR/R5_Results） | 已应用（$RESULTS_DIR/R6_Results） |
| 扁平输出（单样本模式） | 已应用（图件到 --outdir 子目录） | 已应用（csv + 图到 --outdir 根） |
| 嵌套输出（全量模式） | 已应用 | 已应用 |
| 分片写入（单样本模式） | 不适用（R05 只产图件，无 QC 汇总表，不写 ALL_SAMPLES_*） | 已应用（r6_summary.csv） |
| 不写 ALL_SAMPLES_*（单样本模式） | 已应用（无汇总表） | 已应用 |
| ALL_SAMPLES_* 保留（全量模式） | 不适用（无汇总表） | 已应用 |
| manifest 带键 | 不适用（per-sample，不需 manifest） | 不适用 |
| 输入路径扁平推导（单样本模式） | 已应用（`file.path(R2_DIR, "<Subname>_seurat_R2.rds")`） | 已应用 |
| fail-fast：缺样本报错 | 已应用 | 已应用 |
| fail-fast：缺 --outdir 报错 | 已应用 | 已应用 |
| 科学逻辑不变 | 已应用 | 已应用 |

### Fan-in 组（R07/R08/R09，加 --manifest）

| 改动项 | R07 | R08 | R09 |
|---|---|---|---|
| `source("config/args.R")` | 已应用 | 已应用 | 已应用 |
| `--sample` 支持 | 不适用（fan-in，无单样本模式） | 不适用 | 不适用 |
| `--registry` 缺省保持 $DATA_DIR | 已应用 | 已应用 | 已应用 |
| `--indir` 覆盖上游目录 | 已应用（R3/R4/R6_DIR 同时覆盖） | 已应用（R3/R4_DIR） | 已应用（R2/R3/R4_DIR） |
| `--outdir` 缺省 | 已应用（$RESULTS_DIR/R7_Results） | 已应用（$RESULTS_DIR/R8_Results） | 已应用（$RESULTS_DIR/R9_Results） |
| `--manifest` 两列带键 | 已应用（`Dataset/Subname<TAB>path`） | 已应用 | 已应用 |
| 按 basename 归类 | 已应用（3 类：density_gene_correlations/filtered_density_genes/cell_state_coupling） | 已应用（2 类：density_gene_correlations/filtered_density_genes） | 已应用（3 类：density_gene_correlations/filtered_density_genes/_seurat_R2.rds） |
| Q4(a) 无法归类 basename 报错 | 已应用 | 已应用 | 已应用 |
| Q4(b) 必需类型条目数为 0 报错 | 已应用（R3+R4 必需，R6 可选） | 已应用（R3+R4 必需） | 已应用（R3+R4 必需，R2 可选） |
| Q4(c) 打印各类型条目数 | 已应用 | 已应用 | 已应用 |
| 无 --manifest 回退旧路径构造 | 已应用（registry 驱动 `file.path(*_DIR, D, S, file)`） | 已应用 | 已应用 |
| 分片写入 | 不适用（cohort 级产出，无分片） | 不适用 | 不适用 |
| 科学逻辑不变 | 已应用 | 已应用 | 已应用 |

### Observation 4/5 处理

- **Observation 4**（R06→R07 列名不匹配）：R07 的 manifest 改造不涉及列名匹配逻辑（manifest 只管文件路径，不管文件内容列名）。R06 的 `cell_state_coupling.csv` 写出的 `effect_label` 列名与 R07 期望的 `effect_class` 不匹配是既有科学逻辑问题，按硬约束 1/2 只报不修，fan-in 改造不以任何方式规避或补偿。
- **Observation 5**（R09 tier 值匹配失效）：R09 的 manifest 改造不涉及 tier 值匹配逻辑。R09 Part C 的 `tier == "tier1" | tier == "1"` 与 R04 写的 `tier1_strict` 不匹配是既有科学逻辑问题，只报不修。

## 补1：T14/T15 内容层断言

### T14（P2b→R01 接缝）

- **新增**：对 R01 产物取 .rds 指纹，断言五列 density 的 md5 与全量模式一致（不只断言文件存在性）
- **falsifies**：R01 输入路径不匹配扁平布局 + density 列未从 P2b cell_density.csv 传播到 rds
- **反向验证**：T14_REV（嵌套路径 + 扁平 --indir → 无 rds → FAIL）✓

### T15（R01→R04 四级链条）

- **新增**：R01/R02 的 .rds 指纹比对（@commands 排除验证）+ R03/R04 CSV 指纹比对
- **falsifies**：单样本输出内容偏离全量模式（wrong flat layout / missing density column）
- **sort-order 从 falsifies 删除**：指纹按 key 排序设计，行序无关（反向验证证实反转行序指纹不变）
- **反向验证**：
  - T15_REV1（wrong --indir → 无输出 → FAIL）✓
  - T15_REV2a（删除一列 → 指纹不匹配 → FAIL）✓
  - T15_REV2b（反转行序 → 指纹仍匹配 → 证伪不成立，从 falsifies 删除）✓

## 补2：T15 os.environ 恢复

- T14 和 T15 的 `os.environ["DATA_DIR"]/["RESULTS_DIR"]` 修改均包裹在 try/finally 中，原始值在 finally 里恢复
- 15/15 全部通过，环境变量不泄漏

## 验证层级

本机 R 4.5.2 + Seurat 5.4.0，L3。R01 全量模式在 Donor2（缺 cell_area）上因 Seurat 5.4.0 API 变更崩溃（Observation 17），不影响 T14/T15（Donor1 跑通且指纹一致）。

## S5b 修正轮：持久化测试 T16/T17/T18

### T16：R04→R05/R06 接缝（持久化）

- R01→R04 单样本链条 → R05 `--sample`（图件产出）→ R06 `--sample`
- **R06 在 fixture 上无法产出** `cell_state_coupling.csv`：fixture 的合成数据 190 个基因全部 `not_significant`，无 tier1 基因，R06 的 coupling 分析无输入
- T16 断言 R05 跑通（图件产出），R06 覆盖为已知缺口
- **反向验证**：T16_REV（R05 wrong --indir → 无 scatter plots → FAIL）✓

### T17：R03/R04/R06 分片→R07 --manifest fan-in（持久化）

- Donor1 + Donor3 两个样本的 R03/R04 产出 → 构造 manifest（两列带键）→ R07 `--manifest`
- R06 的 `cell_state_coupling.csv` 用 dummy 数据替代（R06 在 fixture 上无 tier1 基因）
- T17 断言 R07 产出 `sample_density_profile.csv` 存在且可指纹化（内容层断言）
- **全量比对不可行**：R01 全量在 Donor2 崩溃 → R07 全量无法完成
- **反向验证**：T17_REV（manifest 缺 Donor3 → ALL_SAMPLES_R7_PROFILE.csv 1 行 vs 2 行 → 指纹不匹配 → FAIL）✓

### T18：Q4 三条校验（持久化）

- (a) manifest 含无法归类的 basename → R07 报错退出 ✓
- (b) 必需类型条目数为 0（只有 R4 无 R3）→ R07 报错退出 ✓
- (c) manifest 行序打乱后 ALL_SAMPLES_R7_PROFILE.csv 指纹一致 ✓
- **反向验证**：T18_REV_a（bad basename → "cannot be classified" 报错）、T18_REV_b（0 R3 → "0 entries" 报错）、T18_REV_c（shuffled == ordered）

## 未完成项 + 阻碍原因 + 建议解法

| 未完成项 | 阻碍原因 | 建议解法 |
|---|---|---|
| R06 `cell_state_coupling.csv` 单样本 vs 全量指纹比对 | fixture 合成数据 0 tier1 基因，R06 无输入 | 在目标环境用真实数据（有 tier1 基因）补验 |
| R07 `sample_density_profile.csv` 单样本 vs 全量指纹比对 | R01 全量在 Donor2 崩溃（Seurat 5.4.0 API 变更），R07 全量无法完成 | 在目标环境（R 4.2.0 + Seurat 5.2.1，`$` 访问不存在列返回 NULL）补验 |
| R08 跨数据集比较的 manifest fan-in 验证 | R08 需要多个 dataset 的 R3/R4 产出，fixture 只有 2 个 dataset（Fixture_Human + Fixture_Mouse），跨物种比较需要不同物种的基因名 | 在目标环境用真实多物种数据补验 |
| R09 tier 决策的 manifest fan-in 验证 | R09 需要全部样本的 R2 rds（Seurat 对象），Donor2 崩溃导致全量不完整 | 在目标环境补验 |

## 已知验证缺口（延续 S5a）

### (a) R 阶段等价验证的实际样本覆盖

- S5a 覆盖：Donor1（R01→R04 单样本 vs 全量指纹一致）
- S5b 新增：Donor1 + Donor3（R07 --manifest fan-in 内容层断言）
- Donor2 因 Seurat 5.4.0 `$` cell_area 崩溃，全量模式不完整

### (b) 条件列 NA 路径在 R 侧未执行

- Donor2 缺 `cell_area` → R01 崩溃 → 条件列 NA 路径（`median_cell_area` 为 NA → 分片 → merge_qc NA 补齐）在 R 侧未验证

### (c) R06 cell_state_coupling.csv 在 fixture 上无法产出

- fixture 合成数据 0 tier1 基因 → R06 无输入 → `cell_state_coupling.csv` 未产出
- 需在目标环境用真实数据（有 tier1 基因）补验

### (d) "真实 22 样本都有 cell_area" 是未验证推测

- 真实数据不在本机，无法核实

## 测试套件结果

**18/18 全部通过。**
