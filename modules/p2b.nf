// ============================================================
// modules/p2b.nf — P2B per-sample 密度计算（fan-out）
//
// 并行度：per-sample（每个样本一个 task）。
// SPEC §1：P2B 是「fan-out」——每个样本独立算 5 种密度估计，
// 输入该样本的 cell_metadata.csv + 所属 dataset 的 k_selection.json。
// ============================================================

process P2B {
    tag "$sample"
    container params.python_image

    publishDir(
        path: { "${params.outdir}/P2_Results/${sample}" },
        mode: 'copy'
    )

    input:
    tuple val(dataset), val(sample), path(meta), path(kfile)
    path registry
    path script

    output:
    tuple val(sample),
          path("cell_density.csv"),
          path("density_qc.csv"),
          path("density_diagnostics.png")

    script:
    """
    ${params.python} ${script} \\
        --sample "${sample}" \\
        --kfile "${kfile}" \\
        --metadata "${meta}" \\
        --registry "${registry}" \\
        --outdir .
    """
}
