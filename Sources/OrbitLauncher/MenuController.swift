import AppKit

@MainActor
final class MenuController {
    let appIndex: AppIndex
    let runtime: LuaRuntime
    var nodes: [MenuNode] = []
    private var activeMenu = "root"
    private var navigation: [String] = []
    private var providerGeneration = 0
    private var query = ""
    private var iconCache: [String: NSImage] = [:]
    var onRows: ((String, [DisplayRow]) -> Void)?
    var onNotice: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    init(appIndex: AppIndex, runtime: LuaRuntime) {
        self.appIndex = appIndex
        self.runtime = runtime
        runtime.onReload = { [weak self] result in
            switch result {
            case .success(let nodes):
                self?.iconCache = [:]
                self?.nodes = nodes
                self?.refresh(query: "")
            case .failure(let error): self?.onNotice?(error.localizedDescription)
            }
        }
        appIndex.onChange = { [weak self] in self?.refresh(query: "") }
    }

    func open(route: String = "root") {
        activeMenu = resolve(route)
        navigation = []
        refresh(query: "")
    }

    func update(query: String) { refresh(query: query) }

    func activate(_ row: DisplayRow) {
        if row.kind == .app {
            appIndex.launch(path: String(row.id.dropFirst(4)))
            onDismiss?()
            return
        }
        // Provider rows have no backing node; they carry their action inline.
        if let action = row.action {
            runtime.invoke(scriptAction: action, query: query)
            onDismiss?()
            return
        }
        guard let node = nodes.first(where: { $0.id == row.id }) else { return }
        if node.kind == .menu {
            navigation.append(activeMenu)
            activeMenu = node.id
            refresh(query: "")
        } else if let reference = node.actionReference {
            runtime.invoke(reference: reference, query: query)
            onDismiss?()
        } else if let scriptAction = node.scriptAction {
            runtime.invoke(scriptAction: scriptAction, query: query)
            onDismiss?()
        }
    }

    func back() -> Bool {
        guard activeMenu != "root" else { return false }
        activeMenu = navigation.popLast() ?? nodes.first(where: { $0.id == activeMenu })?.parent ?? "root"
        refresh(query: "")
        return true
    }

    func invoke(id: String) -> Bool {
        guard let node = node(matching: id) else { return false }
        if let reference = node.actionReference { runtime.invoke(reference: reference) }
        else if let scriptAction = node.scriptAction { runtime.invoke(scriptAction: scriptAction) }
        else { return false }
        return true
    }

    /// An exact id wins over any alias, matching how routes resolve in `orbitctl`.
    private func node(matching route: String) -> MenuNode? {
        let needle = route.lowercased().replacingOccurrences(of: "_", with: "-")
        if let exact = nodes.first(where: { $0.id.lowercased() == needle }) { return exact }
        return nodes.first { node in
            node.aliases.contains { $0.lowercased().replacingOccurrences(of: "_", with: "-") == needle }
        }
    }

    private func resolve(_ route: String) -> String {
        guard let node = node(matching: route), node.kind == .menu else { return "root" }
        return node.id
    }

    private func icon(for node: MenuNode) -> NSImage? {
        guard !node.iconPath.isEmpty else { return nil }
        if let cached = iconCache[node.iconPath] { return cached }
        guard let image = NSImage(contentsOfFile: (node.iconPath as NSString).expandingTildeInPath) else { return nil }
        iconCache[node.iconPath] = image
        return image
    }

    private func refresh(query: String) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = self.query
        let activeNode = nodes.first(where: { $0.id == activeMenu })
        let title = activeNode?.headerTitle ?? "Go"
        var rows: [DisplayRow] = []
        if activeMenu == "apps" {
            rows.append(contentsOf: appIndex.results(for: trimmed, limit: trimmed.isEmpty ? appIndex.entries.count : 40))
        } else if activeMenu == "root" && !trimmed.isEmpty {
            rows.append(contentsOf: appIndex.results(for: trimmed, limit: 40))
        }
        let candidates = nodes.filter { node in
            if trimmed.isEmpty { return node.parent == activeMenu }
            return node.id != "root" && isDescendant(node, of: activeMenu)
        }
        rows.append(contentsOf: candidates.compactMap { node in
            let score = trimmed.isEmpty ? node.order : FuzzyMatcher.score(trimmed, in: node.searchText)
            guard let score else { return nil }
            return DisplayRow(id: node.id, kind: node.kind, label: node.label, detail: trimmed.isEmpty ? node.detail : path(for: node), symbol: node.symbol, image: icon(for: node), score: score, section: node.parent == activeMenu ? "current" : "drilldown")
        })
        if trimmed.isEmpty {
            rows.sort { activeMenu == "apps" ? $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending : $0.score < $1.score }
        } else {
            rows.sort {
                let lhsSection = $0.section == "current" ? 0 : 1
                let rhsSection = $1.section == "current" ? 0 : 1
                if lhsSection != rhsSection { return lhsSection < rhsSection }
                return $0.score == $1.score ? $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending : $0.score < $1.score
            }
            if let split = rows.firstIndex(where: { $0.section != "current" }), split > 0 {
                var row = rows[split]
                row = DisplayRow(id: row.id, kind: row.kind, label: row.label, detail: row.detail, symbol: row.symbol, image: row.image, score: row.score, section: "drilldown-start", action: row.action)
                rows[split] = row
            }
        }
        let baseRows = rows
        onRows?(title, baseRows)

        // A provider belongs to the submenu that declares it and supplies that
        // submenu's rows while it is open — entering `search` is what runs `search`'s
        // provider, not merely seeing it listed one level up.
        providerGeneration += 1
        let generation = providerGeneration
        guard let name = activeNode?.provider else { return }
        runtime.provider(name: name, menuID: activeMenu, query: trimmed) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.providerGeneration else { return }
                switch result {
                case .success(let providerRows): self.onRows?(title, baseRows + providerRows)
                case .failure(let error): self.onNotice?(error.localizedDescription)
                }
            }
        }
    }

    private func isDescendant(_ node: MenuNode, of ancestor: String) -> Bool {
        if ancestor == "root" { return true }
        var parent = node.parent
        for _ in 0..<32 {
            if parent == ancestor { return true }
            guard let next = nodes.first(where: { $0.id == parent }) else { return false }
            parent = next.parent
        }
        return false
    }

    private func path(for node: MenuNode) -> String {
        var labels: [String] = []
        var current: MenuNode? = node
        for _ in 0..<32 {
            guard let item = current, item.id != "root" else { break }
            labels.insert(item.label, at: 0)
            current = nodes.first(where: { $0.id == item.parent })
        }
        return labels.joined(separator: " > ")
    }
}
