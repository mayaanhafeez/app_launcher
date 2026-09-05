import Foundation
@testable import KitsuneLauncher

// Shared scaffolding for the tests that touch the filesystem, the Lua queue or a
// socket. Everything here is hermetic and bounded: no test may read the real
// `~/.config/kitsune`, bind the real container socket, or wait without a deadline.
//
// The same rule covers actions. `MenuController.activate` really dispatches, and
// `LuaRuntime.invoke` really drives Terminal through `osascript` — a test node
// carrying `shell = "brew install ..."` will install it. Give test nodes `.url("")`,
// or `.url("{query}")` where the action has to want a query: `invoke` guards every
// case on `!isBlank`, and a resolved query has no URL scheme for `NSWorkspace` to
// open, so neither one can launch anything.

/// A directory under `/tmp`, not `NSTemporaryDirectory()`: a `sockaddr_un` path is
/// capped at 104 bytes and the per-user temp directory alone eats most of that, so
/// the IPC tests would fail to bind from a path that is merely long.
func kitsuneTemporaryDirectory(_ prefix: String = "kitsune-test") -> URL {
    let url = URL(fileURLWithPath: "/tmp").appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func kitsuneRemove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

/// A value that crosses a queue boundary — a Lua reload result, a watcher callback,
/// a socket reply — guarded by a lock so the polling below is not a data race.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

/// Polls until `condition` holds, giving up at `timeout`. Awaiting rather than
/// blocking is what lets the main queue drain, which is where `LuaRuntime` and
/// `IPCServer` deliver their results — and the deadline is what keeps a regression
/// a failing test rather than a hung CI job.
@discardableResult
func kitsuneWaitUntil(timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

/// Writes `contents` to `url` **in place**: the same inode, truncated and rewritten,
/// which is what `cat > config.lua` and any editor that saves without a temp-file
/// swap do. `Data.write(to:.atomic)` would instead replace the directory entry and
/// so exercise a different watcher path entirely.
func kitsuneRewriteInPlace(_ url: URL, _ contents: String) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data(contents.utf8))
    try handle.synchronize()
}

// MARK: - Lua

/// Everything a config load publishes, collected off the main queue.
struct ConfigLoad {
    var nodes: [MenuNode] = []
    var settings: Settings?
    var error: String?

    func node(_ id: String) -> MenuNode? { nodes.first { $0.id == id } }
}

/// Writes `source` (or nothing, to exercise the missing-config path) into a fresh
/// temp directory and loads it. The runtime is returned alive because the Lua state
/// — and therefore every registered provider — dies with it.
func kitsuneLoadConfig(
    _ source: String?,
    files: [String: String] = [:],
    timeout: TimeInterval = 5
) async -> (runtime: LuaRuntime, load: ConfigLoad, directory: URL) {
    let directory = kitsuneTemporaryDirectory("kitsune-lua")
    let file = directory.appendingPathComponent("config.lua")
    // `files` are relative paths, so a test can lay out `plugins/foo.lua` the way a
    // real config splits itself up.
    for (name, contents) in files {
        let target = directory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: target, atomically: true, encoding: .utf8)
    }
    if let source { try? source.write(to: file, atomically: true, encoding: .utf8) }

    let collected = Locked(ConfigLoad())
    let finished = Locked(false)
    let runtime = LuaRuntime()
    runtime.onSettings = { settings in
        var value = collected.value
        value.settings = settings
        collected.value = value
    }
    runtime.onReload = { result in
        var value = collected.value
        switch result {
        case .success(let nodes): value.nodes = nodes
        case .failure(let error): value.error = error.localizedDescription
        }
        collected.value = value
        finished.value = true
    }
    runtime.load(file: file)
    _ = await kitsuneWaitUntil(timeout: timeout) { finished.value }
    return (runtime, collected.value, directory)
}

/// What a provider run produced. `nil` means the completion never fired, which is
/// the shape of a hang — asserted against rather than waited on forever.
struct ProviderOutcome: @unchecked Sendable {
    var rows: [DisplayRow] = []
    var error: String?

    var labels: [String] { rows.map(\.label) }
}

func kitsuneProviderOutcome(
    _ runtime: LuaRuntime,
    name: String,
    query: String = "",
    timeout: TimeInterval = 0.15,
    wait: TimeInterval = 5
) async -> ProviderOutcome? {
    let box = Locked<ProviderOutcome?>(nil)
    runtime.provider(name: name, menuID: "menu", query: query, timeout: timeout) { result in
        switch result {
        case .success(let rows): box.value = ProviderOutcome(rows: rows, error: nil)
        case .failure(let error): box.value = ProviderOutcome(rows: [], error: error.localizedDescription)
        }
    }
    _ = await kitsuneWaitUntil(timeout: wait) { box.value != nil }
    return box.value
}
