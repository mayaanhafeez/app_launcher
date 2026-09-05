import Testing
@testable import KitsuneLauncher

@Test func fuzzyMatching() {
    #expect(FuzzyMatcher.score("sfr", in: "Safari") != nil)
    #expect(FuzzyMatcher.score("xyz", in: "Safari") == nil)
    #expect(FuzzyMatcher.score("saf", in: "Safari")! < FuzzyMatcher.score("sfr", in: "Safari")!)
}
