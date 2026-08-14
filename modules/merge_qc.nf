// ============================================================
// modules/merge_qc.nf — MERGE_QC 合并 QC/summary 分片（fan-in）
//
// 每个 task 合并一张表的 per-sample 分片（p1_qc.csv / density_qc.csv /
// r1_qc.csv / r2_qc.csv / r3_summary.csv / r4_summary.csv）为
// ALL_SAMPLES_*.csv。
//
// 分片通过 stageAs: "shard_*/*" 分目录 stage，basename 保持原样——
// merge_qc.py 的 find_shards() 按精确 basename（qc_schema.SHARD_TO_TABLE）
// 发现分片，不能给分片加 <key>. 前缀。
// ============================================================

process MERGE_QC {
    tag "$table"
    container params.python_image

    publishDir(
        path: { "${params.outdir}" },
        mode: 'copy'
    )

    input:
    tuple val(table), path(shards, stageAs: 'shard_*/*'), path(registry)
    path script
    path qc_schema

    output:
    path("ALL_SAMPLES_*.csv")

    script:
    """
    # merge_qc.py 需与 qc_schema.py 同目录（sys.path 相对 __file__ 定位）
    mkdir -p tools
    cp "${script}" tools/merge_qc.py
    cp "${qc_schema}" tools/qc_schema.py

    ${params.python} tools/merge_qc.py \\
        --table "${table}" \\
        --registry "${registry}" \\
        --shards shard_* \\
        --out "${table}"
    """
}
