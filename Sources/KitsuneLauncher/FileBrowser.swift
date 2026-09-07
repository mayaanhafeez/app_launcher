import AppKit

/// A query that names a filesystem location rather than a menu, produced only by a
/// leading `/` or `~`. Splitting at the last separator is the whole trick: `~/dev/pro`
/// enumerates `~/dev` and filters by `pro`, so every keystroke after the separator is
/// a filter rather than another walk of the disk.
struct PathQuery: Equatable {
    /// What the user typed up to and including the last separator, verbatim. Browsing
    /// into a directory extends *this*, so a `~/`-rooted query stays `~/`-rooted
    /// instead of being replaced by an expanded absolute path mid-type.
    let prefix: String
    /// `prefix`, tilde-expanded: the directory actually enumerated.
    let directory: String
    /// The trailing fragment being matched against that directory's entries.
    let fragment: String

    /// Nil unless the query names a path. A query is not a path merely because it
    /// contains a slash — only a leading `/` or `~` switches the list over, so
    /// ordinary menu searches are untouched.
    init?(_ query: String) {
        guard query.hasPrefix("/") || query.hasPrefix("~") else { return nil }
        // `~foo` is a different user's home to the shell, and nothing this resolves.
        guard !query.hasPrefix("~") || query == "~" || query.hasPrefix("~/") else { return nil }

        let separator = query.lastIndex(of: "/")
        prefix = separator.map { String(query[...$0]) } ?? "~/"
        fragment = separator.map { String(query[query.index(after: $0)...]) } ?? ""
        directory = (prefix as NSString).expandingTildeInPath
    }

    /// What the panel's prompt says while browsing — the directory, written the short
    /// way the user would write it.
    var title: String { (directory as NSString).abbreviatingWithTildeInPath }
}

/// The filesystem as a row source. Everything here touches only the disk, so it runs
/// off the main thread and is testable against a temp directory.
enum FileBrowser {
    static let rowPrefix = "path:"

    /// The absolute path a path row points at, or nil for any other row.
    static func path(for row: DisplayRow) -> String? {
        row.id.hasPrefix(rowPrefix) ? String(row.id.dropFirst(rowPrefix.count)) : nil
    }

    /// One directory listing: filtered by the fragment, directories first, capped at
    /// `spec.limit`.
    ///
    /// Every row carries `.open(path)` — including directories, whose Return browses
    /// instead. That is what gives the actions menu Reveal in Finder, Copy Path and
    /// Open With here for free, with no new case in `RowActions`.
    nonisolated static func rows(for query: PathQuery, spec: FileSpec) -> [DisplayRow] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: query.directory) else { return [] }
        // A fragment that starts with a dot is the only reason anyone types one, so it
        // reveals hidden entries whatever the setting says.
        let wantsHidden = spec.showHidden || query.fragment.hasPrefix(".")

        let matches = names.compactMap { name -> (name: String, score: Int)? in
            guard wantsHidden || !name.hasPrefix(".") else { return nil }
            guard !query.fragment.isEmpty else { return (name, 0) }
            guard let score = FuzzyMatcher.score(query.fragment, in: name) else { return nil }
            return (name, score)
        }

        return matches
            .map { match -> (name: String, score: Int, isDirectory: Bool) in
                (match.name, match.score, isBrowsable(query.directory + "/" + match.name))
            }
            .sorted { lhs, rhs in
                // Directories first, as the spec asks: at a path you are usually on
                // your way somewhere rather than at the destination.
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .prefix(max(1, spec.limit))
            .enumerated()
            .map { index, entry in
                let path = query.directory + "/" + entry.name
                return DisplayRow(
                    id: rowPrefix + path,
                    // A directory is a menu, so it draws a chevron and reads as
                    // somewhere to go.
                    kind: entry.isDirectory ? .menu : .action,
                    label: entry.name,
                    detail: "",
                    symbol: "",
                    image: icon(for: path),
                    score: index,
                    section: "files",
                    action: .open(path)
                )
            }
    }

    /// A package is a directory the Finder presents as a file, so an `.app` opens
    /// rather than being browsed into — the same rule `AppIndex` applies when it
    /// declines to descend into one.
    nonisolated private static func isBrowsable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        return !NSWorkspace.shared.isFilePackage(atPath: path)
    }

    /// The same 2x flattening `AppIndex` uses, behind a small cache: a directory is
    /// re-enumerated on every keystroke, so the same icons are asked for over and
    /// over and a cache hit is the common case.
    nonisolated private static func icon(for path: String) -> NSImage {
        if let cached = iconCache.value(for: path) { return cached }
        let image = AppIndex.thumbnail(for: path)
        iconCache.store(image, for: path)
        return image
    }

    private static let iconCache = IconCache()

    /// Bounded, and cleared wholesale when it fills: this is a typing cache, not a
    /// store, and the cost of a miss is one icon.
    private final class IconCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: NSImage] = [:]
        private let capacity = 512

        func value(for path: String) -> NSImage? {
            lock.lock(); defer { lock.unlock() }
            return entries[path]
        }

        func store(_ image: NSImage, for path: String) {
            lock.lock(); defer { lock.unlock() }
            if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
            entries[path] = image
        }
    }
}
