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
