import AppKit
import CoreServices

@MainActor
final class AppIndex: NSObject, NSMetadataQueryDelegate {
    private(set) var entries: [AppEntry] = []
    private let worker = DispatchQueue(label: "orbit.app-index", qos: .utility)
    private var metadataQuery: NSMetadataQuery?
    var onChange: (() -> Void)?

    func start() {
        worker.async { [weak self] in
            let home = FileManager.default.homeDirectoryForCurrentUser
            let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), home.appendingPathComponent("Applications")]
            var paths = Set<String>()
            for root in roots {
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let url as URL in enumerator where url.pathExtension == "app" { paths.insert(url.path) }
            }
            let built = paths.compactMap(Self.makeEntry).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Task { @MainActor [weak self] in self?.merge(built) }
        }
        startMetadataQuery()
    }

    func results(for query: String, limit: Int = 12) -> [DisplayRow] {
        entries.compactMap { entry -> DisplayRow? in
            guard let score = FuzzyMatcher.score(query, in: entry.searchText) else { return nil }
            return DisplayRow(id: "app:\(entry.id)", kind: .app, label: entry.name, detail: entry.path, symbol: "", image: entry.icon, score: score)
        }.sorted { $0.score == $1.score ? $0.label < $1.label : $0.score < $1.score }.prefix(limit).map { $0 }
    }

    func launch(id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: entry.path), configuration: .init())
    }

    private func merge(_ incoming: [AppEntry]) {
        var byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        incoming.forEach { byPath[$0.path] = $0 }
        entries = byPath.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onChange?()
    }

    nonisolated private static func makeEntry(path: String) -> AppEntry? {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "app" else { return nil }
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let identifier = bundle?.bundleIdentifier ?? path
        let category = bundle?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String ?? ""
        return AppEntry(id: identifier, name: name, path: path, searchText: "\(name) \(identifier) \(category)", icon: NSWorkspace.shared.icon(forFile: path))
    }

    private func startMetadataQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemContentTypeKey, "com.apple.application-bundle")
        query.delegate = self
        metadataQuery = query
        query.start()
    }

    func metadataQueryDidFinishGathering(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery else { return }
        query.disableUpdates()
        let paths = query.results.compactMap { ($0 as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String }
        query.enableUpdates()
        worker.async { [weak self] in
            let built = paths.compactMap(Self.makeEntry)
            Task { @MainActor [weak self] in self?.merge(built) }
        }
    }
}
