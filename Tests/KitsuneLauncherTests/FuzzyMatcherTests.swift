import Testing
@testable import KitsuneLauncher

@Test func fuzzyMatching() {
    #expect(FuzzyMatcher.score("sfr", in: "Safari") != nil)
    #expect(FuzzyMatcher.score("xyz", in: "Safari") == nil)
    #expect(FuzzyMatcher.score("saf", in: "Safari")! < FuzzyMatcher.score("sfr", in: "Safari")!)
}

/// The scoring rule exactly as it was before `FuzzyMatcher.Query` existed: one fold per
/// call, `[Character]` throughout, no ASCII path. Kept here as the reference the
/// optimised implementation is checked against — a faster matcher that ranks differently
/// is a behaviour change, not an optimisation.
private func referenceScore(_ query: String, in candidate: String) -> Int? {
    let needle = Array(query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current))
    if needle.isEmpty { return 0 }
    let haystack = Array(candidate.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current))
    var position = 0
    var score = 0
    var previous = -2
    for character in needle {
        guard let found = haystack[position...].firstIndex(of: character) else { return nil }
        let index = found
        score += index == previous + 1 ? 1 : 8 + index - position
        if index == 0 || " /._-".contains(haystack[max(0, index - 1)]) { score -= 5 }
        previous = index
        position = index + 1
    }
    return max(0, score + haystack.count / 12)
}

@Test func preparedQueryMatchesTheReferenceScoring() {
    let candidates = [
        "Safari", "Google Chrome", "Visual Studio Code", "System Settings",
        "com.apple.Displays-Settings.extension", "~/dev/app_launcher/README.md",
        "Privacy & Security", "a", "", "  spaced  out  ", "UPPER_CASE-name.ext",
        // Non-ASCII on both sides: these must fall back to the character path, where
        // folding can change length as well as content.
        "Café Münster", "naïve résumé", "Ø slash", "日本語のアプリ", "Ünïcödé",
    ]
    let queries = [
        "", "a", "s", "sf", "saf", "sfr", "chr", "code", "xyz", "zzz", "  ", "-", ".",
        "settings", "SETTINGS", "SeTtInGs", "café", "cafe", "münster", "munster",
        "日本", "ünï", "readme", "md", "app_launcher", "privacy security",
    ]
    for query in queries {
        for candidate in candidates {
            #expect(FuzzyMatcher.score(query, in: candidate) == referenceScore(query, in: candidate),
                    "query \(query.debugDescription) against \(candidate.debugDescription)")
        }
    }
}

@Test func preparedQueryIsReusableAcrossCandidates() {
    // The whole point of the type: build once, apply many times, same answers.
    let needle = FuzzyMatcher.Query("sfr")
    for candidate in ["Safari", "Software Refresh", "nope", "SaFaRi"] {
        #expect(needle.score(in: candidate) == referenceScore("sfr", in: candidate))
    }
    #expect(FuzzyMatcher.Query("").isEmpty)
    #expect(FuzzyMatcher.Query("").score(in: "anything") == 0)
}

@Test func startsWordsNeedsEachQueryWordToBeginAWordInOrder() {
    #expect(FuzzyMatcher.Query("dia").startsWords(in: "Dia  company.thebrowser.dia"))
    #expect(FuzzyMatcher.Query("sys set").startsWords(in: "System Settings"))
    #expect(FuzzyMatcher.Query("wi-fi").startsWords(in: "Wi-Fi  wifi"))
    #expect(FuzzyMatcher.Query("café").startsWords(in: "Le Café Münster"))
    #expect(FuzzyMatcher.Query("").startsWords(in: "anything"))
    // A substring inside a word, and letters strung across words, are not.
    #expect(!FuzzyMatcher.Query("dia").startsWords(in: "Obsidian md.obsidian"))
    #expect(!FuzzyMatcher.Query("dia").startsWords(in: "Clipboard clipboard clip history"))
    // In order, and one word per query word: `set` here is only inside `Reset`.
    #expect(!FuzzyMatcher.Query("net set").startsWords(in: "Settings Network Reset"))
    #expect(!FuzzyMatcher.Query("new new").startsWords(in: "New Menu"))
}

@Test func frecencyOnlyDiscountsAMatchThatStartsWords() {
    let needle = FuzzyMatcher.Query("dia")
    // No usage: exactly the fuzzy score, whatever the match shape.
    #expect(needle.rank(in: "Xdiax") { 0 } == needle.score(in: "Xdiax"))
    // A strung match is never discounted, at any weight.
    let strung = "Clipboard clipboard clip history"
    #expect(needle.rank(in: strung) { 10_000_000 } == needle.score(in: strung))
    #expect(needle.rank(in: "Dia") { 0 }! < needle.rank(in: strung) { 10_000_000 }!)
    // A word-prefix match still is, and that is what lets frecency reorder them.
    #expect(needle.rank(in: "Dia Browser") { 50 }! < needle.rank(in: "Dia") { 0 }!)
    // The bonus is not even asked for on a miss.
    var asked = false
    #expect(needle.rank(in: "zzz") { asked = true; return 1 } == nil)
    #expect(!asked)
}
