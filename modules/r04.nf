// ============================================================
// modules/r04.nf — R04 density gene 筛选与分级（per-sample）
//
// 输入：R03 的 density_gene_correlations.csv。
// 输出：filtered_density_genes.csv + r4_summary.csv（诊断 PNG 留在 work dir）。
// ============================================================

process R04 {
    tag "$sample"
    container 'thesis-r:4.2.0'

    publishDir(
        path: { "${params.outdir}/R4_Results/${sample}" },
        mode: 'copy'
    )

    input:
    tuple val(sample), path(corr)
    path registry
    path script
    path args_r
    path probe_r

    output:
    tuple val(sample), path("filtered_density_genes.csv"), path("r4_summary.csv")

    script:
    """
    ${params.rscript} "${probe_r}"

    mkdir -p 02_R_core_pipeline config
    cp "${script}" 02_R_core_pipeline/
    cp "${args_r}" config/args.R

    ${params.rscript} 02_R_core_pipeline/${script} \\
        --sample "${sample}" \\
        --registry "${registry}" \\
        --indir . \\
        --outdir .
    """
}
