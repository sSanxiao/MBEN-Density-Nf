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

**状态：待执行**（用户 push 后由 CI 实跑，本机不预跑）。

- `-profile test,docker`，3 样本 / 27 任务。
- fixture 就地生成在 `/tmp/p1_fixture`，不提交进仓库；`fixture_host == fixture_container`
  为 Linux 恒等映射（详见 NEXTFLOW_NOTES.md §6.1）。

### W 项：耗时（CI 实跑后回填）

| 项 | 耗时 | 备注 |
|---|---|---|
| unit job | （待回填） | D2 |
| pipeline job（总） | （待回填） | D3 |
| R 镜像 pull（2.36 GB） | （待回填） | 超过 15 min 才考虑 tiny fixture，否则不做 |
| Python 镜像 pull | （待回填） | |
| nextflow run（27 任务） | （待回填） | |
