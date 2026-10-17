import Foundation
import Testing
@testable import KitsuneLauncher

/// A bundle `makeEntry` accepts: a `.app` directory with an Info.plist naming it.
func kitsuneMakeApp(_ name: String, in root: URL) throws {
    let contents = root.appendingPathComponent("\(name).app/Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleName": name, "CFBundleIdentifier": "test.kitsune.\(name)"]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
}

/// The scan runs on a background queue and lands on the main actor, so the index is
/// polled from there — `kitsuneWaitUntil` takes a `@Sendable` closure that cannot read it.
@MainActor
func kitsuneWaitForApps(_ index: AppIndex, timeout: TimeInterval = 5, _ condition: ([String]) -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition(index.entries.map(\.name)) { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition(index.entries.map(\.name))
}

@MainActor
@Test func refreshPicksUpAnAppInstalledAfterTheFirstScan() async throws {
    let root = kitsuneTemporaryDirectory("kitsune-apps")
    defer { kitsuneRemove(root) }
    try kitsuneMakeApp("Before", in: root)

    let index = AppIndex(baseRoots: [root])
    index.refresh()
    #expect(await kitsuneWaitForApps(index) { $0 == ["Before"] })

    try kitsuneMakeApp("After", in: root)
    // An unchanged spec is exactly the case `apply(scan:)` ignores, and the reason a
    // reload has to force the scan.
    index.apply(scan: AppScanSpec())
    try? await Task.sleep(nanoseconds: 200_000_000)
    #expect(index.entries.map(\.name) == ["Before"])

    index.refresh()
    #expect(await kitsuneWaitForApps(index) { $0 == ["After", "Before"] })
}

@MainActor
@Test func refreshDropsAnAppDeletedAfterTheFirstScan() async throws {
    let root = kitsuneTemporaryDirectory("kitsune-apps")
    defer { kitsuneRemove(root) }
    try kitsuneMakeApp("Kept", in: root)
    try kitsuneMakeApp("Gone", in: root)

    let index = AppIndex(baseRoots: [root])
    index.refresh()
    #expect(await kitsuneWaitForApps(index) { $0.count == 2 })

    kitsuneRemove(root.appendingPathComponent("Gone.app"))
    index.refresh()
    #expect(await kitsuneWaitForApps(index) { $0 == ["Kept"] })
}
