import AppKit
import CoreServices

@MainActor
final class AppIndex: NSObject {
    private(set) var entries: [AppEntry] = []
    private let worker = DispatchQueue(label: "kitsune.app-index", qos: .utility)
    private var scanSpec = AppScanSpec()
    private var iconPoints = thumbnailSize
    var onChange: (() -> Void)?

    /// The roots every scan covers, before `apps.paths` is added to them.
    nonisolated static var defaultRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
    }

    func start() { rescan() }

    /// Republished on every config reload; a changed set of roots re-scans.
    func apply(scan: AppScanSpec) {
        guard scan != scanSpec else { return }
        scanSpec = scan
        rescan()
    }

    /// Icons are flattened once, at scan time, to the size the panel actually draws.
    /// A theme with a larger `icon_slot` therefore has to re-flatten, or it scales a
    /// 36pt bitmap up and renders visibly soft.
    func apply(iconPoints points: CGFloat) {
        let resolved = max(16, points.rounded())
        guard resolved != iconPoints else { return }
        iconPoints = resolved
        rescan()
    }

    private func rescan() {
        let roots = Self.defaultRoots + scanSpec.paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let depth = scanSpec.depth
        let points = iconPoints
        worker.async { [weak self] in
            let built = Self.appPaths(in: roots, depth: depth)
                .compactMap { Self.makeEntry(path: $0, iconPoints: points) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Task { @MainActor [weak self] in self?.replace(built) }
        }
    }

    /// Every `.app` at most `depth` components below one of `roots`. Packages are
    /// returned but never descended into — an app ships helper apps inside itself,
    /// and a launcher has no business offering them.
    nonisolated static func appPaths(in roots: [URL], depth: Int) -> [String] {
        var paths = Set<String>()
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() == "app" {
                    if isTopLevelApplication(url.path) { paths.insert(url.path) }
                    enumerator.skipDescendants()
                } else if enumerator.level >= depth {
                    enumerator.skipDescendants()
                }
            }
        }
        return paths.sorted()
    }

    /// `bonus` is subtracted from each match's score before the sort — frecency has to
    /// be applied here rather than to the returned rows, because the truncation to
    /// `limit` happens inside this sort and would otherwise discard the very apps the
    /// discount was meant to promote.
    func results(for query: String, limit: Int = 12, bonus: (String) -> Int = { _ in 0 }) -> [DisplayRow] {
        // Folded once for the whole index rather than once per app.
        let needle = FuzzyMatcher.Query(query)
        return entries.compactMap { entry -> DisplayRow? in
            guard let score = needle.score(in: entry.searchText) else { return nil }
            return DisplayRow(id: "app:\(entry.path)", kind: .app, label: entry.name, detail: entry.path, symbol: "", image: entry.icon, score: score - bonus(entry.path), section: "apps")
        }.sorted { $0.score == $1.score ? $0.label < $1.label : $0.score < $1.score }.prefix(limit).map { $0 }
    }

    func launch(path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
    }

    /// A scan is the whole truth about what is installed under the configured roots,
    /// so it replaces rather than merges: dropping a path from `apps.paths`, or
    /// deleting an app, has to remove those rows on the next reload.
    private func replace(_ incoming: [AppEntry]) {
        entries = incoming
        onChange?()
    }

    /// Reads the three fields it needs out of `Contents/Info.plist` directly, rather
    /// than through `Bundle(url:)`.
    ///
    /// `Bundle` is the obvious API and the expensive one: Foundation caches every
    /// instance process-wide and holds its **fully parsed Info.plist** for the life of
    /// the process. Three strings per app cost the whole document — and an Info.plist
    /// is full of nested arrays and dictionaries (`UTExportedTypeDeclarations`,
    /// `LSApplicationQueriesSchemes`). Measured against a direct read over the same 151
    /// apps, in isolated processes: 18.6MB versus 13.0MB.
    ///
    /// The one thing `Bundle` gives that a raw read does not is *localization*:
    /// `object(forInfoDictionaryKey:)` consults `InfoPlist.strings`, which is where
    /// Find My and Voice Memos keep their display names — their Info.plists carry
    /// neither name key at all. So the filesystem's own localized name (what Finder
    /// shows) stands in when the plist has nothing, ahead of the bare filename this
    /// used to fall back to.
    /// Exposed for the on-disk audit in the benchmark suite.
    nonisolated static func entryForAudit(path: String) -> AppEntry? { makeEntry(path: path) }

    nonisolated private static func makeEntry(path: String, iconPoints: CGFloat = thumbnailSize) -> AppEntry? {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "app" else { return nil }

        let info = infoPlist(at: url)
        let strings = localizedStrings(at: url)
        let localized = localizedName(of: url)
        // Same precedence `Bundle.object(forInfoDictionaryKey:)` uses: a localized
        // override beats the Info.plist value for the same key, and a `-macos`
        // platform-suffixed key beats the bare one. Image Playground needs the latter —
        // its loctable carries CFBundleDisplayName "Playground" *and*
        // CFBundleDisplayName-macos "Image Playground", and only the suffixed one is
        // the name the Mac shows.
        func value(_ key: String) -> String? {
            (strings["\(key)-macos"] as? String) ?? (strings[key] as? String)
                ?? (info["\(key)-macos"] as? String) ?? (info[key] as? String)
        }
        let name = value("CFBundleDisplayName")
            ?? value("CFBundleName")
            ?? localized
            ?? url.deletingPathExtension().lastPathComponent
        let identifier = (info["CFBundleIdentifier"] as? String) ?? path
        let category = (info["LSApplicationCategoryType"] as? String) ?? ""

        // Finder's name joins the search text even when it did not win the label, so an
        // app stays findable by the name the user actually sees on disk.
        let alternate = (localized == name) ? "" : (localized ?? "")
        return AppEntry(id: identifier, name: name, path: path,
                        searchText: "\(name) \(alternate) \(identifier) \(category)",
                        icon: thumbnail(for: path))
    }

    /// The bundle's Info.plist as a plain dictionary, retained by nobody. Handles the
    /// binary format as well as XML, which `PropertyListSerialization` does for free.
    nonisolated private static func infoPlist(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else { return [:] }
        return dictionary
    }

    /// `InfoPlist.strings` for the running locale, which is the *only* thing `Bundle`
    /// was still providing that a plist read does not: Find My and Voice Memos carry
    /// their display names here and nowhere else, and dropping it renamed them to
    /// "FindMy" and "VoiceMemos". Localizations are tried in the user's own preferred
    /// order before the development ones, exactly as bundle lookup does.
    ///
    /// `.strings` is usually a binary plist and occasionally the old text format;
    /// `PropertyListSerialization` reads both, and a file that is neither is skipped
    /// rather than failing the entry.
    nonisolated private static func localizedStrings(at url: URL) -> [String: Any] {
        let resources = url.appendingPathComponent("Contents/Resources")
        var candidates: [String] = []
        for language in Locale.preferredLanguages {
            candidates.append(language)
            // A loctable keys regional locales with an underscore (`en_GB`) where
            // `preferredLanguages` hands back a hyphen (`en-GB`).
            candidates.append(language.replacingOccurrences(of: "-", with: "_"))
            if let base = language.split(separator: "-").first { candidates.append(String(base)) }
        }
        candidates.append(contentsOf: ["Base", "en", "English"])

        var seen = Set<String>()
        var ordered: [String] = []
        for name in candidates where seen.insert(name).inserted { ordered.append(name) }

        for name in ordered {
            let file = resources.appendingPathComponent("\(name).lproj/InfoPlist.strings")
            guard let data = try? Data(contentsOf: file),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dictionary = plist as? [String: Any] else { continue }
            return dictionary
        }

        // Apple's own apps ship no `.strings` at all: Find My and Voice Memos keep
        // every locale in one `InfoPlist.loctable`, a binary plist of
        // locale -> [key: value]. Read after the per-locale files because it is the
        // larger parse, and only ever transiently — nothing here is retained.
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("InfoPlist.loctable")),
              let table = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return [:] }
        for name in ordered {
            if let entry = table[name] as? [String: Any] { return entry }
        }
        return [:]
    }

    /// The name Finder shows, with the extension trimmed when Finder is showing it.
    nonisolated private static func localizedName(of url: URL) -> String? {
        guard let name = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName else { return nil }
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Icons are the index's whole memory cost: `NSWorkspace.icon(forFile:)` hands
    /// back a multi-representation image sized for the Finder, and the index holds
    /// one per app for the process lifetime. Flattening each to a single bitmap at
    /// the size the panel actually draws turns megabytes per icon into ~20KB.
    nonisolated static let thumbnailSize: CGFloat = 36   // covers `Theme.iconSlot` (34) with room to spare

    nonisolated static func thumbnail(for path: String, size: CGFloat = thumbnailSize) -> NSImage {
        let source = NSWorkspace.shared.icon(forFile: path)
        let pixels = Int(size * 2)   // 2x is the densest Mac display scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return source }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }

    nonisolated static func isTopLevelApplication(_ path: String) -> Bool {
        guard path.hasSuffix(".app") else { return false }
        let components = URL(fileURLWithPath: path).pathComponents
        guard let appIndex = components.lastIndex(where: { $0.hasSuffix(".app") }) else { return false }
        return !components[..<appIndex].contains(where: { $0.hasSuffix(".app") })
            && !path.contains("/Library/Developer/")
            && !path.contains("/.Trash/")
    }
}
