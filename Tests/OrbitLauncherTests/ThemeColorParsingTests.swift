import AppKit
import Testing
@testable import OrbitLauncher

/// `theme.lua`'s explicit colour keys and the palette scheme files read hex the same
/// way. They did not always: the overrides went through `NSColor(hex:)`, which takes
/// only 6 digits and silently returns black on anything else, so a value copied out
/// of a palette into an override blacked out the panel with no error.
private func loadTheme(_ source: String) -> (theme: Theme, cleanup: () -> Void) {
    let directory = orbitTemporaryDirectory("orbit-theme")
    let file = directory.appendingPathComponent("theme.lua")
    try? source.write(to: file, atomically: true, encoding: .utf8)
    return (ThemeRuntime().load(file: file), { orbitRemove(directory) })
}

@Test func themeOverridesAcceptEveryHexFormThePalettesDo() {
    let expected = NSColor(hex: "17191f")
    for literal in ["17191f", "#17191f", "0x17191f", "0xff17191f"] {
        let (theme, cleanup) = loadTheme("return { bg = \"\(literal)\" }")
        defer { cleanup() }
        #expect(theme.bg == expected, "\(literal) should parse as it does in a palette file")
    }
    // Shorthand expands per digit: #17f -> 1177ff.
    let (theme, cleanup) = loadTheme("return { bg = \"#17f\" }")
    defer { cleanup() }
    #expect(theme.bg == NSColor(hex: "1177ff"))
}

@Test func anUnparseableOverrideLeavesTheExistingColourStanding() {
    let (theme, cleanup) = loadTheme("return { bg = \"not-a-colour\", fg = \"d8dee9\" }")
    defer { cleanup() }
    // The default, not black: a typo costs one wrong token, not a dead panel.
    #expect(theme.bg == Theme().bg)
    #expect(theme.fg == NSColor(hex: "d8dee9"))
}
