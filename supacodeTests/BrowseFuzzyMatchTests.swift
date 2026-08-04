import Testing

@testable import supacode

@Suite struct BrowseFuzzyMatchTests {
  @Test func matchesCharactersInOrderAcrossTheWholeRelativePath() {
    #expect(BrowseFuzzyMatch.matches(path: "code/supacode", query: "co/sup"))
    #expect(BrowseFuzzyMatch.matches(path: "code/supacode", query: "code supa"))
    #expect(BrowseFuzzyMatch.matches(path: "code/supacode", query: "csup"))
    // Out of order is not a match, however many characters are present.
    #expect(!BrowseFuzzyMatch.matches(path: "code/supacode", query: "supcode/"))
    #expect(!BrowseFuzzyMatch.matches(path: "code/supacode", query: "zsup"))
  }

  @Test func matchingIsCaseInsensitiveAndIgnoresQueryWhitespace() {
    #expect(BrowseFuzzyMatch.matches(path: "Code/SupaCode", query: " CO sup "))
    #expect(BrowseFuzzyMatch.score(path: "code", query: "   ") == nil)
    #expect(BrowseFuzzyMatch.score(path: "code", query: "") == nil)
  }

  @Test func segmentBoundaryMatchesRankAboveMidWordMatches() {
    let ranked = BrowseFuzzyMatch.ranked(
      ["my-project-supacode", "supacode", "unsupported"],
      query: "sup",
      path: { $0 }
    )

    // `supacode` starts on the whole path, `my-project-supacode` on a word boundary,
    // and `unsupported` matches mid-word.
    #expect(ranked == ["supacode", "my-project-supacode", "unsupported"])
  }

  @Test func shallowerPathsRankAboveDeeperOnesOnTies() {
    let ranked = BrowseFuzzyMatch.ranked(
      ["nest/deeper/supacode", "nest/supacode", "supacode"],
      query: "supacode",
      path: { $0 }
    )

    #expect(ranked == ["supacode", "nest/supacode", "nest/deeper/supacode"])
  }

  @Test func contiguousRunsRankAboveScatteredMatches() {
    let ranked = BrowseFuzzyMatch.ranked(
      ["s-u-p-a", "supa"],
      query: "supa",
      path: { $0 }
    )

    #expect(ranked == ["supa", "s-u-p-a"])
  }

  @Test func equalScoresKeepTheirIncomingOrder() {
    let ranked = BrowseFuzzyMatch.ranked(
      ["target-beta", "target-alpha"],
      query: "target",
      path: { $0 }
    )

    #expect(ranked == ["target-beta", "target-alpha"])
  }

  @Test func rankedDropsNonMatches() {
    let ranked = BrowseFuzzyMatch.ranked(["supacode", "unrelated"], query: "sup", path: { $0 })

    #expect(ranked == ["supacode"])
  }
}
