import Foundation
import Testing
@testable import KitsuneLauncher

// The saves a config watcher has to notice. A directory vnode event only fires when
// an entry is added, removed or renamed, so a directory-only watch misses an editor
// that writes in place — which is most of them, and all of `cat > config.lua`.

private func startedWatcher(
    in directory: URL,
    filenames: [String] = ["config.lua", "theme.lua"],
    watchesDirectory: Bool = true
) throws -> (watcher: ConfigWatcher, changes: Locked<Int>) {
    let changes = Locked(0)
    let watcher = ConfigWatcher(directory: directory, filenames: filenames, watchesDirectory: watchesDirectory)
    watcher.onChange = { changes.value += 1 }
    try watcher.start()
    return (watcher, changes)
}

/// The file watches are armed asynchronously on the watcher's own queue, so a write
/// issued the same instant as `start()` is a race, not a regression.
private func settle() async { try? await Task.sleep(nanoseconds: 200_000_000) }

@Test func watcherFiresOnAnInPlaceRewrite() async throws {
    let directory = kitsuneTemporaryDirectory("kitsune-watch")
    defer { kitsuneRemove(directory) }
    let config = directory.appendingPathComponent("config.lua")
    try "return { items = {} }".write(to: config, atomically: true, encoding: .utf8)

    let (watcher, changes) = try startedWatcher(in: directory)
    defer { _ = watcher }
    await settle()
    #expect(changes.value == 0)

    // `cat > config.lua`: same inode, truncated and rewritten. The directory never
    // changes, so only the per-file watch can see this.
    try kitsuneRewriteInPlace(config, "return { items = { { id = 'root', label = 'Go' } } }")

    #expect(await kitsuneWaitUntil(timeout: 3) { changes.value > 0 })
}

@Test func watcherRearmsAfterASaveByRename() async throws {
    let directory = kitsuneTemporaryDirectory("kitsune-watch")
    defer { kitsuneRemove(directory) }
    let config = directory.appendingPathComponent("config.lua")
    try "return { items = {} }".write(to: config, atomically: true, encoding: .utf8)

    let (watcher, changes) = try startedWatcher(in: directory)
    defer { _ = watcher }
    await settle()

    // An atomic save swaps in a new file, leaving the watched descriptor on a dead
    // inode.
    try "return { items = { { id = 'root' } } }".write(to: config, atomically: true, encoding: .utf8)
    #expect(await kitsuneWaitUntil(timeout: 3) { changes.value > 0 })

    // The watch has to follow the replacement, or every save after the first one is
    // silently lost. Debounced, so give the re-arm a moment before the next write.
    await settle()
    let seen = changes.value
    try kitsuneRewriteInPlace(config, "return { items = { { id = 'root', label = 'Go' } } }")
    #expect(await kitsuneWaitUntil(timeout: 3) { changes.value > seen })
}

// NOTE: there is deliberately no test asserting that the 80ms window *coalesces* a
// burst of writes, because it does not: `scheduleChange` queues one delayed
// callback per vnode event rather than superseding the pending one, so eight
// in-place rewrites were measured to produce sixteen `onChange` calls (and so
// sixteen full config reloads). Pinning that here would enshrine it; it is
// reported instead.

@Test func fileOnlyWatcherSeesWritesWithoutADirectoryWatch() async throws {
    // The `~/.config/theme` pointer is watched this way: no directory watch (the
    // whole of ~/.config would be far too noisy), just the one file.
    let directory = kitsuneTemporaryDirectory("kitsune-watch")
    defer { kitsuneRemove(directory) }
    let pointer = directory.appendingPathComponent("theme")
    try "kanagawa".write(to: pointer, atomically: true, encoding: .utf8)

    let (watcher, changes) = try startedWatcher(in: directory, filenames: ["theme"], watchesDirectory: false)
    defer { _ = watcher }
    await settle()
    #expect(changes.value == 0)

    try kitsuneRewriteInPlace(pointer, "everforest")
    #expect(await kitsuneWaitUntil(timeout: 3) { changes.value > 0 })
}

@Test func watcherStartsEvenWhenTheDirectoryIsAbsent() async throws {
    // A fresh install has no ~/.config/kitsune at all; the watcher creates it rather
    // than throwing, so the first save after `Open Config Folder` is still seen.
    let root = kitsuneTemporaryDirectory("kitsune-watch")
    defer { kitsuneRemove(root) }
    let directory = root.appendingPathComponent("nested/kitsune")
    #expect(!FileManager.default.fileExists(atPath: directory.path))

    let (watcher, changes) = try startedWatcher(in: directory)
    defer { _ = watcher }
    #expect(FileManager.default.fileExists(atPath: directory.path))
    await settle()

    // Creating the file is a directory event, which is the half a directory watch
    // does catch.
    try "return { items = {} }".write(to: directory.appendingPathComponent("config.lua"), atomically: true, encoding: .utf8)
    #expect(await kitsuneWaitUntil(timeout: 3) { changes.value > 0 })
}
