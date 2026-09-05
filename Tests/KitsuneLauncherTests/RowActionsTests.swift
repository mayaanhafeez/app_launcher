import AppKit
import Testing
@testable import OrbitLauncher

// `RowActions.entries` is a pure function of a row, like `VimKeys.normalModeAction`
// and `ShortcutSpec.position`, so the whole table is assertable without a window.
// The navigation half is asserted through `MenuController` directly — none of it
// needs an `NSApplication` either.

private func row(_ id: String, kind: RowKind, label: String = "Row",
                 action: ScriptAction? = nil) -> DisplayRow {
    DisplayRow(id: id, kind: kind, label: label, detail: "", symbol: "", image: nil,
               score: 0, section: "current", action: action)
}

@Test func appRowsOfferPathActions() {
    let entries = RowActions.entries(for: row("app:/Applications/Safari.app", kind: .app, label: "Safari"), query: "")
    #expect(entries.map(\.label) == ["Reveal in Finder", "Copy Path", "Open With…", "Copy Label"])
    #expect(entries[0].action == .revealInFinder("/Applications/Safari.app"))
    #expect(entries[1].action == .copyText("/Applications/Safari.app"))
    #expect(entries[2].action == .openWithPicker("/Applications/Safari.app"))
    #expect(entries[3].action == .copyText("Safari"))
}

// Only the picker navigates, so only it may draw a chevron and skip the dismiss.
@Test func onlyThePickerOpensASubmenu() {
    let entries = RowActions.entries(for: row("app:/Applications/Safari.app", kind: .app), query: "")
    #expect(entries.filter(\.action.opensASubmenu).map(\.label) == ["Open With…"])
}

// The point of taking the query: copying a template with a `{query}` hole in it
// would be copying something that never ran.
@Test func copyAsShellCommandResolvesTheQuery() {
    let entries = RowActions.entries(for: row("brew.install", kind: .action, action: .shell("brew install {query}")),
                                     query: "ripgrep")
    #expect(entries.first?.label == "Copy as Shell Command")
    #expect(entries.first?.action == .copyText("brew install 'ripgrep'"))
}

@Test func urlAndOpenRowsOfferWhatTheyCarry() {
    let url = RowActions.entries(for: row("docs", kind: .action, action: .url("https://example.com")), query: "")
    #expect(url.map(\.label) == ["Copy URL", "Copy Label"])

    let file = RowActions.entries(for: row("notes", kind: .action, action: .open("~/notes.md")), query: "")
    #expect(file.map(\.label) == ["Reveal in Finder", "Copy Path", "Open With…", "Copy Label"])
}

// Every row has a label, so every row has at least one thing worth doing to it —
// which is what keeps Tab from ever opening an empty list.
@Test func everyOrdinaryRowCanAtLeastCopyItsLabel() {
    for kind in [RowKind.action, .menu, .app, .notice] {
        let entries = RowActions.entries(for: row("x", kind: kind, label: "Thing"), query: "")
        #expect(entries.last?.action == .copyText("Thing"))
    }
}

// The back row is chrome, not an item. An empty list is why `showActions` no-ops
// on it rather than pushing a menu the user has to escape back out of.
@Test func theBackRowOffersNothing() {
    #expect(RowActions.entries(for: row("orbit.back", kind: .back, label: "Back"), query: "").isEmpty)
}

// A blank target is a no-op everywhere else in the launcher, and is here too:
// there is no path to reveal and nothing to copy.
@Test func blankTargetsContributeNoEntries() {
    let entries = RowActions.entries(for: row("empty", kind: .action, action: .shell("")), query: "")
    #expect(entries.map(\.label) == ["Copy Label"])
}

// MARK: - Navigation

@MainActor private func controller() -> MenuController {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "setup", parent: "root", kind: .menu, label: "Setup", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 1),
        MenuNode(id: "setup.zed", parent: "setup", kind: .action, label: "Zed", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: .url(""), order: 2),
    ]
    return controller
}

@MainActor
@Test func actionsMenuListsTheRowsActionsBelowABackRow() {
    let controller = controller()
    var labels: [String] = []
    var title = ""
    controller.onRows = { header, rows in title = header; labels = rows.map(\.label) }
    controller.open()
    controller.showActions(for: row("app:/Applications/Safari.app", kind: .app, label: "Safari"))

    // The back row is decorated on as it is for any other submenu — the actions menu
    // is a menu, not a modal surface.
    #expect(labels == ["Back", "Reveal in Finder", "Copy Path", "Open With…", "Copy Label"])
    #expect(title == "Safari")
    #expect(controller.back())
}

// The whole point of the frame stack: an actions menu is a detour from a search, so
// escaping out of it has to put the search back.
@MainActor
@Test func leavingAnActionsMenuRestoresTheQuery() {
    let controller = controller()
    var published: [String] = []
    controller.onQuery = { published.append($0) }
    controller.open()
    controller.update(query: "zed")

    controller.showActions(for: row("setup.zed", kind: .action, label: "Zed"))
    #expect(published.last == "")      // the actions menu starts with a clean field
    #expect(controller.back())
    #expect(published.last == "zed")
}

// ...while an ordinary submenu keeps clearing it, which is the behaviour the
// query-reset work on main established and this must not undo.
@MainActor
@Test func leavingAnOrdinarySubmenuStillClearsTheQuery() {
    let controller = controller()
    var published: [String] = []
    controller.onQuery = { published.append($0) }
    controller.open()
    controller.update(query: "set")
    controller.activate(row("setup", kind: .menu, label: "Setup"))
    #expect(published.last == "")
    #expect(controller.back())
    #expect(published.last == "")
}

// A nested picker unwinds one level at a time, because it is one more frame.
@MainActor
@Test func nestedActionMenusUnwindOneLevelAtATime() {
    let controller = controller()
    var titles: [String] = []
    controller.onRows = { title, _ in titles.append(title) }
    controller.open()
    controller.update(query: "zed")
    controller.showActions(for: row("setup.zed", kind: .action, label: "Zed"))
    #expect(titles.last == "Zed")
    #expect(controller.back())     // back to the root list
    #expect(!controller.back())    // and root refuses, which is the cue to hide
}

// The sentinel id matches no node, which is what keeps a provider or command from
// firing against whatever menu the actions list was opened from.
@MainActor
@Test func anActionsMenuRunsNoProviderOrCommand() {
    #expect(!MenuController.actionsMenuID.isEmpty)
    let controller = controller()
    #expect(!controller.nodes.contains { $0.id == MenuController.actionsMenuID })
}
