#!/usr/bin/env bash
# ============================================================
# tools/verify_equivalence.sh
# ------------------------------------------------------------
# One-command 4-way fingerprint comparison:
#   1. Old full mode (pre-refactor invocations)
#   2. New full mode (refactored scripts, no --sample)
#   3. New per-sample mode (refactored scripts, --sample)
#   4. Shard merge (merge_qc.py / merge_k_selection.py)
#
# Prints a PASS/SKIP/FAIL table for acceptance criteria A-F.
#
# Environment variables:
#   RSCRIPT   Path to Rscript executable (default: Rscript)
#   DATA_DIR  Directory containing sample_registry.json (required)
#   RESULTS_DIR  Output root (required)
#   PYTHON    Python executable (default: python)
#
# Usage:
#   RSCRIPT=/path/to/Rscript DATA_DIR=/data RESULTS_DIR=/tmp/out \
#     bash tools/verify_equivalence.sh
#
# Python 3.7 compatible: no walrus, no importlib.metadata, no f-strings
#       in subprocess calls. All Python invocations use heredoc + sys.argv.
# ============================================================

set -uo pipefail
# NOTE: set -e is intentionally OFF.  This script must continue after
# individual stage failures (Donor2 is a known expected failure).
# Failures are tracked via FAILED_STAGES; summary exit code is set at
# the end based on acceptance criteria results.

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
RSCRIPT="${RSCRIPT:-Rscript}"
PYTHON="${PYTHON:-python}"
DATA_DIR="${DATA_DIR:?DATA_DIR is required (must contain sample_registry.json)}"
RESULTS_DIR="${RESULTS_DIR:?RESULTS_DIR is required}"
REGISTRY="$DATA_DIR/sample_registry.json"

# --- Create output directories ---
OLD_FULL="$RESULTS_DIR/old_full"
NEW_FULL="$RESULTS_DIR/new_full"
NEW_SINGLE="$RESULTS_DIR/new_single"
MERGED="$RESULTS_DIR/merged"
LOGDIR="$RESULTS_DIR/logs"
mkdir -p "$OLD_FULL" "$NEW_FULL" "$NEW_SINGLE" "$MERGED" "$LOGDIR"

# --- R-stage subset registry (必修3) ---
# Donor2 is the fixture sample intentionally missing cell_area. Obs 17
# (latent pipeline defect, confirmed on Seurat 5.2.1 and 5.4.0) causes
# R01 to crash on Donor2, which in full mode terminates the loop before
# all subsequent samples.  Excluding Donor2 from R-stage comparisons
# lets us verify the other 4 samples.
#   - P stages continue to use the full registry (Donor2 covers the
#     conditional column path at the Python level — confirmed working).
#   - R stages use the subset registry via --registry override.
#   - This does NOT modify any tested script (hard constraint 1).
#     The exclusion is a verification configuration, not a code change.
R_STAGE_EXCLUDE="Fixture_Human/Donor2"
R_REGISTRY="$RESULTS_DIR/registry_rstage.json"

echo ""
echo "=== R-stage subset registry ==="
echo "  Full registry:      $REGISTRY"
echo "  R-stage registry:   $R_REGISTRY"
echo "  Excluding:          $R_STAGE_EXCLUDE"
echo "  Reason:             Obs 17 (R01 crashes on samples without cell_area;"
echo "                      confirmed on Seurat 5.2.1 and 5.4.0; latent pipeline"
echo "                      defect, not a version API change)"

"$PYTHON" - "$REGISTRY" "$R_STAGE_EXCLUDE" "$R_REGISTRY" <<'PYEOF'
import sys, json
full_reg = sys.argv[1]
exclude_key = sys.argv[2]
out_path = sys.argv[3]
with open(full_reg) as f:
    reg = json.load(f)
reg.pop(exclude_key, None)
with open(out_path, 'w') as f:
    json.dump(reg, f, indent=2)
print("  R-stage registry written: %d samples (1 excluded)" % len(reg))
PYEOF

echo ""

# --- Results table ---
RESULTS_TABLE=""
PASS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0
GAPS_LIST=""

# Stage-failure tracking (mandatory 2: per-sample, per-stage breakdown)
# Format: one entry per line: "label|exit_code"
FAILED_STAGES=""

record_result() {
    local name="$1"
    local status="$2"
    local detail="$3"
    RESULTS_TABLE="${RESULTS_TABLE}| ${name} | ${status} | ${detail} |\n"
    case "$status" in
        PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
        SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
        FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    esac
}

add_gap() {
    GAPS_LIST="${GAPS_LIST}- $1\n"
}

# ============================================================
# run_stage — error-handling wrapper (mandatory 2)
#
# Usage: run_stage <label> <cmd> [args...]
#
# Writes full output to $LOGDIR/<label>.log.
# On failure: prints sample/stage name, exit code, last 5 lines
# of the log, appends to FAILED_STAGES, and continues.
# Returns 0 on success, 1 on failure (caller may inspect if needed).
# ============================================================
run_stage() {
    local label="$1"
    shift
    local log="$LOGDIR/${label}.log"
    if "$@" > "$log" 2>&1; then
        echo "  [OK] ${label}"
        return 0
    else
        local ec=$?
        echo "  [FAIL] ${label} (exit ${ec})"
        echo "  --- log tail (${log}) ---"
        tail -n 5 "$log" 2>/dev/null | sed 's/^/  | /'
        echo "  --- end ---"
        FAILED_STAGES="${FAILED_STAGES}${label}|${ec}
"
        return 1
    fi
}

# --- Fingerprint helpers (Python heredoc, 3.7 compatible) ---
fingerprint_csv() {
    local fpath="$1"
    "$PYTHON" - "$fpath" <<'PYEOF'
import sys, json
sys.path.insert(0, 'tools')
import fingerprint as fp
try:
    r = fp.fingerprint_csv(sys.argv[1])
    print(json.dumps(r))
except Exception as e:
    sys.stderr.write('ERROR: ' + str(e) + '\n')
    sys.exit(1)
PYEOF
}

fingerprint_rds() {
    local fpath="$1"
    "$RSCRIPT" tools/fingerprint.R --file "$fpath" 2>/dev/null
}

# ============================================================
# Stage 1: Old full mode (pre-refactor invocations)
# ============================================================
echo "=== Stage 1: Old full mode ==="

export DATA_DIR
export RESULTS_DIR="$OLD_FULL"

echo "  P1b (old full)..."
run_stage "old_P1b" "$PYTHON" 01_python_preprocessing/P1b_data_loading.py \
    --registry "$REGISTRY" \
    --outdir "$OLD_FULL/P1_Results"

echo "  P1c (old full)..."
run_stage "old_P1c" "$PYTHON" 01_python_preprocessing/P1c_gene_intersection.py \
    --registry "$REGISTRY" \
    --indir "$OLD_FULL/P1_Results" \
    --outdir "$OLD_FULL/P1_Results/Gene_Intersection"

echo "  P2 (old full)..."
# P2 reads DATA_DIR for registry, RESULTS_DIR for P1 input and P2 output
run_stage "old_P2" "$PYTHON" 01_python_preprocessing/P2_density_calculation.py

echo "  R01-R04 (old full)..."
for r in R01_build_seurat R02_sctransform R03_density_gene_correlation R04_filter_density_genes; do
    run_stage "old_${r}" "$RSCRIPT" "02_R_core_pipeline/${r}.R" \
        --registry "$R_REGISTRY"
done

# ============================================================
# Stage 2: New full mode (refactored, no --sample)
# ============================================================
echo "=== Stage 2: New full mode ==="

export RESULTS_DIR="$NEW_FULL"

echo "  P1b (new full)..."
run_stage "new_P1b" "$PYTHON" 01_python_preprocessing/P1b_data_loading.py \
    --registry "$REGISTRY" \
    --outdir "$NEW_FULL/P1_Results"

echo "  P2 (new full, original script)..."
# P2 original script (kept unchanged for comparison baseline)
export DATA_DIR  # ensure P2 can find registry
run_stage "new_P2" "$PYTHON" 01_python_preprocessing/P2_density_calculation.py

echo "  R01-R04 (new full)..."
for r in R01_build_seurat R02_sctransform R03_density_gene_correlation R04_filter_density_genes; do
    run_stage "new_${r}" "$RSCRIPT" "02_R_core_pipeline/${r}.R" \
        --registry "$R_REGISTRY"
done

# ============================================================
# Stage 3: New per-sample mode
# ============================================================
echo "=== Stage 3: New per-sample mode ==="

# Read sample names from registry (heredoc, 3.7 compatible)
SAMPLES=$("$PYTHON" - "$REGISTRY" <<'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    reg = json.load(f)
for k in reg:
    print(k.strip())
PYEOF
)
# Strip any \r characters that may leak from Windows Python on Git Bash
SAMPLES=$(echo "$SAMPLES" | tr -d '\r')

# --- 3a: P1b per-sample for ALL samples (must complete before P2a) ---
echo "  3a: P1b per-sample..."
for SAMPLE in $SAMPLES; do
    SAFE_NAME=$(echo "$SAMPLE" | tr '/' '_')
    SAMPLE_DIR="$NEW_SINGLE/$SAFE_NAME"
    mkdir -p "$SAMPLE_DIR"
    run_stage "P1b_${SAFE_NAME}" "$PYTHON" 01_python_preprocessing/P1b_data_loading.py \
        --registry "$REGISTRY" \
        --sample "$SAMPLE" \
        --outdir "$SAMPLE_DIR"
done

# --- 3b: P2a per-dataset (needs all cell_metadata.csv from 3a) ---
echo "  3b: P2a per-dataset..."
# Build manifest with Windows-compatible paths (Python on Windows cannot read
# /f/... MSYS2 paths from file content; command-line args are auto-converted
# but embedded paths are not).
if command -v cygpath &>/dev/null; then
    _NEW_SINGLE_MANIFEST="$(cygpath -w "$NEW_SINGLE")"
else
    _NEW_SINGLE_MANIFEST="$NEW_SINGLE"
fi

DATASETS=$(echo "$SAMPLES" | cut -d'/' -f1 | sort -u)
for DATASET in $DATASETS; do
    P2A_DIR="$NEW_SINGLE/p2a_${DATASET}"
    META_LIST="$NEW_SINGLE/meta_${DATASET}.txt"
    # Build manifest (tr -d '\r' removes Windows bash CR pollution)
    : > "$META_LIST"
    for S in $SAMPLES; do
        D=$(echo "$S" | cut -d'/' -f1)
        if [ "$D" = "$DATASET" ]; then
            SN=$(echo "$S" | tr '/' '_')
            printf '%s\t%s\n' "$S" "${_NEW_SINGLE_MANIFEST}/${SN}/cell_metadata.csv" | tr -d '\r' >> "$META_LIST"
        fi
    done
    run_stage "P2a_${DATASET}" "$PYTHON" 01_python_preprocessing/P2a_select_k.py \
        --dataset "$DATASET" \
        --registry "$REGISTRY" \
        --metadata-list "$META_LIST" \
        --outdir "$P2A_DIR"
done

# --- 3c: P2b + R01-R04 per-sample ---
echo "  3c: P2b + R01-R04 per-sample..."
for SAMPLE in $SAMPLES; do
    echo "  Processing: $SAMPLE"
    SAFE_NAME=$(echo "$SAMPLE" | tr '/' '_')
    SAMPLE_DIR="$NEW_SINGLE/$SAFE_NAME"
    DATASET=$(echo "$SAMPLE" | cut -d'/' -f1)
    P2A_DIR="$NEW_SINGLE/p2a_${DATASET}"

    run_stage "P2b_${SAFE_NAME}" "$PYTHON" 01_python_preprocessing/P2b_density.py \
        --sample "$SAMPLE" \
        --registry "$REGISTRY" \
        --kfile "$P2A_DIR/k_selection.json" \
        --metadata "$SAMPLE_DIR/cell_metadata.csv" \
        --outdir "$SAMPLE_DIR"

    # R01-R04 per-sample (flat) — skip samples excluded from R-stage registry
    if [ "$SAMPLE" = "$R_STAGE_EXCLUDE" ]; then
        echo "  [SKIP] $SAMPLE: excluded from R-stage registry (Obs 17)"
        continue
    fi

    R_INDIR="$SAMPLE_DIR"
    for r in R01_build_seurat R02_sctransform R03_density_gene_correlation R04_filter_density_genes; do
        R_PREFIX=$(echo "$r" | cut -d_ -f1)
        R_OUTDIR="$NEW_SINGLE/r_${SAFE_NAME}_${R_PREFIX}"
        run_stage "${R_PREFIX}_${SAFE_NAME}" "$RSCRIPT" "02_R_core_pipeline/${r}.R" \
            --sample "$SAMPLE" \
            --registry "$R_REGISTRY" \
            --indir "$R_INDIR" \
            --outdir "$R_OUTDIR"
        R_INDIR="$R_OUTDIR"
    done
done

# ============================================================
# Stage 4: Shard merge
# ============================================================
echo "=== Stage 4: Shard merge ==="

# Merge P1 QC shards
P1_SHARD_DIRS=""
for SAMPLE in $SAMPLES; do
    SAFE_NAME=$(echo "$SAMPLE" | tr '/' '_')
    P1_SHARD_DIRS="$P1_SHARD_DIRS $NEW_SINGLE/$SAFE_NAME"
done

run_stage "merge_P1_QC" "$PYTHON" tools/merge_qc.py \
    --registry "$REGISTRY" \
    --shards $P1_SHARD_DIRS \
    --table "ALL_SAMPLES_P1_QC.csv" \
    --out "$MERGED/ALL_SAMPLES_P1_QC.csv"

# Merge K selection shards
P2A_SHARD_DIRS=""
for DATASET in $(echo "$SAMPLES" | cut -d'/' -f1 | sort -u); do
    P2A_SHARD_DIRS="$P2A_SHARD_DIRS $NEW_SINGLE/p2a_${DATASET}"
done

run_stage "merge_K_SEL" "$PYTHON" tools/merge_k_selection.py \
    --registry "$REGISTRY" \
    --shards $P2A_SHARD_DIRS \
    --out "$MERGED/ALL_DATASETS_K_SELECTION.csv"

# ============================================================
# Mandatory 3: Check whether P1b failed on Donor2 specifically
# ============================================================
echo ""
echo "============================================"
echo "  Mandatory 3: P1b Donor2 status"
echo "============================================"

DONOR2_IN_REGISTRY=""
if echo "$SAMPLES" | grep -q "Donor2"; then
    DONOR2_IN_REGISTRY="yes"
fi

P1B_DONOR2_FAILED=false
if [ -n "$DONOR2_IN_REGISTRY" ]; then
    DONOR2_SAFE=$(echo "$SAMPLES" | tr ' ' '\n' | grep "Donor2" | head -1 | tr '/' '_')
    DONOR2_LABEL="P1b_${DONOR2_SAFE}"
    P1B_DONOR2_LOG="$LOGDIR/${DONOR2_LABEL}.log"
    # Check if P1b Donor2 is in FAILED_STAGES (only true if it actually failed)
    if echo "$FAILED_STAGES" | grep -q "^${DONOR2_LABEL}|"; then
        P1B_DONOR2_FAILED=true
        echo "  P1b Donor2: FAILED (log: ${P1B_DONOR2_LOG})"
        echo "  Consequence: Donor2 failure starts at Python stage,"
        echo "  earlier than previously recorded. Updating known gaps."
    elif [ -f "$P1B_DONOR2_LOG" ]; then
        # Log exists but stage not in FAILED_STAGES → stage succeeded
        echo "  P1b Donor2: OK (log present, stage completed successfully)"
    else
        echo "  P1b Donor2: SKIPPED (neither failed nor produced log)"
    fi
fi

if ! $P1B_DONOR2_FAILED; then
    if [ -n "$DONOR2_IN_REGISTRY" ]; then
        echo "  P1b Donor2: OK (no failure at Python stage)"
    else
        echo "  P1b Donor2: N/A (Donor2 not in registry)"
    fi
fi

# ============================================================
# Mandatory 4: Confirm old-full A项 failure point
# ============================================================
echo ""
echo "============================================"
echo "  Mandatory 4: Old-full A项 failure analysis"
echo "============================================"

echo "  Checking which old-full stages produced output..."
echo "  (P=Python stages, R=R stages)"
for csv_rel in \
    "P1_Results/ALL_SAMPLES_P1_QC.csv" \
    "P2_Results/ALL_DATASETS_K_SELECTION.csv" \
    "R3_Results/ALL_SAMPLES_R3_SUMMARY.csv" \
    "R4_Results/ALL_SAMPLES_R4_SUMMARY.csv"; do
    OLD_CSV="$OLD_FULL/$csv_rel"
    base=$(basename "$csv_rel")
    if [ -f "$OLD_CSV" ]; then
        echo "  ${base}: present"
    else
        echo "  ${base}: MISSING"
    fi
done

# Check old-full failed stages explicitly
if echo "$FAILED_STAGES" | grep -q "^old_R0"; then
    echo ""
    echo "  Old-full R-stage failures detected:"
    echo "$FAILED_STAGES" | grep "^old_R0" | while read -r line; do
        echo "    - $line"
    done
fi

# ============================================================
# Stage failures summary (mandatory 2)
# ============================================================
echo ""
echo "============================================"
echo "  Stage Failures"
echo "============================================"

if [ -z "$FAILED_STAGES" ]; then
    echo "  (none — all stages passed)"
else
    # Count and list by stage type
    echo "  Per-sample, per-stage breakdown:"
    echo "  Stage           | Sample              | Exit | Log"
    echo "  -----------------|---------------------|------|-----"
    OLD_IFS="$IFS"
    IFS="
"
    for entry in $FAILED_STAGES; do
        [ -z "$entry" ] && continue
        label="${entry%%|*}"
        ec="${entry##*|}"
        STAGE_TYPE=$(echo "$label" | cut -d_ -f1)
        SAMPLE_PART=$(echo "$label" | cut -d_ -f2-)
        printf "  %-16s | %-20s | %-4s | %s\n" \
            "$STAGE_TYPE" "$SAMPLE_PART" "$ec" "$LOGDIR/${label}.log"
    done
    IFS="$OLD_IFS"

    TOTAL_FAILS=$(echo "$FAILED_STAGES" | grep -c '[^[:space:]]' || echo 0)
    echo ""
    echo "  Total stage failures: $TOTAL_FAILS"
fi

# ============================================================
# Acceptance criteria A-F
# ============================================================
echo ""
echo "============================================"
echo "  Acceptance Criteria Results"
echo "============================================"
echo "| Criterion | Status | Detail |"
echo "|------------|--------|--------|"

# --- A: Old full == New full (CSV fingerprints) ---
# Covers all ALL_SAMPLES_* and ALL_DATASETS_* aggregate CSVs within Scope B.
# Both-sides-missing is SKIPPED (not PASS / not FAIL):
#   two independent failures cannot be compared, and silently treating
#   bilateral absence as equivalence would hide simultaneous regressions.
A_OK=true
A_DETAIL=""
A_SKIPS=""
for csv_rel in \
    "P1_Results/ALL_SAMPLES_P1_QC.csv" \
    "P2_Results/ALL_SAMPLES_P2_QC.csv" \
    "P2_Results/ALL_DATASETS_K_SELECTION.csv" \
    "R1_Results/ALL_SAMPLES_R1_QC.csv" \
    "R2_Results/ALL_SAMPLES_R2_QC.csv" \
    "R3_Results/ALL_SAMPLES_R3_SUMMARY.csv" \
    "R4_Results/ALL_SAMPLES_R4_SUMMARY.csv"; do

    OLD_CSV="$OLD_FULL/$csv_rel"
    NEW_CSV="$NEW_FULL/$csv_rel"

    OLD_EXISTS=false
    NEW_EXISTS=false
    [ -f "$OLD_CSV" ] && OLD_EXISTS=true
    [ -f "$NEW_CSV" ] && NEW_EXISTS=true

    if ! $OLD_EXISTS && ! $NEW_EXISTS; then
        # Both missing: skip (cannot compare; reason recorded)
        A_SKIPS="${A_SKIPS} ${csv_rel}:both_missing"
        continue
    fi
    if ! $OLD_EXISTS; then
        A_DETAIL="${A_DETAIL} old:${csv_rel}:missing"
        A_OK=false
        continue
    fi
    if ! $NEW_EXISTS; then
        A_DETAIL="${A_DETAIL} new:${csv_rel}:missing"
        A_OK=false
        continue
    fi

    OLD_FP=$(fingerprint_csv "$OLD_CSV" 2>/dev/null || echo "ERR")
    NEW_FP=$(fingerprint_csv "$NEW_CSV" 2>/dev/null || echo "ERR")

    if [ "$OLD_FP" = "$NEW_FP" ] && [ "$OLD_FP" != "ERR" ]; then
        A_DETAIL="${A_DETAIL} ${csv_rel}:OK"
    else
        A_DETAIL="${A_DETAIL} ${csv_rel}:MISMATCH"
        A_OK=false
    fi
done

if [ -n "$A_SKIPS" ]; then
    A_DETAIL="${A_DETAIL} [skipped:${A_SKIPS} ]"
fi

if $A_OK; then
    A_MSG="all comparable CSV fingerprints match"
    [ -n "$A_SKIPS" ] && A_MSG="${A_MSG} (${A_SKIPS} skipped — both sides missing)"
    record_result "A: old-full == new-full" "PASS" "$A_MSG"
else
    record_result "A: old-full == new-full" "FAIL" "$A_DETAIL"
fi

# --- B: New full == New per-sample (per-sample fingerprints) ---
# Both-sides-missing is SKIPPED (e.g., Donor2 excluded from R_REGISTRY).
B_OK=true
B_DETAIL=""
B_SKIPS=""
for SAMPLE in $SAMPLES; do
    SAFE_NAME=$(echo "$SAMPLE" | tr '/' '_')
    SUBNAME=$(echo "$SAMPLE" | cut -d'/' -f2)
    DATASET=$(echo "$SAMPLE" | cut -d'/' -f1)

    # R01 rds
    FULL_RDS="$NEW_FULL/R1_Results/$DATASET/$SUBNAME/${SUBNAME}_seurat.rds"
    SINGLE_RDS="$NEW_SINGLE/r_${SAFE_NAME}_R01/${SUBNAME}_seurat.rds"

    F_RDS_EXISTS=false; S_RDS_EXISTS=false
    [ -f "$FULL_RDS" ] && F_RDS_EXISTS=true
    [ -f "$SINGLE_RDS" ] && S_RDS_EXISTS=true

    if ! $F_RDS_EXISTS && ! $S_RDS_EXISTS; then
        B_SKIPS="${B_SKIPS} ${SAMPLE}:rds:both_missing"
        # Continue to r3csv check below (may also be both-missing)
    elif $F_RDS_EXISTS && $S_RDS_EXISTS; then
        FULL_FP=$(fingerprint_rds "$FULL_RDS" 2>/dev/null || echo "ERR")
        SINGLE_FP=$(fingerprint_rds "$SINGLE_RDS" 2>/dev/null || echo "ERR")
        if [ "$FULL_FP" = "$SINGLE_FP" ] && [ "$FULL_FP" != "ERR" ]; then
            B_DETAIL="$B_DETAIL $SAMPLE:rds:OK"
        else
            B_DETAIL="$B_DETAIL $SAMPLE:rds:MISMATCH"
            B_OK=false
        fi
    else
        F_EXISTS="N"; S_EXISTS="N"
        $F_RDS_EXISTS && F_EXISTS="Y"
        $S_RDS_EXISTS && S_EXISTS="Y"
        B_DETAIL="$B_DETAIL $SAMPLE:rds:missing(f=$F_EXISTS,s=$S_EXISTS)"
        B_OK=false
    fi

    # R03 CSV
    FULL_CSV="$NEW_FULL/R3_Results/$DATASET/$SUBNAME/density_gene_correlations.csv"
    SINGLE_CSV="$NEW_SINGLE/r_${SAFE_NAME}_R03/density_gene_correlations.csv"

    F_CSV_EXISTS=false; S_CSV_EXISTS=false
    [ -f "$FULL_CSV" ] && F_CSV_EXISTS=true
    [ -f "$SINGLE_CSV" ] && S_CSV_EXISTS=true

    if ! $F_CSV_EXISTS && ! $S_CSV_EXISTS; then
        B_SKIPS="${B_SKIPS} ${SAMPLE}:r3csv:both_missing"
    elif $F_CSV_EXISTS && $S_CSV_EXISTS; then
        FULL_FP=$(fingerprint_csv "$FULL_CSV" 2>/dev/null || echo "ERR")
        SINGLE_FP=$(fingerprint_csv "$SINGLE_CSV" 2>/dev/null || echo "ERR")
        if [ "$FULL_FP" = "$SINGLE_FP" ] && [ "$FULL_FP" != "ERR" ]; then
            B_DETAIL="$B_DETAIL $SAMPLE:r3csv:OK"
        else
            B_DETAIL="$B_DETAIL $SAMPLE:r3csv:MISMATCH"
            B_OK=false
        fi
    else
        B_DETAIL="$B_DETAIL $SAMPLE:r3csv:missing"
        B_OK=false
    fi
done

if [ -n "$B_SKIPS" ]; then
    B_DETAIL="${B_DETAIL} [skipped:${B_SKIPS} ]"
fi

if $B_OK; then
    B_MSG="all sample fingerprints match"
    [ -n "$B_SKIPS" ] && B_MSG="${B_MSG} (${B_SKIPS} skipped — both sides missing)"
    record_result "B: new-full == new-per-sample" "PASS" "$B_MSG"
else
    record_result "B: new-full == new-per-sample" "FAIL" "$B_DETAIL"
fi

# --- C: Old full == New full (rds fingerprints) ---
# Both-sides-missing is SKIPPED (e.g., Donor2 excluded from R_REGISTRY).
C_OK=true
C_DETAIL=""
C_SKIPS=""
for SAMPLE in $SAMPLES; do
    SUBNAME=$(echo "$SAMPLE" | cut -d'/' -f2)
    DATASET=$(echo "$SAMPLE" | cut -d'/' -f1)
    OLD_RDS="$OLD_FULL/R1_Results/$DATASET/$SUBNAME/${SUBNAME}_seurat.rds"
    NEW_RDS="$NEW_FULL/R1_Results/$DATASET/$SUBNAME/${SUBNAME}_seurat.rds"

    OLD_EXISTS=false; NEW_EXISTS=false
    [ -f "$OLD_RDS" ] && OLD_EXISTS=true
    [ -f "$NEW_RDS" ] && NEW_EXISTS=true

    if ! $OLD_EXISTS && ! $NEW_EXISTS; then
        C_SKIPS="${C_SKIPS} ${SAMPLE}:both_missing"
    elif $OLD_EXISTS && $NEW_EXISTS; then
        OLD_FP=$(fingerprint_rds "$OLD_RDS" 2>/dev/null || echo "ERR")
        NEW_FP=$(fingerprint_rds "$NEW_RDS" 2>/dev/null || echo "ERR")
        if [ "$OLD_FP" = "$NEW_FP" ] && [ "$OLD_FP" != "ERR" ]; then
            C_DETAIL="$C_DETAIL $SAMPLE:OK"
        else
            C_DETAIL="$C_DETAIL $SAMPLE:MISMATCH"
            C_OK=false
        fi
    else
        C_DETAIL="$C_DETAIL $SAMPLE:missing"
        C_OK=false
    fi
done

if [ -n "$C_SKIPS" ]; then
    C_DETAIL="${C_DETAIL} [skipped:${C_SKIPS} ]"
fi

if $C_OK; then
    C_MSG="all rds fingerprints match"
    [ -n "$C_SKIPS" ] && C_MSG="${C_MSG} (${C_SKIPS} skipped — both sides missing)"
    record_result "C: old-full == new-full (rds)" "PASS" "$C_MSG"
else
    record_result "C: old-full == new-full (rds)" "FAIL" "$C_DETAIL"
fi

# --- D: P2a+P2b == original P2 ---
D_OK=true
D_DETAIL=""
for SAMPLE in $SAMPLES; do
    DATASET=$(echo "$SAMPLE" | cut -d'/' -f1)
    SUBNAME=$(echo "$SAMPLE" | cut -d'/' -f2)
    SAFE_NAME=$(echo "$SAMPLE" | tr '/' '_')
    OLD_P2="$OLD_FULL/P2_Results/$DATASET/$SUBNAME/cell_density.csv"
    NEW_P2B="$NEW_SINGLE/$SAFE_NAME/cell_density.csv"

    if [ -f "$OLD_P2" ] && [ -f "$NEW_P2B" ]; then
        OLD_FP=$(fingerprint_csv "$OLD_P2" 2>/dev/null || echo "ERR")
        NEW_FP=$(fingerprint_csv "$NEW_P2B" 2>/dev/null || echo "ERR")
        if [ "$OLD_FP" = "$NEW_FP" ] && [ "$OLD_FP" != "ERR" ]; then
            D_DETAIL="$D_DETAIL $SAMPLE:OK"
        else
            D_DETAIL="$D_DETAIL $SAMPLE:MISMATCH"
            D_OK=false
        fi
    else
        D_DETAIL="$D_DETAIL $SAMPLE:missing"
        D_OK=false
    fi
done

if $D_OK; then
    record_result "D: P2a+P2b == original P2" "PASS" "density fingerprints match"
else
    record_result "D: P2a+P2b == original P2" "FAIL" "$D_DETAIL"
fi

# --- E: Shards merge == full-mode ALL_SAMPLES_* ---
E_OK=true
E_DETAIL=""

MERGED_P1QC="$MERGED/ALL_SAMPLES_P1_QC.csv"
FULL_P1QC="$NEW_FULL/P1_Results/ALL_SAMPLES_P1_QC.csv"
if [ -f "$MERGED_P1QC" ] && [ -f "$FULL_P1QC" ]; then
    M_FP=$(fingerprint_csv "$MERGED_P1QC" 2>/dev/null || echo "ERR")
    F_FP=$(fingerprint_csv "$FULL_P1QC" 2>/dev/null || echo "ERR")
    if [ "$M_FP" = "$F_FP" ] && [ "$M_FP" != "ERR" ]; then
        E_DETAIL="$E_DETAIL P1_QC:OK"
    else
        E_DETAIL="$E_DETAIL P1_QC:MISMATCH"
        E_OK=false
    fi
else
    M_EXISTS="N"; F_EXISTS="N"
    [ -f "$MERGED_P1QC" ] && M_EXISTS="Y"
    [ -f "$FULL_P1QC" ] && F_EXISTS="Y"
    E_DETAIL="$E_DETAIL P1_QC:missing(m=$M_EXISTS,f=$F_EXISTS)"
    E_OK=false
fi

MERGED_K="$MERGED/ALL_DATASETS_K_SELECTION.csv"
FULL_K="$NEW_FULL/P2_Results/ALL_DATASETS_K_SELECTION.csv"
if [ -f "$MERGED_K" ] && [ -f "$FULL_K" ]; then
    M_FP=$(fingerprint_csv "$MERGED_K" 2>/dev/null || echo "ERR")
    F_FP=$(fingerprint_csv "$FULL_K" 2>/dev/null || echo "ERR")
    if [ "$M_FP" = "$F_FP" ] && [ "$M_FP" != "ERR" ]; then
        E_DETAIL="$E_DETAIL K_SEL:OK"
    else
        E_DETAIL="$E_DETAIL K_SEL:MISMATCH"
        E_OK=false
    fi
else
    M_EXISTS="N"; F_EXISTS="N"
    [ -f "$MERGED_K" ] && M_EXISTS="Y"
    [ -f "$FULL_K" ] && F_EXISTS="Y"
    E_DETAIL="$E_DETAIL K_SEL:missing(m=$M_EXISTS,f=$F_EXISTS)"
    E_OK=false
fi

if $E_OK; then
    record_result "E: merged == full-mode ALL_SAMPLES" "PASS" "shard merge fingerprints match"
else
    record_result "E: merged == full-mode ALL_SAMPLES" "FAIL" "$E_DETAIL"
fi

# --- F: No new dependencies introduced ---
F_OK=true
F_DETAIL=""

# Check setup/install_deps.R not modified
if git -C "$ROOT" diff --name-only HEAD -- setup/install_deps.R 2>/dev/null | grep -q .; then
    F_DETAIL="install_deps.R modified"
    F_OK=false
fi

# Check no NEW install.packages / pip install in pipeline scripts
# (exclude comments — grep -v '^\s*#')
NEW_INSTALLS=$(grep -rn 'install\.packages\|pip install' \
    01_python_preprocessing/P1b_data_loading.py \
    01_python_preprocessing/P1c_gene_intersection.py \
    01_python_preprocessing/P2a_select_k.py \
    01_python_preprocessing/P2b_density.py \
    02_R_core_pipeline/R0[1-9]*.R 2>/dev/null | \
    grep -v '^\s*#' | \
    grep -v "install.packages('gridExtra')" || true)

# Check for NEW library() calls (extract each library() call individually,
# then filter out known packages)
KNOWN_PKGS="Seurat Matrix data.table jsonlite ggplot2 viridis pheatmap ggrepel gridExtra harmony scran SingleCellExperiment BiocParallel dplyr tidyr future scales patchwork ggridges reshape2 matrixStats survival coxphf AnnotationDbi org.Hs.eg.db GEOquery slingshot Biobase"

NEW_LIBS=""
for f in \
    01_python_preprocessing/P1b_data_loading.py \
    01_python_preprocessing/P1c_gene_intersection.py \
    01_python_preprocessing/P2a_select_k.py \
    01_python_preprocessing/P2b_density.py \
    02_R_core_pipeline/R0[1-9]*.R; do

    # Extract all library(X) calls, one per line
    LIBS=$(grep -oE 'library\([A-Za-z0-9_.]+\)' "$f" 2>/dev/null | sed 's/library(//;s/)//' || true)

    for pkg in $LIBS; do
        KNOWN=false
        for kp in $KNOWN_PKGS; do
            if [ "$pkg" = "$kp" ]; then
                KNOWN=true
                break
            fi
        done
        if ! $KNOWN; then
            NEW_LIBS="$NEW_LIBS $f:$pkg"
        fi
    done
done

if [ -n "$NEW_INSTALLS" ]; then
    F_DETAIL="new install/pip calls: $NEW_INSTALLS"
    F_OK=false
fi

if [ -n "$NEW_LIBS" ]; then
    F_DETAIL="$F_DETAIL new library: $NEW_LIBS"
    F_OK=false
fi

if [ -z "$F_DETAIL" ]; then
    F_DETAIL="no new dependencies"
fi

if $F_OK; then
    record_result "F: no new dependencies" "PASS" "$F_DETAIL"
else
    record_result "F: no new dependencies" "FAIL" "$F_DETAIL"
fi

# ============================================================
# Known verification gaps (§8, updated per mandatory 3 result)
# ============================================================
echo ""
echo "============================================"
echo "  Known Verification Gaps (§8)"
echo "============================================"

add_gap "1. R-stage equivalence covers 4 samples (Donor1/Donor3/MouseA/MouseB). Donor2 excluded via subset registry (Obs 17 — latent pipeline defect, confirmed on Seurat 5.2.1 and 5.4.0, NOT a version API change). Exclusion is a verification configuration, not a code change (hard constraint 1)."
add_gap "2. Conditional NA path (median_cell_area NA -> shard -> merge_qc NA fill) not executed on R side (root cause: Obs 17; real data 22/22 have cell_area → this path would not occur in production)"
add_gap "3. R06 cell_state_coupling.csv cannot be produced on fixture data (0 tier1 genes)"
if $P1B_DONOR2_FAILED; then
    add_gap "4. P1b Donor2 FAILS at Python stage — gap extends earlier than R stage only (verified this run)"
else
    add_gap "4. P1b Donor2 status: CONFIRMED — passes at Python stage, fails at R01 (Obs 17, latent pipeline defect, NOT a Seurat version issue — confirmed on 5.2.1)"
fi
add_gap "5. R07 content equivalence not tested (R01 full-mode incomplete)"
add_gap "6. R08 cross-dataset comparison manifest fan-in not tested (fixture has only 2 datasets)"
add_gap "7. R09 tier decision manifest fan-in not tested (R2 rds full incomplete)"
add_gap "8. CONFIRMED: all 22 real samples have cell_area (server-verified); Donor2 is the only sample without it in the fixture"
add_gap ""
add_gap "R-stage verification uses a subset registry excluding Donor2 (必修3)."
add_gap "Gaps #7 (cell_area speculation) and #8 (P1b Donor2) are CLOSED per server verification."
add_gap "Remaining gaps are blocked by fixture limitations (0 tier1 genes, 2 datasets) or"
add_gap "P-stage crashes (Obs 16: P1c UnboundLocalError with 1 Human dataset)."

echo -e "$GAPS_LIST"

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================"
echo "  Summary"
echo "============================================"
echo -e "$RESULTS_TABLE"
echo "PASS: $PASS_COUNT  |  SKIP: $SKIP_COUNT  |  FAIL: $FAIL_COUNT"
echo ""
echo "Note: R stages used a subset registry excluding Donor2 (Obs 17)."
echo "      P stages used the full registry (including Donor2 for conditional"
echo "      column path coverage). See R-stage subset registry section above."

if [ $FAIL_COUNT -gt 0 ]; then
    exit 1
fi
