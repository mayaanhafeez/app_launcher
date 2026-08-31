import AppKit

/// A colour scheme imported from an external file.
///
/// Base16, terminal-emulator configs and Omarchy's `colors.toml` are all flat
/// `key → hex` files; they differ only in separator and key vocabulary. So one
/// tokenizer reads every dialect and `role(_:)` resolves the semantic roles the
/// panel needs against a priority list of key names.
struct Palette: Sendable {
    private let values: [String: NSColor]
    let name: String

    init(name: String, values: [String: NSColor]) {
        self.name = name
        self.values = values
    }

    var isEmpty: Bool { values.isEmpty }

    /// First key that resolved, in the order given.
    func first(_ keys: [String]) -> NSColor? {
        for key in keys { if let color = values[key] { return color } }
        return nil
    }

    var background: NSColor? { first(["background", "base00", "main_bg", "bg"]) }
    var foreground: NSColor? { first(["foreground", "base05", "main_fg", "fg"]) }
    var surface: NSColor? { first(["lighter_background", "base01", "selected_bg", "color0", "dark_background"]) }
    var muted: NSColor? { first(["muted", "dark_foreground", "base03", "inactive_fg", "color8"]) }
    var accent: NSColor? { first(["accent", "base0d", "hi_fg", "blue", "color4", "selection_background"]) }
    var selection: NSColor? { first(["selection", "selection_background", "base02", "selected_bg"]) }
    var border: NSColor? { first(["lighter_background", "base02", "selection", "selected_bg", "muted", "color8"]) }

    // MARK: - Loading

    static func load(contentsOf url: URL) -> Palette? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let values = parse(text)
        guard !values.isEmpty else { return nil }
        // Omarchy stores schemes as <theme>/colors.toml, so the folder is the name.
        var name = url.deletingPathExtension().lastPathComponent
        if name == "colors" { name = url.deletingLastPathComponent().lastPathComponent }
        return Palette(name: name, values: values)
    }

    /// Resolves a `palette = ...` value: an explicit path, or a bare name looked up
    /// across the scheme directories that exist on this machine. `auto` follows
    /// `~/.config/theme`, so `set-theme` retints the launcher along with everything else.
    static func resolve(_ reference: String, configDirectory: URL) -> Palette? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var name = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        if name == "auto" {
            let pointer = home.appendingPathComponent(".config/theme")
            guard let active = try? String(contentsOf: pointer, encoding: .utf8) else { return nil }
            name = active.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
        }

        if name.contains("/") {
            return load(contentsOf: URL(fileURLWithPath: (name as NSString).expandingTildeInPath))
        }

        let underscored = name.replacingOccurrences(of: "-", with: "_")
        var candidates: [URL] = []
        for base in [name, underscored] {
            for ext in ["toml", "yaml", "yml", "conf", "theme", ""] {
                let filename = ext.isEmpty ? base : "\(base).\(ext)"
                candidates.append(configDirectory.appendingPathComponent("themes/\(filename)"))
            }
            candidates.append(home.appendingPathComponent("omarchy/themes/\(base)/colors.toml"))
            candidates.append(home.appendingPathComponent(".config/kitty/themes/\(base).conf"))
            candidates.append(home.appendingPathComponent(".config/ghostty/themes/\(base)"))
            candidates.append(home.appendingPathComponent(".config/btop/themes/\(base).theme"))
        }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let palette = load(contentsOf: url) { return palette }
        }
        return nil
    }

    // MARK: - Parsing

    static func parse(_ text: String) -> [String: NSColor] {
        var values: [String: NSColor] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // A hex literal never starts a line, so a leading marker is always a comment.
            guard !"#;".contains(line.first!), !line.hasPrefix("//"), !line.hasPrefix("--") else { continue }
            guard let (key, value) = split(line) else { continue }

            // Ghostty writes its ANSI colours as `palette = 0=#414868`.
            if key == "palette", let equals = value.firstIndex(of: "="), let index = Int(value[value.startIndex..<equals]) {
                if let color = color(from: String(value[value.index(after: equals)...])) { values["color\(index)"] = color }
                continue
            }
            if let color = color(from: value) { values[key] = color }
        }
        return values
    }

    /// Splits on the first `=` or `:`, falling back to whitespace for kitty's
    /// `foreground               #e5e5e5`.
    private static func split(_ line: String) -> (String, String)? {
        var separatorIndex: String.Index?
        for index in line.indices where line[index] == "=" || line[index] == ":" {
            separatorIndex = index
            break
        }
        let rawKey: String
        let rawValue: String
        if let separatorIndex {
            rawKey = String(line[line.startIndex..<separatorIndex])
            rawValue = String(line[line.index(after: separatorIndex)...])
        } else {
            guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
            rawKey = String(line[line.startIndex..<space])
            rawValue = String(line[space...])
        }
        let key = normalizeKey(rawKey)
        guard !key.isEmpty else { return nil }
        return (key, trimValue(rawValue))
    }

    /// `theme[main_bg]` -> `main_bg`; `"base00"` -> `base00`.
    private static func normalizeKey(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if key.hasPrefix("theme["), key.hasSuffix("]") {
            key = String(key.dropFirst("theme[".count).dropLast())
        }
        key = key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return key.replacingOccurrences(of: "-", with: "_")
    }

    /// A `#` only begins a comment when whitespace precedes it. Without that rule
    /// `palette = 0=#414868` loses its colour, and so does a bare `#rrggbb`.
    private static func commentStart(in value: String) -> String.Index? {
        var previous: Character?
        for index in value.indices {
            if value[index] == "#", let previous, previous == " " || previous == "\t" { return index }
            previous = value[index]
        }
        return nil
    }

    private static func trimValue(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        // Strip a trailing inline comment, but only past a quoted or hex value so a
        // leading `#rrggbb` is never mistaken for one.
        if let quote = value.first, quote == "\"" || quote == "'" {
            let body = value.dropFirst()
            if let close = body.firstIndex(of: quote) { value = String(body[body.startIndex..<close]) }
            else { value = String(body) }
        } else if let hash = commentStart(in: value) {
            value = String(value[value.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"',"))
    }

    /// Accepts `#rrggbb`, `rrggbb`, `#rgb` and JankyBorders' `0xaarrggbb`.
    static func color(from raw: String) -> NSColor? {
        var value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("0x") { value = String(value.dropFirst(2)) }
        if value.hasPrefix("#") { value = String(value.dropFirst()) }
        guard value.allSatisfy({ $0.isHexDigit }) else { return nil }
        switch value.count {
        case 3:
            let expanded = value.map { "\($0)\($0)" }.joined()
            return NSColor(hex: expanded)
        case 6:
            return NSColor(hex: value)
        case 8:
            // 0xAARRGGBB — drop the alpha, the theme composes its own.
            return NSColor(hex: String(value.dropFirst(2)))
        default:
            return nil
        }
    }
}

extension Theme {
    /// Seeds the palette-derived roles. Explicit `theme.lua` keys are applied after
    /// this and therefore still win.
    mutating func apply(palette: Palette) {
        if let value = palette.background { bg = value }
        if let value = palette.surface { surface = value }
        if let value = palette.foreground { fg = value }
        if let value = palette.muted { fgMuted = value }
        if let value = palette.accent { accent = value }
        if let value = palette.border { border = value }
        if let value = palette.selection { selectionBg = value }
    }
}
