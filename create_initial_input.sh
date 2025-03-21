#!/bin/bash

# Set arguments
if [ "$#" -eq  "0" ]
then
   echo "Usage: ${0##*/} <plink_prefix> <out_dir> <code_dir>"
   echo "      <chr> <chr6_hwe_diff>"
   echo "Script removes SNPs with duplicate positions, removes"
   echo "strand ambiguous SNPs, and performs pre-imputation QC."
   echo "Uses mix of PLINK2 & PLINK1.9 (with --keep-allele-order)"
   echo "based on command availability. Crossover is hg19 to hg38"
   echo "or hg38 to hg19. If "chr" input = "all" then the script"
   echo "will create one VCF file per chr. Otherwise, must be a"
   echo "single chr number '1', '2', etc. Fifth argument is build"
   echo "of input data, should be "hg19" or "hg38". Option to use"
   echo "HWE filter 1e-20 for chr6 MHC instead of 1e-6, add by"
   echo "setting optional 6th argument to "hwe"."
   exit
fi

# TODO: need to update to make all out dirs

plink_prefix=$1
out_dir=$2
code_dir=$3
chr=$4
build=$5 # should be "hg19" or "hg38"
if [ -n "$6" ]; then
      chr6_hwe=$6  # should be "hwe" or just not given
fi

# If plink_prefix is in PLINK2 format, convert to PLINK1.9
if [ ! -f "$plink_prefix".fam ]
then
      echo "plink_prefix given in PLINK2 format"
      plink2 --pfile "$plink_prefix" \
            --keep-allele-order \
            --make-bed \
            --out "$plink_prefix"
fi

mkdir "$out_dir"

# Remove SNPs with duplicate positions
plink --bfile $plink_prefix \
   --list-duplicate-vars suppress-first \
   --keep-allele-order \
   --out ${out_dir}/tmp_dupl_check
   
cat ${out_dir}/tmp_dupl_check.dupvar | sed -e '1d' | \
   cut -f4 > ${out_dir}/tmp_dupl_snpids.txt
plink --bfile $plink_prefix \
   --exclude ${out_dir}/tmp_dupl_snpids.txt \
   --keep-allele-order \
   --make-bed --out ${out_dir}/tmp_no_dupl

# Create bed file to crossover from hg19 to hg38 
cat ${out_dir}/tmp_no_dupl.bim | cut -f1 | sed 's/^/chr/' > ${out_dir}/tmp_c1.txt
cat ${out_dir}/tmp_no_dupl.bim | cut -f4 > ${out_dir}/tmp_c2.txt
cat ${out_dir}/tmp_no_dupl.bim | cut -f4 > ${out_dir}/tmp_c3.txt
cat ${out_dir}/tmp_no_dupl.bim | cut -f2 > ${out_dir}/tmp_c4.txt
paste  ${out_dir}/tmp_c1.txt \
       ${out_dir}/tmp_c2.txt \
       ${out_dir}/tmp_c3.txt \
       ${out_dir}/tmp_c4.txt \
       >  ${out_dir}/tmp_in.bed

# Do crossover
build_num=$(echo "$build" | grep -o '[0-9]\+')
[[ "$build_num" == "19" ]] && to_build_num="38" || to_build_num="19"

CrossMap.py bed ${code_dir}/hg${build_num}ToHg${to_build_num}.over.chain \
   ${out_dir}/tmp_in.bed  \
   ${out_dir}/tmp_out.bed

# Extract only those SNPs that were successfully cross-overed
cut -f4 ${out_dir}/tmp_out.bed > ${out_dir}/tmp_snp_keep.txt
plink --bfile ${out_dir}/tmp_no_dupl \
   --extract ${out_dir}/tmp_snp_keep.txt \
   --keep-allele-order \
   --make-bed --out ${out_dir}/tmp_gwas

# Update bim file positions
Rscript --vanilla ${code_dir}/update_pos.R \
  ${out_dir}/tmp_out.bed ${out_dir}/tmp_gwas.bim

# Remove strand ambiguous SNPs
Rscript --vanilla ${code_dir}/get_strand_amb_SNPs.R ${out_dir}/tmp_no_dupl.bim
plink --bfile ${out_dir}/tmp_gwas \
   --exclude ${out_dir}/tmp_strand_remove_snps.txt \
   --keep-allele-order \
   --make-bed --out ${out_dir}/tmp_gwas_no_AT_CG

# Set all varids to chr:pos:ref:alt
plink2 --bfile ${out_dir}/tmp_gwas_no_AT_CG \
  --set-all-var-ids @:#:\$r:\$a --new-id-max-allele-len 100 \
  --make-pgen --out ${out_dir}/tmp_gwas_no_AT_CG_chrpos_ids

# Perform pre-imputation QC - remove monomorphic SNPs, SNPs with high
# missingness, SNPs not in HWE, & then reate vcf files for uploading
# to imputation server for QC
# Note that the encoding for chromosome is e.g. chr22, not 22

# If all chromosomes/regions should have same HWE
if [ -z "$chr6_hwe" ]; then
   plink2 --pfile ${out_dir}/tmp_gwas_no_AT_CG_chrpos_ids \
      --maf 0.000001 --geno 0.05 --hwe 0.000001 \
      --make-bed --out ${out_dir}/pre_qc

   # If preparing all chromosomes
   if [ "$chr" == "all" ]
   then
      for ((chr_num=1; chr_num<=22; chr_num++)); do
         plink --bfile ${out_dir}/pre_qc \
            --chr $chr_num --keep-allele-order \
            --recode vcf --out ${out_dir}/tmp_chr${chr_num}
         if [ "$to_build_num" == "38" ]; then
            vcf-sort ${out_dir}/tmp_chr${chr_num}.vcf | \
               sed -E 's/^([0-9XYM]+)/chr\1/' | \
               bgzip -c > ${out_dir}/chr${chr_num}_pre_qc.vcf.gz
         else
               vcf-sort ${out_dir}/tmp_chr${chr_num}.vcf | \
               sed -E 's/^chr([0-9XYM]+)/\1/' | \
               bgzip -c > ${out_dir}/chr${chr_num}_pre_qc.vcf.gz
         fi
      done
   # If preparing only one chromosome
   else
      plink --bfile ${out_dir}/pre_qc \
            --chr $chr --keep-allele-order \
            --recode vcf --out ${out_dir}/tmp_chr${chr}
      if [ "$to_build_num" == "38" ]; then
         vcf-sort ${out_dir}/tmp_chr${chr}.vcf | \
            sed -E 's/^([0-9XYM]+)/chr\1/' | \
            bgzip -c > ${out_dir}/chr${chr}_pre_qc.vcf.gz
      else
         vcf-sort ${out_dir}/tmp_chr${chr}.vcf | \
            sed -E 's/^chr([0-9XYM]+)/\1/' | \
            bgzip -c > ${out_dir}/chr${chr}_pre_qc.vcf.gz
      fi
   fi
# If chromosome 6 MHC region should have different HWE
else
   echo "Using HWE 1e-20 for chr6, 1e-6 for all other chr."
   # Get chr6 MHC region from Paul Norman's coordinates
   start=$(head -n 1 ${code_dir}/mhc_extended_${build}.bed | awk -F':' '{gsub(/-.*/, "", $2); print $2}')
   stop=$(tail -n 1 ${code_dir}/mhc_extended_${build}.bed | awk -F':' '{gsub(/-.*/, "", $2); print $2}')

   plink2 --pfile ${out_dir}/tmp_gwas_no_AT_CG_chrpos_ids --chr 6 \
      --from-bp $start --to-bp $stop \
      --make-pgen --out ${out_dir}/tmp_mhc

   # Get all chr6 SNPs not in region
   awk '/^#/ {next} {print $3}' ${out_dir}/tmp_mhc.pvar > \
      ${out_dir}/chr6_mhc_var_id_list.txt

   plink2 --pfile ${out_dir}/tmp_gwas_no_AT_CG_chrpos_ids --chr 6 \
      --exclude ${out_dir}/chr6_mhc_var_id_list.txt \
      --make-pgen --out ${out_dir}/tmp_non_mhc

   # Apply QC
   plink2 --pfile ${out_dir}/tmp_mhc \
      --maf 0.000001 --geno 0.05 --hwe 1e-20 \
      --make-bed --out ${out_dir}/tmp_mhc_pre_qc
   
   plink2 --pfile ${out_dir}/tmp_non_mhc \
      --maf 0.000001 --geno 0.05 --hwe 1e-6 \
      --make-bed --out ${out_dir}/tmp_non_mhc_pre_qc
   
   # Merge chr6 back together
   plink --bfile ${out_dir}/tmp_mhc_pre_qc \
      --bmerge ${out_dir}/tmp_non_mhc_pre_qc \
      --keep-allele-order \
      --make-bed --out ${out_dir}/chr6_pre_qc

   # If preparing all chromosomes
   if [ "$chr" == "all" ]
   then
      plink2 --pfile ${out_dir}/tmp_gwas_no_AT_CG_chrpos_ids \
      --maf 0.000001 --geno 0.05 --hwe 0.000001 \
      --not-chr 6 \
      --make-bed --out ${out_dir}/non_chr6_pre_qc

      # Need to write out pre_qc with all chr for next pipeline step
      plink --bfile ${out_dir}/non_chr6_pre_qc \
         --bmerge ${out_dir}/chr6_pre_qc \
         --keep-allele-order \
         --make-bed --out ${out_dir}/pre_qc

      for ((chr_num=1; chr_num<=22; chr_num++)); do
         plink --bfile ${out_dir}/pre_qc \
            --chr $chr_num --keep-allele-order \
            --recode vcf --out ${out_dir}/tmp_chr${chr_num}
         if [ "$to_build_num" == "38" ]; then
            vcf-sort ${out_dir}/tmp_chr${chr_num}.vcf | \
               sed -E 's/^([0-9XYM]+)/chr\1/' | \
               bgzip -c > ${out_dir}/chr${chr_num}_pre_qc.vcf.gz
         else
            vcf-sort ${out_dir}/tmp_chr${chr_num}.vcf | \
               sed -E 's/^chr([0-9XYM]+)/\1/' | \
               bgzip -c > ${out_dir}/chr${chr_num}_pre_qc.vcf.gz
         fi

      done
   # If preparing only chr6
   else
      # Need to write out pre_qc for next pipeline step
      plink --bfile ${out_dir}/chr6_pre_qc \
         --keep-allele-order \
         --make-bed --out ${out_dir}/pre_qc

      plink --bfile ${out_dir}/pre_qc \
         --chr $chr --keep-allele-order \
         --recode vcf --out ${out_dir}/tmp_chr${chr}

      if [ "$to_build_num" == "38" ]; then
         vcf-sort ${out_dir}/tmp_chr${chr}.vcf | \
            sed -E 's/^([0-9XYM]+)/chr\1/' | \
            bgzip -c > ${out_dir}/chr${chr}_pre_qc.vcf.gz
      else
         vcf-sort ${out_dir}/tmp_chr${chr}.vcf | \
            sed -E 's/^chr([0-9XYM]+)/\1/' | \
            bgzip -c > ${out_dir}/chr${chr}_pre_qc.vcf.gz
      fi
   fi
fi

# Report SNP counts
orig_snp_nr=`wc -l ${plink_prefix}.bim`
crossover_snp_nr=`wc -l ${out_dir}/tmp_gwas.bim`
nonamb_snp_nr=`wc -l ${out_dir}/tmp_gwas_no_AT_CG.bim`
echo "Original SNP nr: $orig_snp_nr"
echo "Crossovered SNP nr: $crossover_snp_nr"
echo "Non-ambiguous SNP nr: $nonamb_snp_nr"
echo "Original SNP nr: $orig_snp_nr" > ${out_dir}/create_initial_input_log.txt
echo "Crossovered SNP nr: $crossover_snp_nr" >> ${out_dir}/create_initial_input_log.txt
echo "Non-ambiguous SNP nr: $nonamb_snp_nr" >> ${out_dir}/create_initial_input_log.txt

if [ -z "$chr6_hwe" ]
then
   qc_snp_nr=`wc -l ${out_dir}/pre_qc.bim`
   echo "Final SNP nr after QC: $qc_snp_nr"
   echo "Final SNP nr after QC: $qc_snp_nr" >> ${out_dir}/create_initial_input_log.txt
   
else
   qc_snp_nr_mhc=`wc -l ${out_dir}/tmp_mhc_pre_qc.bim`
   qc_snp_nr_non_mhc=`wc -l ${out_dir}/tmp_non_mhc_pre_qc.bim` 
   echo "Final chr6 MHC SNP nr after QC: $qc_snp_nr_mhc"
   echo "Final chr6 non-MHC SNP nr after QC: $qc_snp_nr_non_mhc"
   echo "Final chr6 MHC SNP nr after QC: $qc_snp_nr_mhc" >> \
      ${out_dir}/create_initial_input_log.txt
   echo "Final chr6 non-MHC SNP nr after QC: $qc_snp_nr_non_mhc" >> \
      ${out_dir}/create_initial_input_log.txt
   
   if [ "$chr" == "all" ]
   then
      qc_snp_nr_non_chr6=`wc -l ${out_dir}/non_chr6_pre_qc.bim`
      echo "Final all other chr (non-chr6) SNP nr after QC: $qc_snp_nr_non_chr6"
      echo "Final all other chr (non-chr6) SNP nr after QC: $qc_snp_nr_non_chr6" >> \
         ${out_dir}/create_initial_input_log.txt
   fi
fi

# Cleanup
rm ${out_dir}/tmp_*
