import AppKit
import Testing
@testable import OrbitLauncher

// `keep` and `hidden` are inverses over the same filter. A kept row skips the fuzzy
// filter (which is what makes `{query}` usable on a static item at all); a hidden row
// skips the listing but stays searchable and invocable.

@MainActor
private func flagController() -> MenuController {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "install", parent: "root", kind: .menu, label: "Install", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 1),
        MenuNode(id: "install.formula", parent: "install", kind: .action, label: "Homebrew Formula", detail: "Install what you typed", symbol: "", provider: nil, actionReference: nil, scriptAction: .url("{query}"), order: 2, keep: true),
        MenuNode(id: "install.node", parent: "install", kind: .action, label: "Node.js", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: .url(""), order: 3),
        MenuNode(id: "secret", parent: "root", kind: .action, label: "Secret Task", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: .url(""), order: 4, hidden: true),
    ]
    return controller
}

@MainActor
@Test func keepRowSurvivesAQueryThatMatchesNothing() {
    let controller = flagController()
    var labels: [String] = []
    controller.onRows = { _, rows in labels = rows.map(\.label) }
    controller.open(route: "install")
    #expect(labels == ["Back", "Homebrew Formula", "Node.js"])

    // "ripgrep" matches no label here. Without `keep`, typing the argument would
    // remove the one row that exists to consume it — the whole point of the flag.
    controller.update(query: "ripgrep")
    #expect(labels == ["Back", "Homebrew Formula"])
}

@MainActor
@Test func keepRowSortsBelowRealMatches() {
    let controller = flagController()
    var labels: [String] = []
    controller.onRows = { _, rows in labels = rows.map(\.label) }
    controller.open(route: "install")
    controller.update(query: "node")
    // The genuine match ranks first; the kept row falls to the bottom of the static
    // list, which is where provider rows and a bottom-positioned back row expect it.
    #expect(labels == ["Back", "Node.js", "Homebrew Formula"])
}

@MainActor
@Test func keepRowKeepsItsOwnDetail() {
    let controller = flagController()
    var rows: [DisplayRow] = []
    controller.onRows = { _, value in rows = value }
    controller.open(route: "install")
    controller.update(query: "ripgrep")
    // A search hit gets the breadcrumb; a kept row is not a search hit and keeps the
    // detail the config wrote.
    #expect(rows.first(where: { $0.id == "install.formula" })?.detail == "Install what you typed")
}

@MainActor
@Test func hiddenRowIsUnlistedButStillSearchable() {
    let controller = flagController()
    var labels: [String] = []
    controller.onRows = { _, rows in labels = rows.map(\.label) }

    controller.open(route: "root")
    #expect(labels == ["Install"])
    #expect(!labels.contains("Secret Task"))

    controller.update(query: "secret")
    #expect(labels.contains("Secret Task"))
}

@MainActor
@Test func hiddenRowIsStillInvocable() {
    let controller = flagController()
    // `orbitctl invoke` has to reach a hidden node: unlisted is not the same as gone.
    #expect(controller.invoke(id: "secret"))
}

@MainActor
@Test func aQueryActionWithNothingTypedIsRefused() {
    let controller = flagController()
    var dismissed = false
    var notice = ""
    controller.onDismiss = { dismissed = true }
    controller.onNotice = { notice = $0 }
    controller.open(route: "install")

    // `keep` puts a {query} row in front of the user before they have typed anything.
    // Substituting an empty string would run `brew install ''`.
    controller.activate(DisplayRow(id: "install.formula", kind: .action, label: "Homebrew Formula", detail: "", symbol: "", image: nil, score: 0, section: "keep"))
    #expect(!dismissed)
    #expect(notice == "Type something first")

    // With a query it dispatches, and the panel closes.
    controller.update(query: "ripgrep")
    controller.activate(DisplayRow(id: "install.formula", kind: .action, label: "Homebrew Formula", detail: "", symbol: "", image: nil, score: 0, section: "keep"))
    #expect(dismissed)
}

@MainActor
@Test func anActionWithoutAQueryTokenStillRunsOnAnEmptyQuery() {
    let controller = flagController()
    var dismissed = false
    controller.onDismiss = { dismissed = true }
    controller.open(route: "install")
    // Node.js carries no {query}, so nothing about the guard applies to it.
    controller.activate(DisplayRow(id: "install.node", kind: .action, label: "Node.js", detail: "", symbol: "", image: nil, score: 0, section: "current"))
    #expect(dismissed)
}
