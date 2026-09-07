import AppKit
import Foundation
import Testing
@testable import KitsuneLauncher

// What the user is shown when a config fails to load. Lua's raw message is a true
// statement that reads as a wrong one — it names the line where the parser gave up,
// which for a missing comma is below the line to fix, and repeats an absolute path
// that is the same in every error that user will ever see.

private let configDirectory = URL(fileURLWithPath: "/Users/me/.config/kitsune")

/// The config that produced the message below: the comma after line 126 is missing,
/// and Lua notices at `items` on 127.
private func sourceLines() -> String {
    var lines = (1...130).map { "line \($0)" }
    lines[114] = "return {"
    lines[125] = "  vim = false"
    lines[126] = "  items = items,"
    return lines.joined(separator: "\n")
}

private func reader(_ text: String?) -> (String) -> String? { { _ in text } }

@Test func aParseErrorNamesTheFileTheUserKnowsAndQuotesBothLines() {
    let report = ConfigErrorFormatter.describe(
        "Config: /Users/me/.config/kitsune/config.lua:127: '}' expected (to close '{' at line 115) near 'items'",
        directory: configDirectory,
        source: reader(sourceLines())
    )

    // The `Config: ` prefix is the alert's title, and the absolute path is noise.
    #expect(report.summary == "config.lua:127: '}' expected (to close '{' at line 115) near 'items'")
    // Both lines the message names, quoted — including the one Lua only refers to as
    // "line 115", which carries no file of its own.
    #expect(report.excerpt == ["  115 │ return {", "  127 │ items = items,"])
    // The complaint this answers: the line it names is not the line to edit.
    #expect(report.hint.contains("not the line to fix"))
}

@Test func aNestedModuleErrorKeepsThePathTheUserTyped() {
    // `plugins/themes.lua`, not `themes.lua`: the module name is how the config refers
    // to it, and there may be a `themes.lua` at the root as well.
    let report = ConfigErrorFormatter.describe(
        """
        Config: error loading module 'plugins.themes' from file '/Users/me/.config/kitsune/plugins/themes.lua':
        \t/Users/me/.config/kitsune/plugins/themes.lua:12: '}' expected near 'return'
        """,
        directory: configDirectory,
        source: reader((1...12).map { "entry \($0)" }.joined(separator: "\n"))
    )

    #expect(report.summary.contains("plugins/themes.lua:12"))
    #expect(!report.summary.contains("/Users/me"))
    // The tab-indented continuation is folded onto one line rather than left to wrap.
    #expect(!report.summary.contains("\n"))
    #expect(report.excerpt == ["  12 │ entry 12"])
}

@Test func aPathOutsideTheConfigDirectoryFallsBackToItsName() {
    let report = ConfigErrorFormatter.describe(
        "Config: /opt/share/lua/thing.lua:3: unexpected symbol near '='",
        directory: configDirectory,
        source: reader(nil)
    )
    #expect(report.summary == "thing.lua:3: unexpected symbol near '='")
    // Nothing to quote when the file cannot be read; the summary still stands alone.
    #expect(report.excerpt.isEmpty)
    #expect(report.full == report.summary + "\n\n" + report.hint)
}

@Test func aRuntimeErrorGetsNoParserHint() {
    // The hint is about where a *parser* stops. A runtime error names the line that
    // actually ran, so saying "look above it" would be wrong.
    let report = ConfigErrorFormatter.describe(
        "Config: /Users/me/.config/kitsune/config.lua:40: attempt to index a nil value (global 'DEFAULTS')",
        directory: configDirectory,
        source: reader(nil)
    )
    #expect(report.hint.isEmpty)
    #expect(report.summary == "config.lua:40: attempt to index a nil value (global 'DEFAULTS')")
}

@Test func aLineTheFileNoLongerHasIsSkipped() {
    // The file on disk can have moved on from the load that failed — a save the
    // watcher has not reported yet. Quoting past the end would be worse than quoting
    // nothing.
    let report = ConfigErrorFormatter.describe(
        "Config: /Users/me/.config/kitsune/config.lua:900: '}' expected",
        directory: configDirectory,
        source: reader("return {}")
    )
    #expect(report.excerpt.isEmpty)
    #expect(report.summary == "config.lua:900: '}' expected")
}

@Test func severalProblemsAreSplitOnTheirOwnLinesNotOnLuaContinuations() {
    // A load reports a broken config *and* whatever its `pcall` swallowed. The two are
    // newline-separated; a Lua message's own continuation is tab-indented.
    let problems = ConfigErrorFormatter.describeAll(
        """
        Config: /Users/me/.config/kitsune/config.lua:127: '}' expected near 'items'
        error loading module 'plugins.themes' from file '/Users/me/.config/kitsune/plugins/themes.lua':
        \t/Users/me/.config/kitsune/plugins/themes.lua:12: unexpected symbol near '='
        """,
        directory: configDirectory,
        source: reader(nil)
    )

    #expect(problems.count == 2)
    #expect(problems[0].summary.hasPrefix("config.lua:127:"))
    #expect(problems[1].summary.contains("plugins/themes.lua:12"))
}

@Test func theBannerIsOneLineAndCountsTheRest() {
    let one = ConfigError(summary: "config.lua:127: '}' expected", excerpt: [], hint: "")
    let two = ConfigError(summary: "plugins/themes.lua:12: bad", excerpt: [], hint: "")

    #expect(ConfigErrorFormatter.banner(for: []) == nil)
    #expect(ConfigErrorFormatter.banner(for: [one]) == "config.lua:127: '}' expected")
    #expect(ConfigErrorFormatter.banner(for: [one, two])?.hasSuffix("(+1 more)") == true)
    // One line: the banner is a strip across the bottom of the card.
    #expect(ConfigErrorFormatter.banner(for: [one, two])?.contains("\n") == false)
}

@MainActor
@Test func theErrorGlyphIsRepaintedRatherThanTinted() {
    // `contentTintColor` is ignored for a template image in the menu bar — the status
    // item draws it as a mask in the menu bar's own text colour, which is what left the
    // icon black with an error outstanding. The red has to be painted in, and a painted
    // image must stop being a template or the mask wins again.
    let base = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
        NSColor.black.set(); rect.fill(); return true
    }
    base.isTemplate = true

    let tinted = MenuBarItem.tinted(base, .systemRed)
    #expect(tinted.isTemplate == false)
    #expect(base.isTemplate == true)
    #expect(tinted.size == base.size)

    let bitmap = NSBitmapImageRep(data: tinted.tiffRepresentation!)!
    let centre = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!
        .usingColorSpace(.deviceRGB)!
    #expect(centre.redComponent > 0.5)
    #expect(centre.greenComponent < 0.5)
}
