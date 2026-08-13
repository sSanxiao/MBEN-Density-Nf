// ============================================================
// modules/p2a.nf — P2A per-dataset K 值选择（fan-in）
//
// 并行度：per-dataset（channel 按 dataset 分组后，每个 dataset 一个 task）。
// SPEC §1：P2A 是「fan-in」——把该 dataset 全部样本的 cell_metadata.csv
// 收拢进一个 task，输出 k_selection.json。
//
// SPEC §3：--metadata-list 用两列带键格式 <Dataset/Subname><TAB><path>，
// 由本 process 在 work dir 内生成，按 key 配对，不按位置。
// ============================================================

process P2A {
    tag "$dataset"
    container 'thesis-python:3.7.10'

    publishDir(
        path: { "${params.outdir}/P2_Results/${dataset}" },
        mode: 'copy'
    )

    input:
    tuple val(dataset), val(samples), path(metas)
    path registry
    path script

    output:
    tuple val(dataset),
          path("k_selection.json"),
          path("k_decision_table.csv"),
          path("all_samples_knn_cv.csv"),
          path("k_optimization_diagnostic.png")

    script:
    // 生成两列带键 manifest：<Dataset/Subname><TAB><staged meta path>
    // 用 printf '%b' 解释 \t \n，避免 heredoc 缩进破坏内容/终结符。
    def manifest = [samples, metas].transpose().collect { s, m -> "${s}\\t${m}" }.join('\\n')
    """
    printf '%b' '${manifest}' > metadata_list.txt
    ${params.python} ${script} \\
        --dataset "${dataset}" \\
        --metadata-list metadata_list.txt \\
        --registry "${registry}" \\
        --outdir .
    """
}
