import AppKit
import Testing
@testable import OrbitLauncher

// Frecency ranking. The store itself is pure arithmetic over count and age, and the
// controller only ever applies it to a *searched* list — an empty query keeps the
// order the config author wrote.

@MainActor
private func rankingController() -> MenuController {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "one", parent: "root", kind: .action, label: "Terminal", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: .url(""), order: 1),
        MenuNode(id: "two", parent: "root", kind: .action, label: "Terminal Theme", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: .url(""), order: 2),
    ]
    return controller
}

@MainActor
@Test func frecencyPromotesAPreviouslyActivatedRow() {
    let controller = rankingController()
    var labels: [String] = []
    controller.onRows = { _, rows in labels = rows.map(\.label) }
    controller.open(route: "root")

    // Both match "terminal" identically, so the tie breaks on the label.
    controller.update(query: "terminal")
    #expect(labels == ["Terminal", "Terminal Theme"])

    // A weight far above any fuzzy score isolates the wiring: this asserts that the
    // discount reaches the sort at all, not the shape of the curve, which is covered
    // on the store directly below.
    controller.usage.spec.weight = 100
    controller.usage.record("two")
    controller.update(query: "terminal")
    #expect(labels == ["Terminal Theme", "Terminal"])
}

@MainActor
@Test func frecencyLeavesTheAuthoredOrderAlone() {
    let controller = rankingController()
    var labels: [String] = []
    controller.onRows = { _, rows in labels = rows.map(\.label) }
    controller.usage.spec.weight = 100
    controller.usage.record("two")

    // No query: `order` is the config author's deliberate statement about the shape
    // of this menu, and frecency has no business rearranging it.
    controller.open(route: "root")
    #expect(labels == ["Terminal", "Terminal Theme"])
}

@MainActor
@Test func activationRecordsUsage() {
    let controller = rankingController()
    controller.usage.spec.weight = 100
    #expect(controller.usage.bonus(for: "one") == 0)
    controller.activate(DisplayRow(id: "one", kind: .action, label: "Terminal", detail: "", symbol: "", image: nil, score: 0, section: "current"))
    #expect(controller.usage.bonus(for: "one") > 0)
}

@MainActor
@Test func backRowIsNotAUse() {
    let controller = rankingController()
    controller.activate(DisplayRow(id: "orbit.back", kind: .back, label: "Back", detail: "", symbol: "", image: nil, score: -1, section: "back"))
    #expect(controller.usage.bonus(for: "orbit.back") == 0)
}

@MainActor
@Test func usageBonusGrowsWithCountAndDecaysWithAge() {
    let store = UsageStore(url: nil)
    let now = Date()
    #expect(store.bonus(for: "never-used", now: now) == 0)

    store.record("a", now: now)
    let once = store.bonus(for: "a", now: now)
    #expect(once > 0)

    // Frequency enters logarithmically: more uses rank higher, but not without limit.
    for _ in 0..<8 { store.record("a", now: now) }
    let often = store.bonus(for: "a", now: now)
    #expect(often > once)

    // One half-life later the same record is worth materially less.
    let aged = store.bonus(for: "a", now: now.addingTimeInterval(store.spec.halfLife))
    #expect(aged < often)
    #expect(aged > 0)

    // Far enough out it stops mattering at all.
    #expect(store.bonus(for: "a", now: now.addingTimeInterval(store.spec.halfLife * 40)) == 0)
}

@MainActor
@Test func disabledRankingRecordsAndScoresNothing() {
    let store = UsageStore(url: nil)
    store.spec.enabled = false
    store.record("a")
    #expect(store.bonus(for: "a") == 0)

    // Re-enabling must not surface uses that were never recorded.
    store.spec.enabled = true
    #expect(store.bonus(for: "a") == 0)
}

@MainActor
@Test func usageRoundTripsThroughItsFile() async {
    let directory = orbitTemporaryDirectory("orbit-usage")
    defer { orbitRemove(directory) }
    let url = directory.appendingPathComponent("usage.json")

    let store = UsageStore(url: url)
    store.record("a")
    // The flush is deliberately debounced off the activation path, so this waits for
    // the write rather than assuming it already happened.
    _ = await orbitWaitUntil(timeout: 10) { FileManager.default.fileExists(atPath: url.path) }
    #expect(FileManager.default.fileExists(atPath: url.path))

    #expect(UsageStore(url: url).bonus(for: "a") > 0)
}

@MainActor
@Test func aMemoryOnlyStoreWritesNothing() async {
    // The default `MenuController` store is memory-only precisely so a test run can
    // neither read nor overwrite the developer's real usage data.
    let directory = orbitTemporaryDirectory("orbit-usage-none")
    defer { orbitRemove(directory) }
    let store = UsageStore(url: nil)
    store.record("a")
    #expect(store.bonus(for: "a") > 0)
    #expect(try! FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}
