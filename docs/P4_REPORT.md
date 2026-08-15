# P4_REPORT.md — S 项（镜像推送/拉取验证）与 D3 状态

> 记录 D1/D2 的 S 项验证结果与 D3（pipeline job）执行状态。
> 日期：2026-08-14

## S 项：GHCR 镜像推送 + 实际拉取运行验证

**状态：基本完成，Python pull 待 D3 覆盖**（如实记录，不记为全部通过）。

### R 镜像（实测通过）

- pull + run + digest + size 全部实测通过。
- digest：`sha256:4a07f86b2d9e3e7f10731214d64f2d96f908055267f48ab7310960d3699fd349`
- 实际大小：**2.36 GB**（原 3.41 GB，清 renv cache + 三组拆层后 −31%，W 项关键数据）
- 版本探针：R 4.2.0 / Seurat 5.2.1 / SeuratObject 5.0.2 / Matrix 1.6.4 /
  sctransform 0.4.1 / fastDummies 1.7.5（H 门禁 10 项全 OK）

### Python 镜像（digest + 版本已确认，pull 待 D3）

- digest：`sha256:495f6b669b1251432b83a648bed9b39d5a45f7767ad66f6b21f60dcc9ac2607f`
- 版本探针：numpy 1.21.6 / pandas 1.3.5 / scipy 1.7.3 / scikit-learn 1.0.2 /
  matplotlib 3.5.3 / h5py 3.8.0 / pyarrow 12.0.1
- **pull 验证：由 D3 的 CI 覆盖**（GitHub runner 直连无代理，真实执行 docker pull）。
  本机代理在 pip 层 stall，与 R 镜像 push 同源，不再在本机与代理搏斗。
  此条**不记为已完成，也不记为失败**。

### 必答结论（D1/D2 收尾）

- clean=FALSE 已生效（重建后 Layer #13 不再出现 Removing renv/remotes/docopt/littler）。
- 必答 1(b)：renv 未被真正删除，H 门禁无误报（实测 renv/remotes/docopt/littler
  均仍在 site-library；「Removing X」是 renv 对不存在的 project-library 路径的 no-op）。

## D3：pipeline job（T/W 项）

**状态：通过**（unit + pipeline 全绿，2026-08-15）。

- `-profile test,docker`，3 样本 / 27 任务。
- fixture 就地生成在 `/tmp/p1_fixture`，不提交进仓库；`fixture_host == fixture_container`
  为 Linux 恒等映射（详见 NEXTFLOW_NOTES.md §6.1）。

**unit job 与 pipeline job 的分工**：unit job 验证逻辑正确性（T1-T13），其 Python 依赖
从 `env/requirements.txt` 取包名但去版本 pin 安装（pin 为 Python 3.7 容器准备，3.10 runner
上如 scipy 1.7.3 无 wheel）。目标环境的精确版本由容器镜像与 D3 的 pipeline job 覆盖，
不由 unit job 复现。

**D3 首轮 CI 捕获（本机不可见）**：`sed 's/[<>=!~].*//'` 只剥版本号、不滤注释，
`env/requirements.txt` 开头两行 `#` 注释被原样喂给 pip（`Invalid requirement: '#'`）；
已改为 `grep -vE '^\s*(#|$)' | sed ...` 先滤注释与空行。与 T4 常量漂移同族——
「代码看着对、只有 CI 真跑才暴露」。

### W 项：耗时（CI 实跑，2026-08-15 绿色 run）

| 项 | 耗时 | 备注 |
|---|---|---|
| unit job | 1m11s | D2 |
| pipeline job（总） | 2m19s | D3 |
| R 镜像 pull（2.36 GB） | ~26s | 远低于 15 min 阈值 |
| Python 镜像 pull | ~12s | |
| fixture 生成 | ~1s | make_fixture.py --outdir /tmp/p1_fixture |
| nextflow run（27 任务） | ~1m6s | -profile test,docker |

> 耗时取自 Actions step 时间戳（等价于 `time` 命令的 real）。R 镜像 2.36 GB 在 GitHub
> runner 直连下拉取仅 ~26s。

**tiny fixture 悬案关闭**：unit + pipeline 合计约 3.5 min，远低于 15 min 阈值——
**不需要独立 tiny fixture**（关闭 N1 阶段遗留的悬案）。

**Node.js 20 deprecation 警告**：GitHub Actions 平台层面的（actions/checkout@v4 等
action 内部使用的 Node 版本），与本项目配置无关，不需处理（非待办）。

## D4：X 项反向验证（CI 该红时变红）

**结论：CI 会变红（已证）+ artifact 不足以独立定位（已证）；artifact 可定位性待修复后重验。**

- **缺陷**：`modules/r03.nf` 输出文件名 `density_gene_correlations.csv` →
  `density_gene_correlation.csv`（少一个 s）。
- **变红**：Nextflow 报 `Missing output file(s) 'density_gene_correlation.csv'`，
  `Command exit status: 0` —— 脚本本身正常退出，是 Nextflow 输出契约捕获的沉默型缺陷。
- **红色 run**：https://github.com/sSanxiao/mben-density-nf/actions/runs/31868137696/job/94972320929
- **回退后转绿**：文件名改回，恢复绿色。

### artifact 定位能力评估（如实）

红色 run 只产出一个 artifact：`nextflow-trace-report`（599,730 bytes ≈ 586 KB，即
trace.tsv + report.html + timeline.html）。另外两个 artifact **缺失**：

- `nextflow-log`（`.nextflow.log`）——未上传。
- `failed-task-err`（`work/**/.command.err`）——未上传。

原因：`actions/upload-artifact@v4` 默认 `include-hidden-files: false`，`*` / `**` 不匹配
点开头文件（`.nextflow.log`、`.command.err`），glob 匹配不到 → `if-no-files-found: ignore`
使该步骤「绿色」但零产出。

**因此「仅凭 artifact 可独立定位根因」不成立**：trace/report 只能看到 R03 任务级 FAILED，
而关键错误 `Missing output file 'density_gene_correlation.csv'` 实际来自 **job 日志**
（`.nextflow.log` / Nextflow stderr），artifact 未包含。本次根因定位实际依赖 job 日志，
artifact 提供的是 trace/report 层面的辅助信息。

> 修复方向（P5 待办，不笼统写「加 include-hidden-files」）：
> - `.nextflow.log`：`include-hidden-files: true` + `if-no-files-found: error`
>   ——该文件每次 run 后必然存在，匹配不到即配置有误，应当失败。
> - 失败任务的 `.command.err` / `.command.out`：`include-hidden-files: true` +
>   `if-no-files-found: warn` ——成功的 run 没有失败任务，用 error 会误伤绿跑。
> 原则与全项目一致：不让「什么都没找到」冒充成功。
> 修复后需重做一次 X 项，证明 artifact 真的可定位（否则修复本身未验证）。

## P4 验收 S–X 六项总结

| 项 | 内容 | 状态 |
|---|---|---|
| S | 镜像推送 GHCR | 通过（两镜像推送 + CI pull 到；Python pull 由 D3 覆盖） |
| T | CI 跑通 pipeline | 通过（27 任务全完成） |
| U | CI 跑通 unit | 通过（CI 内 12 passed + 0 failed + 6 SKIP；6 个 Seurat 依赖测试由 D3 容器覆盖） |
| V | badge 绿且可点开 | 待绿跑（badge 已加，回退 push 后转绿即通过） |
| W | 运行时长记录 | 通过（耗时表 + tiny fixture 关闭） |
| X | 失败可见性（反向验证） | 部分（变红已证；artifact 独立定位未成立，待修复后重验） |

## 五条「CI 捕获、本机不可见」真实缺陷（与 X 项人为对照实验分开）

X 项是人为引入的对照；以下五条是**真实**缺陷，每条都是「代码看着对、只有 CI 真跑才暴露」：

1. **文件生命周期**：拆层后 `/tmp/renv.lock` 被 Layer 1 的 `rm -rf /tmp/*` 删除。
2. **API 语义**：`install.packages(version=)` 无声吞参，renv pin 从未生效。
3. **类型语义**：`as.character(packageVersion("Matrix"))` 字符串比较 vs `package_version` 对象比较。
4. **跨语言常量漂移**：`qc_schema.EXCLUDED_FILES` 加了 `meta_Fixture_*.txt`，`fingerprint.R` 的 `EXCLUDED_FILES_R` 未同步。
5. **管道边缘条件**：`sed` 只剥版本号不滤注释，`#` 注释被喂给 pip。
