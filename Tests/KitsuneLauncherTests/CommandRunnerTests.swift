import AppKit
import Testing
@testable import KitsuneLauncher

// Subprocess-backed rows. Every command here is `printf`, `sleep` or a write into the
// test's own temp directory — nothing that touches the network, a package manager, or
// anything outside the directory the test removes afterwards.

@MainActor
private func fastSpec(_ mutate: (inout CommandSpec) -> Void = { _ in }) -> CommandSpec {
    var spec = CommandSpec()
    spec.debounce = 0        // the debounce has its own test; everywhere else it is noise
    spec.timeout = 5
    mutate(&spec)
    return spec
}

@MainActor
private func runCommand(_ runner: CommandRunner, _ command: String, query: String = "", wait: TimeInterval = 10) async -> [DisplayRow]? {
    let box = Locked<[DisplayRow]?>(nil)
    runner.rows(command: command, menuID: "menu", query: query) { box.value = $0 }
    _ = await kitsuneWaitUntil(timeout: wait) { box.value != nil }
    return box.value
}

// MARK: - Parsing

@Test func parsesTabSeparatedRows() {
    let rows = CommandRunner.parse("Alpha\tfirst\techo one\nBeta\tsecond\nGamma\n", menuID: "m", limit: 100)
    #expect(rows.map(\.label) == ["Alpha", "Beta", "Gamma"])
    #expect(rows[0].detail == "first")
    #expect(rows[1].detail == "second")

    // A third field is the action; without one the row is inert.
    if case .shell(let command)? = rows[0].action { #expect(command == "echo one") } else { Issue.record("expected a shell action") }
    #expect(rows[1].action == nil)
    #expect(rows[0].kind == .action)
    #expect(rows[1].kind == .notice)
}

@Test func parsesJSONLines() {
    let text = """
    {"label":"Repo","detail":"a repository","symbol":"folder","url":"https://example.com"}
    {"label":"Run","shell":"echo hi","value":"run"}
    """
    let rows = CommandRunner.parse(text, menuID: "m", limit: 100)
    #expect(rows.map(\.label) == ["Repo", "Run"])
    #expect(rows[0].symbol == "folder")
    if case .url(let target)? = rows[0].action { #expect(target == "https://example.com") } else { Issue.record("expected a url action") }
    // `value` names the row, which is what keeps its id stable as the query changes.
    #expect(rows[1].id == "m.cmd.run")
}

@Test func parsingSkipsBlanksAndCapsRows() {
    let rows = CommandRunner.parse("one\n\n   \ntwo\nthree\n", menuID: "m", limit: 2)
    #expect(rows.map(\.label) == ["one", "two"])
}

@Test func parsingKeepsTheCommandsOwnOrder() {
    // `brew search` and friends already rank their output; re-sorting would discard it.
    let rows = CommandRunner.parse("zebra\napple\nmango\n", menuID: "m", limit: 100)
    #expect(rows.map(\.label) == ["zebra", "apple", "mango"])
    #expect(rows.map(\.score) == [0, 1, 2])
}

@Test func duplicateLabelsGetDistinctIDs() {
    let rows = CommandRunner.parse("same\nsame\n", menuID: "m", limit: 100)
    #expect(rows[0].id != rows[1].id)
}

@Test func malformedJSONLineIsSkippedNotFatal() {
    let rows = CommandRunner.parse("{\"nope\":1}\nplain\n", menuID: "m", limit: 100)
    #expect(rows.map(\.label) == ["plain"])
}

// MARK: - Spawning

@MainActor
@Test func spawnsAndParsesRealOutput() async {
    let runner = CommandRunner()
    runner.spec = fastSpec()
    let rows = await runCommand(runner, "printf 'Alpha\\tfirst\\nBeta\\tsecond\\n'")
    #expect(rows?.map(\.label) == ["Alpha", "Beta"])
    #expect(rows?.first?.detail == "first")
}

@MainActor
@Test func queryIsSubstitutedAndShellQuoted() async {
    let directory = kitsuneTemporaryDirectory("kitsune-cmd-injection")
    defer { kitsuneRemove(directory) }
    let canary = directory.appendingPathComponent("pwned").path

    let runner = CommandRunner()
    runner.spec = fastSpec()
    // If {query} were interpolated raw, this would close the quote and run `touch`.
    let hostile = "a'; touch \(canary); echo 'b"
    let rows = await runCommand(runner, "printf '%s\\n' {query}", query: hostile)

    #expect(rows?.count == 1)
    #expect(rows?.first?.label == hostile)
    #expect(!FileManager.default.fileExists(atPath: canary))
}

@MainActor
@Test func aCommandThatOverstaysIsKilled() async {
    let runner = CommandRunner()
    runner.spec = fastSpec { $0.timeout = 0.3 }
    let started = Date()
    let rows = await runCommand(runner, "sleep 30; printf 'never\\n'", wait: 10)
    // It returns, empty, at roughly the deadline rather than hanging the list.
    #expect(rows?.isEmpty == true)
    #expect(Date().timeIntervalSince(started) < 8)
}

@MainActor
@Test func rowsAreCachedByResolvedCommand() async {
    let directory = kitsuneTemporaryDirectory("kitsune-cmd-cache")
    defer { kitsuneRemove(directory) }
    let ledger = directory.appendingPathComponent("runs").path

    let runner = CommandRunner()
    runner.spec = fastSpec()
    let command = "printf 'x' >> \(ledger); printf 'Row\\n'"

    #expect(await runCommand(runner, command)?.map(\.label) == ["Row"])
    #expect(await runCommand(runner, command)?.map(\.label) == ["Row"])

    // Two requests, one spawn: backspacing through a query must not respawn.
    let ledgerContents = (try? String(contentsOfFile: ledger, encoding: .utf8)) ?? ""
    #expect(ledgerContents == "x")
}

@MainActor
@Test func differentQueriesAreDifferentCacheEntries() async {
    let runner = CommandRunner()
    runner.spec = fastSpec()
    #expect(await runCommand(runner, "printf '%s\\n' {query}", query: "one")?.first?.label == "one")
    #expect(await runCommand(runner, "printf '%s\\n' {query}", query: "two")?.first?.label == "two")
}

@MainActor
@Test func cancelDropsAPendingRun() async {
    let runner = CommandRunner()
    runner.spec = fastSpec { $0.debounce = 0.5 }
    let box = Locked<[DisplayRow]?>(nil)
    runner.rows(command: "printf 'Row\\n'", menuID: "menu", query: "") { box.value = $0 }
    runner.cancel()
    // Long enough for the debounce to have elapsed twice over.
    _ = await kitsuneWaitUntil(timeout: 2) { box.value != nil }
    #expect(box.value == nil)
}

@MainActor
@Test func rowCapIsEnforcedOnRealOutput() async {
    let runner = CommandRunner()
    runner.spec = fastSpec { $0.maxRows = 5 }
    let rows = await runCommand(runner, "for i in 1 2 3 4 5 6 7 8 9 10; do printf 'row%s\\n' $i; done")
    #expect(rows?.count == 5)
}

// MARK: - Wiring

@MainActor
@Test func commandRowsFollowTheStaticRows() async {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.commands.spec = fastSpec()
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "search", parent: "root", kind: .menu, label: "Search", detail: "", symbol: "", provider: nil, command: "printf 'FromCommand\\n'", actionReference: nil, scriptAction: nil, order: 1),
        MenuNode(id: "search.static", parent: "search", kind: .action, label: "Static", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: .url(""), order: 2),
    ]
    let labels = Locked<[String]>([])
    controller.onRows = { _, rows in labels.value = rows.map(\.label) }
    controller.open(route: "search")

    // The static list paints immediately; the command's rows arrive after it and are
    // appended, never replacing what was already there.
    #expect(labels.value == ["Back", "Static"])
    _ = await kitsuneWaitUntil(timeout: 10) { labels.value.contains("FromCommand") }
    #expect(labels.value == ["Back", "Static", "FromCommand"])
}

@MainActor
@Test func navigatingAwayCancelsTheCommand() async {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.commands.spec = fastSpec { $0.debounce = 0.4 }
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "search", parent: "root", kind: .menu, label: "Search", detail: "", symbol: "", provider: nil, command: "printf 'FromCommand\\n'", actionReference: nil, scriptAction: nil, order: 1),
    ]
    let labels = Locked<[String]>([])
    controller.onRows = { _, rows in labels.value = rows.map(\.label) }

    controller.open(route: "search")
    _ = controller.back()
    _ = await kitsuneWaitUntil(timeout: 2) { labels.value.contains("FromCommand") }
    // Root has no command, so the pending run is dropped rather than repainting a
    // menu the user already left.
    #expect(!labels.value.contains("FromCommand"))
}
