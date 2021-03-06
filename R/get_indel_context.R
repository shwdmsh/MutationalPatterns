#' Get indel contexts
#'
#' @details
#' Determines the COSMIC context from a GRanges or GRangesList object containing Indel mutations.
#' It applies the get_indel_context_gr function to each gr in the input.
#'
#' @param vcf_list GRanges or GRangesList object containing Indel mutations.
#' The mutations should be called similarly to HaplotypeCaller.
#' @param ref_genome BSGenome reference genome object
#'
#' @return A modified version of the input grl. In each gr two columns have been added.
#' "muttype" showing the main indel type and "muttype_sub" which shows the subtype.
#' The subtype is either the number of repeats or the microhomology length.
#'
#' @examples
#'
#' ## Get a GRangesList or GRanges object with only indels.
#' ## See 'read_vcfs_as_granges' or 'get_mut_type' for more info on how to do this.
#' indel_grl <- readRDS(system.file("states/blood_grl_indel.rds",
#'   package = "MutationalPatterns"
#' ))
#'
#' ## Load the corresponding reference genome.
#' ref_genome <- "BSgenome.Hsapiens.UCSC.hg19"
#' library(ref_genome, character.only = TRUE)
#'
#' ## Get the indel contexts
#' get_indel_context(indel_grl, ref_genome)
#' @family Indels
#' @importFrom magrittr %>%
#' @seealso
#' \code{\link{read_vcfs_as_granges}}, \code{\link{get_mut_type}}
#'
#' @export
#'
get_indel_context <- function(vcf_list, ref_genome) {
  # Check that the seqnames of the gr and ref_genome match
  .check_chroms(vcf_list, ref_genome)

  # Turn grl into list if needed.
  if (inherits(vcf_list, "CompressedGRangesList")) {
    vcf_list <- as.list(vcf_list)
  }

  # Get indel context per sample
  if (inherits(vcf_list, "list")) {
    grl <- purrr::map(vcf_list, function(x) .get_indel_context_gr(x, ref_genome)) %>%
      GenomicRanges::GRangesList()
    return(grl)
  } else if (inherits(vcf_list, "GRanges")) {
    gr <- .get_indel_context_gr(vcf_list, ref_genome)
    return(gr)
  } else {
    .not_gr_or_grl(vcf_list)
  }
}

#' Get indel contexts from a single gr
#'
#' @details
#' Determines the COSMIC context from a GRanges object containing Indel mutations.
#' It throws an error if there are any variants with multiple alternative alleles or SNVs.
#'
#' @param gr GRanges object containing Indel mutations.
#' The mutations should be called similarly to HaplotypeCaller.
#' @param ref_genome BSGenome reference genome object
#'
#' @return A modified version of the input gr. In the gr two columns have been added.
#' "muttype" showing the main indel type and "muttype_sub" which shows the subtype.
#' The subtype is either the number of repeats or the microhomology length.
#'
#'
#' @noRd
#'
#' @importFrom magrittr %>%
#'
.get_indel_context_gr <- function(gr, ref_genome) {

  # Check that no snvs are present.
  .check_no_snvs(gr)

  # Calculate indel size to determine main category
  ref_sizes <- gr %>%
    .get_ref() %>%
    width()
  alt_sizes <- gr %>%
    .get_alt() %>%
    unlist() %>%
    width()
  mut_size <- alt_sizes - ref_sizes

  # For the main indel categories, determine their sub categories.
  # (Also split the big deletion categorie into repeat and micro homology.)
  gr_1b_dels <- .get_1bp_dels(gr, mut_size, ref_genome)
  gr_1b_ins <- .get_1bp_ins(gr, mut_size, ref_genome)
  gr_big_dels <- .get_big_dels(gr, mut_size, ref_genome)
  gr_big_ins <- .get_big_ins(gr, mut_size, ref_genome)

  gr <- c(gr_1b_dels, gr_1b_ins, gr_big_dels, gr_big_ins) %>%
    BiocGenerics::sort()
  return(gr)
}

#' Get contexts from 1bp deletions
#'
#' @details
#' Determines the COSMIC context for the 1bp deletions in a GRanges object containing Indel mutations.
#' This function is called by get_indel_context_gr.
#'
#'
#' @param gr GRanges object containing Indel mutations.
#' The mutations should be called similarly to HaplotypeCaller.
#' @param mut_size A double vector containing the size of each Indel.
#' @param ref_genome BSGenome reference genome object
#'
#' @return A modified version of the input gr.
#' All variants that are not a 1bp deletion are removed.
#' In each gr two columns have been added.
#' "muttype" showing the main indel type and "muttype_sub" which shows the subtype.
#' The subtype is the number of repeats.
#'
#'
#' @importFrom magrittr %>%
#' @noRd
#'
#'
.get_1bp_dels <- function(gr, mut_size, ref_genome) {

  # Select mutations
  gr <- gr[mut_size == -1]
  if (length(gr) == 0) {
    return(gr)
  }

  # Get the deleted bases
  del_bases <- gr %>%
    .get_ref() %>%
    as.character() %>%
    substring(2)

  # Get the extended sequence.
  seq <- .get_extended_sequence(gr, 19, ref_genome)

  # Check homopolymer length
  # For each mut replace the deleted basetype in the flanking sequence with Zs.
  seq_z <- stringr::str_replace_all(
    as.character(seq),
    del_bases,
    rep("Z", length(seq))
  )
  # Remove all bases after the Zs and count how many bases are left.
  # Add one for the deleted base itself.
  homopolymer_length <- gsub("[^Z].*", "", as.character(seq_z)) %>%
    nchar() + 1
  del_bases[del_bases == "A"] <- "T"
  del_bases[del_bases == "G"] <- "C"

  # Return the results
  gr$muttype <- stringr::str_c(del_bases, "_deletion")
  gr$muttype_sub <- homopolymer_length
  return(gr)
}

#' Get contexts from 1bp insertions
#'
#' @details
#' Determines the COSMIC context for the 1bp insertions in a GRanges object containing Indel mutations.
#' This function is called by get_indel_context_gr.
#'
#'
#' @param gr GRanges object containing Indel mutations.
#' The mutations should be called similarly to HaplotypeCaller.
#' @param mut_size A double vector containing the size of each Indel.
#' @param ref_genome BSGenome reference genome object
#'
#' @return A modified version of the input gr.
#' All variants that are not a 1bp insertion are removed.
#' In each gr two columns have been added.
#' "muttype" showing the main indel type and "muttype_sub" which shows the subtype.
#' The subtype is the number of repeats.
#'
#'
#' @importFrom magrittr %>%
#' @noRd
#'
.get_1bp_ins <- function(gr, mut_size, ref_genome) {

  # Select mutations
  gr <- gr[mut_size == 1]
  if (length(gr) == 0) {
    return(gr)
  }

  # Get inserted bases.
  ins_bases <- gr %>%
    .get_alt() %>%
    unlist() %>%
    as.character() %>%
    substring(2)

  # Get extended sequence
  seq <- .get_extended_sequence(gr, 20, ref_genome)

  # Check homopolymer length
  # For each mut replace the inserted basetype in the flanking sequence with Zs.
  seq_z <- stringr::str_replace_all(
    as.character(seq),
    ins_bases,
    rep("Z", length(seq))
  )

  # Remove all bases after the Zs and count how many bases are left.
  homopolymer_length <- gsub("[^Z].*", "", as.character(seq_z)) %>%
    nchar()
  ins_bases[ins_bases == "A"] <- "T"
  ins_bases[ins_bases == "G"] <- "C"

  # Return the results
  gr$muttype <- stringr::str_c(ins_bases, "_insertion")
  gr$muttype_sub <- homopolymer_length
  return(gr)
}

#' Get contexts from bigger inserions
#'
#' @details
#' Determines the COSMIC context for insertions larger than 1bp in a GRanges object containing Indel mutations.
#' This function is called by get_indel_context_gr.
#'
#'
#' @param gr GRanges object containing Indel mutations.
#' The mutations should be called similarly to HaplotypeCaller.
#' @param mut_size A double vector containing the size of each Indel.
#' @param ref_genome BSGenome reference genome object
#'
#' @return A modified version of the input gr.
#' All variants that are not insertions larger than 1bp are removed.
#' In each gr two columns have been added.
#' "muttype" showing the main indel type and "muttype_sub" which shows the subtype.
#' The subtype is the number of repeats.
#'
#'
#' @importFrom magrittr %>%
#' @noRd
#'
.get_big_ins <- function(gr, mut_size, ref_genome) {

  # Select mutations
  gr <- gr[mut_size > 1]
  if (length(gr) == 0) {
    return(gr)
  }
  mut_size <- mut_size[mut_size > 1]

  # Get inserted bases
  ins_bases <- gr %>%
    .get_alt() %>%
    unlist() %>%
    as.character() %>%
    substring(2)
  biggest_ins <- ins_bases %>%
    nchar() %>%
    max()
  flank_dist <- biggest_ins * 20

  # Get extended sequence
  seq <- .get_extended_sequence(gr, flank_dist, ref_genome)

  # Determine nr. repeats.
  # For each mut replace the deleted basetype in the flanking sequence with Zs.
  seq_z <- stringr::str_replace_all(
    as.character(seq),
    ins_bases,
    rep("Z", length(seq))
  )

  # Remove all bases after the Zs and count how many bases are left.
  n_repeats <- gsub("[^Z].*", "", as.character(seq_z)) %>%
    nchar()

  # Return results
  gr$muttype <- stringr::str_c(mut_size, "bp_insertion")
  gr$muttype_sub <- n_repeats
  return(gr)
}

#' Get contexts from larger deletions
#'
#' @details
#' Determines the COSMIC context for deletions larger than 1bp in a GRanges object
#' containing Indel mutations.
#' This function is called by get_indel_context_gr.
#' The function determines if there is microhomology for deletions that are not in repeat regions.
#'
#' @param gr GRanges object containing Indel mutations.
#' The mutations should be called similarly to HaplotypeCaller.
#' @param mut_size A double vector containing the size of each Indel.
#' @param ref_genome BSGenome reference genome object
#'
#' @return A modified version of the input gr.
#' All variants that are not a deletion larger than 1bp are removed.
#' In each gr two columns have been added.
#' "muttype" showing the main indel type and "muttype_sub" which shows the subtype.
#' The subtype is the number of repeats or the microhomology length.
#'
#'
#' @importFrom magrittr %>%
#' @noRd
#'
.get_big_dels <- function(gr, mut_size, ref_genome) {

  # Select mutations
  gr <- gr[mut_size < -1]
  if (length(gr) == 0) {
    return(gr)
  }
  mut_size <- mut_size[mut_size < -1]

  # Get deleted bases
  del_bases <- gr %>%
    .get_ref() %>%
    as.character() %>%
    substring(2)
  biggest_dels <- del_bases %>%
    nchar() %>%
    max()
  flank_dist <- biggest_dels * 20

  # Find extended sequence
  seq <- .get_extended_sequence(gr, flank_dist, ref_genome)

  # Determine nr. repeats.
  # For each mut replace the deleted basetype in the flanking sequence with Zs.
  seq_z <- stringr::str_replace_all(
    as.character(seq),
    del_bases,
    rep("Z", length(seq))
  )

  # Remove all bases after the Zs and count how many bases are left.
  # Add +1 for the deleted bases itself
  n_repeats <- gsub("[^Z].*", "", as.character(seq_z)) %>%
    nchar() + 1

  gr$muttype <- stringr::str_c(abs(mut_size), "bp_deletion")
  gr$muttype_sub <- n_repeats


  # Determine if there is microhomology for deletions that are not in repeat regions.
  # There is always at least 1 'repeat', because of the deleted bases themselves.
  pos_mh <- gr$muttype_sub == 1

  gr_repeat <- gr[!pos_mh]
  gr_mh <- gr[pos_mh]

  if (length(gr_mh) == 0) {
    return(gr_repeat)
  }

  mut_size_mh <- mut_size[pos_mh]
  del_bases_mh <- del_bases[pos_mh]
  del_bases_s <- strsplit(del_bases_mh, "")
  seq_s <- strsplit(as.character(seq[pos_mh]), "")


  # Also check for microhomology to the left of the deletion.
  # For this take the reverse sequence to the left of the deletion and the reverse deleted bases.
  rev_del_bases <- IRanges::reverse(del_bases_mh)
  rev_l_del_bases_s <- strsplit(rev_del_bases, "")

  # Flank the granges object, to get a sequence, that can be searched for repeats.
  # This can result in a warning message, when the flanked range extends beyond
  # the chrom lenght. This message is suppressed.
  withCallingHandlers(
    {
      l_flank <- GenomicRanges::flank(gr_mh, biggest_dels)
    },
    warning = function(w) {
      if (grepl("out-of-bound range located on sequence", conditionMessage(w))) {
        invokeRestart("muffleWarning")
      }
    }
  )

  # Trim the ranges that are extended beyond the actual length of the chromosome.
  # Add 1 base, because the first base in the granges obj is not deleted and
  # should be used in the flank.
  l_flank <- l_flank %>%
    GenomicRanges::trim() %>%
    GenomicRanges::shift(1)
  rev_l_seq <- Biostrings::getSeq(BSgenome::getBSgenome(ref_genome), l_flank) %>%
    IRanges::reverse()
  rev_l_seq_s <- strsplit(as.character(rev_l_seq), "")

  # For each mutation determine how many bases show hm
  nr_pos_mh <- length(del_bases_s)
  nr_mh <- vector("list", nr_pos_mh)
  for (i in seq_len(nr_pos_mh)) {
    del_bases_sample <- del_bases_s[[i]]
    seq_s_sample <- seq_s[[i]][seq_len(length(del_bases_sample))]
    same <- del_bases_sample == seq_s_sample

    # Determine how many bases are the same before the first difference.
    # na.rm is for when a sequence has been trimmed.
    r_nr_mh_sample <- cumprod(same) %>%
      sum(na.rm = TRUE)

    l_del_bases_sample <- rev_l_del_bases_s[[i]]
    l_seq_s_sample <- rev_l_seq_s[[i]][seq_len(length(l_del_bases_sample))]
    l_same <- l_del_bases_sample == l_seq_s_sample
    l_nr_mh_sample <- cumprod(l_same) %>%
      sum(na.rm = TRUE)

    nr_mh_sample <- max(r_nr_mh_sample, l_nr_mh_sample)

    nr_mh[[i]] <- nr_mh_sample
  }
  nr_mh <- unlist(nr_mh)

  # Update gr when mh is indeed present
  mh_f <- nr_mh > 0
  gr_mh$muttype[mh_f] <- stringr::str_c(
    abs(mut_size_mh[mh_f]),
    "bp_deletion_with_microhomology"
  )
  gr_mh$muttype_sub[mh_f] <- nr_mh[mh_f]

  # Combine muts with and without mh
  gr <- c(gr_mh, gr_repeat) %>%
    BiocGenerics::sort()
  return(gr)
}

#' Retreive the flanking sequence from a GRanges object
#'
#' @details
#' This function retreives the flanking sequence from a GRanges object.
#' The size of the flanking sequence is supplied as an argument to the function.
#' This function works by first extending the ranges and then retreiving the sequence.
#'
#'
#'
#' @param gr GRanges object containing Indel mutations.
#' The mutations should be called similarly to HaplotypeCaller.
#' @param flank_dist A numeric vector of length one containing the number of flanking base pairs.
#' @param ref_genome BSGenome reference genome object
#'
#' @return A DNAStringSet containing the flaning bases.
#'
#'
#' @noRd
#'
#'
.get_extended_sequence <- function(gr, flank_dist, ref_genome) {

  # Flank the granges object, to get a sequence, that can be searched for repeats.
  # This can result in a warning message, when the flanked range extends
  # beyond the chrom lenght. This message is suppressed.
  withCallingHandlers(
    {
      gr_extended <- GenomicRanges::flank(gr, flank_dist, start = FALSE)
    },
    warning = function(w) {
      if (grepl("out-of-bound range located on sequence", conditionMessage(w))) {
        invokeRestart("muffleWarning")
      }
    }
  )

  # Trim the ranges that are extended beyond the actual length of the chromosome.
  gr_extended <- GenomicRanges::trim(gr_extended)
  seq <- Biostrings::getSeq(BSgenome::getBSgenome(ref_genome), gr_extended)
  return(seq)
}
