// ============================================================
// modules/p1b.nf — P1B per-sample 数据加载
//
// 并行度：per-sample（channel 每个元素一个 task）。
// SPEC §0：process 只处理单个样本，绝不内部循环全部样本。
// 脚本以 path 输入 stage 进 work dir（容器内 $projectDir 不自动挂载）。
//
// 输出文件中只有 cell_metadata.csv 被重命名为 <key>.cell_metadata.csv（key=样本名，
// / 换成 _）——因为 P2A 用显式 manifest（路径带 key）识别输入，需要唯一名。
// filtered_matrix.h5 / p1_qc.csv 保持原名：R01 按 basename 读、MERGE 按 basename 合并。
// publishDir 用 saveAs 把 cell_metadata.csv 的发布名还原为原名。
// ============================================================

process P1B {
    tag "$sample"
    container 'thesis-python:3.7.10'

    publishDir(
        path: { "${params.outdir}/P1_Results/${sample}" },
        mode: 'copy',
        saveAs: { f -> f.endsWith('.cell_metadata.csv') ? f.substring(f.indexOf('.') + 1) : f }
    )

    input:
    tuple val(sample), path(h5), path(parquet)
    path registry
    path script

    output:
    tuple val(sample),
          path("filtered_matrix.h5"),
          path("*.cell_metadata.csv"),
          path("p1_qc.csv")

    script:
    def key = sample.replaceAll('/', '_')
    """
    ${params.python} ${script} \\
        --sample "${sample}" \\
        --registry "${registry}" \\
        --outdir .

    # 仅重命名 cell_metadata.csv（P2A fan-in 用显式 manifest 按 key 识别，需唯一名）
    mv cell_metadata.csv "${key}.cell_metadata.csv"
    """
}
