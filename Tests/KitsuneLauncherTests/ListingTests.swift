import AppKit
import Testing
@testable import KitsuneLauncher

// `kitsunectl list` — the rows a route would show, without opening a window and
// without disturbing what the panel is currently showing.

@MainActor
private func listingController() -> MenuController {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "setup", parent: "root", kind: .menu, label: "Setup", title: "Settings", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 1),
        MenuNode(id: "setup.network", parent: "setup", kind: .action, label: "Network", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: .url(""), order: 2),
    ]
    return controller
}

@MainActor
@Test func listingReportsRowsForARoute() {
    let controller = listingController()
    let listing = controller.rows(route: "setup", query: "")
    #expect(listing.title == "Settings")
    // Decorated exactly as the panel would see it, back row included.
    #expect(listing.rows.map(\.label) == ["Back", "Network"])
}

@MainActor
@Test func listingDoesNotDisturbTheActiveMenu() {
    let controller = listingController()
    var emissions = 0
    controller.onRows = { _, _ in emissions += 1 }
    controller.open(route: "setup")
    let settled = emissions

    _ = controller.rows(route: "root", query: "")
    // No emission: a listing is a question, not a navigation.
    #expect(emissions == settled)
    // And the controller is still inside the submenu it was opened at.
    #expect(controller.back())
    #expect(!controller.back())
}

@MainActor
@Test func listingResolvesAnUnknownRouteToRoot() {
    let controller = listingController()
    #expect(controller.rows(route: "nonsense", query: "").title == "Go")
}

@MainActor
@Test func listCommandEncodesRowsAsJSON() {
    let commands = IPCCommands(list: { _, _ in
        (title: "Apps", rows: [
            DisplayRow(id: "app:/Applications/A.app", kind: .app, label: "A", detail: "/Applications/A.app", symbol: "", image: nil, score: 3, section: "apps"),
        ])
    })
    let response = commands.handle(IPCRequest(command: "list", argument: "apps"))
    #expect(response.ok)

    let payload = try? JSONDecoder().decode(ListingPayload.self, from: Data(response.message.utf8))
    #expect(payload?.title == "Apps")
    #expect(payload?.rows.count == 1)
    #expect(payload?.rows.first?.kind == "app")
    #expect(payload?.rows.first?.id == "app:/Applications/A.app")
}

@MainActor
@Test func listCommandSplitsRouteFromQuery() {
    final class Box { var route = ""; var query = "" }
    let box = Box()
    let commands = IPCCommands(list: { route, query in
        box.route = route
        box.query = query
        return (title: "Go", rows: [])
    })

    _ = commands.handle(IPCRequest(command: "list", argument: "root google chrome"))
    // Only the first space separates them, so a multi-word query stays intact.
    #expect(box.route == "root")
    #expect(box.query == "google chrome")

    _ = commands.handle(IPCRequest(command: "list", argument: nil))
    #expect(box.route == "root")
    #expect(box.query == "")
}

@MainActor
@Test func listCommandFailsWhenThereIsNoMenu() {
    // The default closure stands in for a delegate that has been torn down.
    #expect(!IPCCommands().handle(IPCRequest(command: "list", argument: "apps")).ok)
}
