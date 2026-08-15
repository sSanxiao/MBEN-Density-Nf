// ============================================================
// modules/r03.nf — R03 density-gene Spearman 相关（per-sample）
//
// 输入：R02 的 <Subname>_seurat_R2.rds。
// 输出：density_gene_correlations.csv + r3_summary.csv。
// ============================================================

process R03 {
    tag "$sample"
    container params.r_image

    publishDir(
        path: { "${params.outdir}/R3_Results/${sample}" },
        mode: 'copy'
    )

    input:
    tuple val(sample), path(rds2)
    path registry
    path script
    path args_r
    path probe_r

    output:
    tuple val(sample), path("density_gene_correlations.csv"), path("r3_summary.csv")

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
