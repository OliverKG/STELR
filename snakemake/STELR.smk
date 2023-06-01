import os
import subprocess
import json
from TELR_utility import get_contig_length

rule all:
    input: 
        "intermediate_files/contigs/chr2L_33030_33030/07_te2contig_filter.tsv",
        lambda wildcards: f"intermediate_files/{config['sample_name']}.vcf_filtered.tsv"
        #"{sample_name}.loci_eval.tsv"

def input_reads_if_in_bam_format(wildcards):
    #   this rule returns the bam format input if the input is given in bam format, or an empty list if not.
    #returning an empty list essentially gives snakemake permission to accept the input file in fasta 
    #format; otherwise it tries to check the next file back in the workflow, and causes a cyclic dependency
    #error if the input and output for the rule bam_input are the same.
    if ".bam" in config["reads"]: return config["reads"]
    else: return []
rule bam_input: #if input is given in bam format, convert it to fasta format.
    #todo -- check if this bam format is ACTUALLY aligned.
    input:
        input_reads_if_in_bam_format
    output:
        config["fasta_reads"]
    shell:
        "python3 STELR_alignment.py bam2fasta '{input}' '{output}'"

"""
1st stage: identify TE insertion candidate loci
"""

'''1st stage
"Read alignment (NGMLR)"
^(or minimap2)
'''
#only run if reads are supplied in fasta format
rule alignment:
    input:
        config["fasta_reads"]
    output:
        "intermediate_files/{sample_name}.sam"
    params:
        reads = config["fasta_reads"],
        reference = config["reference"],
        out = "intermediate_files",
        method = config["aligner"],#minimap2 or ngmlr
        presets = config["presets"]#ont or pacbio
    threads: config["thread"]
    shell:
        "python3 STELR_alignment.py alignment '{params.reads}' '{params.reference}' '{params.out}' '{wildcards.sample_name}' '{threads}' '{params.method}' '{params.presets}'"

def find_alignment(wildcards):
    bam_input = f"intermediate_files/input/reads-{wildcards.sample_name}.bam"
    if(os.path.isfile(bam_input)): return bam_input
    else: return f"intermediate_files/{wildcards.sample_name}.sam"
rule sort_index_bam:
    input:
        find_alignment#gives name of input file (this depends on whether the user supplied input was in bam format or it was aligned later)
    output:
        "intermediate_files/{sample_name}_sort.bam"
    threads: config["thread"]
        #samtools
    shell:
        "python3 STELR_alignment.py sort_index_bam '{input}' '{output}' '{threads}'"
    
'''1st stage
SV calling (Sniffles)
'''
rule detect_sv:
    input:
        bam = "intermediate_files/{sample_name}_sort.bam",
        reference = config["reference"]
    output:
        "intermediate_files/{sample_name}_{sv_detector}.vcf"
    params:
        out = "intermediate_files",
        sample_name = config["sample_name"],
        thread = config["thread"]
    shell:
        "python3 STELR_sv.py detect_sv '{input.bam}' '{input.reference}' '{params.out}' '{params.sample_name}' '{params.thread}'"

rule parse_vcf:
    input:
        "intermediate_files/{sample_name}_Sniffles.vcf"#replace Sniffles with config[sv_detector] later if there are options
    output:
        "intermediate_files/{sample_name}.vcf_parsed.tsv.tmp"
    params:
        '"%CHROM\\t%POS\\t%END\\t%SVLEN\\t%RE\\t%AF\\t%ID\\t%ALT\\t%RNAMES\\t%FILTER\\t[ %GT]\\t[ %DR]\\t[ %DV]\n"'
        #bcftools
    shell:
        'bcftools query -i \'SVTYPE="INS" & ALT!="<INS>"\' -f "{params}" "{input}" > "{output}"'

rule swap_vcf_coordinate:
    input:
        "intermediate_files/{sample_name}.vcf_parsed.tsv.tmp"
    output:
        "intermediate_files/{sample_name}.vcf_parsed.tsv.swap"
    shell:
        "python3 STELR_sv.py swap_coordinate '{input}' '{output}'"

rule rm_vcf_redundancy:
    input:
        "intermediate_files/{sample_name}.vcf_parsed.tsv.swap"
    output:
        "intermediate_files/{sample_name}.vcf_parsed.tsv"
    shell:
        "python3 STELR_sv.py rm_vcf_redundancy '{input}' '{output}'"

rule write_ins_seqs:
    input:
        "intermediate_files/{sample_name}.vcf_parsed.tsv"
    output:
        "intermediate_files/{sample_name_plus}.vcf_ins.fasta"
    shell:
        "python3 STELR_sv.py write_ins_seqs '{input}' '{output}'"

'''1st stage
Filter for TE insertion candidate (RepeatMasker)
'''

rule sv_repeatmask:
    input:
        ins_seqs = lambda wildcards: f"intermediate_files/{config['sample_name'].replace('+','plus')}.vcf_ins.fasta",
        library = config["library"]
    output:
        "intermediate_files/vcf_ins_repeatmask/{ins_seqs}.out.gff"
    params:
        repeatmasker_dir = "intermediate_files/vcf_ins_repeatmask",
        thread = config["thread"]
    shell:
        "python3 STELR_sv.py repeatmask '{params.repeatmasker_dir}' '{input.ins_seqs}' '{input.library}' '{params.thread}'"

rule sv_RM_sort:
    input:
        "intermediate_files/vcf_ins_repeatmask/{ins_seqs}.out.gff"
    output:
        "intermediate_files/vcf_ins_repeatmask/{ins_seqs}.out.sort.gff"
        #bedtools
    shell:
        "bedtools sort -i '{input}' > '{output}'"

rule sv_RM_merge:
    input:
        "intermediate_files/vcf_ins_repeatmask/{ins_seqs}.out.sort.gff"
    output:
        "intermediate_files/vcf_ins_repeatmask/{ins_seqs}.out.merge.bed"
        #bedtools
    shell:
        "bedtools merge -i '{input}' > '{output}'"

rule sv_TE_extract:
    input:
        parsed_vcf = "intermediate_files/{sample_name}.vcf_parsed.tsv",
        ins_seqs = lambda wildcards: f"intermediate_files/{config['sample_name'].replace('+','plus')}.vcf_ins.fasta",
        ins_rm_merge = lambda wildcards: f"intermediate_files/vcf_ins_repeatmask/{config['sample_name'].replace('+','plus')}.vcf_ins.fasta.out.merge.bed"
    output:
        ins_filtered = "intermediate_files/{sample_name}.vcf.filtered.tmp.tsv",
        loci_eval = "{sample_name}.loci_eval.tsv"
    shell:
        "python3 STELR_sv.py te_extract '{input.parsed_vcf}' '{input.ins_seqs}' '{input.ins_rm_merge}' '{output.ins_filtered}' '{output.loci_eval}'"

rule seq_merge:
    input:
        "intermediate_files/{sample_name}.vcf.filtered.tmp.tsv"
    output: 
        "intermediate_files/{sample_name}.vcf.merged.tmp.tsv"
    params:
        window = 20
        #bedtools
    shell:
        'bedtools merge -o collapse -c 2,3,4,5,6,7,8,9,10,11,12,13,14 -delim ";" -d "{params.window}" -i "{input}" > "{output}"'

checkpoint merge_parsed_vcf:##### can we thread back to here? (probably not easily)
    input:
        "intermediate_files/{sample_name}.vcf.merged.tmp.tsv"
    output:
        "intermediate_files/{sample_name}.vcf_filtered.tsv"
    shell:
        "python3 STELR_sv.py merge_vcf '{input}' '{output}'"

"""
2nd stage: assembly and polish local TE contig
"""

'''2nd stage
Local contig assembly and polishing (wtdbg2/flye + minimap2)
'''

rule initialize_contig_dir:
    input:
        lambda wildcards: f"intermediate_files/{config['sample_name']}.vcf_filtered.tsv"
    output:
        "intermediate_files/contigs/{contig}/00_vcf_parsed.tsv"
    shell:
        "python3 STELR_assembly.py make_contig_dir '{input}' '{wildcards.contig}' '{output}'"

rule get_read_ids: # get a list of all the read IDs from the parsed vcf file
    input:
        "intermediate_files/contigs/{contig}/00_vcf_parsed.tsv"
    output:
        "intermediate_files/contigs/{contig}/00_reads.id"
    shell:
        "python3 STELR_assembly.py write_read_IDs '{input}' '{output}'"

rule unique_IDlist: # get a list of unique IDs from the readlist
    input:
        "intermediate_files/contigs/{contig}/00_{readlist}.id"
    output:
        "intermediate_files/contigs/{contig}/00_{readlist}.id.unique
    shell:
        "cat '{input}' | sort | uniq > '{output}'"

rule filter_readlist: # use seqtk to get the fasta reads from the input reads file
    input:
        "intermediate_files/contigs/{contig}/00_{readlist}.id.unique
    output:
        "intermediate_files/contigs/{contig}/00_{readlist}.fa
    shell:
        "seqtk subseq '{config[fasta_reads]}' '{input}' | seqtk seq -a > '{output}'"

rule run_assembly:
    input:
        "intermediate_files/contigs/{contig}/00_reads.fa"
    output:
        "intermediate_files/contigs/{contig}/01_initial_assembly.fa"
    threads: 1
    shell:
        """
        python3 STELR_assembly.py run_{config[assembler]}_assembly '{input}' '{wildcards.contig}' '{threads}' '{config[presets]}' '{output}' || true
        touch '{output}'
        """

rule run_polishing:
    input:
        reads = "intermediate_files/contigs/{contig}/00_reads.fa",
        initial_assembly = "intermediate_files/contigs/{contig}/01_initial_assembly.fa"
    output:
        "intermediate_files/contigs/{contig}/02_polished_assembly.fa"
    threads: 1
    shell:
        """
        python3 STELR_assembly.py run_{config[polisher]}_polishing '{input.initial_assembly}' '{output}' '{input.reads}' '{wildcards.contig}' '{threads}' '{config[polish_iterations]}' '{config[presets]}' || true
        touch '{output}'
        """

rule get_parsed_contigs:
    input:
        "intermediate_files/contigs/{contig}/02_polished_assembly.fa"
    output:
        "intermediate_files/contigs/{contig}/03_contig1.fa"
    shell:
        """
        python3 STELR_assembly.py parse_assembled_contig '{input}' '{output}' || true
        touch '{output}'
        """

def merged_contigs_input(wildcards):
    return [f"intermediate_files/contigs/{contig}/03_contig1.fa" for contig in all_contigs(**wildcards)]
def all_contigs(wildcards):
    vcf_parsed_file = checkpoints.merge_parsed_vcf.get(**wildcards).output[0]
    with open(vcf_parsed_file) as vcf_parsed:
        contigs = []
        for line in vcf_parsed:
            contigs.append("_".join(line.split("\t")[:3]))
    return contigs
rule merged_contigs:
    input:
        merged_contigs_input
    output:
        "{sample_name}.contigs.fa"
    shell:
        """
        cat '{input}' > '{output}'
        """

"""
3rd stage: annotate TE and predict location in reference genome
"""

'''3rd stage
Contig TE annotation (minimap2 + RepeatMasker)
'''

rule get_vcf_seq:
    input:
        contig = "intermediate_files/contigs/{contig}/00_reads.fa",
        vcf_parsed = "intermediate_files/contigs/{contig}/00_vcf_parsed.tsv"
    output:
        "intermediate_files/contigs/{contig}/04_vcf_seq.fa"
    shell:
        """
        python3 STELR_te.py get_vcf_seq '{wildcards.contig}' '{input.vcf_parsed}' '{output}' || true
        touch '{output}'
        """

rule map_contig:
    input:
        subject = "intermediate_files/contigs/{contig}/03_contig1.fa",
        query = "intermediate_files/contigs/{contig}/04_vcf_seq.fa"
    output:
        "intermediate_files/contigs/{contig}/05_vcf_mm2.paf"
    params:
        presets = lambda wildcards: '{"pacbio":"map-pb","ont":"map-ont"}[config["presets"]]
    threads: 1
    shell:
        """
        minimap2 -cx '{params.presets}' --secondary=no -v 0 -t '{threads}' '{input.subject}' '{input.query}' > '{output}'
        """

rule te_contig_map:
    input:
        minimap_initial = "intermediate_files/contigs/{contig}/05_vcf_mm2.paf",
        subject = "intermediate_files/contigs/{contig}/03_contig1.fa",
        library = config["library"]
    output:
        "intermediate_files/contigs/{contig}/06_te_mm2.paf"
    params:
        presets = lambda wildcards: '{"pacbio":"map-pb","ont":"map-ont"}[config["presets"]]
    threads: 1
    shell:
        """
        if [ -s '{input.minimap_initial}' ]; then
            minimap2 -cx '{params.presets}' '{input.subject}' '{input.library}' -v 0 -t '{threads}' > '{output}'
        else
            touch '{output}'
        fi
        """

rule minimap2bed:
    input:
        "intermediate_files/{minimap_output}.paf"
    output:
        "intermediate_files/{minimap_output}.bed"
    shell:
        "python3 STELR_utility.py minimap2bed '{input}' '{output}'"

rule vcf_alignment_filter_intersect:
    input:
        vcf_seq_mm2 = "intermediate_files/contigs/{contig}/05_vcf_mm2.bed",
        te_mm2 = "intermediate_files/contigs/{contig}/06_te_mm2.bed"
    output:
        "intermediate_files/contigs/{contig}/07_te2contig_filter.tsv"
    shell:
        """
        if [ -s '{input.te_mm2}' ]; then
            bedtools intersect -a '{input.te_mm2}' -b '{input.vcf_seq_mm2}' -wao > '{output}'
        else
            touch '{output}'
        fi
        """

rule vcf_alignment_filter:
    input:
        "intermediate_files/contigs/{contig}/07_te2contig_filter.tsv"
    output:
        "intermediate_files/contigs/{contig}/08_te2contig_filtered.bed"
    shell:
        """
        if [ -s '{input}' ]; then
            python3 STELR_te.py vcf_alignment_filter '{input}' '{output}'
        fi
        touch '{output}'
        """

rule te_annotation_merge:
    input:
        "intermediate_files/contigs/{contig}/08_te2contig_filtered.bed"
    output:
        "intermediate_files/contigs/{contig}/09_te2contig_merged.bed"
    shell:
        """
        if [ -s '{input}' ]; then
            bedtools merge -d 10000 -c 4,6 -o distinct,distinct -delim "|" -i '{input}' > '{output}'
        else
            touch '{output}'
        fi
        """

checkpoint annotate_contig:
    input:
        "intermediate_files/contigs/{contig}/09_te2contig_merged.bed"
    output:
        "intermediate_files/contigs/{contig}/tes/annotation.bed"
    shell:
        """
        if [ -s '{input}' ]; then
            python3 STELR_te.py annotate_contig '{input}' '{output}'
        else
            touch '{output}'
        fi
        """

## use RM to annotate config

rule te_fasta:
    input:
        bed_file = "intermediate_files/contigs/{contig}/tes/annotation.bed",
        sequence = "intermediate_files/contigs/{contig}/03_contig1.fa"
    output:
        "intermediate_files/contigs/{contig}/rm_01_annotated_tes.fasta"
    shell:
        """
        if [ -s '{input.bed_file}' ]; then
            bedtools getfasta -fi '{input.sequence}' -bed '{input.bed_file}' > '{output}'
        else
            touch '{output}'
        fi
        """

rule rm_annotate:
    input:
        te_fasta = "intermediate_files/contigs/{contig}/rm_01_annotated_tes.fasta",
        te_library = config["library"]
    output:
        "intermediate_files/contigs/{contig}/rm_01_annotated_tes.fasta.out.gff"
    params:
        rm_dir = lambda wildcards: f"intermediate_files/contigs/{wildcards.contig}'"
    threads: 1
    shell:
        """
        if [ -s '{input.te_fasta}' ]; then
            RepeatMasker -dir '{params.rm_dir}' -gff -s -nolow -no_is -xsmall -e ncbi -lib '{input.te_library}' -pa '{threads}' '{input.te_fasta}'
        fi
        touch '{output}'
        """

rule rm_annotation_sort:
    input:
        "intermediate_files/contigs/{contig}/rm_01_annotated_tes.fasta.out.gff"
    output:
        "intermediate_files/contigs/{contig}/rm_02_annotated_tes.out.sort.gff"
    shell:
        """
        if [ -s '{input.bed_file}' ]; then
            bedtools sort -i '{input}' > '{output}'
        else
            touch '{output}'
        fi
        """

rule rm_annotation_parse_merge:
    input:
        "intermediate_files/contigs/{contig}/rm_02_annotated_tes.out.sort.gff"
    output:
        "intermediate_files/contigs/{contig}/rm_03_annotated_tes_parsed.bed"
    shell:
        """
        if [ -s '{input}' ]; then
            python3 STELR_te.py rm_parse_merge '{input}' '{output}'
        else
            touch '{output}'
        fi
        """

rule rm_annotation_bedtools_merge:
    input:
        "intermediate_files/contigs/{contig}/rm_03_annotated_tes_parsed.bed"
    output:
        "intermediate_files/contigs/{contig}/rm_04_annotated_tes_merged.bed"
    shell:
        """
        if [ -s '{input}' ]; then
            bedtools merge -c 4,6 -o distinct -delim "|" -i '{input}' > '{output}'
        else
            touch '{output}'
        fi
        """

rule rm_reannotate:
    input:
        repeat_masker_out = "intermediate_files/contigs/{contig}/rm_04_annotated_tes_merged.bed",
        original_bed = "intermediate_files/contigs/{contig}/tes/annotation.bed"
    output:
        "intermediate_files/contigs/{contig}/rm_05_annotation.bed"
    shell:
        """
        if [ -s '{input.repeat_masker_out}' ]; then
            python3 STELR_te.py rm_reannotate '{input.repeat_masker_out}' '{input.original_bed}' '{output}'
        else
            touch '{output}'
        fi
        """

# repeatmask reference genome using custom TE library
#   Not sure which step in the workflow this actually belongs to
rule ref_repeatmask:
    input:
        ref = config["reference"],
        lib = config["library"]
    output:
        "intermediate_files/ref_repeatmask/{reference}.masked",
        "intermediate_files/ref_repeatmask/{reference}.out.gff",
        "intermediate_files/ref_repeatmask/{reference}.out"
    params:
        ref_rm_dir = "intermediate_files/ref_repeatmask"
    threads: config["thread"]
    shell:
        """
        if [ ! -d '{params.ref_rm_dir}' ]; then mkdir '{params.ref_rm_dir}
        fi
        RepeatMasker -dir '{params.ref_rm_dir}' -gff -s -nolow -no_is -e ncbi -lib '{input.lib}' -pa '{threads}' '{input.ref}'
        touch '{output}'
        """

rule ref_rm_process:
    input:
        gff = "intermediate_files/ref_repeatmask/{reference}.out.gff",
        out = "intermediate_files/ref_repeatmask/{reference}.out"
    output:
        "intermediate_files/ref_repeatmask/{reference}.out.gff3"
    shell:
        "python3 STELR_te.py parse_rm_out '{input}' '{output}'"
        #left off here, STELR_te.py repeatmask()

rule ref_te_bed:
    input:
        "intermediate_files/ref_repeatmask/{reference}.out.gff3"
    output:
        "intermediate_files/ref_repeatmask/{reference}.te.bed.unsorted"
    shell:
        """
        python3 STELR_te.py gff3tobed '{input}' '{output}'
        touch '{output}'
        """

rule sort_ref_rm:
    input:
        "intermediate_files/ref_repeatmask/{reference}.te.bed.unsorted"
    output:
        "intermediate_files/ref_repeatmask/{reference}.te.bed"
    shell:
        """
        if [ -s '{input}' ]; then
            bedtools sort -i '{input}' > '{output}'
        else
            touch '{output}'
        fi
        """

##### TELR Liftover

rule build_index:
    input:
        "intermediate_files/{genome}'"
    output:
        "intermediate_files/{genome}.fai"
    shell:
        "samtools faidx '{input}'"

rule make_te_json:
    input:
        "intermediate_files/contigs/{contig}/tes/{te}/00_annotation.bed"
    output:
        "intermediate_files/contigs/{contigs}/tes/{te}/00_annotation.json"
    shell:
        "python3 STELR_liftover.py make_json '{input}' '{output}'"

rule get_genome_size:
    input:
        "intermediate_files/{genome}.fai"
    output:
        "intermediate_files/{genome}.size"
    shell:
        "python3 STELR_liftover.py get_genome_size '{input}' '{output}'"

rule flank_bed:
    input:
        fasta = "intermediate_files/contigs/{contig}/03_contig1.fa",
        size = "intermediate_files/contigs/{contig}/03_contig1.fa.size",
        te_dict = "intermediate_files/contigs/{contig}/tes/{te}/00_annotation.json"
    output:
        "intermediate_files/contigs/{contig}/tes/{te}/12_{flank}_flank.bed"
    params:
        flank_len = config["flank_len"]
    shell:
        """
        python3 STELR_liftover.py '{input.fasta}' '{input.size}' '{input.te_dict}' '{params.flank_len}' '{output}'
        touch '{output}'
        """

rule flank_fasta:
    input:
        fasta = "intermediate_files/contigs/{contig}/03_contig1.fa",
        bed = "intermediate_files/contigs/{contig}/tes/{te}/12_{flank}_flank.bed"
    output:
        "intermediate_files/contigs/{contig}/tes/{te}/12_{flank}_flank.fa"
    shell:
        """
        if [ -s '{input.bed}' ]; then
            bedtools getfasta -fi '{input.fasta}' -bed '{input.bed}' -fo '{output}'
        else
            touch '{output}'
        fi
        """

rule align_flank:
    input:
        flank_fa = "intermediate_files/contigs/{contig}/tes/{te}/12_{flank}_flank.fa",
        ref_fa = config["reference"]
    output:
        "intermediate_files/contigs/{contig}/tes/{te}/13_{flank}_flank.paf"
    params:
        preset = "asm10",
        num_secondary = 10
    shell:
        """
        if [ -s '{input.flank_fa}' ]; then
            minimap2 -cx '{params.preset}' -v 0 -N '{params.num_secondary}' '{input.ref_fa}' '{input.flank_fa}' > '{output}'
        else
            touch '{output}'
        fi
        """

rule get_flank_alignment_info:
    input:
        "intermediate_files/contigs/{contig}/tes/{te}/13_{flank}_flank.paf"
    output:
        "intermediate_files/contigs/{contig}/tes/{te}/14_{flank}_flank.info"
    shell:
        """
        if [ -s '{input}' ]; then
            python3 STELR_liftover.py get_paf_info '{input}' '{output}'
        else
            touch '{output}'
        fi
        """

rule flank_paf_to_bed:
    input:
        "intermediate_files/contigs/{contig}/tes/{te}/13_{flank}_flank.paf"
    output:
        "intermediate_files/contigs/{contig}/tes/{te}/14_{flank}_flank.bed_unsorted"
    params:
        different_contig_name = config["different_contig_name"]
    shell:
        """
        if [ -s '{input}' ]; then
            python3 STELR_liftover.py paf_to_bed '{input}' '{output}' '{wildcards.contig}' '{params.different_contig_name}'
        else
            touch '{output}'
        fi
        """

rule sort_flank_bed:
    input:
        "intermediate_files/contigs/{contig}/tes/{te}/14_{flank}_flank.bed_unsorted"
    output:
        "intermediate_files/contigs/{contig}/tes/{te}/14_{flank}_flank.bed"
    shell:
        """
        if [ -s '{input}' ]; then
            bedtools sort -i '{input}' > '{output}'
        else
            touch '{output}'
        fi
        """

rule closest_flank_maps_to_ref:
    input:
        flank_5p = "intermediate_files/contigs/{contig}/tes/{te}/14_5p_flank.bed",
        flank_3p = "intermediate_files/contigs/{contig}/tes/{te}/14_3p_flank.bed"
    output:
        "intermediate_files/contigs/{contig}/tes/{te}/15_flank_overlap.bed"
    shell:
        """
        if [ -s '{input.flank_5p}' ] && [ -s '{input.flank_3p}' ]; then
            bedtools closest -a '{input.flank_5p}' -b '{input.flank_3p}' -s -d -t all > '{output}'
        else
            touch '{output}'
        fi
        """

checkpoint json_for_report:
    input:
        overlap = "intermediate_files/contigs/{contig}/tes/{te}/15_flank_overlap.bed",
        info_5p = "intermediate_files/contigs/{contig}/tes/{te}/14_5p_flank.info",
        info_3p = "intermediate_files/contigs/{contig}/tes/{te}/14_3p_flank.info"
    output:
        "intermediate_files/contigs/{contig}/tes/{te}/15_flank_overlap.json"
    shell:
        """
        python3 STELR_liftover.py bed_to_json {input.overlap} {input.info_5p} {input.info_3p} {output}
        touch {output}
        """

rule make_report:
    input:
        overlap = "intermediate_files/contigs/{contig}/tes/{te}/15_flank_overlap.json",
        te_json = "intermediate_files/contigs/{contig}/tes/{te}/00_annotation.json",
        ref_bed = lambda wildcards: f"intermediate_files/ref_repeatmask/{os.path.basename(config['reference'])}.te.bed"
    output:
        "intermediate_files/contigs/{contig}/tes/{te}/16_{overlap_id}_report.json"
    params: 
        flank_overlap_max = config["overlap"],
        flank_gap_max = config["gap"]
    """
    python3 STELR_liftover.py make_report {input.overlap} {wildcards.overlap_id} {input.te_json} {input.ref_bed} {config[reference]} {params.flank_overlap_max} {params.flank_gap_max} {output} || true
    touch {output}
    """

def annotation_from_option(wildcards):
    return '{True:f"intermediate_files/contigs/{wildcards.contig}/10_annotation.bed",False:f"intermediate_files/contigs/{wildcards.contig}/rm_05_rm_reannotated_tes.bed"}[config["minimap2_family"]]


    shell:
        """
        if [ -s '{input}' ]; then
            
        else
            touch '{output}'
        fi
        """

def get_te_dirs(wildcards): #expects annotation file to be in contigs/{contig}/tes/
    annotation_file = checkpoints.annotate_contig.get(**wildcards).output[0]
    te_dir = annotation_file[:annotation_file.rindex("/")]
    annotation_file = annotation_file[annotation_file.rindex("/")+1:]
    ls = subprocess.run(f"ls '{te_dir}'", shell=True, capture_output=True, text=True)
    return ls.stdout.split().remove(annotation_file)

'''3rd stage
Identify TE insertion breakpoint (minimap2)
'''

"""
4th stage: estimate intra-sample TE allele frequency (TAF)
"""

'''4th stage
Read extraction (samtools)
'''

rule read_context:
    input:
        vcf_parsed = "intermediate_files/contigs/{contig}/00_vcf_parsed.tsv",
        bam = "intermediate_files/{sample_name}_sort.bam"
    output:
        read_ids = "intermediate_files/contigs/{contig}/00_read_context.id",
        vcf_parsed_new = "intermediate_files/contigs/{contig}/00_parsed_vcf_with_readcount.tsv"
    params:
        window = 1000
    shell:
        "python3 STELR_assembly.py read_context '{wildcards.contig}' '{input.vcf_parsed}' '{input.bam}' '{output.read_ids}' '{output.vcf_parsed_new}' '{params.window}'"

'''4th stage
Read alignment to TE contig (minimap2)
'''

rule get_reverse_complement:
    input:
        "intermediate_files/contigs/{contig}/03_contig1.fa"
    output:
        "intermediate_files/contigs/{contig}/10_revcomp.fa"
    shell:
        """
        if [ -s '{input}' ]; then
            python3 STELR_utility.py get_rev_comp_sequence '{input}' '{output}'
        else
            touch '{output}'
        fi
        """
        
rule realignment:
    input:
        contig = "intermediate_files/contigs/{contig}/{contig_revcomp}.fa",
        reads = "intermediate_files/contigs/{contig}/00_read_context.fa"
    output:
        "intermediate_files/contigs/{contig}/{contig_revcomp}_realign.sam"
    params:
        presets = lambda wildcards: '{"pacbio":"map-pb","ont":"map-ont"}[config["presets"]]
    shell:
        """
        if [ -s '{input.contig}' ]; then
            minimap2 -a -x '{params.presets}' -v 0 '{input.contig}' '{input.reads}' > '{output}'
        else
            touch '{output}'
        fi
        """

rule realignment_to_bam:
    input:
        "intermediate_files/contigs/{contig}/{contig_revcomp}_realign.sam"
    output:
        "intermediate_files/contigs/{contig}/{contig_revcomp}_realign.bam"
    shell:
        """
        if [ -s '{input}' ]; then
            samtools view -bS '{input}' > '{output}'
        else
            touch '{output}'
        fi
        """

rule sort_index_realignment:
    input:
        "intermediate_files/contigs/{contig}/{contig_revcomp}_realign.bam"
    output:
        "intermediate_files/contigs/{contig}/{contig_revcomp}_realign.sort.bam"
    threads: 1
    shell:
        """
        if [ -s '{input}' ]; then
            samtools sort -@ '{threads}' -o '{output}' '{input}'
            samtools index -@ '{threads}' '{output}'
        else
            touch '{output}'
        fi
        """

'''4th stage
Depth-based TAF estimation (SAMtools)
'''

rule estimate_te_depth:
    input:
        bam = "intermediate_files/contigs/{contig}/{contig_revcomp}_realign.sort.bam",
        contig = "intermediate_files/contigs/{contig}/{contig_revcomp}.fa"
    output:
        depth_5p = "intermediate_files/contigs/{contig}/tes/{te}/{contig_revcomp}_5p_te.depth",
        depth_3p = "intermediate_files/contigs/{contig}/tes/{te}/{contig_revcomp}_3p_te.depth"
    params:
        te_interval = config["af_te_interval"],
        te_offset = config["af_te_offset"]
    shell:
        """
        if [ -s '{input.bam}' ]; then
            python3 STELR_te.py estimate_te_depth '{input.bam}' '{input.contig}' '{wildcards.te}' '{params.te_interval}' '{params.te_offset}' '{output.depth_5p}' '{output.depth_3p}'
        else
            touch '{output}'
        fi
        """

rule estimate_flank_depth:
    input:
        bam = "intermediate_files/contigs/{contig}/{contig_revcomp}_realign.sort.bam",
        contig = "intermediate_files/contigs/{contig}/{contig_revcomp}.fa"
    output:
        depth_5p = "intermediate_files/contigs/{contig}/tes/{te}/{contig_revcomp}_5p_flank.depth",
        depth_3p = "intermediate_files/contigs/{contig}/tes/{te}/{contig_revcomp}_3p_flank.depth"
    params:
        flank_len = config["af_flank_interval"],
        flank_offset = config["af_flank_offset"]
    shell:
        """
        if [ -s '{input.bam}' ]; then
            python3 STELR_te.py estimate_flank_depth '{input.bam}' '{input.contig}' '{wildcards.te}' '{params.flank_len}' '{params.flank_offset}' '{output.depth_5p}' '{output.depth_3p}'
        else
            touch '{output}'
        fi
        """
    
rule estimate_coverage:
    input:
        te_5p = "intermediate_files/contigs/{contig}/tes/{te}/{contig_revcomp}_5p_te.depth",
        te_3p = "intermediate_files/contigs/{contig}/tes/{te}/{contig_revcomp}_3p_te.depth",
        flank_5p = "intermediate_files/contigs/{contig}/tes/{te}/{contig_revcomp}_5p_flank.depth",
        flank_3p = "intermediate_files/contigs/{contig}/tes/{te}/{contig_revcomp}_3p_flank.depth"
    output:
        "intermediate_files/contigs/{contig}/tes/{te}/{contig_revcomp}.freq"
    shell:
        "python3 STELR_te.py estimate_coverage '{input.te_5p}' '{input.te_3p}' '{flank_5p}' '{flank_3p}' '{output}'"

rule get_allele_frequency:
    input:
        fwd = "intermediate_files/contigs/{contig}/tes/{te}/03_contig1.freq",
        rev = "intermediate_files/contigs/{contig}/tes/{te}/10_revcomp.freq"
    output:
        "intermediate_files/contigs/{contig}/tes/{te}/11_allele_frequency.json"
    shell:
        "python3 STELR_te.py get_af '{input.fwd}' '{input.rev}' '{output}'"
