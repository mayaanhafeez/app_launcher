import AppKit

enum RowKind: String, Sendable {
    case action
    case menu
    case app
    case notice
    case separator
}

struct MenuNode: Sendable {
    let id: String
    let parent: String
    let kind: RowKind
    let label: String
    let detail: String
    let symbol: String
    let provider: String?
    let actionReference: Int32?
    let scriptAction: ScriptAction?
    let order: Int
}

enum ScriptAction: Sendable {
    case shell(String)
    case appleScript(String)
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
}

struct AppEntry: @unchecked Sendable {
    let id: String
    let name: String
    let path: String
    let searchText: String
    let icon: NSImage
}

struct Theme: Sendable {
    var bg = NSColor(hex: "17191f")
    var surface = NSColor(hex: "22252d")
    var accent = NSColor(hex: "7aa2f7")
    var fg = NSColor(hex: "d8dee9")
    var fgMuted = NSColor(hex: "7f8490")
    var border = NSColor(hex: "3b3f4a")
    var radius: CGFloat = 18
    var rowHeight: CGFloat = 56
    var padding: CGFloat = 18
    var font = "SF Pro"
    var fontSize: CGFloat = 15
    var blur = 0.82
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
