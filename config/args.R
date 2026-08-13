# ============================================================
# config/args.R
# ------------------------------------------------------------
# Minimal --key value argument parser shared by all R scripts.
# No external dependencies (base R only). See P1 SPEC v2 §2.1.
#
# Usage in a script:
#   source(file.path(dirname_of_repo_root, "config/args.R"))
#   args <- parse_args(defaults = list(sample = NULL, outdir = NULL))
#
# Conventions (SPEC v2 §2):
#   --sample <Dataset/Subname>  process a single sample only
#   --registry <path>           override registry path (default stays
#                               each script's existing behaviour)
#   --manifest <path>           explicit file list for fan-in stages
#   --indir / --outdir <path>   input/output roots
# ============================================================

# Minimal --key value parser. No external dependencies.
parse_args <- function(defaults = list()) {
  a <- commandArgs(trailingOnly = TRUE)
  out <- defaults
  i <- 1L
  while (i <= length(a)) {
    tok <- a[[i]]
    if (!startsWith(tok, "--")) stop("Unexpected argument: ", tok)
    key <- sub("^--", "", tok)
    if (i + 1L <= length(a) && !startsWith(a[[i + 1L]], "--")) {
      out[[key]] <- a[[i + 1L]]; i <- i + 2L
    } else {
      out[[key]] <- TRUE; i <- i + 1L
    }
  }
  out
}
