import AppKit

/// Where the list currently is. An actions menu is built from the row the user
/// pressed Tab on and backs no `MenuNode`, so — unlike every other location — it
/// cannot be named by an id.
enum MenuLocation {
    case menu(String)
    case actions(subject: DisplayRow, entries: [RowActionEntry])
}

@MainActor
final class MenuController {
    let appIndex: AppIndex
    let runtime: LuaRuntime
    let usage: UsageStore
    let clipboard: ClipboardHistory
    let commands = CommandRunner()
    var nodes: [MenuNode] = []
    /// Async rows for the current generation, held so that whichever source answers
    /// second can repaint the list without discarding what the first one returned.
    private var providerRows: [DisplayRow] = []
    private var commandRows: [DisplayRow] = []
    /// Republished on every config reload, like `backRow`.
    var search = SearchSpec()
    var providerLimits = ProviderSpec()
    private var location: MenuLocation = .menu("root")
    private var navigation: [Frame] = []

    /// The id an actions menu reports. It deliberately matches no node, which is what
    /// keeps the back row present (`decorated` only withholds it at `root`) and keeps
    /// providers and commands from firing inside an actions list — both find their
    /// work by looking the active menu up by id.
    static let actionsMenuID = "orbit.actions"

    /// The built-in clipboard route. A real node, so it lists, searches, aliases and
    /// routes like anything else — only its rows come from somewhere else.
    static let clipboardMenuID = "clipboard"

    private var activeMenu: String {
        switch location {
        case .menu(let id): return id
        case .actions: return Self.actionsMenuID
        }
    }

    /// One entry on the navigation stack.
    private struct Frame {
        let location: MenuLocation
        /// The query to put back when this frame is returned to. `nil` clears it,
        /// which is what every ordinary submenu does and must keep doing: leaving a
        /// submenu is a fresh start. An actions menu is the exception — it is a
        /// detour from a search, so the search has to survive it.
        let restoreQuery: String?
    }
    private var providerGeneration = 0
    private var query = ""
    private var iconCache: [String: NSImage] = [:]
    /// Appearance of the synthetic back row. Republished on every config reload.
    var backRow = BackRowSpec() {
        didSet {
            guard backRow != oldValue else { return }
            refresh(query: query)
        }
    }
    var onRows: ((String, [DisplayRow]) -> Void)?
    var onQuery: ((String) -> Void)?
    var onNotice: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    /// Clipboard history, republished on every config reload. Off by default, so
    /// nothing is captured until a config asks for it.
    var clipboardSpec = ClipboardSpec() {
        didSet {
            guard clipboardSpec != oldValue else { return }
            clipboard.apply(clipboardSpec)
            syncClipboardNode()
            refresh(query: query)
        }
    }

    /// `usage` and `clipboard` default to memory-only stores so a test — or any caller
    /// that does not opt in — can never read or write the real files.
    init(appIndex: AppIndex, runtime: LuaRuntime, usage: UsageStore = UsageStore(url: nil),
         clipboard: ClipboardHistory = ClipboardHistory(url: nil)) {
        self.appIndex = appIndex
        self.runtime = runtime
        self.usage = usage
        self.clipboard = clipboard
        runtime.onReload = { [weak self] result in
            switch result {
            case .success(let nodes):
                self?.iconCache = [:]
                // A reload can change what a command *is*, so its answers for the old
                // one are no longer about anything.
                self?.commands.clearCache()
                self?.nodes = nodes
                self?.syncClipboardNode()
                self?.refresh(query: "")
            case .failure(let error): self?.onNotice?(error.localizedDescription)
            }
        }
        appIndex.onChange = { [weak self] in self?.refresh(query: "") }
    }

    func open(route: String = "root") {
        location = .menu(resolve(route))
        navigation = []
        onQuery?("")
        refresh(query: "")
    }

    func update(query: String) { refresh(query: query) }

    func activate(_ row: DisplayRow) {
        // Recorded before dispatch, and for every kind but the synthetic back row:
        // navigating out of a submenu is not a use of anything.
        if row.kind != .back { usage.record(row.id) }
        if row.kind == .back {
            // Only reachable inside a submenu, but a back that finds nothing to pop
            // means the same thing here as Escape at root does.
            if !back() { onDismiss?() }
            return
        }
        if row.kind == .app {
            appIndex.launch(path: String(row.id.dropFirst(4)))
            onDismiss?()
            return
        }
        // Actions-menu rows are handled by the host itself, and carry no node to look
        // up any more than a provider row does.
        if let rowAction = row.rowAction {
            perform(rowAction, subject: row)
            return
        }
        // Provider rows have no backing node; they carry their action inline.
        if let action = row.action {
            guard dispatch(action) else { return }
            onDismiss?()
            return
        }
        guard let node = nodes.first(where: { $0.id == row.id }) else { return }
        if node.kind == .menu {
            push(.menu(node.id), restoring: nil)
        } else if let reference = node.actionReference {
            runtime.invoke(reference: reference, query: query)
            onDismiss?()
        } else if let scriptAction = node.scriptAction {
            guard dispatch(scriptAction) else { return }
            onDismiss?()
        }
    }

    /// Runs an action, or refuses it. A `{query}` row is now reachable with nothing
    /// typed — `keep` is what put it there — and substituting an empty string would
    /// run `brew install ''` rather than doing nothing. Returns whether it dispatched,
    /// so the caller knows not to dismiss a panel the user still has to type into.
    private func dispatch(_ action: ScriptAction) -> Bool {
        guard !(action.wantsQuery && query.isBlank) else {
            onNotice?("Type something first")
            return false
        }
        runtime.invoke(scriptAction: action, query: query)
        return true
    }

    func back() -> Bool {
        guard activeMenu != "root" else { return false }
        let frame = navigation.popLast()
        // With no frame to pop — a route opened directly, rather than navigated into
        // — fall back to the node's parent, as this has always done.
        location = frame?.location ?? .menu(nodes.first(where: { $0.id == activeMenu })?.parent ?? "root")
        let restored = frame?.restoreQuery ?? ""
        onQuery?(restored)
        // Refreshed with the restored query, not merely repainted with it:
        // `PanelController.setQuery` deliberately does not fire `onQuery` back, so
        // nothing else would rebuild the list against it.
        refresh(query: restored)
        return true
    }

    /// The actions menu for `row`, pushed like any other submenu. A row with nothing
    /// worth doing to it — the back row — is left alone rather than opening an empty
    /// list the user then has to escape out of.
    func showActions(for row: DisplayRow) {
        let entries = RowActions.entries(for: row, query: query)
        guard !entries.isEmpty else { return }
        push(.actions(subject: row, entries: entries), restoring: query)
    }

    private func push(_ next: MenuLocation, restoring: String?) {
        navigation.append(Frame(location: location, restoreQuery: restoring))
        location = next
        onQuery?("")
        refresh(query: "")
    }

    /// Runs a row action. Everything but the picker is terminal, so it dismisses;
    /// the picker navigates and must not.
    private func perform(_ action: RowAction, subject: DisplayRow) {
        switch action {
        case .copyText(let text):
            guard !text.isBlank else { onNotice?("Nothing to copy"); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            clipboard.noteOwnWrite()
            onDismiss?()
        case .revealInFinder(let path):
            NSWorkspace.shared.activateFileViewerSelecting([Self.fileURL(path)])
            onDismiss?()
        case .openWith(let appPath, let target):
            NSWorkspace.shared.open([Self.fileURL(target)], withApplicationAt: Self.fileURL(appPath),
                                    configuration: NSWorkspace.OpenConfiguration())
            onDismiss?()
        case .openWithPicker(let target):
            let entries = Self.openWithEntries(for: target)
            guard !entries.isEmpty else { onNotice?("Nothing can open that"); return }
            // Nested inside the actions menu, which the frame stack handles for free:
            // one Escape returns to the actions, a second to the list.
            push(.actions(subject: subject, entries: entries), restoring: nil)
        }
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Every app that claims it can open `target`, keyed by path so two apps sharing a
    /// display name still get distinct ids.
    private static func openWithEntries(for target: String) -> [RowActionEntry] {
        NSWorkspace.shared.urlsForApplications(toOpen: fileURL(target)).map { app in
            RowActionEntry(id: "orbit.action.open-with:\(app.path)",
                           label: FileManager.default.displayName(atPath: app.path),
                           symbol: "app", detail: app.path,
                           action: .openWith(appPath: app.path, target: target))
        }
    }

    /// An actions list is short and its order is deliberate, so a query decides only
    /// whether a row survives — never where it sits.
    private static func actionRows(_ entries: [RowActionEntry], query: String) -> [DisplayRow] {
        entries.enumerated().compactMap { index, entry in
            guard query.isEmpty || FuzzyMatcher.score(query, in: "\(entry.label) \(entry.detail)") != nil else { return nil }
            return DisplayRow(id: entry.id, kind: entry.action.opensASubmenu ? .menu : .action,
                              label: entry.label, detail: entry.detail, symbol: entry.symbol,
                              image: nil, score: index, section: "actions", rowAction: entry.action)
        }
    }

    func invoke(id: String) -> Bool {
        guard let node = node(matching: id) else { return false }
        if let reference = node.actionReference { runtime.invoke(reference: reference) }
        else if let scriptAction = node.scriptAction { runtime.invoke(scriptAction: scriptAction) }
        else { return false }
        return true
    }

    /// The rows a route would show, without disturbing the panel's own active menu,
    /// query or navigation stack. This is what `kitsunectl list` reports, and what lets
    /// the search, sort, drilldown and back-row rules be asserted without a window.
    ///
    /// Provider rows are absent by design: a provider is asynchronous, and this is a
    /// synchronous snapshot of the static list.
    func rows(route: String, query: String) -> (title: String, rows: [DisplayRow]) {
        let menu = resolve(route)
        let built = build(menu: menu, query: query.trimmingCharacters(in: .whitespacesAndNewlines))
        return (built.title, decorated(built.rows, menu: menu))
    }

    /// An exact id wins over any alias, matching how routes resolve in `kitsunectl`.
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

    /// The static rows for `menu` under `query`. Pure with respect to navigation: it
    /// reads `activeMenu` nowhere, which is what lets `rows(route:query:)` answer for
    /// any route without disturbing what the panel is showing.
    private func build(menu: String, query: String) -> (title: String, rows: [DisplayRow]) {
        let menuNode = nodes.first(where: { $0.id == menu })
        let title = menuNode?.headerTitle ?? "Go"
        var rows: [DisplayRow] = []
        // Frecency has to be applied *inside* the app search, not after it: the index
        // sorts and truncates to the limit itself, so a discount applied to the result
        // could not rescue an app that had already been cut.
        let appBonus: (String) -> Int = { [usage] path in usage.bonus(for: "app:\(path)") }
        if menu == "apps" {
            rows.append(contentsOf: appIndex.results(for: query, limit: query.isEmpty ? appIndex.entries.count : search.appLimit, bonus: appBonus))
        } else if menu == Self.clipboardMenuID {
            // Already newest-first and capped by the store; no frecency, because the
            // ordering of a clipboard history *is* its recency.
            rows.append(contentsOf: clipboard.results(for: query, limit: clipboardSpec.limit))
        } else if menu == "root" && !query.isEmpty {
            rows.append(contentsOf: appIndex.results(for: query, limit: search.appLimit, bonus: appBonus))
        }
        let candidates = nodes.filter { node in
            guard node.id != "root" else { return false }
            // `hidden` drops a node from the listing only. It stays searchable here,
            // and `node(matching:)` still resolves it for aliases and `invoke`.
            if query.isEmpty { return node.parent == menu && !node.hidden }
            return isDescendant(node, of: menu)
        }
        rows.append(contentsOf: candidates.compactMap { node -> DisplayRow? in
            // A closure rather than a nested function: a nested `func` does not inherit
            // the enclosing actor isolation, so it cannot call `icon(for:)`.
            let image = icon(for: node)
            let row = { (score: Int, detail: String, section: String) -> DisplayRow in
                DisplayRow(id: node.id, kind: node.kind, label: node.label, detail: detail,
                           symbol: node.symbol, image: image, score: score, section: section)
            }
            if query.isEmpty { return row(node.order, node.detail, "current") }
            // A `keep` row skips the filter entirely and keeps its own detail: it exists
            // to consume what was typed, so the breadcrumb a search hit would get is
            // noise on it.
            if node.keep { return row(node.order, node.detail, "keep") }
            guard let base = FuzzyMatcher.score(query, in: node.searchText(includingDetail: search.matchDetail)) else { return nil }
            return row(base - usage.bonus(for: node.id), path(for: node),
                       node.parent == menu ? "current" : "drilldown")
        })
        if query.isEmpty {
            rows.sort { menu == "apps" ? $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending : $0.score < $1.score }
        } else {
            rows.sort {
                let lhs = Self.sectionRank($0.section)
                let rhs = Self.sectionRank($1.section)
                if lhs != rhs { return lhs < rhs }
                return $0.score == $1.score ? $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending : $0.score < $1.score
            }
            if let split = rows.firstIndex(where: { $0.section != "current" }), split > 0 {
                var row = rows[split]
                row = DisplayRow(id: row.id, kind: row.kind, label: row.label, detail: row.detail, symbol: row.symbol, image: row.image, score: row.score, section: "drilldown-start", action: row.action)
                rows[split] = row
            }
        }
        if search.rowLimit > 0 { rows = Array(rows.prefix(search.rowLimit)) }
        return (title, rows)
    }

    /// Direct children first, then everything found by drilling down, then the rows
    /// that survive the filter on purpose. `keep` sorting last is what leaves it below
    /// the search results and — since provider rows are appended after this list — above
    /// the provider rows, which is the order the back row's `position = "bottom"` assumes.
    private static func sectionRank(_ section: String) -> Int {
        switch section {
        case "current": return 0
        case "keep": return 2
        default: return 1
        }
    }

    private func refresh(query: String) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = self.query
        let menu = activeMenu
        let built = built(query: trimmed)
        let baseRows = built.rows
        let title = built.title
        onRows?(title, decorated(baseRows, menu: menu))

        // A provider and a command both belong to the submenu that declares them and
        // supply that submenu's rows while it is open — entering `search` is what runs
        // `search`'s provider, not merely seeing it listed one level up.
        providerGeneration += 1
        let generation = providerGeneration
        providerRows = []
        commandRows = []
        let node = nodes.first(where: { $0.id == menu })

        // Both sources are asynchronous and either may answer first, so each stores
        // its own rows and re-emits the union rather than the base plus itself.
        let emit: @MainActor () -> Void = { [weak self] in
            guard let self, generation == self.providerGeneration else { return }
            self.onRows?(title, self.decorated(baseRows + self.providerRows + self.commandRows, menu: menu))
        }

        if let name = node?.provider {
            let dispatch: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self, generation == self.providerGeneration else { return }
                runtime.provider(name: name, menuID: menu, query: trimmed, timeout: providerLimits.timeout, instructions: providerLimits.instructions) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self, generation == self.providerGeneration else { return }
                        switch result {
                        case .success(let rows):
                            self.providerRows = rows
                            emit()
                        case .failure(let error): self.onNotice?(error.localizedDescription)
                        }
                    }
                }
            }
            // The generation check inside `dispatch` is what makes the debounce a
            // debounce: a later keystroke bumps the generation and the pending call
            // returns without spawning a state.
            if providerLimits.debounce > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + providerLimits.debounce, execute: dispatch)
            } else {
                dispatch()
            }
        }

        if let command = node?.command, !command.isBlank {
            commands.rows(command: command, menuID: menu, query: trimmed) { [weak self] rows in
                guard let self, generation == self.providerGeneration else { return }
                self.commandRows = rows
                emit()
            }
        } else {
            // Navigating away from a command menu has to kill whatever it started.
            commands.cancel()
        }
    }

    /// The rows for wherever the list currently is. `build(menu:query:)` answers for a
    /// real menu; an actions menu has no node to ask, so its rows come from the entries
    /// captured when it was pushed.
    private func built(query: String) -> (title: String, rows: [DisplayRow]) {
        switch location {
        case .menu(let id): return build(menu: id, query: query)
        case .actions(let subject, let entries): return (subject.label, Self.actionRows(entries, query: query))
        }
    }

    /// The back row is synthetic and is added at the point of emission, not merged
    /// into `candidates`: a static row goes through the fuzzy filter, so the first
    /// keystroke would drop the one row that is meant to survive every query. Adding
    /// it here also keeps `position = "bottom"` below the provider rows, which arrive
    /// after the base list.
    private func decorated(_ rows: [DisplayRow], menu: String) -> [DisplayRow] {
        guard backRow.enabled, menu != "root" else { return rows }
        let row = DisplayRow(id: "kitsune.back", kind: .back, label: backRow.label, detail: backRow.detail,
                             symbol: backRow.symbol, image: nil, score: -1, section: "back")
        return backRow.atTop ? [row] + rows : rows + [row]
    }

    /// Injected the way `LuaRuntime` injects a missing `root`, and re-injected after
    /// every reload because a reload replaces `nodes` wholesale. Disabling the feature
    /// takes the row away again on the next save.
    private func syncClipboardNode() {
        nodes.removeAll { $0.id == Self.clipboardMenuID }
        guard clipboardSpec.enabled else { return }
        // `Int.max` sorts it below whatever the config author wrote: a built-in has no
        // business displacing their own ordering.
        nodes.append(MenuNode(id: Self.clipboardMenuID, parent: "root", kind: .menu, label: "Clipboard",
                              detail: "Recently copied text", symbol: "doc.on.clipboard",
                              aliases: ["clip", "history"], provider: nil, actionReference: nil,
                              scriptAction: nil, order: Int.max))
    }

    private func isDescendant(_ node: MenuNode, of ancestor: String) -> Bool {
        if ancestor == "root" { return true }
        var parent = node.parent
        for _ in 0..<search.depth {
            if parent == ancestor { return true }
            guard let next = nodes.first(where: { $0.id == parent }) else { return false }
            parent = next.parent
        }
        return false
    }

    private func path(for node: MenuNode) -> String {
        var labels: [String] = []
        var current: MenuNode? = node
        for _ in 0..<search.depth {
            guard let item = current, item.id != "root" else { break }
            labels.insert(item.label, at: 0)
            current = nodes.first(where: { $0.id == item.parent })
        }
        return labels.joined(separator: " > ")
    }
}
