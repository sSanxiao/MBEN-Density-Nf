#!/usr/bin/env nextflow
// ============================================================
// main.nf — P3 Nextflow 工作流（N4：P1B → P2A → P2B → R01–R04 → MERGE）
//
// SPEC §1 DAG：
//   P1B (fan-out) → P2A (fan-in) → P2B (fan-out) → R01→R02→R03→R04 (per-sample)
//   → MERGE_QC / MERGE_K_SELECTION (fan-in)
// SPEC §0：每个 process 只处理单个样本/单个 dataset，绝不内部循环全部。
// ============================================================

include { P1B } from './modules/p1b'
include { P2A } from './modules/p2a'
include { P2B } from './modules/p2b'
include { R01 } from './modules/r01'
include { R02 } from './modules/r02'
include { R03 } from './modules/r03'
include { R04 } from './modules/r04'
include { MERGE_QC } from './modules/merge_qc'
include { MERGE_K_SELECTION } from './modules/merge_k_selection'

// 可复用的子集 registry 生成：过滤 + 打印排除原因 + 写临时文件。
// test_exclude / r_stage_exclude 都用它，避免写两套。
def write_subset(reg_map, exclude_list, label, reason, out_name, out_dir) {
    def excluded = reg_map.keySet().findAll { k -> k in exclude_list }
    if (excluded) {
        println "  [${label}] 排除 ${excluded.size()} 个样本: ${excluded} — ${reason}"
    }
    def filtered = reg_map.findAll { k, v -> !(k in exclude_list) }
    new File(out_dir).mkdirs()
    def f = file("${out_dir}/${out_name}")
    // 只在内容变化（或文件不存在）时才写，避免每次运行重写导致 mtime 变化、
    // 进而让 -resume 的任务哈希不稳定（会话实测：重写会让 P1B 等每次重算）。
    def content = new groovy.json.JsonBuilder(filtered).toPrettyString()
    if (!f.exists() || f.text != content) {
        f.text = content
    }
    return f
}

workflow {
    // ---- 0. 子集 registry 生成（test_exclude / r_stage_exclude 复用同一机制）----
    def full_reg = new groovy.json.JsonSlurper().parseText(file(params.registry).text)

    def base_registry = write_subset(full_reg, params.test_exclude,
        'test_exclude', 'test 冒烟子集', 'registry.base.json',
        "${projectDir}/.nextflow/registry")
    def r_registry = write_subset(
        new groovy.json.JsonSlurper().parseText(base_registry.text),
        params.r_stage_exclude, 'r_stage_exclude',
        'Obs 17: Donor2 R 阶段崩溃', 'registry.r.json',
        "${projectDir}/.nextflow/registry")

    // ---- 1. sample channel（来自 base registry）----
    // 每个样本额外携带其原始 h5 / parquet 的 host 路径作为 path 输入，
    // 使 -resume 能按样本隔离地检测输入数据变化（SPEC §1：P1B 输入 =
    // registry + 原始 h5/parquet）。脚本仍经 registry 的容器路径读取（docker
    // 挂载），path 输入负责让 Nextflow 哈希原始数据内容。
    Channel
        .fromPath(base_registry)
        .map { p -> new groovy.json.JsonSlurper().parseText(p.text) }
        .flatMap { reg ->
            reg.keySet().collect { sample ->
                def info = reg[sample]
                def rel = info.path.replace(params.fixture_container, '')
                def h5 = "${params.fixture_host}${rel}/cell_feature_matrix.h5"
                def parquet = "${params.fixture_host}${rel}/cells.parquet"
                tuple(sample, h5, parquet)
            }
        }
        .set { sample_ch }

    def p1b_script = file("${projectDir}/01_python_preprocessing/P1b_data_loading.py")
    def p2a_script = file("${projectDir}/01_python_preprocessing/P2a_select_k.py")
    def p2b_script = file("${projectDir}/01_python_preprocessing/P2b_density.py")
    def r01_script = file("${projectDir}/02_R_core_pipeline/R01_build_seurat.R")
    def r02_script = file("${projectDir}/02_R_core_pipeline/R02_sctransform.R")
    def r03_script = file("${projectDir}/02_R_core_pipeline/R03_density_gene_correlation.R")
    def r04_script = file("${projectDir}/02_R_core_pipeline/R04_filter_density_genes.R")
    def args_r = file("${projectDir}/config/args.R")
    def probe_r = file("${projectDir}/tools/r_env_probe.R")
    def merge_qc_script = file("${projectDir}/tools/merge_qc.py")
    def merge_k_script = file("${projectDir}/tools/merge_k_selection.py")
    def qc_schema_py = file("${projectDir}/tools/qc_schema.py")

    // ---- 2. P1B：per-sample（fan-out）----
    P1B(sample_ch, base_registry, p1b_script)

    // ---- 3. P2A：per-dataset（fan-in）----
    P1B.out
        .map { sample, h5, meta, qc -> tuple(sample.split('/')[0], sample, meta) }
        .groupTuple(by: 0)
        .set { p2a_input }
    P2A(p2a_input, base_registry, p2a_script)

    // ---- 4. P2B：per-sample（fan-out，many-to-one join）----
    P1B.out
        .map { sample, h5, meta, qc -> tuple(sample.split('/')[0], sample, meta) }
        .combine(P2A.out.map { dataset, kfile, table, cv, png -> tuple(dataset, kfile) })
        .filter { ds, sample, meta, ds2, kfile -> ds == ds2 }
        .map { ds, sample, meta, ds2, kfile -> tuple(ds, sample, meta, kfile) }
        .set { p2b_input }
    P2B(p2b_input, base_registry, p2b_script)

    // ---- 5. R01：per-sample（R 阶段排除 r_stage_exclude）----
    P1B.out
        .map { sample, h5, meta, qc -> tuple(sample, h5, meta) }
        .combine(P2B.out.map { sample, density, dqc, png -> tuple(sample, density) })
        .filter { s1, h5, meta, s2, density -> s1 == s2 }
        .map { s1, h5, meta, s2, density -> tuple(s1, h5, meta, density) }
        .filter { sample, h5, meta, density -> !(sample in params.r_stage_exclude) }
        .set { r01_input }
    R01(r01_input, r_registry, r01_script, args_r, probe_r)

    // ---- 6. R02：per-sample（链式）----
    R01.out
        .map { sample, rds, qc -> tuple(sample, rds) }
        .set { r02_input }
    R02(r02_input, r_registry, r02_script, args_r, probe_r)

    // ---- 7. R03：per-sample（链式）----
    R02.out
        .map { sample, rds2, qc -> tuple(sample, rds2) }
        .set { r03_input }
    R03(r03_input, r_registry, r03_script, args_r, probe_r)

    // ---- 8. R04：per-sample（链式）----
    R03.out
        .map { sample, corr, summary -> tuple(sample, corr) }
        .set { r04_input }
    R04(r04_input, r_registry, r04_script, args_r, probe_r)

    // ---- 9. MERGE_QC：per-table fan-in ----
    // 每个 stage 的 QC 分片打上 table 标签，groupTuple 按表收拢；
    // stageAs 分目录保持 basename。P 阶段表用完整 registry，R 阶段表用 R 子集 registry。
    Channel.empty()
        .mix(P1B.out.map { sample, h5, meta, qc -> tuple('ALL_SAMPLES_P1_QC.csv', qc) })
        .mix(P2B.out.map { sample, density, dqc, png -> tuple('ALL_SAMPLES_P2_QC.csv', dqc) })
        .mix(R01.out.map { sample, rds, qc -> tuple('ALL_SAMPLES_R1_QC.csv', qc) })
        .mix(R02.out.map { sample, rds2, qc -> tuple('ALL_SAMPLES_R2_QC.csv', qc) })
        .mix(R03.out.map { sample, corr, summary -> tuple('ALL_SAMPLES_R3_SUMMARY.csv', summary) })
        .mix(R04.out.map { sample, fdg, summary -> tuple('ALL_SAMPLES_R4_SUMMARY.csv', summary) })
        .groupTuple(by: 0)
        .map { table, shards ->
            def reg = table.startsWith('ALL_SAMPLES_R') ? r_registry : base_registry
            tuple(table, shards, reg)
        }
        .set { merge_qc_input }
    MERGE_QC(merge_qc_input, merge_qc_script, qc_schema_py)

    // ---- 10. MERGE_K_SELECTION：per-dataset fan-in ----
    P2A.out.map { dataset, kfile, table, cv, png -> kfile }.collect().set { k_shards }
    MERGE_K_SELECTION(k_shards, base_registry, merge_k_script, qc_schema_py)
}
