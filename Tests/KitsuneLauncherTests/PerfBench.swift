import AppKit
import Testing
@testable import KitsuneLauncher

// Stopwatches, not assertions. Gated behind KITSUNE_BENCH because they are CPU-bound
// and long enough to starve the rest of the suite: run in parallel with everything else
// they pushed a timing-sensitive IPC test over its deadline, which is a flaky suite
// caused entirely by measurement. Run them deliberately:
//
//   KITSUNE_BENCH=1 swift test -c release --filter benchmark
//
// Release matters — generics specialise there, and the debug numbers invert.
private let benchmarksEnabled = ProcessInfo.processInfo.environment["KITSUNE_BENCH"] != nil
@MainActor
private func benchNodes(count: Int) -> [MenuNode] {
    var nodes: [MenuNode] = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
    ]
    // A realistic shape: ~25 top-level menus, each with children two deep, which is
    // what the shipped config plus the settings tree actually looks like.
    var order = 1
    for group in 0..<25 {
        nodes.append(MenuNode(id: "g\(group)", parent: "root", kind: .menu, label: "Group \(group)", detail: "", symbol: "gear", provider: nil, actionReference: nil, scriptAction: nil, order: order)); order += 1
        for child in 0..<((count - 26) / 25) {
            nodes.append(MenuNode(id: "g\(group).c\(child)", parent: "g\(group)", kind: .action, label: "Child \(group)-\(child) chrome settings", detail: "some detail text", symbol: "doc", provider: nil, actionReference: nil, scriptAction: .url(""), order: order)); order += 1
        }
    }
    return nodes
}

@MainActor
@Test(.enabled(if: benchmarksEnabled)) func benchmarkRootQuery() {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.nodes = benchNodes(count: 251)
    print("nodes: \(controller.nodes.count)")

    for (name, query) in [("empty", ""), ("one char 'c'", "c"), ("three 'chr'", "chr"), ("miss 'zzz'", "zzz")] {
        // Warm up, then time a run long enough to swamp the clock's resolution.
        for _ in 0..<50 { _ = controller.rows(route: "root", query: query) }
        let start = Date()
        let iterations = 500
        for _ in 0..<iterations { _ = controller.rows(route: "root", query: query) }
        let each = Date().timeIntervalSince(start) / Double(iterations) * 1000
        let rows = controller.rows(route: "root", query: query).rows.count
        print(String(format: "  %-14s %7.3f ms/build   (%d rows)", (name as NSString).utf8String!, each, rows))
    }
}

@MainActor
@Test(.enabled(if: benchmarksEnabled)) func benchmarkSymbolLookup() {
    // Panel.swift builds an SF Symbol image inside `configure`, so this runs once per
    // visible row per reload. Worth caching only if it actually costs something.
    let names = ["gear", "doc", "wifi", "hand.raised", "keyboard", "person.crop.circle",
                 "cpu", "magnifyingglass", "bolt", "paintpalette"]
    for name in names { _ = NSImage(systemSymbolName: name, accessibilityDescription: nil) }
    let iterations = 2000
    let start = Date()
    for index in 0..<iterations {
        _ = NSImage(systemSymbolName: names[index % names.count], accessibilityDescription: nil)
    }
    let each = Date().timeIntervalSince(start) / Double(iterations) * 1_000_000
    print(String(format: "  NSImage(systemSymbolName:) %.1f us/call  -> %.3f ms for 20 visible rows",
                 each, each * 20 / 1000))
}

/// Scan cost: the new plist path reads more files per app (Info.plist, then possibly a
/// .strings or a whole multi-locale .loctable), so it has to be checked against the
/// Bundle path it replaced rather than assumed cheaper.
@MainActor
@Test(.enabled(if: benchmarksEnabled)) func benchmarkScanCost() {
    let paths = AppIndex.appPaths(in: AppIndex.defaultRoots, depth: 3)

    var start = Date()
    for path in paths {
        let url = URL(fileURLWithPath: path)
        let bundle = Bundle(url: url)
        _ = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        _ = bundle?.bundleIdentifier
    }
    let bundleMs = Date().timeIntervalSince(start) * 1000

    // Bundles are cached process-wide, so a second pass would measure nothing; the new
    // path caches nothing and is timed as-is.
    start = Date()
    for path in paths { _ = AppIndex.entryForAudit(path: path) }
    let plistMs = Date().timeIntervalSince(start) * 1000

    print(String(format: "  %d apps: Bundle path %.0f ms (cold, includes icons: no) | plist path %.0f ms (metadata only; icons lazy)",
                  paths.count, bundleMs, plistMs))
}

/// `results(for:)` now decodes icons for the rows it returns, on the main thread, while
/// the user types. The bounded cache makes a repeat query cheap; the question is what a
/// *new* query costs when its rows are not in the cache yet.
@MainActor
@Test(.enabled(if: benchmarksEnabled)) func benchmarkAppResultsIconCost() async {
    let index = AppIndex()
    index.start()
    let ready = Locked<Bool>(false)
    index.onChange = { ready.value = true }
    _ = await kitsuneWaitUntil(timeout: 30) { ready.value }
    print("  index: \(index.entries.count) apps")

    // Distinct single letters, so each query returns a largely different row set and
    // walks past the 64-entry cache the way real typing across sessions would.
    let queries = "abcdefghijklmnopqrstuvwxyz".map(String.init)

    var coldTotal = 0.0
    for query in queries {
        let start = Date()
        _ = index.results(for: query, limit: 40)
        coldTotal += Date().timeIntervalSince(start) * 1000
    }
    var warmTotal = 0.0
    for query in queries {
        let start = Date()
        _ = index.results(for: query, limit: 40)
        warmTotal += Date().timeIntervalSince(start) * 1000
    }
    print(String(format: "  first pass  %.2f ms/query   second pass %.2f ms/query  (26 queries, limit 40)",
                 coldTotal / 26, warmTotal / 26))

    // The fairest case for the cache: typing one word, where each keystroke's rows are
    // a subset of the last and everything is already hot.
    for _ in 0..<3 { _ = index.results(for: "chr", limit: 40) }
    var hotTotal = 0.0
    for _ in 0..<200 {
        let start = Date()
        _ = index.results(for: "chr", limit: 40)
        hotTotal += Date().timeIntervalSince(start) * 1000
    }
    print(String(format: "  fully warm, same query: %.3f ms/query", hotTotal / 200))

    // The pathological case: the full apps list, which is what `show apps` draws.
    let start = Date()
    _ = index.results(for: "", limit: index.entries.count)
    print(String(format: "  full list (%d rows, cold-ish): %.1f ms", index.entries.count,
                 Date().timeIntervalSince(start) * 1000))
}
