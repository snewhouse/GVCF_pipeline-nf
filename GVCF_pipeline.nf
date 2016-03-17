#! /usr/bin/env nextflow

// usage : ./GVCF_pipeline.nf --bam_folder BAM/ --cpu 8 --mem 32 --hg19_ref hg19.fasta --RG "PL:ILLUMINA"

if (params.help) {
    log.info ''
    log.info '--------------------------------------------------'
    log.info 'NEXTFLOW BAM COMPLETE REALIGNMENT'
    log.info '--------------------------------------------------'
    log.info ''
    log.info 'Usage: '
    log.info 'nextflow run bam_realignment.nf --bam_folder BAM/ --cpu 8 --mem 32 --fasta_ref hg19.fasta'
    log.info ''
    log.info 'Mandatory arguments:'
    log.info '    --bam_folder          FOLDER                  Folder containing BAM files to be called.'
    log.info '    --hg19_ref            FILE                    Reference fasta file (with index) (excepted if in your config).'
    log.info '    --gold_std_indels     FILE                    Gold standard GATK for indels.'
    log.info '    --phase1_indels       FILE                    Phase 1 GATK for indels.'
    log.info '    --GenomeAnalysisTK    FILE                    GenomeAnalysisTK.jar file.'
    log.info 'Optional arguments:'
    log.info '    --cpu                 INTEGER                 Number of cpu used by bwa mem and sambamba (default: 8).'
    log.info '    --mem                 INTEGER                 Size of memory used by sambamba (in GB) (default: 32).'
    log.info '    --RG                  STRING                  Samtools read group specification with "\t" between fields.'
    log.info '                                                  e.g. --RG "PL:ILLUMINA\tDS:custom_read_group".'
    log.info '                                                  Default: "ID:bam_file_name\tSM:bam_file_name".'
    log.info '    --out_folder          STRING                  Output folder (default: results_realignment).'
    log.info '    --intervals_gvcf      FILE                    Bed file provided to GATK HaplotypeCaller.'
    log.info ''
    exit 1
}

params.RG = ""
params.cpu = 8
params.mem = 32
params.out_folder="results_GVCF_pipeline"
intervals_gvcf = params.intervals_gvcf ? '-L '+params.intervals_gvcf : ""

bams = Channel.fromPath( params.bam_folder+'/*.bam' )
              .ifEmpty { error "Cannot find any bam file in: ${params.bam_folder}" }

process bam_realignment {

    memory = params.mem+'GB'
  
    tag { bam_tag }

    input:
    file bam from bams

    output:
    set val(bam_tag), file("${bam_tag}_realigned.bam"), file("${bam_tag}_realigned.bam.bai") into outputs_bam_realignment

    shell:
    bam_tag = bam.baseName
    '''
    samtools collate -uOn 128 !{bam_tag}.bam tmp_!{bam_tag} | samtools fastq - | bwa mem -M -t!{params.cpu} -R "@RG\tID:!{bam_tag}\tSM:!{bam_tag}\t!{params.RG}" -p !{params.hg19_ref} - | samblaster --addMateTags | sambamba view -S -f bam -l 0 /dev/stdin | sambamba sort -t !{params.cpu} -m !{params.mem}G --tmpdir=!{bam_tag}_tmp -o !{bam_tag}_realigned.bam /dev/stdin
    '''
}

process indel_realignment {

    memory = params.mem+'GB'

    tag { bam_tag }

    input:
    set val(bam_tag), file("${bam_tag}_realigned.bam"), file("${bam_tag}_realigned.bam.bai")  from outputs_bam_realignment

    output:
    set val(bam_tag), file("${bam_tag}_realigned2.bam"), file("${bam_tag}_realigned2.bai")  into outputs_indel_realignment

    shell:
    '''
    java -jar !{params.GenomeAnalysisTK} -T RealignerTargetCreator -nt 6 -R !{params.hg19_ref} -I !{bam_tag}_realigned.bam -known !{params.gold_std_indels} -known !{params.phase1_indels} -o !{bam_tag}_target_intervals.list
    java -jar !{params.GenomeAnalysisTK} -T IndelRealigner -R !{params.hg19_ref} -I !{bam_tag}_realigned.bam -targetIntervals !{bam_tag}_target_intervals.list -known !{params.gold_std_indels} -known !{params.phase1_indels} -o !{bam_tag}_realigned2.bam
    '''
}

process recalibration {

    memory = params.mem+'GB'

    tag { bam_tag }

    input:
    set val(bam_tag), file("${bam_tag}_realigned2.bam"), file("${bam_tag}_realigned2.bai")  from outputs_indel_realignment

    output:
    set val(bam_tag), file("${bam_tag}_realigned_recal.bam"), file("${bam_tag}_realigned_recal.bai") into outputs_recalibration

    shell:
    '''
    java -jar !{params.GenomeAnalysisTK} -T BaseRecalibrator -nct !{params.cpu} -R !{params.hg19_ref} -I !{bam_tag}_realigned2.bam -knownSites !{params.dbsnp} -knownSites !{params.gold_std_indels} -knownSites !{params.phase1_indels} -o !{bam_tag}_recal.table
    java -jar !{params.GenomeAnalysisTK} -T BaseRecalibrator -nct !{params.cpu} -R !{params.hg19_ref} -I !{bam_tag}_realigned2.bam -knownSites !{params.dbsnp} -knownSites !{params.gold_std_indels} -knownSites !{params.phase1_indels} -BQSR !{bam_tag}_recal.table -o !{bam_tag}_post_recal.table
    java -jar !{params.GenomeAnalysisTK} -T AnalyzeCovariates -R !{params.hg19_ref} -before !{bam_tag}_recal.table -after !{bam_tag}_post_recal.table -plots !{bam_tag}_recalibration_plots.pdf
    java -jar !{params.GenomeAnalysisTK} -T PrintReads -nct !{params.cpu} -R !{params.hg19_ref} -I !{bam_tag}_realigned2.bam -BQSR !{bam_tag}_recal.table -o !{bam_tag}_realigned_recal.bam
    '''
}

process GVCF {

    memory = params.mem+'GB'

    publishDir params.out_folder, mode: 'move'

    tag { bam_tag }

    input:
    set val(bam_tag), file("${bam_tag}_realigned_recal.bam"), file("${bam_tag}_realigned_recal.bai") from outputs_recalibration
    
    output:
    file("${bam_tag}_raw_calls.g.vcf") into output_gvcf
    file("${bam_tag}_raw_calls.g.vcf.idx") into output_gvcf_idx

    shell:
    '''
    java -jar !{params.GenomeAnalysisTK} -T HaplotypeCaller -nct !{params.cpu} -R !{params.hg19_ref} -I !{bam_tag}_realigned_recal.bam --emitRefConfidence GVCF !{intervals_gvcf} -o !{bam_tag}_raw_calls.g.vcf
    '''
}










