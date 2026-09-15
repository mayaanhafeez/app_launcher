import AppKit
import Testing
@testable import KitsuneLauncher

private func loadThemeSet(_ source: String) -> (ThemeSet, () -> Void) {
    let directory = kitsuneTemporaryDirectory("kitsune-screen-theme")
    let file = directory.appendingPathComponent("theme.lua")
    try? source.write(to: file, atomically: true, encoding: .utf8)
    return (ThemeRuntime().loadSet(file: file), { kitsuneRemove(directory) })
}

@Test func screenOverridesInheritTheGlobalTheme() {
    let (themes, cleanup) = loadThemeSet("""
    return {
      width = 400,
      accent = "112233",
      screens = { ["42"] = { width = 500 } },
    }
    """)
    defer { cleanup() }
    let resolved = themes.resolved(screenNumber: "42", localizedName: nil, isMain: false).theme
    #expect(resolved.width == 500)
    #expect(resolved.accent == NSColor(hex: "112233"))
    #expect(themes.resolved(screenNumber: "7", localizedName: nil, isMain: false).theme.width == 400)
}

@Test func screenCanSelectItsOwnPaletteAndOverrideIt() {
    let (themes, cleanup) = loadThemeSet("""
    return {
      palette = "missing-global",
      screens = { main = { palette = "missing-screen", accent = "abcdef" } },
    }
    """)
    defer { cleanup() }
    let resolved = themes.resolved(screenNumber: nil, localizedName: nil, isMain: true)
    #expect(resolved.theme.accent == NSColor(hex: "abcdef"))
}

@Test func stableDisplayNumberTakesPriorityOverTheDisplayName() {
    var themes = ThemeSet(global: Theme())
    var named = Theme(); named.width = 450
    var numbered = Theme(); numbered.width = 520
    themes.screens = [
        ScreenTheme(key: "Studio Display", theme: named, paletteName: ""),
        ScreenTheme(key: "42", theme: numbered, paletteName: ""),
    ]
    #expect(themes.resolved(screenNumber: "42", localizedName: "Studio Display", isMain: false).theme.width == 520)
}
