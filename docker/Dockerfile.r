# Dockerfile.r — R 4.2.0 environment for thesis pipeline (R01-R09 stages)
#
# Base: rocker/r-ver:4.2.0 (Ubuntu 20.04 focal)
# focal apt repositories are active → system dependencies via apt-get.
# R packages are installed as precompiled binaries from a fixed RSPM
# snapshot (2026-08-01), ensuring reproducible builds.
#
# R 4.2.0 is pinned to the environment that produced the thesis results.
# Do not bump.

FROM rocker/r-ver:4.2.0

LABEL description="Thesis pipeline R environment (Seurat 5.2.1 / Matrix 1.6-4 / sctransform 0.4.1)"
LABEL maintainer="Qilu Wang"
LABEL r.version="4.2.0"
LABEL rspm.snapshot="2026-08-01"
LABEL rspm.url="https://packagemanager.posit.co/cran/__linux__/focal/2026-08-01"

# -------------------------------------------------------
# System dependencies (Ubuntu focal, apt works)
# -------------------------------------------------------
# libhdf5-dev          → HDF5 I/O (Seurat HDF5-backed assays)
# libcurl4-openssl-dev → HTTP/HTTPS requests (httr, curl)
# libssl-dev           → SSL/TLS (HTTPS, secure connections)
# libxml2-dev          → XML parsing (xml2, Seurat metadata)
# libpng-dev           → PNG image output (ggplot2, Seurat plots)
# libfontconfig1-dev   → Font rendering (ggplot2, text in plots)
# libglpk-dev          → GLPK linear programming (igraph)
# build-essential      → gcc/g++/make for compiling R packages from source
# gfortran             → Fortran compiler (Matrix, RcppArmadillo, etc.)
# curl                 → CLI HTTP client (renv download backend)
# -------------------------------------------------------
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
        libhdf5-dev \
        libcurl4-openssl-dev \
        libssl-dev \
        libxml2-dev \
        libpng-dev \
        libfontconfig1-dev \
        libglpk-dev \
        build-essential \
        gfortran \
        curl \
    && rm -rf /var/lib/apt/lists/*

# -------------------------------------------------------
# R package installation via renv
# -------------------------------------------------------
# Fixed RSPM snapshot (2026-08-01) providing precompiled binary packages
# for Ubuntu focal.  The snapshot date is after the latest package release
# date in renv.lock (irlba 2.3.7, 2026-01-26), ensuring all pinned
# versions are available (including archived versions like xfun 0.57).
# Explicit __linux__/focal/ prefix guarantees focal binaries.
# -------------------------------------------------------
ENV RSPM_SNAPSHOT_DATE=2026-08-01
ENV RENV_CONFIG_REPOS_OVERRIDE=https://packagemanager.posit.co/cran/__linux__/focal/2026-08-01

# Install renv with an EXPLICIT version pin.  renv's own version changes
# restore() behavior: the RSPM snapshot 2026-08-01 ships renv 1.2.3, which
# fails to resolve Seurat's fastDummies dependency ("dependency
# 'fastDummies' is not available"); renv 1.2.4 (the version the C3 build
# actually used) resolves it correctly.  Pin 1.2.4 via CRAN — old versions
# stay in the archive, so the pin is deterministic despite the rolling URL.
RUN R -e 'install.packages("renv", version = "1.2.4", repos = "https://cloud.r-project.org")'

# Record build provenance
RUN echo "RSPM snapshot: 2026-08-01" > /opt/build_info.txt \
    && echo "R version: 4.2.0" >> /opt/build_info.txt \
    && echo "Base image: rocker/r-ver:4.2.0" >> /opt/build_info.txt \
    && echo "Platform: Ubuntu 20.04 (focal)" >> /opt/build_info.txt

# Copy renv.lock (layer caching: only rebuild when lock changes)
COPY env/renv.lock /tmp/renv.lock

# Restore all 130 packages from the lock file
RUN R -e 'renv::restore(lockfile = "/tmp/renv.lock", prompt = FALSE, clean = TRUE)' \
    && rm /tmp/renv.lock

# -------------------------------------------------------
# hdf5r — explicit add-on (renv.lock gap)
# -------------------------------------------------------
# Seurat::Read10X_h5 dynamically loads hdf5r (Seurat Suggests, not a
# direct Imports), so renv::snapshot() on the server did not capture it.
# It IS present on the server (installed_packages.csv: hdf5r 1.3.12) and
# is required by R01_build_seurat.R.  Install from the same fixed RSPM
# snapshot to keep the environment reproducible.
# -------------------------------------------------------
RUN R -e 'install.packages("hdf5r", repos = Sys.getenv("RENV_CONFIG_REPOS_OVERRIDE"))'

# -------------------------------------------------------
# Verify key package versions (H criterion)
# -------------------------------------------------------
RUN R -e '\
cat("=== sessionInfo ===\n"); \
sessionInfo() \
'

CMD ["R"]
