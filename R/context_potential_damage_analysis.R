#' Potential damage analysis for the supplied mutational contexts
#'
#' The ratio of possible 'stop gain', 'mismatches' and 'synonymous mutations' is
#' counted per mutational context. This is done for the supplied ENTREZ gene ids.
#' This way it can be determined how damaging a mutational context could be.
#' N gives the total number of possible mutations per context.
#'
#' The function works by first selecting the longest transcript per gene.
#' The coding sequence (cds) of this transcript is then assembled. Next, the function
#' loops over the reference contexts. For each context (and it's reverse complement),
#' all possible mutation locations are determined.
#' It's also determined whether these locations are the first, second
#' or third base of the cds codon (mut loc). Each unique combination of codon and
#' mut loc is then counted. For each combination the reference amino acid and the
#' possible alternative amino acids are determined. By comparing the reference and
#' alternative amino acids, the number of 'stop_gains', 'mismatches' and
#' 'synonymous mutations' is determined. This is then normalized per
#' mutation context.
#' For example, mutations with the ACA context could be located in the third
#' position of a codon like TAC. This might happen 200 times in the supplied genes.
#' This TAC codon could then be mutated in either a TAA, TAG or a TAT. The first two
#' of these options would induce a stop codon, while the third one would be synonymous.
#' By summing up all codons the number of stop_gains', 'mismatches' and
#' 'synonymous mutations' is determined per mutation context.
#'
#' @param contexts Vector of mutational contexts to use for the analysis.
#' @param txdb Transcription annotation database
#' @param ref_genome BSGenome reference genome object
#' @param gene_ids Entrez gene ids
#' @param verbose Boolean. Determines whether progress is printed. (Default: FALSE)
#'
#' @return A tibble with the ratio of 'stop gain', 'mismatch' and 'synonymous' mutations
#' per mutation context.
#' @export
#'
#' @examples
#'
#' ## See the 'mut_matrix()' example for how we obtained the
#' ## mutation matrix information:
#' mut_mat <- readRDS(system.file("states/mut_mat_data.rds",
#'   package = "MutationalPatterns"
#' ))
#'
#' contexts <- rownames(mut_mat)
#'
#' ## Load the corresponding reference genome.
#' ref_genome <- "BSgenome.Hsapiens.UCSC.hg19"
#' library(ref_genome, character.only = TRUE)
#'
#' ## Load the transcription annotation database
#' ## You can obtain the database from the UCSC hg19 dataset using
#' ## Bioconductor:
#' # BiocManager::install("TxDb.Hsapiens.UCSC.hg19.knownGene")
#' library("TxDb.Hsapiens.UCSC.hg19.knownGene")
#' txdb <- TxDb.Hsapiens.UCSC.hg19.knownGene
#'
#' ## Here we will use the Entrez Gene IDs from several cancer
#' ## genes. In practice you might want to use larger gene lists,
#' ## but here we only use a few to keep the run-time low.
#' ## In this example we are using:
#' ## TP53, KRAS, NRAS, BRAF, BRCA2, CDKN2A, ARID1A, PTEN and TERT
#' gene_ids <- c(7157, 3845, 4893, 673, 675, 1029, 8289, 5728, 7015)
#'
#' ## Run the function
#' context_potential_damage_analysis(contexts, txdb, ref_genome, gene_ids)
#'
#' ## The function can provide updates about its progress.
#' ## This can be usefull when it's running slowly,
#' ## which can happen when you are using many gene_ids.
#' context_potential_damage_analysis(contexts, txdb, ref_genome, gene_ids, verbose = TRUE)
context_potential_damage_analysis <- function(contexts, txdb, ref_genome, gene_ids, verbose = FALSE) {

  # Check dependencies are installed.
  if (!requireNamespace("GenomicFeatures", quietly = TRUE)) {
    stop(paste0(
      "Package 'GenomicFeatures' is needed for context_potential_damage_analysis to work. ",
      "Please install it if you want to use this function."
    ), call. = FALSE)
  }
  if (!requireNamespace("AnnotationDbi", quietly = TRUE)) {
    stop(paste0(
      "Package 'AnnotationDbi' is needed for context_potential_damage_analysis to work. ",
      "Please install it if you want to use this function."
    ), call. = FALSE)
  }

  # Get DNA of exons. This is strand specific, so I don't need to worry about this.
  seqs <- .get_cds_sequences(txdb, ref_genome, gene_ids)

  if (verbose) {
    message("Finished getting the coding sequences.")
  }

  # Get substitution and contexts
  substitution <- stringr::str_replace(contexts, "\\w\\[(.*)\\]\\w", "\\1")
  l_context <- stringr::str_remove(contexts, "\\[.*")
  r_context <- stringr::str_remove(contexts, ".*\\]")
  ori_bases <- stringr::str_replace(contexts, "\\[(.*)>.*\\]", "\\1")
  ref_base <- stringr::str_remove(substitution, ">.*")
  alt_base <- stringr::str_remove(substitution, ".*>")

  # Group by ori_bases, because the DNA needs to be searched based on them.
  contexts_tb <- tibble::tibble(
    "ori_bases" = ori_bases,
    "ref_base" = ref_base,
    "alt_base" = alt_base,
    "l_context" = l_context,
    "r_context" = r_context
  ) %>%
    dplyr::group_by(ori_bases) %>%
    dplyr::summarise(
      ref_base = ref_base[[1]],
      alt_bases = list(alt_base),
      l_context = l_context[[1]],
      r_context = r_context[[1]],
      .groups = "drop_last"
    )


  # Perform damage analysis per context.
  mismatches <- purrr::map(seq_len(nrow(contexts_tb)), .single_context_damage_analysis, contexts_tb, seqs, verbose) %>%
    dplyr::bind_rows()

  return(mismatches)
}


#' Get cds sequences for supplied genes
#'
#' Per gene the longest transcript is used.
#'
##' @param txdb Transcription annotation database
#' @param ref_genome BSGenome reference genome object
#' @param gene_ids Entrez gene ids
#'
#' @return DNAStringSet containing the cds sequences
#' @noRd
#'
.get_cds_sequences <- function(txdb, ref_genome, gene_ids) {

  # These variables use non standard evaluation.
  # To avoid R CMD check complaints we initialize them to NULL.
  GENEID <- tx_size <- TXNAME <- NULL

  # Get cds per transcript
  cds_tx <- GenomicFeatures::cdsBy(txdb, by = "tx", use.names = TRUE)

  # Get sizes of transcripts
  tx_sizes <- cds_tx %>%
    BiocGenerics::width() %>%
    sum() %>%
    tibble::enframe(name = "TXNAME", value = "tx_size")

  # Get gene names belonging to transcripts
  withCallingHandlers(
    { # Supress the returned 1:many mapping message
      gene2txname <- AnnotationDbi::select(txdb, AnnotationDbi::keys(txdb, "GENEID"), columns = c("GENEID", "TXNAME"), keytype = "GENEID")
    },
    message = function(m) {
      if (grepl(" returned 1:many mapping between keys and columns", conditionMessage(m))) {
        invokeRestart("muffleMessage")
      }
    }
  )
  gene2txname <- gene2txname %>%
    dplyr::filter(GENEID %in% gene_ids) %>%
    dplyr::inner_join(tx_sizes, by = "TXNAME")

  # Keep longest transcript per gene
  txname_keep <- gene2txname %>%
    dplyr::group_by(GENEID) %>%
    dplyr::arrange(dplyr::desc(tx_size), .by_group = TRUE) %>%
    dplyr::summarise(TXNAME = TXNAME[[1]], .groups = "drop_last") %>%
    dplyr::pull(TXNAME)


  cds_tx <- cds_tx[names(cds_tx) %in% txname_keep]

  # Get sequences (per cds per transcript.)
  seqs <- Biostrings::getSeq(BSgenome::getBSgenome(ref_genome), cds_tx)

  # Merge cds sequences per transcript
  seqs <- purrr::map(as.list(seqs), function(seq) do.call(c, as.list(seq))) %>%
    Biostrings::DNAStringSet()

  return(seqs)
}

#' Get the potential damage per mutational context
#'
#' @param i Index of the mutational contexts
#' @param contexts_tb A tibble containing the mutational contexts
#' @param seqs DNAStringSet containing the cds sequences
#' @param verbose Boolean. Determines whether progress is printed. (Default: FALSE)
#'
#' @return A tibble with the ratio of 'stop gain', 'mismatch' and 'synonymous' mutations
#' for one mutation context.
#' @noRd
#'
.single_context_damage_analysis <- function(i, contexts_tb, seqs, verbose) {

  # These variables use non standard evaluation.
  # To avoid R CMD check complaints we initialize them to NULL.
  alt_base <- context <- n <- NULL

  # Get data from this context
  contexts_tb <- contexts_tb[i, ]
  ori_bases <- contexts_tb$ori_bases
  ref_base <- contexts_tb$ref_base
  alt_bases <- contexts_tb$alt_bases[[1]]
  l_context <- contexts_tb$l_context
  r_context <- contexts_tb$r_context

  # Count muttypes for forward context
  muttype_counts <- .single_context_damage_analysis_strand(ori_bases, ref_base, alt_bases, seqs) %>%
    dplyr::mutate(context = paste0(l_context, "[", ref_base, ">", alt_base, "]", r_context)) %>%
    dplyr::select(type, context, n)

  # Get reverse context
  rev_ori_bases <- ori_bases %>%
    Biostrings::DNAString() %>%
    Biostrings::reverseComplement() %>%
    as.character()
  rev_ref_base <- ref_base %>%
    Biostrings::DNAString() %>%
    Biostrings::reverseComplement() %>%
    as.character()
  rev_alt_bases <- alt_bases %>%
    Biostrings::DNAStringSet() %>%
    Biostrings::reverseComplement() %>%
    as.character()

  # Count muttypes for reverse context
  muttype_counts_rev <- .single_context_damage_analysis_strand(rev_ori_bases, rev_ref_base, rev_alt_bases, seqs)

  # Combine forward and reverse context
  muttype_counts$n <- muttype_counts$n + muttype_counts_rev$n

  # Normalize
  norm_muttype_counts <- muttype_counts %>%
    dplyr::group_by(context) %>%
    dplyr::mutate(ratio = n / sum(n)) %>%
    dplyr::ungroup()

  if (verbose) {
    message(paste0("Finished with the ", ori_bases, " context."))
  }

  return(norm_muttype_counts)
}

#' Get the potential damage per mutational context for a single strand
#'
#' @param ori_bases Mutational context
#' @param ref_base Reference base
#' @param alt_bases Vector of possible alternative bases.
#' @param seqs DNAStringSet containing the cds sequences
#'
#' @return A tibble with the number of 'stop gain', 'mismatch' and 'synonymous' mutations
#' for one mutation context on one strand.
#' @noRd
#'
.single_context_damage_analysis_strand <- function(ori_bases, ref_base, alt_bases, seqs) {

  # These variables use non standard evaluation.
  # To avoid R CMD check complaints we initialize them to NULL.
  loc <- dna <- NULL

  # Determine reference codons and mutation location
  ori_bases_biostring <- Biostrings::DNAString(ori_bases)
  ref_mut_loc_l <- purrr::map(as.list(seqs), .get_ref_codons, ori_bases_biostring)

  # Get ref codons from list
  ref_codons_l <- purrr::map(ref_mut_loc_l, "ref_codons")
  names(ref_codons_l) <- NULL
  ref_codons <- do.call(c, ref_codons_l)

  # Get mutation locations in codons from list
  mut_loc_in_codon_l <- purrr::map(ref_mut_loc_l, "mut_loc_in_codon")
  names(mut_loc_in_codon_l) <- NULL
  mut_loc_in_codon <- do.call(c, mut_loc_in_codon_l)


  # Count how often each combination of codon and mutated base location occurs
  tb <- tibble::tibble("loc" = mut_loc_in_codon, "dna" = as.vector(ref_codons))
  counts <- tb %>%
    dplyr::group_by(loc, dna) %>%
    dplyr::count() %>%
    dplyr::ungroup()

  # Calculate the occuring mismatch for each combi of codon and mut base location.
  muttype_counts <- purrr::map(alt_bases, .calculate_mismatches, counts) %>%
    dplyr::bind_rows() %>%
    dplyr::mutate(ori_bases = ori_bases, ref_base = ref_base)

  return(muttype_counts)
}

#' Get reference codons for one gene
#'
#' @param seq DNAString containing the cds for one gene
#' @param ori_bases Mutational context
#'
#' @return List. Containing reference codons and
#' the position of the possible mutation in the codon.
#' @noRd
#'
.get_ref_codons <- function(seq, ori_bases) {

  # Determine locations of context in dna
  locs <- Biostrings::matchPattern(ori_bases, seq)

  # Determine locations of mut in dna
  locs_mutbase <- end(locs) - (end(locs) - start(locs)) / 2

  # Get the reference codons
  exon_codons <- Biostrings::codons(seq)
  codon_nr <- ceiling(locs_mutbase / 3)
  ref_codons <- Biostrings::DNAStringSet(exon_codons[codon_nr])

  # Determine mutation location in reference
  mut_loc_in_codon <- dplyr::case_when(
    locs_mutbase %% 3 == 0 ~ 3,
    locs_mutbase %% 3 == 2 ~ 2,
    locs_mutbase %% 3 == 1 ~ 1
  )

  return(list("ref_codons" = ref_codons, "mut_loc_in_codon" = mut_loc_in_codon))
}

#' Calculate the possible mismatches for each of the codons
#' for one possible alternative base.
#'
#' @param alt_base Alternative base
#' @param counts Tibble of all codons.
#'
#' @return A tibble with the number of 'stop gain', 'mismatch' and 'synonymous' mutations
#' for one mutation context on one strand for one alternative base.
#' @noRd
#'
.calculate_mismatches <- function(alt_base, counts) {

  # These variables use non standard evaluation.
  # To avoid R CMD check complaints we initialize them to NULL.
  n <- NULL

  ref_codons_sum <- Biostrings::DNAStringSet(counts$dna)
  mut_loc_in_codon_sum <- counts$loc

  # Calculate mutated codons.
  mut_codons <- purrr::map2(as.list(ref_codons_sum), mut_loc_in_codon_sum, .mutate_codon, alt_base) %>%
    Biostrings::DNAStringSet()

  # Translate reference codons
  counts$ref_aa <- ref_codons_sum %>%
    Biostrings::translate() %>%
    as.vector()

  # Translate mutated codons
  counts$mut_aa <- mut_codons %>%
    Biostrings::translate() %>%
    as.vector()

  # Identify stop_gain, missense and synonymous mutations
  counts <- counts %>%
    dplyr::mutate(type = dplyr::case_when(
      mut_aa == "*" & ref_aa != "*" ~ "Stop_gain",
      mut_aa != ref_aa ~ "Missense",
      mut_aa == ref_aa ~ "Synonymous"
    ))

  # Count the number of stop_gain, missense and synonymous.
  counts <- counts %>%
    dplyr::mutate(type = factor(type, levels = c("Stop_gain", "Missense", "Synonymous"))) %>%
    dplyr::group_by(type, .drop = FALSE) %>%
    dplyr::summarise(n = sum(n), .groups = "drop_last") %>%
    dplyr::mutate(alt_base = alt_base)

  return(counts)
}


#' Mutate codons with an alternative base
#'
#' @param ref_codon A reference codon
#' @param mut_loc_in_codon The location of the mutation in the codon
#' @param alt_base The alternative base that will be inserted
#'
#' @return A mutated version of the codon
#' @noRd
#'
.mutate_codon <- function(ref_codon, mut_loc_in_codon, alt_base) {
  ref_codon[mut_loc_in_codon] <- alt_base
  return(ref_codon)
}
