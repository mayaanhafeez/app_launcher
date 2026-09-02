import Testing
@testable import OrbitLauncher

// The settings blocks added for the values that used to be compile-time constants,
// plus the two node flags. Absent keys must leave defaults alone — the same contract
// `settingsFallBackToDefaultsForAbsentKeys` asserts for the older blocks.

@Test func tuningBlocksDecode() async {
    let (runtime, load, directory) = await orbitLoadConfig("""
    return {
      ranking = { half_life = 60, weight = 3 },
      search = { app_limit = 5, row_limit = 7, depth = 2, match_detail = false },
      provider_limits = { timeout = 0.5, instructions = 5000, debounce = 0.2 },
      watch = { debounce = 0.3 },
      items = {
        { id = "root", label = "Go" },
        { id = "pinned", label = "Pinned", shell = "brew install {query}", keep = true },
        { id = "quiet", label = "Quiet", shell = "true", hidden = true },
        { id = "plain", label = "Plain", shell = "true" },
      },
    }
    """)
    defer { orbitRemove(directory); _ = runtime }

    #expect(load.settings?.ranking.enabled == true)
    #expect(load.settings?.ranking.halfLife == 60)
    #expect(load.settings?.ranking.weight == 3)

    #expect(load.settings?.search.appLimit == 5)
    #expect(load.settings?.search.rowLimit == 7)
    #expect(load.settings?.search.depth == 2)
    #expect(load.settings?.search.matchDetail == false)

    #expect(load.settings?.providers.timeout == 0.5)
    // Floored: an instruction budget below the hook's own step size would abort every
    // script on its first check.
    #expect(load.settings?.providers.instructions == 10_000)
    #expect(load.settings?.providers.debounce == 0.2)

    #expect(load.settings?.watchDebounce == 0.3)

    #expect(load.node("pinned")?.keep == true)
    #expect(load.node("pinned")?.hidden == false)
    #expect(load.node("quiet")?.hidden == true)
    #expect(load.node("plain")?.keep == false)
    #expect(load.node("plain")?.hidden == false)
}

@Test func rankingFalseSwitchesFrecencyOff() async {
    let (runtime, load, directory) = await orbitLoadConfig("""
    return { ranking = false, items = { { id = "root", label = "Go" } } }
    """)
    defer { orbitRemove(directory); _ = runtime }
    #expect(load.settings?.ranking.enabled == false)
    // The short form must leave the rest of the spec at its defaults, so re-enabling
    // it later does not need every key restated.
    #expect(load.settings?.ranking.weight == RankingSpec().weight)
}

@Test func absentTuningKeysKeepTheirDefaults() async {
    let (runtime, load, directory) = await orbitLoadConfig("""
    return { items = { { id = "root", label = "Go" } } }
    """)
    defer { orbitRemove(directory); _ = runtime }

    #expect(load.settings?.search.appLimit == SearchSpec().appLimit)
    #expect(load.settings?.search.depth == SearchSpec().depth)
    #expect(load.settings?.search.matchDetail == true)
    #expect(load.settings?.providers.timeout == ProviderSpec().timeout)
    #expect(load.settings?.providers.debounce == 0)
    #expect(load.settings?.watchDebounce == 0.08)
    #expect(load.settings?.ranking.enabled == true)
}

@Test func matchDetailNarrowsTheHaystack() {
    let node = MenuNode(id: "one", parent: "root", kind: .action, label: "Network",
                        detail: "Wi-Fi and Ethernet", symbol: "",
                        provider: nil, actionReference: nil, scriptAction: .shell("true"), order: 1)
    #expect(FuzzyMatcher.score("ethernet", in: node.searchText(includingDetail: true)) != nil)
    #expect(FuzzyMatcher.score("ethernet", in: node.searchText(includingDetail: false)) == nil)
}
