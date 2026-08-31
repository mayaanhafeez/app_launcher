import AppKit

enum RowKind: String, Sendable {
    case action
    case menu
    case app
    case notice
    case separator
    /// The synthetic row that leaves a submenu. It backs no `MenuNode`, so every
    /// place that looks a row up by id has to check for it first.
    case back
}

/// An action described by Lua and executed by the host. Provider states have no
/// execution globals, so a provider row *describes* what to run and the host runs
/// it — that is what keeps dynamic rows sandboxed but still actionable.
enum ScriptAction: Sendable {
    case shell(String)
    case appleScript(String)
    case open(String)
    case url(String)

    static let queryToken = "{query}"

    private var template: String {
        switch self {
        case .shell(let value), .appleScript(let value), .open(let value), .url(let value): return value
        }
    }

    var wantsQuery: Bool { template.contains(Self.queryToken) }

    /// Substitutes the live query into `{query}`, escaped for the destination.
    /// Shell values arrive already single-quoted, so `brew install {query}` is safe
    /// to write bare.
    func resolved(query: String) -> ScriptAction {
        guard wantsQuery else { return self }
        switch self {
        case .shell(let value): return .shell(value.replacingOccurrences(of: Self.queryToken, with: Self.shellQuoted(query)))
        case .appleScript(let value): return .appleScript(value.replacingOccurrences(of: Self.queryToken, with: Self.appleScriptQuoted(query)))
        case .open(let value): return .open(value.replacingOccurrences(of: Self.queryToken, with: query))
        case .url(let value): return .url(value.replacingOccurrences(of: Self.queryToken, with: Self.urlEncoded(query)))
        }
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func urlEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}

struct MenuNode: Sendable {
    let id: String
    let parent: String
    let kind: RowKind
    let label: String
    /// Header text while this submenu is open. Defaults to `label`.
    var title: String = ""
    let detail: String
    let symbol: String
    /// Path to a custom image, `~` allowed. Wins over `symbol` when set.
    var iconPath: String = ""
    /// Extra route names for `orbitctl show <alias>`; also searchable.
    var aliases: [String] = []
    let provider: String?
    let actionReference: Int32?
    let scriptAction: ScriptAction?
    let order: Int

    var headerTitle: String { title.isEmpty ? label : title }
    /// Leaf id segment, so `install.editor.zed` is findable by typing "zed".
    var leafID: String { String(id.split(separator: ".").last ?? "") }
    var searchText: String { "\(label) \(detail) \(leafID) \(aliases.joined(separator: " "))" }
}

struct DisplayRow: @unchecked Sendable {
    let id: String
    let kind: RowKind
    let label: String
    let detail: String
    let symbol: String
    let image: NSImage?
    let score: Int
    let section: String
    /// Set on provider rows, which have no backing `MenuNode` to look up.
    var action: ScriptAction? = nil
}

struct AppEntry: @unchecked Sendable {
    let id: String
    let name: String
    let path: String
    let searchText: String
    let icon: NSImage
}

/// Global hotkey, configurable from `config.lua`.
struct HotKeySpec: Sendable, Equatable {
    var key: String = "space"
    var modifiers: [String] = ["option"]
}

/// The row that leaves a submenu, configured by `back = { ... }` in config.lua.
/// `back = false` there switches it off entirely.
struct BackRowSpec: Sendable, Equatable {
    var enabled = true
    var label = "Back"
    /// SF Symbol name; empty leaves the icon slot blank.
    var symbol = "chevron.left"
    var detail = ""
    /// `"top"` or `"bottom"` — anything else reads as top.
    var position = "top"

    var atTop: Bool { position.lowercased() != "bottom" }
}

/// Positional shortcuts for the visible list: the nth key activates the nth row.
/// Configured by `shortcuts = { ... }` in config.lua; `shortcuts = false` switches
/// them off. Kept pure — no AppKit state beyond the flags — so the key map is
/// testable without a window, like `VimKeys`.
struct ShortcutSpec: Sendable, Equatable {
    var enabled = true
    /// Modifier names from the same vocabulary as `hotkey.mods`.
    var modifiers: [String] = ["command"]
    /// Key characters by position: the first activates row 1, the second row 2, and
    /// so on. Ten by default, so "0" is the tenth row rather than the zeroth.
    var keys: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    /// Draw each row's shortcut on its right-hand side.
    var hints = true

    var flags: NSEvent.ModifierFlags {
        modifiers.reduce(into: NSEvent.ModifierFlags()) { mask, name in
            switch name.lowercased() {
            case "command", "cmd", "super": mask.insert(.command)
            case "option", "opt", "alt": mask.insert(.option)
            case "control", "ctrl": mask.insert(.control)
            case "shift": mask.insert(.shift)
            default: break
            }
        }
    }

    /// Modifier glyphs in the order macOS writes them, so a hint reads the way the
    /// same chord would in any other menu.
    var modifierGlyphs: String {
        let flags = self.flags
        var glyphs = ""
        if flags.contains(.control) { glyphs += "\u{2303}" }
        if flags.contains(.option) { glyphs += "\u{2325}" }
        if flags.contains(.shift) { glyphs += "\u{21E7}" }
        if flags.contains(.command) { glyphs += "\u{2318}" }
        return glyphs
    }

    /// What to draw on the row at `position`, or nil where there is no key for it.
    func hint(at position: Int) -> String? {
        guard enabled, hints, keys.indices.contains(position) else { return nil }
        return modifierGlyphs + keys[position].uppercased()
    }

    /// The 0-based list position a key press selects, or nil if it isn't a shortcut.
    /// Only the four intent-carrying modifiers are compared: caps lock and the
    /// numeric-pad/function bits ride along on ordinary presses and would otherwise
    /// break an exact match.
    func position(for characters: String, modifiers pressed: NSEvent.ModifierFlags) -> Int? {
        guard enabled else { return nil }
        let considered: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard !flags.isEmpty, pressed.intersection(considered) == flags else { return nil }
        let needle = characters.lowercased()
        return keys.firstIndex { $0.lowercased() == needle }
    }
}

/// Extra places to look for `.app` bundles, from `apps = { ... }` in config.lua.
/// The built-in roots (`/Applications`, `/System/Applications`, `~/Applications`)
/// are always scanned; these are added to them.
struct AppScanSpec: Sendable, Equatable {
    /// Roots to scan, `~` allowed.
    var paths: [String] = []
    /// How many path components below a root to walk. A root like `~/dev` can be
    /// enormous, and an app buried deeper than this is not something a launcher
    /// should be turning up. Three covers every built-in root, down to
    /// `~/Applications/CrossOver/Steam/Steam.app`.
    var depth = 3
}

struct Settings: Sendable {
    var hotKey = HotKeySpec()
    /// Modal navigation, off unless `vim = true` in config.lua.
    var vimMode = false
    /// Launch at login, off unless `login_item = true` in config.lua. Registering
    /// something with launchd is not a thing to do to a user by default.
    var loginItem = false
    var back = BackRowSpec()
    var shortcuts = ShortcutSpec()
    var apps = AppScanSpec()
}

// MARK: - Vim mode

enum InputMode: Sendable {
    case normal
    case insert
}

/// What a normal-mode key press means. Kept free of AppKit state so the key map is
/// testable on its own.
enum VimAction: Equatable, Sendable {
    case moveDown
    case moveUp
    /// `/` — clear the query and start typing.
    case beginSearch
    /// `i` — resume typing where the cursor was left.
    case insertAtCursor
    /// `a` — append at the end of the query.
    case insertAtEnd
    /// `s` — replace the query and start typing.
    case substitute
    /// Normal mode swallows unmapped keys, so letters never reach the field.
    case ignore
    /// Modified keys stay with AppKit so system shortcuts keep working.
    case passThrough
}

enum VimKeys {
    static func normalModeAction(characters: String, modifiers: NSEvent.ModifierFlags) -> VimAction {
        if !modifiers.intersection([.command, .control, .function]).isEmpty { return .passThrough }
        switch characters {
        case "j": return .moveDown
        case "k": return .moveUp
        case "/": return .beginSearch
        case "i": return .insertAtCursor
        case "a": return .insertAtEnd
        case "s": return .substitute
        default: return .ignore
        }
    }
}

// MARK: - Theme

/// Every value the panel draws with. Layout is native, so this token set *is* the
/// entire appearance surface — anything hardcoded in Panel.swift is a value the
/// user can never reach, which is why spacing, sizing and typography all live here.
struct Theme: Sendable {
    // Palette
    var bg = NSColor(hex: "17191f")
    var surface = NSColor(hex: "22252d")
    var fg = NSColor(hex: "d8dee9")
    var fgMuted = NSColor(hex: "7f8490")
    var accent = NSColor(hex: "7aa2f7")
    var border = NSColor(hex: "3b3f4a")
    var selectionBg: NSColor? = nil
    var selectionFg: NSColor? = nil

    // Alphas, composed onto the palette rather than baked into it
    var bgAlpha: CGFloat = 0.82
    var borderAlpha: CGFloat = 1
    var selectionAlpha: CGFloat = 0.10
    var detailAlpha: CGFloat = 0.55
    var chevronAlpha: CGFloat = 0.36
    var dividerAlpha: CGFloat = 0.20
    var blur: Double = 0.82

    // Geometry
    var radius: CGFloat = 12
    var rowRadius: CGFloat = 8
    var width: CGFloat = 380
    /// Cap on panel height as a fraction of the visible screen.
    var maxHeight: CGFloat = 0.6
    var borderWidth: CGFloat = 1
    var offsetY: CGFloat = 28

    // Spacing, all multiplied by `spacingScale`
    var spacingScale: CGFloat = 1
    var panelPadding: CGFloat = 12
    /// Per-edge overrides for `panelPadding`. Unset means "follow panelPadding", so a
    /// theme that only sets `panel_padding` keeps the uniform inset it has today.
    var paddingTop: CGFloat? = nil
    var paddingBottom: CGFloat? = nil
    var paddingSides: CGFloat? = nil
    var rowGap: CGFloat = 2
    var rowPaddingX: CGFloat = 10
    var iconSlot: CGFloat = 34
    var iconGap: CGFloat = 8
    var labelGap: CGFloat = 1
    var rowHeight: CGFloat = 44
    var rowHeightDetail: CGFloat = 56
    var dividerHeight: CGFloat = 15
    var headerGap: CGFloat = 8
    var selectionInset: CGFloat = 0
    var selectionBar: CGFloat = 0

    // Typography — one base size with a proportional scale, so `font_size` alone
    // rescales the whole panel coherently.
    var family = ""
    var fontSize: CGFloat = 13
    /// When the detail line renders: "search" (omarchy's behavior), "always", "never".
    var detailMode = "search"
    var labelWeight: NSFont.Weight = .medium
    var detailWeight: NSFont.Weight = .regular
}

extension Theme {
    func space(_ value: CGFloat) -> CGFloat { value <= 0 ? 0 : max(1, (value * spacingScale).rounded()) }

    // Resolved, scaled edge insets. Every call site uses these rather than
    // `space(panelPadding)`, so an override reaches the layout and the content
    // sizing together.
    var topPadding: CGFloat { space(paddingTop ?? panelPadding) }
    var bottomPadding: CGFloat { space(paddingBottom ?? panelPadding) }
    var sidePadding: CGFloat { space(paddingSides ?? panelPadding) }

    private func scaled(_ multiplier: CGFloat) -> CGFloat { max(1, (fontSize * multiplier).rounded()) }

    var captionSize: CGFloat { scaled(0.833) }
    var smallSize: CGFloat { scaled(0.917) }
    var bodySize: CGFloat { scaled(1.0) }
    var titleSize: CGFloat { scaled(1.167) }
    var headingSize: CGFloat { scaled(1.333) }
    var iconSize: CGFloat { scaled(1.5) }

    var selectionFill: NSColor { (selectionBg ?? fg).withAlphaComponent(selectionAlpha) }
    var selectionText: NSColor { selectionFg ?? accent }
    var cardBackground: NSColor { bg.withAlphaComponent(bgAlpha) }
    var borderColor: NSColor { border.withAlphaComponent(borderAlpha) }
    var detailColor: NSColor { fgMuted.withAlphaComponent(detailAlpha) }
    var chevronColor: NSColor { fg.withAlphaComponent(chevronAlpha) }
    var dividerColor: NSColor { fg.withAlphaComponent(dividerAlpha) }

    var headerHeight: CGFloat { max(space(30), headingSize + space(12)) }
    /// Leading edge of the label column: icon slot plus its gutters.
    var labelInset: CGFloat { space(rowPaddingX) + space(iconSlot) + space(iconGap) }

    func rowHeight(hasDetail: Bool) -> CGFloat { space(hasDetail ? rowHeightDetail : rowHeight) }

    /// Resolves the themed family, falling back to the system font. A named family
    /// keeps its requested weight instead of silently dropping to regular.
    func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        guard !family.isEmpty, let base = NSFont(name: family, size: size) else {
            return .systemFont(ofSize: size, weight: weight)
        }
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func weight(named name: String) -> NSFont.Weight? {
        switch name.lowercased() {
        case "ultralight": return .ultraLight
        case "thin": return .thin
        case "light": return .light
        case "regular", "normal": return .regular
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        case "black": return .black
        default: return nil
        }
    }
}

extension NSColor {
    convenience init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard clean.count == 6, let value = UInt64(clean, radix: 16) else {
            self.init(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            return
        }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}

enum FuzzyMatcher {
    static func score(_ query: String, in candidate: String) -> Int? {
        let needle = Array(query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current))
        if needle.isEmpty { return 0 }
        let haystack = Array(candidate.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current))
        var position = 0
        var score = 0
        var previous = -2
        for character in needle {
            guard let found = haystack[position...].firstIndex(of: character) else { return nil }
            let index = found
            score += index == previous + 1 ? 1 : 8 + index - position
            if index == 0 || " /._-".contains(haystack[max(0, index - 1)]) { score -= 5 }
            previous = index
            position = index + 1
        }
        return max(0, score + haystack.count / 12)
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
