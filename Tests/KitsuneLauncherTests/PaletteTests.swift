import AppKit
import Testing
@testable import KitsuneLauncher

private func hex(_ color: NSColor?) -> String? {
    guard let srgb = color?.usingColorSpace(.sRGB) else { return nil }
    return String(format: "%02x%02x%02x",
                  Int((srgb.redComponent * 255).rounded()),
                  Int((srgb.greenComponent * 255).rounded()),
                  Int((srgb.blueComponent * 255).rounded()))
}

@Test func readsOmarchyColorsToml() {
    let palette = Palette(name: "kanagawa", values: Palette.parse("""
    mode = "dark"

    accent = "#dcd7ba"
    selection = "#363646"
    muted = "#54546D"

    background = "#1f1f28"
    lighter_background = "#223249"
    foreground = "#dcd7ba"
    """))
    #expect(hex(palette.background) == "1f1f28")
    #expect(hex(palette.foreground) == "dcd7ba")
    #expect(hex(palette.accent) == "dcd7ba")
    #expect(hex(palette.selection) == "363646")
    #expect(hex(palette.muted) == "54546d")
    #expect(hex(palette.surface) == "223249")
}

@Test func readsBase16Yaml() {
    // Both the flat legacy layout and the newer `palette:` block parse the same way.
    let palette = Palette(name: "dracula", values: Palette.parse("""
    scheme: "Dracula"
    author: "Jamy Golden"
    palette:
      base00: "282a36"
      base01: "44475a"
      base02: "44475a"
      base03: "6272a4"
      base05: "f8f8f2"
      base0D: "bd93f9"
    """))
    #expect(hex(palette.background) == "282a36")
    #expect(hex(palette.foreground) == "f8f8f2")
    #expect(hex(palette.accent) == "bd93f9")   // base0D
    #expect(hex(palette.muted) == "6272a4")    // base03
    #expect(hex(palette.surface) == "44475a")  // base01
}

@Test func readsKittyConf() {
    // Whitespace-separated, with `##` header comments and a `#rrggbb` value.
    let palette = Palette(name: "andromeda", values: Palette.parse("""
    ## name: Andromeda
    ## author: Signal Directive

    foreground               #e5e5e5
    background               #23262e
    selection_background     #d65d0e
    color8                   #6c6c6c
    """))
    #expect(hex(palette.background) == "23262e")
    #expect(hex(palette.foreground) == "e5e5e5")
    #expect(hex(palette.selection) == "d65d0e")
    #expect(hex(palette.muted) == "6c6c6c")
}

@Test func readsGhosttyPaletteEntries() {
    let values = Palette.parse("""
    background = #1a1b26
    foreground = #ffffff
    selection-background = #bb9af7
    palette = 0=#414868
    palette = 4=#7aa2f7
    """)
    let palette = Palette(name: "archriot", values: values)
    #expect(hex(palette.background) == "1a1b26")
    #expect(hex(palette.selection) == "bb9af7")
    #expect(hex(values["color0"]) == "414868")
    #expect(hex(values["color4"]) == "7aa2f7")
}

@Test func readsBtopThemeBrackets() {
    let palette = Palette(name: "andromeda", values: Palette.parse("""
    # Andromeda — btop theme
    theme[main_bg]="#23262e"
    theme[main_fg]="#e5e5e5"
    """))
    #expect(hex(palette.background) == "23262e")
    #expect(hex(palette.foreground) == "e5e5e5")
}

@Test func acceptsTheHexFormsInTheWild() {
    #expect(hex(Palette.color(from: "#1e1e2e")) == "1e1e2e")
    #expect(hex(Palette.color(from: "1e1e2e")) == "1e1e2e")
    #expect(hex(Palette.color(from: "#abc")) == "aabbcc")
    #expect(hex(Palette.color(from: "0xff89b4fa")) == "89b4fa")  // JankyBorders
    #expect(Palette.color(from: "dark") == nil)
    #expect(Palette.color(from: "") == nil)
}

@Test func inlineCommentsDoNotEatHexValues() {
    let values = Palette.parse("""
    accent = "#dcd7ba"  # the comment
    background = #1f1f28
    """)
    #expect(hex(values["accent"]) == "dcd7ba")
    #expect(hex(values["background"]) == "1f1f28")
}

@Test func paletteSeedsThemeRolesButKeepsOtherTokens() {
    var theme = Theme()
    let radius = theme.radius
    theme.apply(palette: Palette(name: "t", values: Palette.parse("background = #101010\nforeground = #fefefe")))
    #expect(hex(theme.bg) == "101010")
    #expect(hex(theme.fg) == "fefefe")
    #expect(theme.radius == radius)   // palettes carry colour only
}
