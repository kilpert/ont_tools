#_____ RUN READ QC  __________________________________________________________#

rule run_pycoqc:
    input:
        "run_data/{run}/copy_finished"
    output:
        html = "qc/pycoqc/per_run/{run}.pycoQC.html",
        json = "qc/pycoqc/per_run/{run}.pycoQC.json"
    log:
        "logs/{run}_pycoqc.log"
    conda:
        "../env/pycoqc.yml"
    threads:
        1
    shell:
        """
        file=$(find run_data/{wildcards.run} -name 'sequencing_summary*')
        pycoQC \
            --summary_file $file\
            --html_outfile {output.html} \
            --json_outfile {output.json} \
            >{log} 2>&1
        """

rule run_multiqc:
    input:
        expand("qc/pycoqc/per_run/{run}.pycoQC.html", run = ID_runs)
    output:
        "qc/pycoqc/per_run/run_multiqc_report.html"
    log:
        "logs/run_multiqc.log"
    threads:
       1
    params:
        multiqc = config['apps']['multiqc']
    shell:
        """
        {params.multiqc} \
            --force \
            --config config/multiqc.yml \
            --outdir qc/per_run \
            --filename run_multiqc_report \
            qc/per_run/ \
            >{log} 2>> {log}
        """

#_____ SAMPLE READ QC  _________________________________________________________#

rule sample_pycoqc:
    input:
        unpack(get_summary_files),
        check_copy_finished
    output:
        html = "qc/pycoqc/{sample,[A-Za-z0-9]+}.pycoQC.html",
        json = "qc/pycoqc/{sample,[A-Za-z0-9]+}.pycoQC.json"
    conda:
        "../env/pycoqc.yml"
    log:
        "logs/{sample}_pycoqc.log"
    threads:
        1
    shell:
        """
        pycoQC \
            --summary_file {input.summary_files} \
            --html_outfile {output.html} \
            --json_outfile {output.json} \
            >{log} 2>&1
        """

#____ GENOME MAPPING QC __________________________________________________________#

rule qualimap:
    input:
        "Sample_{sample}/{sample}.bam"
    output:
        directory('qc/qualimap/{sample}_genome')
    log:
        "logs/{sample}_qualimap.log"
    threads:
        8
    params:
        qualimap = config['apps']['qualimap']
    shell:
        """
        {params.qualimap} bamqc \
            -bam {input} \
            --paint-chromosome-limits \
            -nt {threads} \
            -outdir {output} \
            --java-mem-size=12G \
            >{log} 2>&1
        """

#_____ cDNA SPLICED MAPPING QC _________________________________________________#

rule rna_qualimap:
    input:
        "Sample_{sample}/{sample}.spliced.bam"
    output:
        "qc/qualimap/{sample}_rna/rnaseq_qc_results.txt"
    log:
        "logs/{sample}_qualimap_rna.log"
    threads:
        2
    params:
        gtf = config['ref']['annotation'],
        qualimap = config['apps']['qualimap']
    shell:
        """
        {params.qualimap} rnaseq \
            -bam {input} \
            -gtf {params.gtf} \
            -outdir qc/qualimap/{wildcards.sample}_rna \
            --java-mem-size=12G \
            >{log} 2>&1
        """

#____ ASSEMBLY QC _____________________________________________________________#

rule quast:
    input:
        files = expand("Sample_{s}/{s}.asm.{asm}.fasta",
            s=ID_samples,
            asm=config['assembly']['methods'])
    output:
        "qc/quast_results/report.tsv"
    conda:
        "../env/quast.yml"
    log:
        "logs/quast.log"
    params:
        ref=config['ref']['genome']
    threads:
        8
    shell:
        """
        quast \
            --threads {threads} \
            --no-sv             \
            --reference {params.ref} \
            --output-dir qc/quast_results \
            {input} \
            >{log} 2>&1
        """

#____ VARIANT QC _____________________________________________________________#
rule bcftools_stats:
    input:
        vcf = rules.combine_vcf.output
    output:
        "qc/variants/{sample}.stats"
    log:
        "logs/{sample}_bcftools.log"
    conda:
        "../env/bcftools.yml"
    shell:
        """
        bcftools stats {input} > {output} 2> {log}
        """

#_____ TRANSCRIPTOME ANNOTATION QC ____________________________________________#

rule sqanti:
    input:
        gtf = "Sample_{sample}/{sample}.stringtie.gtf",
        anno_ref = config['ref']['annotation'],
        genome = config['ref']['genome']
    output:
        "qc/sqanti/{sample}/{sample}_classification.txt"
    log:
        "logs/{sample}_sqanti.log"
    conda:
        "../env/sqanti.yml"
    params:
        sqanti = config['apps']['sqanti'],
        cdna_cupcake = config['apps']['cdna_cupcake']
    shell:
        """
        set +u;
        export PYTHONPATH=$PYTHONPATH:{params.cdna_cupcake}sequence/
        export PYTHONPATH=$PYTHONPATH:{params.cdna_cupcake}
        {params.sqanti} \
            -d qc/sqanti/{wildcards.sample} \
            -o {wildcards.sample} \
            --skipORF \
            --gtf {input.gtf} \
            {input.anno_ref} {input.genome} \
            >{log} 2>&1
        """

#_______ GFFCOMPARE ___________________________________________________________#

rule gffcompare:
    input:
        gtf = "Sample_{sample}/{sample}.{tool}.gtf",
        ref = config['ref']['annotation'],
        genome = config['ref']['genome']
    output:
        "qc/gffcompare/{sample}_{tool}/{sample}_{tool}.stats"
    log:
        "logs/{sample}_{tool}.log"
    conda:
        "../env/gffcompare.yml"
    params:
        opts = config['gffcompare']['options']
    shell:
        """
        gffcompare \
            {params.opts} \
            -r {input.ref} \
            -o qc/gffcompare/{wildcards.sample}_{wildcards.tool}/{wildcards.sample}_{wildcards.tool} \
            {input.gtf} \
            > {log} 2>&1
        mv Sample_{wildcards.sample}/{wildcards.sample}_{wildcards.tool}.{wildcards.sample}.{wildcards.tool}.gtf.refmap qc/gffcompare/{wildcards.sample}_{wildcards.tool}/{wildcards.sample}.{wildcards.tool}.gtf.refmap
        mv Sample_{wildcards.sample}/{wildcards.sample}_{wildcards.tool}.{wildcards.sample}.{wildcards.tool}.gtf.tmap qc/gffcompare/{wildcards.sample}_{wildcards.tool}/{wildcards.sample}.{wildcards.tool}.gtf.tmap
        """

#_____ MULTI QC  _____________________________________________________________#

qc_out = {
    'mapping' : expand("qc/qualimap/{s}_genome", s = ID_samples),
    'assembly' : ["qc/quast_results/report.tsv"],
    'variant_calling':[expand("qc/variants/{s}.stats", s = ID_samples)],
    'cDNA_stringtie' : expand("qc/gffcompare/{s}_stringtie/{s}_stringtie.stats", s = ID_samples) +
         expand("qc/pychopper/{s}_stats.txt", s = ID_samples), 
    'cDNA_flair': expand("qc/gffcompare/{s}_flair/{s}_flair.stats", s = ID_samples),
    'cDNA_expression' : 
        expand("qc/qualimap/{s}_rna/rnaseq_qc_results.txt", s = ID_samples) + 
        expand("qc/pychopper/{s}_stats.txt", s = ID_samples) +
        expand("Sample_{s}/{s}.summary.tsv", s = ID_samples),
    'cDNA_pinfish' : [],
    'qc' : ["qc/pycoqc/per_run/run_multiqc_report.html"],
}

# Additional output options
if config['vc']['create_benchmark']:
    qc_out['variant_calling'] +=  expand("qc/happy/{s}.summary.csv", s=ID_samples)

qc_out_selected = [qc_out[step] for step in config['steps']]

rule multiqc:
    input:
        expand("qc/pycoqc/{sample}.pycoQC.json", sample = ID_samples),
        [y for x in qc_out_selected for y in x]
    output:
        "qc/multiqc_report.html"
    log:
        "logs/multiqc.log"
    threads:
        1
    params:
        multiqc = config['apps']['multiqc']
    shell:
        """
        {params.multiqc} \
            --force \
            --config config/multiqc.yml \
            --outdir qc\
            --ignore-symlinks \
            {input} > {log} 2>&1
        """