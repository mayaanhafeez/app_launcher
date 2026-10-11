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

@Test func aMissingRootUnderASymlinkResolvesThroughItsAncestor() throws {
    let parent = kitsuneTemporaryDirectory("kitsune-apps")
    defer { kitsuneRemove(parent) }
    let real = parent.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let link = parent.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    let resolvedReal = AppRootWatcher.resolve(real.path)
    #expect(AppRootWatcher.resolve(link.path) == resolvedReal)
    #expect(AppRootWatcher.resolve(link.appendingPathComponent("Apps/More").path) == resolvedReal + "/Apps/More")
}

@Test func aBundleWithoutAnInfoPlistIsNotAnAppYet() throws {
    let root = kitsuneTemporaryDirectory("kitsune-apps")
    defer { kitsuneRemove(root) }
    // A failed copy's leftovers, and a drag install caught before its plist lands.
    let empty = root.appendingPathComponent("Empty.app")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let partial = root.appendingPathComponent("Partial.app/Contents")
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try "<?xml version=\"1.0\"?><plist><dict><key>CFBundleName</key>".write(
        to: partial.appendingPathComponent("Info.plist"), atomically: false, encoding: .utf8)

    #expect(AppIndex.entryForAudit(path: empty.path) == nil)
    #expect(AppIndex.entryForAudit(path: root.appendingPathComponent("Partial.app").path) == nil)

    try makeApp("Partial", in: root)
    #expect(AppIndex.entryForAudit(path: root.appendingPathComponent("Partial.app").path)?.name == "Partial")
}

@Test func aWrappedIOSAppIsStillAnApp() throws {
    // iOS apps on Apple Silicon have no `Contents`; the real bundle sits under `Wrapper`.
    let root = kitsuneTemporaryDirectory("kitsune-apps")
    defer { kitsuneRemove(root) }
    let app = root.appendingPathComponent("Phone.app")
    let inner = app.appendingPathComponent("Wrapper/Phone.app")
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleDisplayName": "My Phone", "CFBundleIdentifier": "test.kitsune.phone"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: inner.appendingPathComponent("Info.plist"))
    try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("WrappedBundle").path,
                                               withDestinationPath: "Wrapper/Phone.app")
    // Named and identified from the wrapped bundle's own plist, not the folder name.
    let entry = AppIndex.entryForAudit(path: app.path)
    #expect(entry?.name == "My Phone")
    #expect(entry?.id == "test.kitsune.phone")
    // The link can land after the directory; that has to re-scan like a plist write.
    #expect(relevant("/Applications/Phone.app/WrappedBundle"))
}

@Test func appsUnderASymlinkedRootKeepThePathTheConfigWrote() throws {
    let parent = kitsuneTemporaryDirectory("kitsune-apps")
    defer { kitsuneRemove(parent) }
    let real = parent.appendingPathComponent("real")
    try makeApp("Inside", in: real.appendingPathComponent("Apps"))
    let link = parent.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    // A root under a link reported the real directory, and a root that *is* the link
    // listed nothing at all.
    #expect(AppIndex.appPaths(in: [link.appendingPathComponent("Apps")], depth: 3)
        == [link.appendingPathComponent("Apps/Inside.app").path])
    #expect(AppIndex.appPaths(in: [link], depth: 3) == [link.appendingPathComponent("Apps/Inside.app").path])
    // Standardizing would have reported a `/private/tmp` root as `/tmp`.
    let spelled = URL(fileURLWithPath: AppRootWatcher.resolve(link.path))
    #expect(AppIndex.appPaths(in: [spelled], depth: 3) == [spelled.appendingPathComponent("Apps/Inside.app").path])
}
