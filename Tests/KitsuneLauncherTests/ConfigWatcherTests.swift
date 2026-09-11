import Foundation
import Testing
@testable import KitsuneLauncher

// The saves a config watcher has to notice. A directory vnode event only fires when
// an entry is added, removed or renamed, so a directory-only watch misses an editor
// that writes in place — which is most of them, and all of `cat > config.lua`.

private func startedWatcher(
    in directory: URL,
    filenames: [String] = ["config.lua", "theme.lua"],
    watchesDirectory: Bool = true,
    recursive: Bool = true
) throws -> (watcher: ConfigWatcher, changes: Locked<Int>) {
    let changes = Locked(0)
    let watcher = ConfigWatcher(
        directory: directory,
        filenames: filenames,
        watchesDirectory: watchesDirectory,
        recursive: recursive
    )
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

@Test func watcherCoalescesABurstOfWrites() async throws {
    let directory = kitsuneTemporaryDirectory("kitsune-watch")
    defer { kitsuneRemove(directory) }
    let config = directory.appendingPathComponent("config.lua")
    try "return { items = {} }".write(to: config, atomically: true, encoding: .utf8)

    let (watcher, changes) = try startedWatcher(in: directory)
    defer { _ = watcher }
    await settle()
    for index in 0..<8 {
        try kitsuneRewriteInPlace(config, "return { value = \(index) }")
    }

    #expect(await kitsuneWaitUntil(timeout: 3) { changes.value > 0 })
    await settle()
    #expect(changes.value == 1)
}

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

// MARK: - The tree below config.lua

/// Lays out `relative` under `directory`, creating the intermediate directories a
/// split config brings with it.
private func write(_ contents: String, to relative: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func watcherFiresOnASaveInsideAPluginDirectory() async throws {
    // `plugins/` is on package.path, so `require "plugins.git"` is a config file in
    // every sense that matters — and saving it in place touches neither the config
    // directory nor either of the two named files.
    let directory = kitsuneTemporaryDirectory("kitsune-watch")
    defer { kitsuneRemove(directory) }
    try "return { items = {} }".write(to: directory.appendingPathComponent("config.lua"), atomically: true, encoding: .utf8)
    let plugin = try write("return {}", to: "plugins/git.lua", in: directory)

    let (watcher, changes) = try startedWatcher(in: directory)
    defer { _ = watcher }
    await settle()
    #expect(changes.value == 0)

    try kitsuneRewriteInPlace(plugin, "return { items = { { id = 'git', label = 'Git' } } }")
    #expect(await kitsuneWaitUntil(timeout: 3) { changes.value > 0 })
}

@Test func watcherFollowsANestedRequirePath() async throws {
    // `lua/?/init.lua` is on the search path too, so the tree can be a few levels deep
    // before it stops being a config.
    let directory = kitsuneTemporaryDirectory("kitsune-watch")
    defer { kitsuneRemove(directory) }
    try "return { items = {} }".write(to: directory.appendingPathComponent("config.lua"), atomically: true, encoding: .utf8)
    let module = try write("return {}", to: "lua/util/text/init.lua", in: directory)

    let (watcher, changes) = try startedWatcher(in: directory)
    defer { _ = watcher }
    await settle()
    #expect(changes.value == 0)

    try kitsuneRewriteInPlace(module, "return { trim = function(s) return s end }")
    #expect(await kitsuneWaitUntil(timeout: 3) { changes.value > 0 })
}

@Test func watcherSeesAPluginDirectoryAddedAfterItStarted() async throws {
    // Nothing but config.lua exists at start, so the tree has to be re-walked on every
    // event rather than enumerated once.
    let directory = kitsuneTemporaryDirectory("kitsune-watch")
    defer { kitsuneRemove(directory) }
    try "return { items = {} }".write(to: directory.appendingPathComponent("config.lua"), atomically: true, encoding: .utf8)

    let (watcher, changes) = try startedWatcher(in: directory)
    defer { _ = watcher }
    await settle()

    // Creating `plugins/git.lua` is a directory event on the config root, which the
    // root watch catches on its own.
    let plugin = try write("return {}", to: "plugins/git.lua", in: directory)
    #expect(await kitsuneWaitUntil(timeout: 3) { changes.value > 0 })

    // The point of the re-walk: the *next* in-place save of that new file is seen too.
    await settle()
    let seen = changes.value
    try kitsuneRewriteInPlace(plugin, "return { items = { { id = 'git' } } }")
    #expect(await kitsuneWaitUntil(timeout: 3) { changes.value > seen })
}

@Test func watcherIgnoresNonLuaFilesBelowTheConfigDirectory() async throws {
    // A README or a checked-in screenshot next to the plugins is not a config, and
    // rewriting one must not rebuild the menu.
    let directory = kitsuneTemporaryDirectory("kitsune-watch")
    defer { kitsuneRemove(directory) }
    try "return { items = {} }".write(to: directory.appendingPathComponent("config.lua"), atomically: true, encoding: .utf8)
    _ = try write("return {}", to: "plugins/git.lua", in: directory)
    let notes = try write("notes", to: "plugins/README.md", in: directory)

    let (watcher, changes) = try startedWatcher(in: directory)
    defer { _ = watcher }
    await settle()

    try kitsuneRewriteInPlace(notes, "more notes")
    // An in-place rewrite leaves the containing directory untouched, so nothing that
    // is watched has changed.
    await settle()
    #expect(changes.value == 0)
}

@Test func fileOnlyWatcherDoesNotWalkItsDirectory() async throws {
    // The `~/.config/theme` pointer watcher is aimed at the whole of `~/.config`.
    // Walking that would watch every dotfile directory the user owns, so recursion is
    // tied to owning the directory.
    let directory = kitsuneTemporaryDirectory("kitsune-watch")
    defer { kitsuneRemove(directory) }
    try "kanagawa".write(to: directory.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
    let stranger = try write("return {}", to: "nvim/init.lua", in: directory)

    let (watcher, changes) = try startedWatcher(in: directory, filenames: ["theme"], watchesDirectory: false)
    defer { _ = watcher }
    await settle()

    try kitsuneRewriteInPlace(stranger, "return { 'unrelated' }")
    await settle()
    #expect(changes.value == 0)
}
