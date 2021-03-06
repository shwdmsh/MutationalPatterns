#' Potential damage analysis for the supplied mutational signatures
#'
#' The ratio of possible 'stop gain', 'mismatches' and 'synonymous mutations' is
#' counted per signature. Normalized ratios are also given. These were calculated
#' by dividing the ratios in each signature, by the ratios of a completely "flat"
#' signature. A normalized ratio of 2 for "stop gain" mutations, means that a
#' signature is twice as likely to cause "stop gain" mutations, compared to a
#' completely random "flat" signature. N is the number of possible mutations per
#' context, multiplied by the signature contribution per context, summed over all
#' contexts.
#'
#' The function uses a tibble with the ratio of 'stop gain', 'mismatch' and 'synonymous' mutations
#' per mutation context as its input. For each signature these ratios are linearly combined based
#' on the signature weights. They are then divided by a "flat" signature to get the normalized
#' ratios.
#'
#'
#' @param signatures Matrix containing signatures
#' @param contexts Vector of mutational contexts to use for the analysis.
#' @param context_mismatches A tibble with the ratio of 'stop gain', 'mismatch' and 'synonymous' mutations
#' per mutation context.
#'
#' @return A tibble with the ratio of 'stop gain', 'mismatch' and 'synonymous' mutations
#' per signature.
#' @export
#'
#' @examples
#'
#' ## Get the signatures
#' signatures <- get_known_signatures()
#'
#' ## See the 'mut_matrix()' example for how we obtained the
#' ## mutation matrix information:
#' mut_mat <- readRDS(system.file("states/mut_mat_data.rds",
#'   package = "MutationalPatterns"
#' ))
#'
#' contexts <- rownames(mut_mat)
#'
#' ## See the 'context_potential_damage_analysis()' example for how we obtained the
#' ## context_mismatches:
#' context_mismatches <- readRDS(system.file("states/context_mismatches.rds",
#'   package = "MutationalPatterns"
#' ))
#'
#' ## Determine the potential damage per signature
#' signature_potential_damage_analysis(signatures, contexts, context_mismatches)
signature_potential_damage_analysis <- function(signatures, contexts, context_mismatches) {

  # These variables use non standard evaluation.
  # To avoid R CMD check complaints we initialize them to NULL.
  context <- ratio <- contribution <- sig <- flat <- n <- NULL
  ratio_by_background <- NULL

  # Add context to signature matrix
  signatures <- as.data.frame(signatures)
  signatures$context <- contexts

  # Add flat background signature
  nr_features <- nrow(signatures)
  signatures$flat_background <- rep(1 / nr_features, nr_features)


  # Combine signatures and context_mismatches and make long.
  sig_context_mismatch <- signatures %>%
    dplyr::full_join(context_mismatches, by = "context") %>%
    tidyr::pivot_longer(cols = c(-context, -type, -ratio, -n), names_to = "sig", values_to = "contribution")

  # Combine weighted contexts per signature and mutation type
  sig_mismatch <- sig_context_mismatch %>%
    dplyr::mutate(ratio = contribution * ratio, n = contribution * n) %>%
    dplyr::group_by(type, sig) %>%
    dplyr::summarise(n = sum(n), ratio = sum(ratio), .groups = "drop_last") %>%
    dplyr::ungroup()

  # Get flat signature to serve as background
  flat_sig <- sig_mismatch %>%
    dplyr::filter(sig == "flat_background") %>%
    dplyr::select(type, flat = ratio)

  # Normalize against the flat background signature
  norm_sig_mismatch <- sig_mismatch %>%
    dplyr::full_join(flat_sig, by = "type") %>%
    dplyr::mutate(ratio_by_background = ratio / flat) %>%
    dplyr::select(type, sig, ratio, ratio_by_background, n) %>%
    dplyr::filter(sig != "flat_background") %>%
    dplyr::arrange(sig)

  return(norm_sig_mismatch)
}
