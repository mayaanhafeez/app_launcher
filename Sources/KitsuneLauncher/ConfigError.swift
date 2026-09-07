import Foundation

/// What a failed config load actually says to the user.
///
/// Lua's own message is accurate and almost unreadable: it names the token where
/// parsing *stopped*, which for the commonest mistake — a missing comma — is lines
/// below the mistake itself, and it repeats an absolute path that is identical for
/// every error a given user will ever see. `'}' expected (to close '{' at line 115)
/// near 'items'` is a true statement about line 127 and tells you nothing about line
/// 126, which is where the comma went missing.
///
/// So the raw message is kept — it is what a search engine matches — and framed:
/// paths are made relative to the config directory, every line the message names is
/// quoted from the file, and a parse error says out loud that the line it names is
/// where Lua gave up rather than where the mistake is.
struct ConfigError: Equatable, Sendable {
    /// One line, paths shortened: `config.lua:127: '}' expected …`.
    var summary: String
    /// The lines the message named, quoted from the file in file order. Empty when
    /// none could be read — a deleted file, or a message naming no line at all.
    var excerpt: [String]
    /// Why the named line may not be the line to edit. Empty for anything that is not
    /// a parse error.
    var hint: String

    /// Everything, for the alert and the clipboard.
    var full: String {
        ([summary] + (excerpt.isEmpty ? [] : [""] + excerpt) + (hint.isEmpty ? [] : ["", hint]))
            .joined(separator: "\n")
    }
}

enum ConfigErrorFormatter {
    /// One load can report more than one problem — a broken `config.lua` *and* the
    /// plugin its `pcall` swallowed. They arrive newline-separated, and a Lua message
    /// carries its own continuation lines indented with a tab, which is what tells the
    /// two apart.
    static func describeAll(
        _ text: String,
        directory: URL? = nil,
        source: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> [ConfigError] {
        var problems: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("\t"), !problems.isEmpty {
                problems[problems.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if !line.isEmpty {
                problems.append(line)
            }
        }
        return problems.map { describe($0, directory: directory, source: source) }
    }

    /// One line for the panel's banner strip: the first problem, and a count of the
    /// rest. The full text is a Lua traceback and belongs in the alert.
    static func banner(for problems: [ConfigError]) -> String? {
        guard let first = problems.first else { return nil }
        let extra = problems.count - 1
        return extra > 0 ? "\(first.summary)  (+\(extra) more)" : first.summary
    }

    /// `Config: `, `Theme: ` and friends are added by `LuaRuntime.reportError` and are
    /// already said by the alert's title.
    private static let prefixes = ["Config: ", "Theme: ", "Action: ", "Provider: "]

    /// Every `…/foo.lua:12` in a Lua message. Deliberately anchored on the extension:
    /// a message also carries quoted source text, and this must not go looking for
    /// colons inside it.
    private static let reference = try! NSRegularExpression(pattern: "(/[^\\s:'\"]+\\.lua):(\\d+)")
    /// The second half of `'}' expected (to close '{' at line 115)`, which names a line
    /// without naming its file.
    private static let bareLine = try! NSRegularExpression(pattern: "at line (\\d+)")

    /// `source` reads a file by path — injected so the whole formatter is testable
    /// without touching the disk, on the same argument as `ClipboardHistory.Reading`.
    static func describe(
        _ message: String,
        directory: URL? = nil,
        source: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> ConfigError {
        var raw = message
        for prefix in prefixes where raw.hasPrefix(prefix) { raw = String(raw.dropFirst(prefix.count)) }
        raw = raw.replacingOccurrences(of: "\n\t", with: " ").replacingOccurrences(of: "\n", with: " ")

        let references = matches(reference, in: raw).map { (path: $0[1], line: Int($0[2]) ?? 0) }
        // The first file named is the one the error is *in*: a module failure names the
        // module's file first, then repeats it inside Lua's own message.
        let file = references.first?.path
        var lines = Set(references.filter { $0.path == file }.map(\.line))
        // A bare `at line N` belongs to the same file — Lua only ever names one.
        lines.formUnion(matches(bareLine, in: raw).compactMap { Int($0[1]) })

        var summary = raw
        for path in Set(references.map(\.path)) {
            summary = summary.replacingOccurrences(of: path, with: shorten(path, directory: directory))
        }

        return ConfigError(
            summary: summary,
            excerpt: file.map { quote(lines: lines, of: $0, source: source) } ?? [],
            hint: raw.contains("expected") || raw.contains("unexpected symbol")
                ? "Lua names the line where it gave up, not the line to fix — a missing comma, `}` or `end` is usually just above it."
                : ""
        )
    }

    /// `/Users/me/.config/kitsune/plugins/git.lua` → `plugins/git.lua`, which is what
    /// the user calls the file. Falls back to the last component for a path outside
    /// the config directory (a `require` reaching somewhere else entirely).
    private static func shorten(_ path: String, directory: URL?) -> String {
        if let directory {
            let root = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
            if path.hasPrefix(root) { return String(path.dropFirst(root.count)) }
        }
        return (path as NSString).lastPathComponent
    }

    /// The named lines, in file order, numbered to line up with the editor. A line the
    /// file does not have is skipped rather than reported as blank — the file on disk
    /// may already have moved on from the load that failed.
    private static func quote(lines: Set<Int>, of path: String, source: (String) -> String?) -> [String] {
        guard !lines.isEmpty, let text = source(path) else { return [] }
        let all = text.components(separatedBy: "\n")
        let width = String(lines.max() ?? 0).count
        return lines.sorted().compactMap { number in
            guard number > 0, number <= all.count else { return nil }
            let padded = String(repeating: " ", count: width - String(number).count) + String(number)
            return "  \(padded) │ \(all[number - 1].trimmingCharacters(in: .whitespaces))"
        }
    }

    private static func matches(_ expression: NSRegularExpression, in text: String) -> [[String]] {
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}
