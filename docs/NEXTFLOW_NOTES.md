# NEXTFLOW_NOTES.md — P3 Nextflow 设计说明

> 本文记录 P3 工作流的工程判断与理由（对应 `P3_NEXTFLOW_SPEC.md` §6）。
> 每条都是「这是一个工程判断，理由是 X」，不是流水账。

---

## 1. 为什么这样切 process

每个 process 的并行度来自其**输入 channel 的粒度**，而不是 process 内部的循环：

| process | 并行度 | 理由 |
|---|---|---|
| `P1B` | per-sample | channel 每个元素是一个样本 key；脚本 `--sample` 只处理一个样本 |
| `P2A` | per-dataset | 把 P1B 的 `cell_metadata.csv` 按 dataset `groupTuple`，每个 dataset 一个 task |
| `P2B` | per-sample | 用 dataset 作 key 把 P1B metadata 与 P2A kfile 配对后，再 fan-out 到每个样本 |

**为什么 P2 必须拆成 P2A / P2B**：P2 原始逻辑是「先对每个 dataset 选 K，
再对每个样本算密度」。这两个阶段的并行粒度不同——前者是 per-dataset 的 fan-in，
后者是 per-sample 的 fan-out。若合成一个 process，就只能退化成「内部循环全部样本」
（§0 明确禁止的假 Nextflow），`-resume` 无意义、DAG 是直线。拆开后，
`fan-in → fan-out` 两种 channel 模式都真正出现，DAG 才有说服力。

## 2. channel 结构

- **fan-out（P1B）**：`sample_registry.json` → `flatMap { keySet() }` 拆成单样本 channel。
- **fan-in（P2A）**：`P1B.out → map(dataset, sample, meta) → groupTuple(by: dataset)`
  收拢成 `(dataset, [samples], [metas])`，每个 dataset 一个 manifest。
- **fan-out（P2B）**：`P1B metadata` 与 `P2A kfile` 用 `combine + filter`（显式
  many-to-one join）按 dataset 配对，再按样本 fan-out。

**P2A 的 manifest 必须两列带键**（`<Dataset/Subname><TAB><path>`）。P2A 脚本用
`split("\t")` 按 key 查表，绝不按位置——因为 Nextflow 任务完成顺序不保证，按位置
配对会在并行时错乱（P1 阶段这里出过一次真 bug）。

**同名文件冲突**：P1B 输出 `cell_metadata.csv` 等扁平名，P2A 做 fan-in 时多个同名
文件会触发 `input file name collision`。工程判断：在 P1B 的 Nextflow 脚本里把扁平
输出重命名为 `<key>.<原名>`（`key` = 样本名 `/`→`_`），再用 `publishDir saveAs`
把发布名还原为原名。这样 work dir 内唯一、发布目录仍保持 `cell_metadata.csv` 等
论文路径叙述不变。

## 3. 三个 profile 的取舍

- **standard（服务器实际运行）**：无容器。服务器 Docker 1.13.1 + 用户无 daemon 权限 +
  无 singularity/apptainer，因此服务器上只能无容器跑。这是真实 HPC 约束，不是缺陷。
- **docker（本机 / 未来 CI）**：`thesis-python:3.7.10` / `thesis-r:4.2.0`（不可变版本标签，
  不用 `latest`），用于展示可复现性。
- **test（冒烟）**：只覆盖 `params.test_exclude`（不绑定执行环境），可与 `standard`/`docker`
  组合（`-profile test,docker` / `-profile test,standard`）。

**本机 standard 的执行环境（关键判断）**：Nextflow 不支持原生 Windows（会话实测
`Unknown signal: HUP`，`sun.misc.Signal` 在 Windows 无 HUP；Seqera 维护者确认 Windows
上唯一方式是 WSL）。因此 **Nextflow 跑在 WSL**，但 standard profile 的「解释器」通过
`/mnt/d` 跨调用 **Windows 原生 python/R**（`D:/python3.9.13/python.exe`、
`D:/R-4.5.2/bin/Rscript.exe`）。这满足 HANDOFF §1.3「不要用 WSL 的 python3/Rscript」——
WSL 只负责 Nextflow 调度，实际计算仍是 Windows 解释器（R 的 `.libPaths()` 正确）。
代价：local executor 默认把输入 stage 成 symlink，Windows 解释器无法跟随 WSL DrvFs
symlink（Errno 22），故 standard profile 强制 `process.stageInMode = 'copy'`。

**可验证证据（R 环境探针）**：每个 R process 内跑 `tools/r_env_probe.R`，打印
`R.version.string` / `.libPaths()` / `packageVersion("Seurat")`。standard profile 实测：

```
R_VERSION: R version 4.5.2 (2025-10-31 ucrt)
LIBPATHS: D:/R/Rlibs;D:/R-4.5.2/library
SEURAT: 5.4.0
```

确认走的是 **Windows 原生 R 4.5.2 + Seurat 5.4.0**（libPaths 是 `D:/R/...` 而非 WSL
的 `/home/...`）。探针单独成文件而不是 `Rscript -e` 内联，因为内联表达式里的双引号
会被 WSL→Windows 跨调用破坏（`'LIBPATHS' 不是内部或外部命令`）。

## 4. 已知限制

- **R05–R09 未纳入**：R05/R06 在 fixture 上产不出有效输出，R07–R09 需要 R06 分片。
  如实记为范围外，不硬塞。
- **P1c 因 Obs 16 排除**：单 Human dataset 必然 UnboundLocalError，不写 P1C process。
- **Donor2 因 Obs 17 排除**：R 阶段用 `params.r_stage_exclude` 显式常量排除，运行时打印
  原因，不用模式匹配。
- **test profile 排除 MouseB**：test 子集 = Donor1 + Donor3 + MouseA，因此不覆盖 MouseB 的
  unknown h5 布局分支（该分支由全量 profile 覆盖）。这是 Donor1+Donor3+MouseA 选型带来的取舍。
- **P 表 5 行 vs R 表 4 行的不对称是 fixture 特有，不是丢样本**：`ALL_SAMPLES_P1_QC.csv` 有
  5 行（P1B 跑全量 5 样本），`ALL_SAMPLES_R1_QC.csv` 有 4 行（R 阶段排除 Donor2）。这一差异
  只存在于 fixture——真实数据 22 个样本全部带 `cell_area`（服务器实测确认），Obs 17 不会触发，
  P 表与 R 表都会是 22 行。请勿把 5 vs 4 误读为「R 阶段静默丢了一个样本」。

## 5. M 项验收标准修订（2026-08-13）

原文要求「standard 与 docker 的 fixture 结果一致」。**这条在任何一台机器上都不可达成**：

- 服务器无可用容器运行时（Docker 1.13.1 + 无权限 + 无 apptainer），跑不了 docker profile；
- 本机 standard 又不是目标环境（Windows 解释器，版本与服务器 Python 3.7.10 / R 4.2.0 不同）。

**修订为**：三个 profile 各自能跑通（冒烟）即可，不做 standard vs docker 数值比对。
数值一致性由 **Q 项**承担——Nextflow **docker** 产出 vs P2 `run_c5_fixture.sh` 的容器产出，
二者同容器同环境，唯一变量是 Nextflow 本身。

## 6. fixture 路径耦合（registry 内嵌绝对路径）

`sample_registry.json` 的 `path` 字段是绝对路径 `/tmp/p1_verify_20260812_182813/fixture/...`。
因此 fixture 必须能在这个精确位置被访问。工程判断：把这条耦合拆成两个参数：

- `params.fixture_container`：registry 内嵌的前缀（容器内/挂载目标，必须与 registry 一致）。
- `params.fixture_host`：fixture 在 host 上的实际位置（docker 挂载源）。

docker profile 用 `-v ${fixture_host}:${fixture_container}`；standard profile 通过
WSL symlink（Nextflow 读 `/tmp/...`）+ Windows junction（Windows 解释器读 `/tmp/...`）
把 `fixture_container` 桥接到 `fixture_host`。换机时只需改 `fixture_host`，
但 `fixture_container` 与 registry 绑定，换机需连同 registry 一起重建。

## 7. 子集必须做在 registry 层（Q4(b) fail-fast 的约束）

P2A 脚本（不可改）从「完整 registry」反推 dataset 样本列表，并校验 manifest 完整性
（`sample_set - manifest_keys` 非空即报错，Q4(b) fail-fast）。因此 **channel 级子集过滤
不可行**——过滤后 manifest 会缺样本，被 Q4(b) 校验拦下。

**这不是 bug，是两个正确设计相互约束的结果**：Q4(b) 要求 fan-in 的 manifest 覆盖 registry
全部样本（防止静默丢样本），而 test 冒烟又需要跑子集。两者只能通过「在 registry 层做子集」
调和——即让 P2A 读到的 registry 本身就是子集，manifest 与它一致。

**实现**：`main.nf` 里一个可复用的 `write_subset()`，从 `params.registry` 减去排除项，
运行时写临时子集 registry（`.nextflow/registry/*.json`，不入库），并打印排除了哪些样本及原因：

- `params.test_exclude`（test profile）→ 全流程子集，`['Fixture_Human/Donor2', 'Fixture_Mouse/MouseB']`
  → 剩 Donor1 + Donor3 + MouseA（2 个 dataset，其中一个含 2 样本，fan-in 与 fan-out 都能体现）。
- `params.r_stage_exclude`（所有 profile）→ 仅 R 阶段排除 Donor2（Obs 17），
  P1B/P2A/P2B 仍跑全量 5 样本，R01–R04 跑 4 样本。

独立 tiny DATA fixture 属 P4（CI 运行时长成为约束时）再做。

**设计张力的完整表述**：P1 的 fail-fast 校验（Q3 的分片完整性、Q4(b) 的 manifest 完整性）
对 P3 施加了两条约束——**子集必须在 registry 层表达**、**文件名必须保持原样**。
这是第二次和第三次遇到同一族约束（第一次是 N2 的 P2A manifest），不是缺陷，
是两个正确设计相互约束的结果。具体到 N4：merge_qc.py 的 `find_shards()` 按精确
basename（`qc_schema.SHARD_TO_TABLE`）发现分片，所以 MERGE 分片不能加 `<key>.` 前缀，
只能用 `stageAs: "shard_*/*"` 分目录保持 basename；而 P1B 的 `<key>.` 重命名只对
`cell_metadata.csv` 成立（P2A 用显式 manifest 按 key 识别，不靠 basename）——
两处机制不同，不能套用同一模式。

## 8. N5 验收结论（P3 收尾）

### Q 项：Nextflow 编排本身不引入数值变化

`compare_tolerance.py` 用显式路径映射（`tools/canonicalize_container.py` 把
`run_c5_fixture.sh` 的扁平 `Fixture_Human_Donor1/`、`p2a_*`、`r_*_R0N` 目录统一到
Nextflow 的 `P1_Results/{Dataset}/{Subname}/` 布局后，配合 `tools/fingerprint_merged.py`
合并 Python(h5/csv) 与 R(rds) 指纹）比对：

- **Common 63 / Only A 0 / Only B 7，63 PASS / 0 FAIL，numeric delta 全为 0**。
- rho / count / p / q / other 五类列全部 **exact match**，基因集合与分类标签完全一致。
- 这是**逐值相同（非容差通过）**：容器产出与 Nextflow docker 产出同环境同脚本，
  唯一变量是 Nextflow 编排，因此可证明 **Nextflow 本身不改变任何数值**。
- Only B 的 7 个文件是 Nextflow 独有的 `ALL_SAMPLES_*.csv`（6）+ `ALL_DATASETS_K_SELECTION.csv`（1），
  `run_c5_fixture.sh` 不产合并物，不参与 Q 比对（合并正确性由 N4 内部验证）。

### N 项：依赖边真实、并行非装饰的直接证据

`-resume` 用 standard profile（两次同 profile，缓存不跨 profile 共享）：

**测试 B（stage 粒度）**：给 R03 加一行注释，共 35 任务——
- CACHED 25：`P1B×5`、`P2A×2`、`P2B×5`、`R01×4`、`R02×4`、`MERGE_QC×4`、`MERGE_K_SELECTION×1`
- 重算 10：`R03×4`、`R04×4`、`MERGE_QC×2`（R3/R4 两张表）

即：只改 R03，上游 P1B/P2A/P2B/R01/R02 全部命中缓存，只有 R03 及其下游 R04（R03 输出改变）
重算——**证明 stage 间的 DAG 依赖边是真实按需失效的，不是整链重跑**。

**测试 A（per-sample 隔离）**：改动 Donor1 的 `cells.parquet`（复制副本操作，测后还原并核对 md5）——
- `P1B`：**Donor1 重算，其余 4 样本全部 CACHED**（样本间无耦合）
- `P2A/P2B/R01/R02`：Human 侧按 dataset 传播（P2A 的 k_selection 变了 → 同 dataset 的 P2B 全重算），
  Mouse 侧全部 CACHED

这是 P2A fan-in → P2B fan-out 的**正确传播语义**：改一个样本的输入，per-sample 层（P1B）只重算
该样本；per-dataset 层（P2A/P2B）重算受影响 dataset。并行不是装饰。

### 工程判断：write_subset() 的 mtime 教训

`main.nf` 的 `write_subset()` 最初每次运行都重写内容相同的子集 registry。结果是：
**内容不变但 mtime 变，Nextflow 的任务哈希随之不稳定，导致整条流水线的缓存静默失效——
所有任务每次 -resume 都重算**。修复：`if (!f.exists() || f.text != content)` 只在内容变化时写。

这条教训的独立价值在于：**「无改动重跑 → 全 CACHED」这一弱预检恰恰掩盖了它**——
因为无改动重跑时 mtime 也没变，缓存看似正常，问题只在「隔一次运行才触发」。弱测试不只是
证明力不足，还会**主动隐藏问题**。对 P5 README 的启示：任何写配置文件到共享路径的逻辑，
都应保证「内容相同即不触碰文件」，否则 -resume 的缓存保证形同虚设。

### 遗留（如实标注，不阻塞 P3 通过）

- **test A 中 Mouse 侧 R03/R04 也重算了**（R02 已 CACHED、输入未变，理论上应缓存）。
  已在 N 项证据中如实标注「未定位」。建议 P4 从干净 work dir 重跑基线后再单独执行测试 A，
  确认 Mouse 侧是否全 CACHED；若仍重算再定位。
- **docker profile 的 -resume 在本机不稳定**（容器化任务哈希逐 run 变化，与 write_subset mtime
  无关）。不花时间排查的理由：服务器只能跑 standard（Docker 1.13.1 无 daemon 权限），
  docker profile 面向 CI 与展示，而 CI 每次都是干净环境、本就不使用 resume。
