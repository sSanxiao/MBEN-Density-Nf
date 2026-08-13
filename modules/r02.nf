// ============================================================
// modules/r02.nf — R02 SCTransform + PCA + UMAP + 聚类（per-sample）
//
// 输入：R01 的 <Subname>_seurat.rds。
// 输出：<Subname>_seurat_R2.rds + r2_qc.csv。
// ============================================================

process R02 {
    tag "$sample"
    container 'thesis-r:4.2.0'

    publishDir(
        path: { "${params.outdir}/R2_Results/${sample}" },
        mode: 'copy'
    )

    input:
    tuple val(sample), path(rds)
    path registry
    path script
    path args_r
    path probe_r

    output:
    tuple val(sample), path("*_seurat_R2.rds"), path("r2_qc.csv")

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
