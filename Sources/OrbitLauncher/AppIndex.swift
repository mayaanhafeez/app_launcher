import AppKit
import CoreServices

@MainActor
final class AppIndex: NSObject {
    private(set) var entries: [AppEntry] = []
    private let worker = DispatchQueue(label: "orbit.app-index", qos: .utility)
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
        entries.compactMap { entry -> DisplayRow? in
            guard let score = FuzzyMatcher.score(query, in: entry.searchText) else { return nil }
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

    nonisolated private static func makeEntry(path: String, iconPoints: CGFloat = thumbnailSize) -> AppEntry? {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "app" else { return nil }
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let identifier = bundle?.bundleIdentifier ?? path
        let category = bundle?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String ?? ""
        return AppEntry(id: identifier, name: name, path: path, searchText: "\(name) \(identifier) \(category)", icon: thumbnail(for: path))
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
