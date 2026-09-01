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

@MainActor
@Test func unknownHotKeyNameKeepsThePreviousBinding() {
    let hotKey = GlobalHotKey()
    #expect(hotKey.current == nil)

    // An obscure chord: this registers system-wide for the test process, so it must
    // not be one a developer (or the launcher itself) is likely to be holding.
    let spec = HotKeySpec(key: "grave", modifiers: ["control", "option", "shift", "command"])
    let registered = hotKey.register(spec)
    let established = hotKey.current

    // The config path that matters: a reload naming a key the map doesn't know is
    // rejected, and the binding already in place survives it. Otherwise a typo in
    // config.lua leaves the launcher with no way to open.
    #expect(!hotKey.register(HotKeySpec(key: "hyperspace", modifiers: ["option"])))
    #expect(hotKey.current == established)

    // Guarded because registration is a system-wide claim that another process can
    // already hold; the rejection above is asserted either way.
    if registered {
        #expect(established == spec)
        // Re-registering the identical spec is a no-op that still reports success,
        // which is what stops every unrelated config save from churning the binding.
        #expect(hotKey.register(spec))
        #expect(hotKey.current == spec)
    }
}
