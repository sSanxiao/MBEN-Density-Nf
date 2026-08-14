// ============================================================
// modules/r01.nf — R01 构建 Seurat 对象（per-sample）
//
// 输入：P1B 的 filtered_matrix.h5 + cell_metadata.csv，P2B 的 cell_density.csv。
// 输出：<Subname>_seurat.rds + r1_qc.csv。
// SPEC §3：Donor2 在 R 阶段排除（Obs 17），排除在 main.nf 用子集 registry 完成。
// ============================================================

process R01 {
    tag "$sample"
    container params.r_image

    publishDir(
        path: { "${params.outdir}/R1_Results/${sample}" },
        mode: 'copy'
    )

    input:
    tuple val(sample), path(h5), path(meta), path(density)
    path registry
    path script
    path args_r
    path probe_r

    output:
    tuple val(sample), path("*_seurat.rds"), path("r1_qc.csv")

    script:
    """
    # 打印实际使用的 R 环境（验证是 Windows R 4.5.2 而非 WSL 解释器）
    ${params.rscript} "${probe_r}"

    # 还原 repo 相对布局，让 R 脚本 dirname(.script_dir)/config/args.R 可解析
    mkdir -p 02_R_core_pipeline config inputs
    cp "${script}" 02_R_core_pipeline/
    cp "${args_r}" config/args.R

    # R01 从 --indir 扁平目录读 filtered_matrix.h5 / cell_metadata.csv / cell_density.csv
    cp "${h5}" inputs/filtered_matrix.h5
    cp "${meta}" inputs/cell_metadata.csv
    cp "${density}" inputs/cell_density.csv

    ${params.rscript} 02_R_core_pipeline/${script} \\
        --sample "${sample}" \\
        --registry "${registry}" \\
        --indir inputs \\
        --outdir .
    """
}
