import AppKit
import Testing
@testable import KitsuneLauncher

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
    // The back row is prepended to every submenu; the search result follows it.
    #expect(labels == ["Back", "Web server"])
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
@Test func enteringAndLeavingMenusClearTheVisibleQuery() {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "colours", parent: "root", kind: .menu, label: "Colour schemes", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 1),
        MenuNode(id: "colours.nord", parent: "colours", kind: .action, label: "Nord", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: .url(""), order: 2),
    ]
    var queryChanges: [String] = []
    var labels: [String] = []
    controller.onQuery = { queryChanges.append($0) }
    controller.onRows = { _, rows in labels = rows.map(\.label) }

    controller.open()
    controller.update(query: "colour")
    controller.activate(DisplayRow(id: "colours", kind: .menu, label: "Colour schemes", detail: "", symbol: "", image: nil, score: 0, section: "current"))
    #expect(queryChanges.last == "")
    #expect(labels == ["Back", "Nord"])

    controller.update(query: "nord")
    #expect(controller.back())
    #expect(queryChanges.last == "")
    #expect(labels == ["Colour schemes"])
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

@MainActor
@Test func backRowIsConfigurableAndOnlyInSubmenus() {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "setup", parent: "root", kind: .menu, label: "Setup", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 1),
        MenuNode(id: "setup.wifi", parent: "setup", kind: .action, label: "Wi-Fi", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: .shell("true"), order: 2),
    ]
    var labels: [String] = []
    controller.onRows = { _, rows in labels = rows.map(\.label) }

    controller.open(route: "root")
    #expect(labels == ["Setup"])          // never at root

    controller.open(route: "setup")
    #expect(labels == ["Back", "Wi-Fi"])

    // It is not a candidate for the fuzzy filter, so a query never drops it.
    controller.update(query: "wifi")
    #expect(labels.first == "Back")

    controller.backRow = BackRowSpec(enabled: true, label: "Up", symbol: "arrow.left", detail: "", position: "bottom")
    #expect(labels == ["Wi-Fi", "Up"])

    controller.backRow = BackRowSpec(enabled: false)
    #expect(labels == ["Wi-Fi"])
}

@MainActor
@Test func backRowActivationNavigatesBack() {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "setup", parent: "root", kind: .menu, label: "Setup", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 1),
    ]
    var labels: [String] = []
    controller.onRows = { _, rows in labels = rows.map(\.label) }
    controller.open(route: "setup")
    controller.activate(DisplayRow(id: "kitsune.back", kind: .back, label: "Back", detail: "", symbol: "", image: nil, score: -1, section: "back"))
    #expect(labels == ["Setup"])          // back at root, so no back row
}

@Test func appScanHonoursItsDepthCapAndSkipsAppsInsideApps() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("kitsune-scan-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: root) }

    // A bundle at each level, plus one nested inside another bundle.
    let bundles = ["Top.app", "one/Nested.app", "one/two/Deep.app", "one/two/three/TooDeep.app", "Top.app/Contents/Helper.app"]
    for bundle in bundles {
        try fileManager.createDirectory(at: root.appendingPathComponent(bundle), withIntermediateDirectories: true)
    }

    let found = Set(AppIndex.appPaths(in: [root], depth: 3).map { URL(fileURLWithPath: $0).lastPathComponent })
    #expect(found == ["Top.app", "Nested.app", "Deep.app"])

    let shallow = Set(AppIndex.appPaths(in: [root], depth: 1).map { URL(fileURLWithPath: $0).lastPathComponent })
    #expect(shallow == ["Top.app"])
}

@Test func iconsAreFlattenedToOneBitmapAtRowSize() {
    let icon = AppIndex.thumbnail(for: "/bin/ls")
    #expect(icon.size == NSSize(width: AppIndex.thumbnailSize, height: AppIndex.thumbnailSize))
    // One representation at 2x, rather than the multi-size image NSWorkspace hands back.
    #expect(icon.representations.count == 1)
    #expect(icon.representations.first?.pixelsWide == Int(AppIndex.thumbnailSize) * 2)
}
