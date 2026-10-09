import CoreServices
import Foundation
import Testing
@testable import KitsuneLauncher

// The app index re-scans when the folders it scans change, so an app installed while
// the launcher is resident shows up without a restart, a reload or Spotlight.

private func makeApp(_ name: String, in root: URL) throws {
    let contents = root.appendingPathComponent("\(name).app/Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleName": name, "CFBundleIdentifier": "test.kitsune.\(name)"]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
}

@MainActor
private func waitForApps(_ index: AppIndex, timeout: TimeInterval = 8, _ condition: ([String]) -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition(index.entries.map(\.name)) { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition(index.entries.map(\.name))
}

private func relevant(_ path: String, depth: Int = 3, flags: Int = 0) -> Bool {
    AppRootWatcher.isRelevant(path: path, flags: FSEventStreamEventFlags(flags), roots: ["/Applications"], depth: depth)
}

@Test func anAppArrivingOrLeavingARootIsRelevant() {
    #expect(relevant("/Applications/OpenCode.app"))
    #expect(relevant("/Applications/OpenCode.app/Contents"))
    #expect(relevant("/Applications/OpenCode.app/Contents/Info.plist"))
    #expect(relevant("/Applications/Utilities/Thing.app"))
    // A folder renamed or removed takes every app below it along.
    #expect(relevant("/Applications/Games"))
    #expect(relevant("/Applications"))
}

@Test func writesInsideABundleAreNotRelevant() {
    // An app updating its own resources changes nothing the index shows.
    #expect(!relevant("/Applications/Safari.app/Contents/Resources/en.lproj/Localizable.strings"))
    #expect(!relevant("/Applications/Xcode.app/Contents/Developer/Tool.app"))
    #expect(!relevant("/Applications/Safari.app/Contents/MacOS/Safari"))
}

@Test func hiddenEntriesAndOtherTreesAreNotRelevant() {
    #expect(!relevant("/Applications/.DS_Store"))
    #expect(!relevant("/Applications/.Hidden/Thing.app"))
    #expect(!relevant("/ApplicationsElsewhere/Thing.app"))
    #expect(!relevant("/Users/someone/Downloads/Thing.app"))
}

@Test func relevanceStopsAtTheScanDepth() {
    #expect(relevant("/Applications/a/b/Deep.app", depth: 3))
    #expect(!relevant("/Applications/a/b/c/Deeper.app", depth: 3))
    // A directory at the depth is never descended, so nothing inside it can be indexed.
    #expect(!relevant("/Applications/a/b/c", depth: 3))
}

@Test func droppedEventsForceARescan() {
    #expect(relevant("/Applications/Safari.app/Contents/MacOS/Safari", flags: kFSEventStreamEventFlagMustScanSubDirs))
    #expect(relevant("/Elsewhere", flags: kFSEventStreamEventFlagKernelDropped))
}

@MainActor
@Test func anAppInstalledAfterLaunchIsIndexedWithoutAReload() async throws {
    let root = kitsuneTemporaryDirectory("kitsune-apps")
    defer { kitsuneRemove(root) }
    try makeApp("Before", in: root)

    let index = AppIndex(baseRoots: [root], watchDebounce: 0.1)
    index.refresh()
    #expect(await waitForApps(index) { $0 == ["Before"] })
    // FSEvents only reports what happens after the stream starts.
    try? await Task.sleep(nanoseconds: 300_000_000)

    try makeApp("Installed", in: root)
    #expect(await waitForApps(index) { $0 == ["Before", "Installed"] })

    kitsuneRemove(root.appendingPathComponent("Before.app"))
    #expect(await waitForApps(index) { $0 == ["Installed"] })

    // The plist keeps naming it "Installed", so the path is what shows the rename.
    try FileManager.default.moveItem(at: root.appendingPathComponent("Installed.app"),
                                     to: root.appendingPathComponent("Renamed.app"))
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline, !index.entries.contains(where: { $0.path.hasSuffix("/Renamed.app") }) {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(index.entries.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["Renamed.app"])
}

@MainActor
@Test func writesInsideAnInstalledBundleDoNotRescan() async throws {
    let root = kitsuneTemporaryDirectory("kitsune-apps")
    defer { kitsuneRemove(root) }
    try makeApp("Quiet", in: root)

    let index = AppIndex(baseRoots: [root], watchDebounce: 0.1)
    let scans = Locked(0)
    index.onChange = { scans.value += 1 }
    index.refresh()
    #expect(await waitForApps(index) { $0 == ["Quiet"] })
    // Creating the bundle just before the stream started can still arrive in its first
    // batch, which FSEvents holds for `latency`; let that flush and rescan first.
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    let settled = scans.value

    let resources = root.appendingPathComponent("Quiet.app/Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try "x".write(to: resources.appendingPathComponent("cache.bin"), atomically: false, encoding: .utf8)
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    #expect(scans.value == settled)
}

@MainActor
@Test func aRootCreatedAfterLaunchIsWatched() async throws {
    // `~/Applications` does not exist on every Mac, and is created by the first thing
    // that installs into it.
    let parent = kitsuneTemporaryDirectory("kitsune-apps")
    defer { kitsuneRemove(parent) }
    let root = parent.appendingPathComponent("Applications")

    let index = AppIndex(baseRoots: [root], watchDebounce: 0.1)
    index.refresh()
    try? await Task.sleep(nanoseconds: 300_000_000)

    try makeApp("Late", in: root)
    #expect(await waitForApps(index) { $0 == ["Late"] })
}
