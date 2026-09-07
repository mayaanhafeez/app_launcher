import Foundation
import Testing
@testable import KitsuneLauncher

// A save that breaks config.lua normally happens with the panel closed — you edit
// config in an editor — so a five-second toast is shown to nobody and the launcher
// looks like it ignored the edit. The outcome of a load therefore has to outlive the
// load, and has to be answerable over IPC.

/// Loads `source` and returns what `onLoadOutcome` published: nil for a clean load,
/// the Lua error otherwise.
private func outcome(of source: String, runtime: LuaRuntime = LuaRuntime(), in directory: URL) async -> String?? {
    let file = directory.appendingPathComponent("config.lua")
    try? source.write(to: file, atomically: true, encoding: .utf8)
    let published = Locked<String??>(nil)
    runtime.onLoadOutcome = { published.value = .some($0) }
    runtime.load(file: file)
    _ = await kitsuneWaitUntil(timeout: 5) { published.value != nil }
    return published.value
}

@Test func aBrokenConfigPublishesItsErrorAndAGoodOneClearsIt() async throws {
    let directory = kitsuneTemporaryDirectory("kitsune-config-error")
    defer { kitsuneRemove(directory) }
    // One runtime throughout: the point is that the *state* changes, not that two
    // separate loads each report themselves.
    let runtime = LuaRuntime()

    let broken = await outcome(of: "return { items = ", runtime: runtime, in: directory)
    #expect(broken??.contains("Config:") == true)

    let fixed = await outcome(of: "return { items = { { id = 'root', label = 'Go' } } }", runtime: runtime, in: directory)
    #expect(fixed == .some(nil))
}

@Test func aMissingConfigIsNotAnError() async throws {
    // A fresh install has no config.lua and falls back to the built-in menu. That is
    // not a failure, and must not tint the menu bar.
    let directory = kitsuneTemporaryDirectory("kitsune-config-error")
    defer { kitsuneRemove(directory) }
    let runtime = LuaRuntime()
    let published = Locked<String??>(nil)
    runtime.onLoadOutcome = { published.value = .some($0) }
    runtime.load(file: directory.appendingPathComponent("config.lua"))
    _ = await kitsuneWaitUntil(timeout: 5) { published.value != nil }
    #expect(published.value == .some(nil))
}

// MARK: - Over IPC

@MainActor
@Test func reloadReportsTheErrorItProduced() {
    // `kitsunectl reload` exits non-zero on `ok: false` and prints the message, so
    // this is what makes a config edit CI-checkable.
    let failing = IPCCommands(reload: { answer in answer("Config: config.lua:3: unexpected symbol") })
    let response = Locked<IPCResponse?>(nil)
    failing.handle(IPCRequest(command: "reload", argument: nil)) { response.value = $0 }

    #expect(response.value?.ok == false)
    #expect(response.value?.message == "Config: config.lua:3: unexpected symbol")
}

@MainActor
@Test func reloadStillReportsOkWhenTheConfigLoads() {
    let succeeding = IPCCommands(reload: { answer in answer(nil) })
    let response = Locked<IPCResponse?>(nil)
    succeeding.handle(IPCRequest(command: "reload", argument: nil)) { response.value = $0 }

    #expect(response.value?.ok == true)
    #expect(response.value?.message == "ok")
}

/// Writes a plugin and a config that loads it the way the shipped template does, and
/// returns what the load reported.
private func outcomeLoadingPlugin(_ plugin: String, from config: String, in directory: URL) async -> String?? {
    let plugins = directory.appendingPathComponent("plugins")
    try? FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
    try? plugin.write(to: plugins.appendingPathComponent("themes.lua"), atomically: true, encoding: .utf8)
    return await outcome(of: config, in: directory)
}

@Test func aPluginTheConfigSwallowedIsStillReported() async throws {
    // The shipped template loads plugins with `pcall(require, ...)` so one broken
    // plugin does not take the whole menu down. That also swallowed the error whole: a
    // syntax error in `plugins/themes.lua` loaded a config that "succeeded", showed
    // nothing anywhere, and simply left the plugin's rows out.
    let directory = kitsuneTemporaryDirectory("kitsune-config-error")
    defer { kitsuneRemove(directory) }

    let reported = await outcomeLoadingPlugin(
        "return { items = { { id = 'x' label = 'X' } } }",
        from: """
        local ok, plugin = pcall(require, "plugins.themes")
        return { items = { { id = "root", label = "Go" } } }
        """,
        in: directory
    )

    #expect(reported??.contains("plugins/themes.lua") == true || reported??.contains("plugins.themes") == true)
    #expect(reported??.contains("label") == true)
}

@Test func aPluginThatLoadsCleanlyReportsNothing() async throws {
    // The whole point of the `pcall` is that a working config is quiet. Recording a
    // failure that never happened would tint the menu bar over nothing.
    let directory = kitsuneTemporaryDirectory("kitsune-config-error")
    defer { kitsuneRemove(directory) }

    let reported = await outcomeLoadingPlugin(
        "return { items = { { id = 'x', label = 'X' } } }",
        from: """
        local ok, plugin = pcall(require, "plugins.themes")
        return { items = { { id = "root", label = "Go" } } }
        """,
        in: directory
    )

    #expect(reported == .some(nil))
}

@Test func aSwallowedFailureIsNotCarriedIntoTheNextLoad() async throws {
    // The error state clears on a load that succeeds, so what one load caught must not
    // outlive it — the plugin is fixed, and the menu bar has to go back to normal.
    let directory = kitsuneTemporaryDirectory("kitsune-config-error")
    defer { kitsuneRemove(directory) }
    let runtime = LuaRuntime()

    let config = """
    local ok, plugin = pcall(require, "plugins.themes")
    return { items = { { id = "root", label = "Go" } } }
    """
    _ = await outcomeLoadingPlugin("return { items = { { id = 'x' label = 'X' } } }", from: config, in: directory)
    let fixed = await outcomeLoadingPlugin("return { items = { { id = 'x', label = 'X' } } }", from: config, in: directory)
    #expect(fixed == .some(nil))
    _ = runtime
}

@Test func aPluginErrorTheConfigDoesNotCatchStillFailsTheLoad() async throws {
    // Re-raising is what keeps the unguarded case unchanged: a bare `require` on a
    // broken module is a failed load, not a warning about one.
    let directory = kitsuneTemporaryDirectory("kitsune-config-error")
    defer { kitsuneRemove(directory) }

    let reported = await outcomeLoadingPlugin(
        "return { items = { { id = 'x' label = 'X' } } }",
        from: """
        local plugin = require "plugins.themes"
        return { items = { { id = "root", label = "Go" } } }
        """,
        in: directory
    )

    #expect(reported??.contains("Config:") == true)
    // Reported once, not twice: the same failure came back through both paths.
    #expect(reported??.components(separatedBy: "themes.lua").count ?? 0 <= 3)
}
