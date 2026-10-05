import AppKit
import Testing
@testable import KitsuneLauncher

private func loadThemeSet(_ source: String) -> (ThemeSet, () -> Void) {
    let directory = kitsuneTemporaryDirectory("kitsune-tint")
    let file = directory.appendingPathComponent("theme.lua")
    try? source.write(to: file, atomically: true, encoding: .utf8)
    return (ThemeRuntime().loadSet(file: file), { kitsuneRemove(directory) })
}

@Test func tintIsOffUnlessTheThemeAsksForIt() {
    let (themes, cleanup) = loadThemeSet("return { width = 400 }")
    defer { cleanup() }
    #expect(themes.global.tint == TintSpec())
    #expect(!themes.global.tint.isVisible)
}

@Test func tintDefaultsToTheBackgroundRole() {
    let (themes, cleanup) = loadThemeSet("""
    return { bg = "102030", tint = {} }
    """)
    defer { cleanup() }
    let theme = themes.global
    #expect(theme.tint.enabled)
    #expect(theme.tint.mode == .color)
    let wash = theme.tint.resolvedColor(in: theme)
    #expect(wash.withAlphaComponent(1) == NSColor(hex: "102030"))
    #expect(wash.alphaComponent == 0.15)
}

@Test func tintColorTakesARoleOrAFixedColour() {
    let (themes, cleanup) = loadThemeSet("""
    return {
      accent = "abcdef",
      tint = { color = "accent" },
      screens = { main = { tint = { color = "#123" } } },
    }
    """)
    defer { cleanup() }
    let global = themes.global
    #expect(global.tint.resolvedColor(in: global).withAlphaComponent(1) == NSColor(hex: "abcdef"))
    let main = themes.resolved(screenNumber: nil, localizedName: nil, isMain: true).theme
    #expect(main.tint.color == .fixed(Palette.color(from: "#123")!))
}

@Test func monochromeIgnoresThePaletteAndDimsHarder() {
    let (themes, cleanup) = loadThemeSet("""
    return { bg = "ff0000", tint = "monochrome" }
    """)
    defer { cleanup() }
    let theme = themes.global
    #expect(theme.tint.mode == .monochrome)
    let wash = theme.tint.resolvedColor(in: theme)
    #expect(wash.withAlphaComponent(1) == .black)
    #expect(wash.alphaComponent == 0.35)
}

/// The role is resolved against each display's own theme, not frozen at decode time,
/// so a display with its own palette is tinted in that palette.
@Test func tintRoleFollowsEachDisplaysTheme() {
    let (themes, cleanup) = loadThemeSet("""
    return {
      bg = "111111",
      tint = { screens = "all" },
      screens = { main = { bg = "222222" } },
    }
    """)
    defer { cleanup() }
    let main = themes.resolved(screenNumber: nil, localizedName: nil, isMain: true).theme
    #expect(main.tint.screens == .all)
    #expect(main.tint.resolvedColor(in: main).withAlphaComponent(1) == NSColor(hex: "222222"))
}

@Test func aDisplayOverrideMergesOntoTheGlobalTint() {
    let (themes, cleanup) = loadThemeSet("""
    return {
      tint = { alpha = 0.2, blur = 0.5 },
      screens = { main = { tint = { mode = "monochrome" } }, ["7"] = { tint = false } },
    }
    """)
    defer { cleanup() }
    let main = themes.resolved(screenNumber: nil, localizedName: nil, isMain: true).theme.tint
    #expect(main.mode == .monochrome)
    #expect(main.resolvedAlpha == 0.2)
    #expect(main.blur == 0.5)
    #expect(!themes.resolved(screenNumber: "7", localizedName: nil, isMain: false).theme.tint.enabled)
}

@Test func badTintValuesLeaveTheDefaultsStanding() {
    let (themes, cleanup) = loadThemeSet("""
    return { tint = { mode = "sepia", color = "nonsense", screens = "some", alpha = 4, blur = -1 } }
    """)
    defer { cleanup() }
    let tint = themes.global.tint
    #expect(tint.enabled)
    #expect(tint.mode == .color)
    #expect(tint.color == .role("bg"))
    #expect(tint.screens == .panel)
    #expect(tint.resolvedAlpha == 1)
    #expect(tint.blur == 0)
}

@Test func aBlurOnlyTintStillDraws() {
    var tint = TintSpec()
    tint.enabled = true
    tint.alpha = 0
    #expect(!tint.isVisible)
    tint.blur = 0.6
    #expect(tint.isVisible)
    tint.enabled = false
    #expect(!tint.isVisible)
}
