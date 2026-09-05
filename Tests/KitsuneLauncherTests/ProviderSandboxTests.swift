import Foundation
import Testing
@testable import KitsuneLauncher

// A provider is dumped out of the config state and re-loaded into a throwaway state
// with no execution globals and a wall-clock deadline. These tests pin both halves:
// what a provider can reach, and that it always comes back.

private let providerConfig = """
return {
  items = {
    { id = "root", label = "Go" },
    { id = "search", label = "Search", provider = "rows" },
  },
  providers = {
    rows = function(query)
      return {
        { label = "Run " .. query, detail = "in a terminal", symbol = "terminal", shell = "echo " .. query },
        { label = "Open", open = "/Applications" },
        { label = "Site", url = "https://example.com" },
        { label = "Notice only" },
        { label = "", detail = "dropped: a row with no label is not a row" },
        { label = "First dup", value = "same" },
        { label = "Second dup", value = "same" },
      }
    end,
    sandbox = function()
      return {
        { label = table.concat({
            type(io), type(os.execute), type(terminal), type(run), type(osascript),
            tostring(kitsune.can_execute),
          }, "/") },
      }
    end,
    countdown = function()
      local n = 0
      for i = 1, 100000 do n = n + i end
      return { { label = "done " .. n } }
    end,
    spin = function()
      while true do end
      return {}
    end,
    boom = function() error("provider blew up") end,
    native = print,
  },
}
"""

@Test func providerRowsDecodeWithTheirActions() async {
    let (runtime, load, directory) = await kitsuneLoadConfig(providerConfig)
    defer { kitsuneRemove(directory) }
    #expect(load.error == nil)

    let outcome = await kitsuneProviderOutcome(runtime, name: "rows", query: "hello", timeout: 5)
    guard let outcome else { Issue.record("provider never completed"); return }
    #expect(outcome.error == nil)

    // The query reaches the provider as its first argument, and the labelless row is
    // dropped rather than rendered blank.
    #expect(outcome.labels == ["Run hello", "Open", "Site", "Notice only", "First dup", "Second dup"])
    #expect(outcome.rows.map(\.kind) == [.action, .action, .action, .notice, .notice, .notice])
    #expect(outcome.rows.allSatisfy { $0.section == "provider" })
    #expect(outcome.rows[0].detail == "in a terminal")
    #expect(outcome.rows[0].symbol == "terminal")

    // Ids are slugged from `value` (falling back to the label) and disambiguated, so
    // two rows sharing a value cannot collide.
    #expect(outcome.rows[0].id == "menu.run-hello")
    #expect(outcome.rows[4].id == "menu.same")
    #expect(outcome.rows[5].id == "menu.same-")

    // The provider state cannot execute anything, so a row *describes* the action and
    // the host runs it.
    if case .shell(let command)? = outcome.rows[0].action { #expect(command == "echo hello") } else { Issue.record("expected a shell action") }
    if case .open(let target)? = outcome.rows[1].action { #expect(target == "/Applications") } else { Issue.record("expected an open action") }
    if case .url(let target)? = outcome.rows[2].action { #expect(target == "https://example.com") } else { Issue.record("expected a url action") }
    #expect(outcome.rows[3].action == nil)
}

@Test func providerStateHasNoExecutionGlobals() async {
    let (runtime, load, directory) = await kitsuneLoadConfig(providerConfig)
    defer { kitsuneRemove(directory) }
    #expect(load.error == nil)

    let outcome = await kitsuneProviderOutcome(runtime, name: "sandbox", timeout: 5)
    guard let outcome else { Issue.record("provider never completed"); return }
    #expect(outcome.error == nil)
    // io, os.execute, terminal, run, osascript, kitsune.can_execute — the config state
    // has the last four; a provider has none of them.
    #expect(outcome.labels == ["nil/nil/nil/nil/nil/false"])
}

@Test func providerExceedingItsDeadlineFailsCleanly() async {
    let (runtime, load, directory) = await kitsuneLoadConfig(providerConfig)
    defer { kitsuneRemove(directory) }
    #expect(load.error == nil)

    // The control run: this loop is well inside the instruction ceiling, so with a
    // generous deadline it finishes. Anything that stops it below is the clock.
    let completed = await kitsuneProviderOutcome(runtime, name: "countdown", timeout: 5)
    #expect(completed?.error == nil)
    #expect(completed?.labels == ["done 5000050000"])

    let started = Date()
    let expired = await kitsuneProviderOutcome(runtime, name: "countdown", timeout: 0)
    guard let expired else { Issue.record("provider never completed"); return }
    #expect(expired.error?.contains("script execution limit exceeded") == true)
    #expect(expired.rows.isEmpty)
    #expect(Date().timeIntervalSince(started) < 5)
}

@Test func infiniteProviderIsStoppedByTheBudget() async {
    let (runtime, load, directory) = await kitsuneLoadConfig(providerConfig)
    defer { kitsuneRemove(directory) }
    #expect(load.error == nil)

    // The shipped 0.15s deadline. A provider runs on every keystroke, so a runaway
    // one must fail rather than wedge the Lua queue behind it.
    let started = Date()
    let outcome = await kitsuneProviderOutcome(runtime, name: "spin")
    guard let outcome else { Issue.record("runaway provider never returned"); return }
    #expect(outcome.error?.contains("script execution limit exceeded") == true)
    #expect(Date().timeIntervalSince(started) < 5)

    // And the queue is still usable afterwards.
    let after = await kitsuneProviderOutcome(runtime, name: "sandbox", timeout: 5)
    #expect(after?.error == nil)
}

@Test func providerErrorsAreSurfacedNotSwallowed() async {
    let (runtime, load, directory) = await kitsuneLoadConfig(providerConfig)
    defer { kitsuneRemove(directory) }
    #expect(load.error == nil)

    let outcome = await kitsuneProviderOutcome(runtime, name: "boom", timeout: 5)
    #expect(outcome?.error?.contains("provider blew up") == true)
    #expect(outcome?.rows.isEmpty == true)
}

@Test func nonSerializableProviderIsRejected() async {
    let (runtime, load, directory) = await kitsuneLoadConfig(providerConfig)
    defer { kitsuneRemove(directory) }
    #expect(load.error == nil)

    // `lua_dump` cannot serialize a C function, which is what a provider has to be
    // put through to reach its sandboxed state.
    let outcome = await kitsuneProviderOutcome(runtime, name: "native", timeout: 5)
    #expect(outcome?.error == "Provider is not serializable")
}

@Test func unknownProviderYieldsNoRows() async {
    let (runtime, load, directory) = await kitsuneLoadConfig(providerConfig)
    defer { kitsuneRemove(directory) }
    #expect(load.error == nil)

    let outcome = await kitsuneProviderOutcome(runtime, name: "not-declared", timeout: 5)
    #expect(outcome?.error == nil)
    #expect(outcome?.rows.isEmpty == true)
}
