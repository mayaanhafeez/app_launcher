import AppKit
import Testing
@testable import KitsuneLauncher

// The store is driven through an injected reading rather than the real pasteboard,
// so a test run can neither read what the developer has copied nor write to their
// clipboard — the same hermetic contract `UsageStore(url: nil)` gives frecency.

@MainActor
private final class FakePasteboard {
    var changeCount = 0
    var concealed = false
    var string: String?

    func copy(_ text: String, concealed: Bool = false) {
        changeCount += 1
        self.string = text
        self.concealed = concealed
    }

    var reading: ClipboardHistory.Reading {
        ClipboardHistory.Reading(changeCount: changeCount, concealed: concealed, string: string)
    }
}

@MainActor
private func store(_ pasteboard: FakePasteboard, url: URL? = nil,
                   _ spec: ClipboardSpec = ClipboardSpec(enabled: true)) -> ClipboardHistory {
    let history = ClipboardHistory(url: url, read: { pasteboard.reading })
    history.apply(spec)
    return history
}

@MainActor
@Test func historyCapturesNewestFirst() {
    let pasteboard = FakePasteboard()
    let history = store(pasteboard)
    for text in ["one", "two", "three"] { pasteboard.copy(text); history.poll() }
    #expect(history.entries.map(\.text) == ["three", "two", "one"])
}

// The list is a history of what you have, not of what you did: copying something
// again moves it up rather than adding a second row for it.
@MainActor
@Test func recopyingMovesAnEntryToTheFront() {
    let pasteboard = FakePasteboard()
    let history = store(pasteboard)
    for text in ["one", "two", "one"] { pasteboard.copy(text); history.poll() }
    #expect(history.entries.map(\.text) == ["one", "two"])
}

@MainActor
@Test func theLimitDropsTheOldest() {
    let pasteboard = FakePasteboard()
    let history = store(pasteboard, ClipboardSpec(enabled: true, limit: 2))
    for text in ["one", "two", "three"] { pasteboard.copy(text); history.poll() }
    #expect(history.entries.map(\.text) == ["three", "two"])
}

// The whole reason the feature can ship on by nobody's default: a password manager
// marks its copy, and a marked copy is never recorded.
@MainActor
@Test func concealedCopiesAreNeverRecorded() {
    let pasteboard = FakePasteboard()
    let history = store(pasteboard)
    pasteboard.copy("hunter2", concealed: true); history.poll()
    pasteboard.copy("ordinary"); history.poll()
    #expect(history.entries.map(\.text) == ["ordinary"])
}

@MainActor
@Test func disabledHistoryRecordsNothingAndForgetsWhatItHad() {
    let pasteboard = FakePasteboard()
    let history = store(pasteboard)
    pasteboard.copy("kept"); history.poll()
    #expect(history.entries.count == 1)

    history.apply(ClipboardSpec(enabled: false))
    #expect(history.entries.isEmpty)
    pasteboard.copy("while off"); history.poll()
    #expect(history.entries.isEmpty)
}

// Re-enabling must not sweep up whatever happens to be on the pasteboard from
// before the user asked for any of this.
@MainActor
@Test func reEnablingIgnoresWhatIsAlreadyOnThePasteboard() {
    let pasteboard = FakePasteboard()
    let history = store(pasteboard, ClipboardSpec(enabled: false))
    pasteboard.copy("copied while off")
    history.apply(ClipboardSpec(enabled: true))
    history.poll()
    #expect(history.entries.isEmpty)

    pasteboard.copy("copied while on"); history.poll()
    #expect(history.entries.map(\.text) == ["copied while on"])
}

@MainActor
@Test func blankCopiesAreIgnored() {
    let pasteboard = FakePasteboard()
    let history = store(pasteboard)
    pasteboard.copy("   \n  "); history.poll()
    #expect(history.entries.isEmpty)
}

// Persistence is opt-in, and revoking it takes the file with it rather than
// leaving what was already written sitting on disk.
@MainActor
@Test func nothingIsWrittenUnlessPersistIsAskedFor() async {
    let directory = kitsuneTemporaryDirectory("kitsune-clip")
    defer { kitsuneRemove(directory) }
    let url = directory.appendingPathComponent("clipboard.json")
    let pasteboard = FakePasteboard()

    let history = store(pasteboard, url: url)
    pasteboard.copy("secret"); history.poll()
    // The flush is coalesced at two seconds; nothing should appear before or after.
    _ = await kitsuneWaitUntil(timeout: 2.5) { false }
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@MainActor
@Test func persistedHistoryRoundTripsThroughItsFile() async {
    let directory = kitsuneTemporaryDirectory("kitsune-clip")
    defer { kitsuneRemove(directory) }
    let url = directory.appendingPathComponent("clipboard.json")
    let pasteboard = FakePasteboard()

    let history = store(pasteboard, url: url, ClipboardSpec(enabled: true, persist: true))
    pasteboard.copy("remembered"); history.poll()
    #expect(await kitsuneWaitUntil(timeout: 5) { FileManager.default.fileExists(atPath: url.path) })

    let reopened = ClipboardHistory(url: url, read: { pasteboard.reading })
    #expect(reopened.entries.map(\.text) == ["remembered"])

    // Turning persistence back off must not leave the file behind.
    history.apply(ClipboardSpec(enabled: true, persist: false))
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

// MARK: - Rows

@MainActor
@Test func rowsCopyTheWholeEntryWhateverTheLabelShows() {
    let pasteboard = FakePasteboard()
    let history = store(pasteboard)
    pasteboard.copy("first line\nsecond line"); history.poll()

    let rows = history.results(for: "", limit: 10)
    // The label is the shape of a row, not of the entry — but the action carries the
    // entry in full, newlines and all.
    #expect(rows.first?.label == "first line second line")
    #expect(rows.first?.detail == "2 lines · 22 characters")
    #expect(rows.first?.rowAction == .copyText("first line\nsecond line"))
}

@MainActor
@Test func rowsAreFuzzySearchable() {
    let pasteboard = FakePasteboard()
    let history = store(pasteboard)
    for text in ["git rebase --continue", "brew upgrade", "git status"] { pasteboard.copy(text); history.poll() }
    let labels = history.results(for: "git", limit: 10).map(\.label)
    #expect(labels.count == 2)
    #expect(labels.allSatisfy { $0.contains("git") })
}

@MainActor
@Test func aVeryLongEntryIsTruncatedForTheRow() {
    let long = String(repeating: "x", count: 400)
    #expect(ClipboardHistory.label(for: long).count == 121)   // 120 plus the ellipsis
    #expect(ClipboardHistory.label(for: long).hasSuffix("…"))
}

// MARK: - The route

@MainActor
@Test func theClipboardRouteAppearsOnlyWhenEnabled() {
    let pasteboard = FakePasteboard()
    let history = ClipboardHistory(url: nil, read: { pasteboard.reading })
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime(), clipboard: history)
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
    ]
    #expect(controller.rows(route: "root", query: "").rows.isEmpty)

    controller.clipboardSpec = ClipboardSpec(enabled: true)
    #expect(controller.rows(route: "root", query: "").rows.map(\.label) == ["Clipboard"])
    // Reachable by alias, like any other node.
    #expect(controller.rows(route: "clip", query: "").title == "Clipboard")

    pasteboard.copy("copied"); history.poll()
    #expect(controller.rows(route: "clipboard", query: "").rows.map(\.label) == ["Back", "copied"])

    controller.clipboardSpec = ClipboardSpec(enabled: false)
    #expect(controller.rows(route: "root", query: "").rows.isEmpty)
}
