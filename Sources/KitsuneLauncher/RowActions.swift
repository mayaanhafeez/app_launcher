import Foundation

/// Something the host does to a row, rather than something the row *is*. Every case
/// here needs the selected `DisplayRow` and either the pasteboard or `NSWorkspace`,
/// which is exactly why none of it can come from Lua: a provider is re-loaded into a
/// throwaway state with no execution globals and never sees what the user selected.
///
/// It is a value, not a closure, for the same reason `ScriptAction` is — the row
/// *describes* what to do and `MenuController` does it, so the list of actions a row
/// offers stays a pure function of the row.
enum RowAction: Equatable, Sendable {
    case copyText(String)
    case revealInFinder(String)
    case openWith(appPath: String, target: String)
    /// Pushes a nested actions menu of the apps that can open `target`. The one case
    /// that navigates rather than acting, so it must not dismiss the panel.
    case openWithPicker(String)

    var opensASubmenu: Bool {
        if case .openWithPicker = self { return true }
        return false
    }
}

/// One entry in a row's actions menu. `id` is what frecency records, so it is
/// namespaced away from node ids — `usage.record` would otherwise conflate "reveal
/// Safari in Finder" with launching Safari.
struct RowActionEntry: Sendable, Equatable {
    let id: String
    let label: String
    let symbol: String
    let detail: String
    let action: RowAction
}

/// The built-in actions each kind of row offers. Kept pure and free of AppKit state,
/// like `VimKeys` and `EditingKeys`, so the whole table is testable without a window.
///
/// Lua will be able to contribute entries later; the native set ships first.
enum RowActions {
    /// `query` is taken so "Copy as Shell Command" copies what would actually run.
    /// `ScriptAction.resolved(query:)` already escapes per destination, so the copied
    /// text is the real command rather than a template with a `{query}` hole in it.
    static func entries(for row: DisplayRow, query: String) -> [RowActionEntry] {
        // The back row is chrome, not an item. There is nothing to copy or reveal.
        guard row.kind != .back else { return [] }
        var entries: [RowActionEntry] = []

        if row.kind == .app {
            entries += fileEntries(path: String(row.id.dropFirst(4)))
        } else if let action = row.action?.resolved(query: query) {
            switch action {
            case .shell(let command) where !command.isBlank:
                entries.append(RowActionEntry(id: "kitsune.action.copy-shell", label: "Copy as Shell Command",
                                              symbol: "terminal", detail: command, action: .copyText(command)))
            case .url(let url) where !url.isBlank:
                entries.append(RowActionEntry(id: "kitsune.action.copy-url", label: "Copy URL",
                                              symbol: "link", detail: url, action: .copyText(url)))
            case .open(let path) where !path.isBlank:
                entries += fileEntries(path: path)
            case .appleScript(let script) where !script.isBlank:
                entries.append(RowActionEntry(id: "kitsune.action.copy-script", label: "Copy AppleScript",
                                              symbol: "applescript", detail: script, action: .copyText(script)))
            default: break
            }
        }

        // Last, and offered on every row: whatever else a row is, it has a label.
        entries.append(RowActionEntry(id: "kitsune.action.copy-label", label: "Copy Label",
                                      symbol: "doc.on.doc", detail: row.label, action: .copyText(row.label)))
        return entries
    }

    /// The three things worth doing to a path. Shared by app rows and by `open = ...`
    /// rows, which differ only in where the path came from.
    private static func fileEntries(path: String) -> [RowActionEntry] {
        guard !path.isBlank else { return [] }
        return [
            RowActionEntry(id: "kitsune.action.reveal", label: "Reveal in Finder",
                           symbol: "folder", detail: path, action: .revealInFinder(path)),
            RowActionEntry(id: "kitsune.action.copy-path", label: "Copy Path",
                           symbol: "doc.on.doc", detail: path, action: .copyText(path)),
            RowActionEntry(id: "kitsune.action.open-with", label: "Open With…",
                           symbol: "arrow.up.forward.app", detail: "", action: .openWithPicker(path)),
        ]
    }
}
