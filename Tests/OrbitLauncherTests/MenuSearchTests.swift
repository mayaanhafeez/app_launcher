import Testing
@testable import OrbitLauncher

@MainActor
@Test func categorySearchIncludesDescendants() {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "dev", parent: "root", kind: .menu, label: "Development", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 1),
        MenuNode(id: "dev.servers", parent: "dev", kind: .menu, label: "Servers", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 2),
        MenuNode(id: "dev.servers.web", parent: "dev.servers", kind: .action, label: "Web server", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: .shell("true"), order: 3),
    ]
    var labels: [String] = []
    controller.onRows = { _, rows in labels = rows.map(\.label) }
    controller.open(route: "dev")
    controller.update(query: "web")
    #expect(labels == ["Web server"])
}

@MainActor
@Test func escapeNavigationContract() {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "setup", parent: "root", kind: .menu, label: "Setup", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 1),
    ]
    controller.open(route: "setup")
    #expect(controller.back())
    #expect(!controller.back())
}

@MainActor
@Test func providerRowsAreActivatable() {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
    ]
    var dismissed = false
    controller.onDismiss = { dismissed = true }

    // A row with no backing node and no action is inert (it is a notice).
    controller.activate(DisplayRow(id: "search.notice", kind: .notice, label: "No results", detail: "", symbol: "", image: nil, score: 0, section: "provider"))
    #expect(!dismissed)

    // A provider row carrying an action dispatches it. An empty url builds no URL,
    // so the branch is taken without the test launching anything.
    controller.activate(DisplayRow(id: "search.google", kind: .action, label: "Google", detail: "", symbol: "", image: nil, score: 0, section: "provider", action: .url("")))
    #expect(dismissed)
}

@MainActor
@Test func routesResolveThroughAliases() {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "system", parent: "root", kind: .menu, label: "System", title: "Session", detail: "", symbol: "", aliases: ["power-menu"], provider: nil, actionReference: nil, scriptAction: nil, order: 1),
    ]
    var header = ""
    controller.onRows = { title, _ in header = title }

    controller.open(route: "power_menu")   // underscores normalize to dashes
    #expect(header == "Session")           // `title` wins over `label` in the header

    controller.open(route: "nope")
    #expect(header == "Go")                // unknown routes fall back to root
}

@MainActor
@Test func searchMatchesLeafIdsAndAliases() {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "install.editor.zed", parent: "install.editor", kind: .action, label: "Editor", detail: "", symbol: "", aliases: ["ide"], provider: nil, actionReference: nil, scriptAction: .shell("true"), order: 1),
    ]
    var labels: [String] = []
    controller.onRows = { _, rows in labels = rows.map(\.label) }

    controller.open(route: "root")
    controller.update(query: "zed")   // leaf id
    #expect(labels == ["Editor"])
    controller.update(query: "ide")   // alias
    #expect(labels == ["Editor"])
}
