# P0 Step 4 遗留项收尾 — R01–R09 显式随机种子与行为中性验证

> 日期：2026-08-17
> 环境：服务器 bioinfo-lab（CentOS 7 / R 4.2.0 / Seurat 5.2.1 / Python 3.7.10）
> 结论：改动**对科学产出行为中性**，已实测验证（A–F 两次均 6/6，全部 CSV/h5 科学产出与
> R02 `.rds` 内容指纹均一致）。

## 1. 改动内容

在 `02_R_core_pipeline/R01–R09` 每个脚本的 `source(.../config/args.R)` 之后加一行：

```r
set.seed(42)
```

在 `R02_sctransform.R` 的 `SCTransform()` 调用处显式加：

```r
seed.use = 1448145
```

（等于当前默认值，把隐式依赖显式化。）

仅此两处，共 **10 行插入、0 删除**，未改动任何科学逻辑、阈值、算法。

## 2. 为何需要

容器化后 BLAS 变化时，必须能区分「环境差异」与「随机性」。若 R 链依赖未显式播种的 RNG，
容器 vs 服务器的数值差异就无从归因——既可能是 BLAS，也可能是随机抽样。补显式种子后，
残余的随机性来源被钉死，剩余数值差异即可归因于 BLAS（数值容差 |Δρ|<1e-6，见
`docs/P2_CONTAINER_VERIFICATION.md`）。

## 3. 验证方法

关键点：**A–F 6/6 不足以证明中性**。`verify_equivalence.sh` 比的是「旧调用方式 vs 新调用方式」，
两侧用同一批脚本——加了种子两侧一起变，A 项照样通过。正确判据是**改动前/后两次运行的产物内容一致**。

步骤：

1. 改动前在服务器 `/home/disk/wangqilu/p1_verify_src` 跑 `run_server_verification.sh`，
   记 `OUTDIR=/tmp/p1_verify_before`。
2. scp 9 个改动后脚本到服务器同目录，`grep -c "set.seed(42)"` / `grep -n "seed.use"` 确认传到位。
3. 改动后再跑一次，`OUTDIR=/tmp/p1_verify_after`。
4. 两次 `verify_out` 各取 `fingerprint.py --dir` 指纹（剔除 `root` 字段）比对；
   对 `.rds` 用 `fingerprint.R --file` 做内容级比对（排除 `@commands` 与时间戳）。

## 4. 实测结论

### 4.1 A–F 汇总（改动前 / 改动后完全一致）

```
| A: old-full == new-full          | PASS | all comparable CSV fingerprints match |
| B: new-full == new-per-sample    | PASS | all sample fingerprints match ( Donor2:rds/r3csv both_missing skipped ) |
| C: old-full == new-full (rds)    | PASS | all rds fingerprints match ( Donor2:both_missing skipped ) |
| D: P2a+P2b == original P2        | PASS | density fingerprints match |
| E: merged == full-mode ALL_SAMPLES | PASS | shard merge fingerprints match |
| F: no new dependencies           | PASS | no new dependencies |

PASS: 6  |  SKIP: 0  |  FAIL: 0
```

两次 Stage Failures 均仅 1 项：`old P1c`（Obs 16，UnboundLocalError，属显式排除项）。

### 4.2 `fingerprint.py --dir`（剔除 root 字段）

```
RESULT: DIFFERENT（40 个文件不同，但全部为非科学产出）
only_before: 0  |  only_after: 0
differing files（40）:
   ~ logs/*.log                      (36 个：时间戳 + 绝对路径)
   ~ new_single/meta_Fixture_Human.txt
   ~ new_single/meta_Fixture_Mouse.txt
   ~ registry_rstage.json
```

对 3 个非 log 文件做**路径归一化**（`/tmp/p1_verify_before`→`/tmp/p1_verify_after`、
时间戳 `20260817_154909`→`20260817_161359`）后，**三者逐字一致**（`normalized-match=True`）。

**所有 CSV / h5 科学产出（含 P1b/P2a/P2b 与 R01–R04 的 qc、correlation、filtered 表）逐字一致。**

### 4.3 `.rds` 字节比对（24 个）

- **R01 `*_seurat.rds`：12 个逐字一致。**
- **R02 `*_seurat_R2.rds`：12 个字节不同**（old_full / new_full / new_single 三份布局均如此）。

R02 `.rds` 的字节差异有**完全确定性的原因**，无需 BLAS 噪声解释：Seurat 对象的 `@commands`
槽会记录每次 SCTransform / FindNeighbors / RunUMAP 调用及其时间戳，因此 R02 的 `.rds`
必然每次字节不同；R01 只做 CreateSeuratObject 与 metadata 合并、不写 `@commands`，故字节一致。
这正是「R01 12 个一致、R02 12 个不同」这一精确分布的来源。

### 4.4 `.rds` 内容指纹比对（fingerprint.R，12 对 R02）

对 before/after 两侧的 12 对 R02 `.rds` 各取 `fingerprint.R --file` 指纹（显式排除
`@commands` 与时间戳），逐对比对 `cells_md5`、`features_md5`、各 assay 各 layer 的 `sum`
与非零元个数、五列 density 的 `md5`：

```
IDENTICAL  new_full/R2_Results/.../Donor1_seurat_R2.rds
IDENTICAL  new_full/R2_Results/.../Donor3_seurat_R2.rds
IDENTICAL  new_full/R2_Results/.../MouseA_seurat_R2.rds
IDENTICAL  new_full/R2_Results/.../MouseB_seurat_R2.rds
IDENTICAL  new_single/r_..._R02/...seurat_R2.rds   (×4)
IDENTICAL  old_full/R2_Results/.../...seurat_R2.rds (×4)

RESULT: 12 identical / 0 different
```

**12/12 全部一致**：R02 `.rds` 的科学内容在改动前后零差异，字节差异纯由 `@commands`
时间戳引起。

## 5. 已实测确认 vs 推测

**已实测确认**（每条均有直接输出支撑）：

1. 改动前 / 改动后 A–F 均 `PASS: 6 | SKIP: 0 | FAIL: 0`。
2. 所有 CSV / h5 科学产出逐字一致（含 R02 的 `r2_qc.csv` 汇总表）。
3. R01 的 12 个 `.rds` 逐字一致。
4. R02 的 12 个 `.rds` **内容指纹逐字一致**（`cells_md5` / `features_md5` /
   各 assay 各 layer 的 `sum`+`nnz` / 五列 density `md5` 全一致）。
5. 40 个非科学文件（36 log + 2 meta + 1 registry）路径归一化后逐字一致。
6. R02 的 12 个 `.rds` **字节**不同，归因于 `@commands` 槽时间戳（确定性、非随机性、非 BLAS）。

**无「推测」项**：上述每条均有直接输出。原先「R02 `.rds` 差异为 BLAS 浮点噪声」的推测，
已被 `fingerprint.R` 内容级比对证伪，更正为「`@commands` 时间戳」这一确定性归因。

> 注：「产物逐字节相同」这一表述，对含 `@commands` 的 `.rds` 本就不适用——正确判据是
> **内容指纹**（排除 `@commands` 与时间戳）。这与 P1 的设计一致（`fingerprint.R` 的 `.rds`
> 路径本就显式排除 `@commands`），不是本次改动引入的例外。

## 6. 与 Thesis_project 的差异

- 本次改动只落在 **`mben-density-nf`** 仓库（`02_R_core_pipeline/R01–R09`）。
- **`Thesis_project`（论文原始代码存档）未做任何改动，也绝不可改动**——它是产出论文结果那份代码的
  存档，任何改动（哪怕行为中性）都是篡改记录。
- 由此，`mben-density-nf` 与 `Thesis_project` 的 R01–R09 自此存在这一处差异：
  `mben-density-nf` 显式 `set.seed(42)` + R02 `seed.use=1448145`；`Thesis_project` 保持原样。
- 不同步的原因：存档不可篡改。这一差异是**有意的、单向的**，方向只从存档到重构仓库，不反向。

## 7. 服务器验证目录说明

- 实际验证目录为 `/home/disk/wangqilu/p1_verify_src`（非 `_v2` 后缀）。
- 该目录是 P1 重构的验证工作副本，其 R01/R02/R05–R09 工作区有未提交的 `tr -d CR` 行尾改动；
  但**内容与 `mben-density-nf` 的 HEAD 完全一致**（已用 md5 逐文件核对），不影响本验证。
- 改动前/后两次 OUTDIR：`/tmp/p1_verify_before`、`/tmp/p1_verify_after`。
