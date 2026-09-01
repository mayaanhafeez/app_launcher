import Foundation
import Testing
@testable import OrbitLauncher

// Config decoding, the no-config fallback, error reporting and the execution
// budget. Every load runs against a throwaway directory, so none of this depends
// on (or disturbs) a real `~/.config/orbit`.

@Test func missingConfigFallsBackToDefaultNodes() async {
    let (runtime, load, directory) = await orbitLoadConfig(nil)
    defer { orbitRemove(directory); _ = runtime }

    #expect(load.error == nil)
    #expect(load.nodes.map(\.id) == ["root", "apps", "system", "tools"])
    // A machine with no config still gets a working panel, so the defaults have to
    // arrive alongside the nodes rather than being left unpublished.
    #expect(load.settings?.hotKey == HotKeySpec())
    #expect(load.settings?.vimMode == false)
}

@Test func configWithoutRootGetsOneInjected() async {
    let (runtime, load, directory) = await orbitLoadConfig("""
    return { items = { { id = "tools", label = "Tools" } } }
    """)
    defer { orbitRemove(directory); _ = runtime }

    #expect(load.error == nil)
    // Injected at the front: everything else parents onto it.
    #expect(load.nodes.first?.id == "root")
    #expect(load.nodes.map(\.id) == ["root", "tools"])
    #expect(load.node("root")?.parent == "")
}

@Test func itemsDecodeIntoNodes() async {
    let (runtime, load, directory) = await orbitLoadConfig("""
    return {
      items = {
        { id = "root", label = "Go" },
        { id = "dev", label = "Development", detail = "Projects", symbol = "hammer", aliases = { "code", "proj" } },
        { id = "dev.servers" },
        { id = "dev.servers.web", label = "Web", shell = "python3 -m http.server" },
        { id = "notes", parent = "dev", label = "Notes", open = "~/notes" },
        { id = "site", label = "Site", url = "https://example.com" },
        { id = "dialog", label = "Dialog", applescript = 'display dialog "hi"' },
        { id = "handler", label = "Handler", action = function(query) return query end },
        { id = "search", label = "Search", title = "Search the web", provider = "results" },
        { label = "no id at all" },
      },
    }
    """)
    defer { orbitRemove(directory); _ = runtime }

    #expect(load.error == nil)
    // The idless entry is dropped rather than becoming an unreachable row.
    #expect(load.nodes.map(\.id) == ["root", "dev", "dev.servers", "dev.servers.web", "notes", "site", "dialog", "handler", "search"])

    let dev = load.node("dev")
    #expect(dev?.parent == "root")
    #expect(dev?.kind == .menu)
    #expect(dev?.detail == "Projects")
    #expect(dev?.symbol == "hammer")
    #expect(dev?.aliases == ["code", "proj"])
    #expect(dev?.order == 2)

    // Parent is inferred from the dotted id, and a missing label falls back to it.
    #expect(load.node("dev.servers")?.parent == "dev")
    #expect(load.node("dev.servers")?.label == "dev.servers")
    #expect(load.node("dev.servers.web")?.parent == "dev.servers")

    // An explicit `parent` wins over the inference, which would have said "root".
    #expect(load.node("notes")?.parent == "dev")

    #expect(load.node("dev.servers.web")?.kind == .action)
    if case .shell(let command)? = load.node("dev.servers.web")?.scriptAction {
        #expect(command == "python3 -m http.server")
    } else { Issue.record("expected a shell action") }
    if case .open(let target)? = load.node("notes")?.scriptAction { #expect(target == "~/notes") } else { Issue.record("expected an open action") }
    if case .url(let target)? = load.node("site")?.scriptAction { #expect(target == "https://example.com") } else { Issue.record("expected a url action") }
    if case .appleScript(let source)? = load.node("dialog")?.scriptAction { #expect(source == "display dialog \"hi\"") } else { Issue.record("expected an applescript action") }

    // A Lua handler is referenced, not inlined, and makes the node an action.
    #expect(load.node("handler")?.actionReference != nil)
    #expect(load.node("handler")?.kind == .action)

    // A provider alone does not make a node actionable: it stays a submenu whose
    // rows the provider supplies while it is open.
    #expect(load.node("search")?.provider == "results")
    #expect(load.node("search")?.kind == .menu)
    #expect(load.node("search")?.headerTitle == "Search the web")
}

@Test func settingsDecodeFromConfig() async {
    let (runtime, load, directory) = await orbitLoadConfig("""
    return {
      hotkey = { key = "k", mods = { "command", "shift" } },
      vim = true,
      login_item = true,
      back = { enabled = true, label = "Up", symbol = "arrow.up", detail = "leave", position = "bottom" },
      shortcuts = { enabled = true, hints = false, mods = { "control" }, keys = { "a", "b", "c" } },
      apps = { paths = { "~/dev", "/Volumes/Apps" }, depth = 5 },
      items = { { id = "root", label = "Go" } },
    }
    """)
    defer { orbitRemove(directory); _ = runtime }

    let settings = load.settings
    #expect(settings?.hotKey == HotKeySpec(key: "k", modifiers: ["command", "shift"]))
    #expect(settings?.vimMode == true)
    #expect(settings?.loginItem == true)
    #expect(settings?.back == BackRowSpec(enabled: true, label: "Up", symbol: "arrow.up", detail: "leave", position: "bottom"))
    #expect(settings?.back.atTop == false)
    #expect(settings?.shortcuts == ShortcutSpec(enabled: true, modifiers: ["control"], keys: ["a", "b", "c"], hints: false))
    #expect(settings?.apps == AppScanSpec(paths: ["~/dev", "/Volumes/Apps"], depth: 5))
}

@Test func settingsFallBackToDefaultsForAbsentKeys() async {
    let (runtime, load, directory) = await orbitLoadConfig("""
    return {
      back = false,
      shortcuts = false,
      apps = { depth = 0 },
      items = { { id = "root", label = "Go" } },
    }
    """)
    defer { orbitRemove(directory); _ = runtime }

    let settings = load.settings
    // `false` is the short form for "switch the row off"; the rest of the spec keeps
    // its defaults so re-enabling it does not need every key restated.
    #expect(settings?.back.enabled == false)
    #expect(settings?.back.label == "Back")
    #expect(settings?.shortcuts.enabled == false)
    #expect(settings?.shortcuts.keys == ShortcutSpec().keys)
    // A depth of 0 would scan nothing at all, so it is clamped rather than honoured.
    #expect(settings?.apps.depth == 1)
    // An absent `hotkey` must leave the binding alone, not blank it.
    #expect(settings?.hotKey == HotKeySpec())
    #expect(settings?.apps.paths == [])
}

@Test func syntaxErrorIsReportedNotSwallowed() async {
    let (runtime, load, directory) = await orbitLoadConfig("return { items = {")
    defer { orbitRemove(directory); _ = runtime }

    #expect(load.nodes.isEmpty)
    #expect(load.error?.hasPrefix("Config:") == true)
    // The Lua message carries the file and line, which is the whole point of
    // surfacing it instead of a generic failure.
    #expect(load.error?.contains("config.lua") == true)
}

@Test func configReturningANonTableIsReported() async {
    let (runtime, load, directory) = await orbitLoadConfig("return 42")
    defer { orbitRemove(directory); _ = runtime }

    #expect(load.nodes.isEmpty)
    #expect(load.error?.hasPrefix("Config:") == true)
}

@Test func runawayConfigHitsTheInstructionBudget() async {
    // No wall-clock deadline on a config load, so this is the instruction ceiling
    // doing the work. Without it the Lua queue would never come back.
    let start = Date()
    let (runtime, load, directory) = await orbitLoadConfig("""
    local n = 0
    while true do n = n + 1 end
    return { items = { { id = "root", label = "Go" } } }
    """, timeout: 20)
    defer { orbitRemove(directory); _ = runtime }

    #expect(load.error?.contains("script execution limit exceeded") == true)
    #expect(load.nodes.isEmpty)
    #expect(Date().timeIntervalSince(start) < 20)
}

@Test func configStateHasExecutionGlobalsButNoIO() async {
    let (runtime, load, directory) = await orbitLoadConfig("""
    return {
      items = {
        { id = "root", label = "Go" },
        { id = "probe", label = table.concat({ type(terminal), type(run), type(osascript), type(io), type(os.execute) }, "/") },
        { id = "orbit", label = tostring(orbit.can_execute) .. "|" .. orbit.config_dir .. "|" .. package.cpath },
      },
    }
    """)
    defer { orbitRemove(directory); _ = runtime }

    // The config state is the only one that gets the execution helpers — and even it
    // loses `io` and `os.execute`, which are the ways around the logged host calls.
    #expect(load.node("probe")?.label == "function/function/function/nil/nil")
    #expect(load.node("orbit")?.label == "true|\(directory.path)|")
}

@Test func configCanRequireFromThePluginsDirectory() async {
    let (runtime, load, directory) = await orbitLoadConfig(
        """
        local extra = require("extra")
        local shared = require("shared")
        return { items = { { id = "root", label = "Go" }, extra.item, shared.item } }
        """,
        files: [
            "plugins/extra.lua": "return { item = { id = \"extra\", label = \"From plugins\" } }",
            "lua/shared.lua": "return { item = { id = \"shared\", label = \"From lua\" } }",
        ]
    )
    defer { orbitRemove(directory); _ = runtime }

    #expect(load.error == nil)
    #expect(load.node("extra")?.label == "From plugins")
    #expect(load.node("shared")?.label == "From lua")
}
