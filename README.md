# mben-density-nf

[![CI](https://github.com/sSanxiao/mben-density-nf/actions/workflows/ci.yml/badge.svg)](https://github.com/sSanxiao/mben-density-nf/actions/workflows/ci.yml)

Nextflow workflow for the cell-density-coupled gene signature pipeline
(MSc thesis, spatial transcriptomics / medulloblastoma).

**Status: work in progress.** The pipeline, containers and verification
tooling are in place; documentation is being written.

- `main.nf`, `modules/` — Nextflow workflow (per-sample fan-out,
  per-dataset fan-in)
- `docker/` — container definitions (R 4.2.0 + Seurat 5.2.1,
  Python 3.7.10), pinned via `env/renv.lock` and `env/requirements.txt`
- `tools/` — content fingerprinting and equivalence verification
- `docs/NEXTFLOW_NOTES.md` — design rationale
- `docs/P2_CONTAINER_VERIFICATION.md` — container vs host numerical
  equivalence results

Original thesis code archive: https://github.com/sSanxiao/Thesis_project