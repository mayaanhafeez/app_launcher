import AppKit
import Carbon
import Foundation
import Testing
@testable import OrbitLauncher

// The name → key-code map from `config.lua`, and the rule that matters most on a
// reload: a name the map doesn't know must not cost the user their only way to open
// the launcher.

@Test func hotKeyNamesMapToKeyCodes() {
    #expect(GlobalHotKey.keyCode(for: "space") == kVK_Space)
    #expect(GlobalHotKey.keyCode(for: "tab") == kVK_Tab)
    #expect(GlobalHotKey.keyCode(for: "f12") == kVK_F12)

    // Aliases for the same physical key.
    #expect(GlobalHotKey.keyCode(for: "return") == GlobalHotKey.keyCode(for: "enter"))
    #expect(GlobalHotKey.keyCode(for: "esc") == GlobalHotKey.keyCode(for: "escape"))
    #expect(GlobalHotKey.keyCode(for: "backspace") == GlobalHotKey.keyCode(for: "delete"))
    #expect(GlobalHotKey.keyCode(for: "backtick") == GlobalHotKey.keyCode(for: "grave"))

    // Letters and digits resolve on their own, case-insensitively and untrimmed.
    #expect(GlobalHotKey.keyCode(for: "a") == kVK_ANSI_A)
    #expect(GlobalHotKey.keyCode(for: "K") == kVK_ANSI_K)
    #expect(GlobalHotKey.keyCode(for: "  Space  ") == kVK_Space)
    #expect(GlobalHotKey.keyCode(for: "7") == kVK_ANSI_7)

    // Anything else is a config typo, and has to read as one.
    #expect(GlobalHotKey.keyCode(for: "hyperspace") == nil)
    #expect(GlobalHotKey.keyCode(for: "f13") == nil)
    #expect(GlobalHotKey.keyCode(for: "") == nil)
    #expect(GlobalHotKey.keyCode(for: "ctrl") == nil)
}

@Test func hotKeyModifierNamesMapToCarbonMasks() {
    #expect(GlobalHotKey.modifierMask(for: []) == 0)
    #expect(GlobalHotKey.modifierMask(for: ["option"]) == UInt32(optionKey))
    #expect(GlobalHotKey.modifierMask(for: ["opt"]) == UInt32(optionKey))
    #expect(GlobalHotKey.modifierMask(for: ["alt"]) == UInt32(optionKey))
    #expect(GlobalHotKey.modifierMask(for: ["Command"]) == UInt32(cmdKey))
    #expect(GlobalHotKey.modifierMask(for: ["cmd"]) == UInt32(cmdKey))
    #expect(GlobalHotKey.modifierMask(for: ["super"]) == UInt32(cmdKey))
    #expect(GlobalHotKey.modifierMask(for: ["ctrl"]) == UInt32(controlKey))
    #expect(GlobalHotKey.modifierMask(for: ["shift"]) == UInt32(shiftKey))

    // Names combine, and an unrecognised one is skipped rather than poisoning the
    // whole chord.
    #expect(GlobalHotKey.modifierMask(for: ["cmd", "shift"]) == UInt32(cmdKey) | UInt32(shiftKey))
    #expect(GlobalHotKey.modifierMask(for: ["meta", "control"]) == UInt32(controlKey))
}

// MARK: - Several chords at once

@Test func hotKeysListDecodesTargets() async {
    let (runtime, load, directory) = await orbitLoadConfig("""
    return {
      hotkeys = {
        { key = "space", mods = { "option" } },
        { key = "t", mods = { "option" }, route = "tools" },
        { key = "l", mods = { "option" }, invoke = "system.lock" },
      },
      items = { { id = "root", label = "Go" } },
    }
    """)
    defer { orbitRemove(directory); _ = runtime }

    #expect(load.settings?.hotKeys == [
        HotKeySpec(key: "space", modifiers: ["option"], target: .toggle("root")),
        HotKeySpec(key: "t", modifiers: ["option"], target: .toggle("tools")),
        HotKeySpec(key: "l", modifiers: ["option"], target: .invoke("system.lock")),
    ])
}

// `invoke` is the more specific statement of intent, so a config that sets both
// plainly meant the action rather than the menu.
@Test func invokeWinsOverRouteOnTheSameChord() async {
    let (runtime, load, directory) = await orbitLoadConfig("""
    return {
      hotkeys = { { key = "l", mods = { "option" }, route = "tools", invoke = "system.lock" } },
      items = { { id = "root", label = "Go" } },
    }
    """)
    defer { orbitRemove(directory); _ = runtime }
    #expect(load.settings?.hotKeys.first?.target == .invoke("system.lock"))
}

// The whole point of keeping the alias: a config written before `hotkeys` existed
// must keep binding exactly what it always did.
@Test func theSingleHotkeyAliasStillWorksAndLosesToTheList() async {
    let (runtime, load, directory) = await orbitLoadConfig("""
    return {
      hotkey = { key = "j", mods = { "control" } },
      hotkeys = { { key = "k", mods = { "command" } } },
      items = { { id = "root", label = "Go" } },
    }
    """)
    defer { orbitRemove(directory); _ = runtime }
    #expect(load.settings?.hotKeys == [HotKeySpec(key: "k", modifiers: ["command"])])
}

// An empty list would otherwise leave the launcher with no way to open at all.
@Test func anEmptyHotkeysListKeepsTheDefaultBinding() async {
    let (runtime, load, directory) = await orbitLoadConfig("""
    return { hotkeys = {}, items = { { id = "root", label = "Go" } } }
    """)
    defer { orbitRemove(directory); _ = runtime }
    #expect(load.settings?.hotKeys == [HotKeySpec()])
}

// Name validation needs no system claim at all, so this half is unconditional: a
// chord the map cannot resolve is rejected before anything is registered.
@MainActor
@Test func anUnknownKeyNameIsRejectedBeforeAnythingIsBound() {
    let hotKey = GlobalHotKey()
    #expect(hotKey.current.isEmpty)
    let rejected = hotKey.register([HotKeySpec(key: "hyperspace", modifiers: ["option"])])
    #expect(rejected.map(\.key) == ["hyperspace"])
    #expect(hotKey.current.isEmpty)
}

// The per-slot fallback, which is the reason this is a registry and not a list: one
// bad line in config.lua costs its own chord and nothing else.
//
// Guarded, because registering is a system-wide claim another process may already
// hold — the unconditional half of the rule is asserted above.
@MainActor
@Test func aRejectedChordCostsOnlyItsOwnSlot() {
    let hotKey = GlobalHotKey()
    // Obscure chords: these register system-wide for the test process, so they must
    // not be ones a developer — or the launcher itself — is likely to be holding.
    let first = HotKeySpec(key: "grave", modifiers: ["control", "option", "shift", "command"])
    let second = HotKeySpec(key: "semicolon", modifiers: ["control", "option", "shift", "command"])
    guard hotKey.register([first, second]).isEmpty else { return }
    let established = hotKey.current
    #expect(established == [first, second])

    // A typo in slot 0 is rejected by name, before anything is torn down...
    #expect(hotKey.register([HotKeySpec(key: "hyperspace", modifiers: ["option"]), second]).map(\.key) == ["hyperspace"])
    // ...and every slot, including the one that failed, keeps what it had.
    #expect(hotKey.current == established)

    // Re-registering the identical set is a no-op that reports no failures, which is
    // what stops an unrelated config save from churning every binding.
    #expect(hotKey.register(established).isEmpty)
    #expect(hotKey.current == established)
}

// Dropping a chord from the config has to unregister it, not leave it bound.
@MainActor
@Test func shrinkingTheSetReleasesTheChordsItDropped() {
    let hotKey = GlobalHotKey()
    let first = HotKeySpec(key: "grave", modifiers: ["control", "option", "shift", "command"])
    let second = HotKeySpec(key: "slash", modifiers: ["control", "option", "shift", "command"])
    guard hotKey.register([first, second]).isEmpty else { return }

    #expect(hotKey.register([first]).isEmpty)
    #expect(hotKey.current == [first])
    // The chord `second` held is free again, so claiming it in a fresh slot succeeds.
    #expect(hotKey.register([first, second]).isEmpty)
    #expect(hotKey.current == [first, second])
}

@Test func aChordReadsBackAsTheUserWroteIt() {
    #expect(HotKeySpec(key: "space", modifiers: ["option"]).chord == "option+space")
    #expect(HotKeySpec(key: "k", modifiers: ["command", "shift"]).chord == "command+shift+k")
}
