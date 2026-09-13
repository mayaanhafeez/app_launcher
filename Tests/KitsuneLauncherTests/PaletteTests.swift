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

// MARK: - Shipped colour schemes

private func shippedSchemes() throws -> [(name: String, palette: Palette)] {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let directory = repo.appendingPathComponent("Config/colour_schemes")
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "toml" }.sorted { $0.path < $1.path }
    return try files.map { (name: $0.deletingPathExtension().lastPathComponent, palette: try #require(Palette.load(contentsOf: $0))) }
}

// A shipped scheme that leaves a role unresolved falls back to that token's built-in
// value, so half the panel would be the theme and half would not — and silently.
@Test func everyShippedSchemeFillsEveryRole() throws {
    let schemes = try shippedSchemes()
    #expect(schemes.count == 21)
    for (name, palette) in schemes {
        #expect(palette.background != nil, "\(name) has no background")
        #expect(palette.foreground != nil, "\(name) has no foreground")
        #expect(palette.surface != nil, "\(name) has no surface")
        #expect(palette.muted != nil, "\(name) has no muted")
        #expect(palette.accent != nil, "\(name) has no accent")
        #expect(palette.selection != nil, "\(name) has no selection")
        #expect(palette.border != nil, "\(name) has no border")
    }
}

// btop's `hi_fg` is a highlight *foreground* and some themes set it to the text colour.
// Converted blindly that leaves an accent invisible against the label it tints, which is
// how the three Rosé Pine variants came to be mapped from upstream instead.
@Test func noShippedSchemeUsesItsTextColourAsTheAccent() throws {
    for (name, palette) in try shippedSchemes() {
        #expect(hex(palette.accent) != hex(palette.foreground), "\(name)'s accent is its foreground")
        #expect(hex(palette.background) != hex(palette.foreground), "\(name) is unreadable")
    }
}

// The menu offers a name; the schemes answer it. A menu row with no scheme behind it is
// one that silently does not retint on a machine without the other tools installed.
// Only that direction is checked: a scheme can land before the row that offers it, and
// `set-theme` knows names this menu has not caught up with.
@Test func shippedSchemesCoverEveryThemeTheMenuOffers() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: repo.appendingPathComponent("Config/plugins/themes.lua"), encoding: .utf8)
    // Just the `local themes = { ... }` table: the comments above it name other things.
    let table = try #require(source.firstMatch(of: /local themes = \{([^}]*)\}/)).1
    let listed = Set(table.matches(of: /"([a-z0-9-]+)"/).map { String($0.1) })
    #expect(listed.count >= 20, "the theme table did not parse")
    #expect(listed.subtracting(Set(try shippedSchemes().map(\.name))).isEmpty,
            "offered by the menu with no shipped scheme")
}

// The Dawn confusion this set exists to end: Omarchy ships its `rose-pine` light, so the
// shipped one must be the dark original and Dawn must keep its own name.
@Test func shippedRosePineIsDarkAndDawnIsSeparate() throws {
    let schemes = Dictionary(uniqueKeysWithValues: try shippedSchemes().map { ($0.name, $0.palette) })
    #expect(hex(schemes["rose-pine"]?.background) == "191724")
    #expect(hex(schemes["rose-pine-moon"]?.background) == "232136")
    #expect(hex(schemes["rose-pine-dawn"]?.background) == "faf4ed")
}

// Shipped schemes live under the config directory, so `resolve` has to reach them there
// — and yield to every other location, or the panel would stop following a theme the
// rest of the system reads from its own files. The name is one no machine can already
// have: a real one would let the developer's own ~/omarchy answer first.
@Test func shippedSchemesResolveByNameButYieldToTheOverrideSlot() throws {
    let config = kitsuneTemporaryDirectory("kitsune-palette")
    defer { kitsuneRemove(config) }
    func write(_ relative: String, _ background: String) throws {
        let url = config.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "background = #\(background)\nforeground = #ffffff".write(to: url, atomically: true, encoding: .utf8)
    }

    try write("colour_schemes/kitsune-test-scheme.toml", "010203")
    #expect(hex(Palette.resolve("kitsune-test-scheme", configDirectory: config)?.background) == "010203")

    // themes/<name> still wins, so overriding a shipped scheme needs no edit to it.
    try write("themes/kitsune-test-scheme.toml", "040506")
    #expect(hex(Palette.resolve("kitsune-test-scheme", configDirectory: config)?.background) == "040506")
}

// A hyphenated name must not reach a *later* location before an *earlier* one gets to
// try the underscored spelling. Walking the whole list per spelling did exactly that:
// btop's theme directory is entirely underscored and `colour_schemes` is hyphenated like
// the menu, so all 21 shipped schemes beat btop's file for the same theme — the shipped
// set silently stopped being a fallback for every name btop spells with underscores.
@Test func anEarlierLocationWinsEvenWhenItSpellsTheNameTheOtherWay() throws {
    let config = kitsuneTemporaryDirectory("kitsune-palette")
    defer { kitsuneRemove(config) }
    func write(_ relative: String, _ background: String) throws {
        let url = config.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "background = #\(background)\nforeground = #ffffff".write(to: url, atomically: true, encoding: .utf8)
    }

    // themes/ is the earlier location and holds only the underscored spelling;
    // colour_schemes/ is the later one and holds the hyphenated spelling the caller used.
    try write("themes/kitsune_test_scheme.toml", "aaaaaa")
    try write("colour_schemes/kitsune-test-scheme.toml", "bbbbbb")
    #expect(hex(Palette.resolve("kitsune-test-scheme", configDirectory: config)?.background) == "aaaaaa")

    // Only that direction: `resolve` spells a name with underscores as an alternative,
    // never the reverse, so an underscored query does not reach a hyphenated file. Every
    // name that arrives here — the menu's rows, ~/.config/theme — is hyphenated.
    kitsuneRemove(config.appendingPathComponent("themes"))
    #expect(Palette.resolve("kitsune-test-scheme", configDirectory: config) != nil)
    #expect(Palette.resolve("kitsune_test_scheme", configDirectory: config) == nil)
}
