import Foundation

/// Scores extraction output against a labeled replay corpus. This is the
/// Phase 0 measurement instrument: it turns "extraction feels noisy" into
/// precision/recall/grounding numbers that gate whether the inbox UI is worth
/// building (principle 3, "extraction is the product").
///
/// No fake confidence: every number is a plain count ratio derived from human
/// labels, reported alongside the raw confusion counts.
nonisolated struct ExtractionScorecard: Sendable, Equatable {
  /// True positives: an attention moment was expected and a candidate of the
  /// expected kind (when specified) was produced.
  let truePositives: Int
  /// False positives: a candidate was produced where none was expected.
  let falsePositives: Int
  /// False negatives: an expected attention moment produced no candidate.
  let falseNegatives: Int
  /// True negatives: correctly produced no candidate for a non-attention event.
  let trueNegatives: Int
  /// Produced a candidate for an expected moment but of the wrong kind.
  let kindMismatches: Int

  /// Candidates produced with at least one evidence reference.
  let groundedCandidates: Int
  /// Candidates produced that a human could resolve from the inbox.
  let actionableCandidates: Int
  /// Total candidates produced across the scored corpora.
  let totalCandidates: Int

  var precision: Double {
    let denominator = truePositives + falsePositives
    return denominator == 0 ? 1 : Double(truePositives) / Double(denominator)
  }

  var recall: Double {
    let denominator = truePositives + falseNegatives
    return denominator == 0 ? 1 : Double(truePositives) / Double(denominator)
  }

  var grounding: Double {
    totalCandidates == 0 ? 1 : Double(groundedCandidates) / Double(totalCandidates)
  }

  var actionability: Double {
    totalCandidates == 0 ? 1 : Double(actionableCandidates) / Double(totalCandidates)
  }

  /// Score one corpus given the engine's extracted candidates for it.
  static func score(
    corpus: ReplayCorpus,
    candidates: [AttentionCandidate]
  ) -> ExtractionScorecard {
    score(corpora: [(corpus, candidates)])
  }

  /// Score across many corpora, summing confusion counts.
  static func score(
    corpora: [(corpus: ReplayCorpus, candidates: [AttentionCandidate])]
  ) -> ExtractionScorecard {
    var truePos = 0
    var falsePos = 0
    var falseNeg = 0
    var trueNeg = 0
    var mismatch = 0
    var grounded = 0
    var actionable = 0
    var total = 0

    for (corpus, candidates) in corpora {
      let candidateByID = Dictionary(
        candidates.map { ($0.sourceEventID, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      total += candidates.count
      grounded += candidates.filter(\.isGrounded).count
      actionable += candidates.filter(\.isActionable).count

      var scoredIDs: Set<String> = []
      for event in corpus.events {
        guard let label = event.label else { continue }
        guard scoredIDs.insert(event.sourceEventID).inserted else { continue }
        let candidate = candidateByID[event.sourceEventID]

        switch (label.attentionExpected, candidate) {
        case (true, let candidate?):
          if let expected = label.expectedKind, candidate.kind != expected {
            mismatch += 1
            falseNeg += 1
          } else {
            truePos += 1
          }
        case (true, nil):
          falseNeg += 1
        case (false, .some):
          falsePos += 1
        case (false, nil):
          trueNeg += 1
        }
      }
    }

    return ExtractionScorecard(
      truePositives: truePos,
      falsePositives: falsePos,
      falseNegatives: falseNeg,
      trueNegatives: trueNeg,
      kindMismatches: mismatch,
      groundedCandidates: grounded,
      actionableCandidates: actionable,
      totalCandidates: total
    )
  }

  /// A plain-text debug report suitable for a CLI or test log, showing metrics
  /// beside the raw counts they come from.
  func report() -> String {
    func pct(_ value: Double) -> String {
      "\(Int((value * 100).rounded()))%"
    }
    return """
      Extraction scorecard
      --------------------
      Precision:     \(pct(precision))  (TP \(truePositives) of \(truePositives + falsePositives) promoted)
      Recall:        \(pct(recall))  (TP \(truePositives) of \(truePositives + falseNegatives) expected)
      Grounding:     \(pct(grounding))  (\(groundedCandidates)/\(totalCandidates) candidates cite evidence)
      Actionability: \(pct(actionability))  (\(actionableCandidates)/\(totalCandidates) resolvable in inbox)
      Confusion:     TP \(truePositives) FP \(falsePositives) FN \(falseNegatives)
                     TN \(trueNegatives) miss \(kindMismatches)
      """
  }
}
