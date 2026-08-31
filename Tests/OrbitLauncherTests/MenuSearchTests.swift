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
