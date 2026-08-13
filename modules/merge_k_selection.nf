// ============================================================
// modules/merge_k_selection.nf — MERGE_K_SELECTION 合并 k_selection.json（fan-in）
//
// 把 P2A 的 per-dataset k_selection.json 合并为 ALL_DATASETS_K_SELECTION.csv。
// 分片同样用 stageAs: "shard_*/*" 分目录（basename 保持 k_selection.json）。
// ============================================================

process MERGE_K_SELECTION {
    container 'thesis-python:3.7.10'

    publishDir(
        path: { "${params.outdir}" },
        mode: 'copy'
    )

    input:
    path shards, stageAs: 'shard_*/*'
    path registry
    path script
    path qc_schema

    output:
    path("ALL_DATASETS_K_SELECTION.csv")

    script:
    """
    mkdir -p tools
    cp "${script}" tools/merge_k_selection.py
    cp "${qc_schema}" tools/qc_schema.py

    ${params.python} tools/merge_k_selection.py \\
        --registry "${registry}" \\
        --shards shard_* \\
        --out ALL_DATASETS_K_SELECTION.csv
    """
}
