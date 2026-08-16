# Environment baseline

Captured 2026-08 from the machine that produced the thesis results.

## R
R 4.2.0 · Seurat 5.2.1 · SeuratObject 5.0.2 · Matrix 1.6-4 · sctransform 0.4.1
Full closure: `renv.lock` (145 packages, counted by JSON-parsing the lockfile's "Packages" key — `len(json.load(open("env/renv.lock"))["Packages"])` — not by grep string matching). Container base: rocker/r-ver:4.2.0.
Scope-B trunk (P1a–P2, R01–R09) uses CRAN packages only — no Bioconductor.

## Python
System python3 3.7.10, no conda env. Pins in `requirements.txt`.
Container base: python:3.7-slim. Pure pip, no apt (buster repos are archived).
Python 3.7 is EOL; it is pinned deliberately as the reproduction target.

## Known limits
- Host BLAS/LAPACK differs from the container's. Container-vs-host equivalence
  is checked by tolerance (|Δρ| < 1e-6, identical gene sets), not byte identity.
  Same-machine before/after equivalence remains byte-identical.
- R version is pinned by the base image tag, not by renv.lock.
- hdf5r is NOT in renv.lock: it is Seurat's Suggests (dynamically loaded by
  Seurat::Read10X_h5 in R01_build_seurat.R), so sessionInfo() does not list
  it and renv::snapshot() did not capture it.  Its version (1.3.12) is fixed
  indirectly by the RSPM snapshot date (2026-08-01), NOT by the lockfile --
  changing the snapshot date can drift it.  The container pins it explicitly
  via install.packages() from the snapshot; the H gate hardcodes 1.3.12 as a
  known non-lockfile add-on.

- setup/install_deps.R is intentionally not migrated: it pins an incorrect
  ggplot2 version (4.0.2; server measured 3.5.2). For non-container installs,
  use renv.lock as the source of truth.
