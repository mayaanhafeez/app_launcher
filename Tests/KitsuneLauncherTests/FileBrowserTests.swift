import AppKit
import Testing
@testable import KitsuneLauncher

// Path mode: a leading `/` or `~` turns the list into a directory listing. The query
// splitting is pure; the enumeration touches only a temp directory built per test.

// MARK: - Recognising a path

@Test func onlyALeadingSlashOrTildeIsAPath() {
    #expect(PathQuery("/") != nil)
    #expect(PathQuery("/usr/lo") != nil)
    #expect(PathQuery("~") != nil)
    #expect(PathQuery("~/dev") != nil)

    // A query is not a path just because it contains a slash — menu searches have to
    // keep working exactly as they did.
    #expect(PathQuery("") == nil)
    #expect(PathQuery("safari") == nil)
    #expect(PathQuery("and/or") == nil)
    // `~user` is another account's home to a shell and nothing this resolves.
    #expect(PathQuery("~root/bin") == nil)
}

@Test func aPathSplitsAtItsLastSeparator() {
    // Everything before the last `/` is enumerated; everything after filters it. That
    // is what makes each keystroke a filter rather than another walk of the disk.
    let query = PathQuery("/usr/local/bi")
    #expect(query?.directory == "/usr/local")
    #expect(query?.fragment == "bi")

    let trailing = PathQuery("/usr/local/")
    #expect(trailing?.directory == "/usr/local")
    #expect(trailing?.fragment == "")

    let root = PathQuery("/us")
    #expect(root?.directory == "/")
    #expect(root?.fragment == "us")
}

@Test func aTildeQueryKeepsItsPrefixButEnumeratesTheExpandedPath() {
    // Browsing extends the prefix, so a `~/`-rooted query must stay `~/`-rooted
    // rather than turning into /Users/... under the user mid-type.
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let query = PathQuery("~/dev/pro")
    #expect(query?.prefix == "~/dev/")
    #expect(query?.directory == "\(home)/dev")
    #expect(query?.fragment == "pro")

    // A bare `~` means the home directory, with nothing typed to filter by.
    #expect(PathQuery("~")?.directory == home)
    #expect(PathQuery("~")?.fragment == "")
}

// MARK: - Listing a directory

/// A small tree: two directories, three files, one dotfile.
private func makeTree() -> URL {
    let root = kitsuneTemporaryDirectory("kitsune-files")
    let manager = FileManager.default
    for directory in ["projects", "pictures"] {
        try? manager.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    for file in ["notes.txt", "profile.json", "readme.md", ".hidden"] {
        try? "x".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }
    return root
}

private func labels(_ query: String, spec: FileSpec = FileSpec()) -> [String] {
    guard let path = PathQuery(query) else { return [] }
    return FileBrowser.rows(for: path, spec: spec).map(\.label)
}

@Test func aListingPutsDirectoriesFirst() {
    let root = makeTree()
    defer { kitsuneRemove(root) }

    let rows = FileBrowser.rows(for: PathQuery(root.path + "/")!, spec: FileSpec())
    let directories = rows.prefix { $0.kind == .menu }.map(\.label)
    #expect(directories == ["pictures", "projects"])
    #expect(rows.dropFirst(2).allSatisfy { $0.kind == .action })
    #expect(rows.map(\.label).contains("notes.txt"))
}

@Test func theTrailingFragmentFiltersTheListing() {
    let root = makeTree()
    defer { kitsuneRemove(root) }

    let matches = labels(root.path + "/pro")
    #expect(matches.contains("projects"))
    #expect(matches.contains("profile.json"))
    #expect(!matches.contains("notes.txt"))
    // Still directories first, within the filtered set.
    #expect(matches.first == "projects")
}

@Test func dotfilesAreHiddenUnlessAskedForOrTypedFor() {
    let root = makeTree()
    defer { kitsuneRemove(root) }

    #expect(!labels(root.path + "/").contains(".hidden"))
    #expect(labels(root.path + "/", spec: FileSpec(showHidden: true)).contains(".hidden"))
    // Typing the dot is the only reason anyone types one, so it reveals them whatever
    // the setting says.
    #expect(labels(root.path + "/.hid").contains(".hidden"))
}

@Test func aListingIsCappedByTheLimit() {
    let root = kitsuneTemporaryDirectory("kitsune-files")
    defer { kitsuneRemove(root) }
    for index in 0..<50 { try? "x".write(to: root.appendingPathComponent("file\(index).txt"), atomically: true, encoding: .utf8) }

    #expect(labels(root.path + "/", spec: FileSpec(limit: 10)).count == 10)
}

@Test func anUnreadableDirectoryIsAnEmptyListingNotACrash() {
    #expect(labels("/nope/definitely/not/here/").isEmpty)
}

@Test func everyRowCarriesItsPathForTheActionsMenu() {
    // Rows carry `.open(path)` so Reveal in Finder, Copy Path and Open With come from
    // the existing RowActions table with no new case — directories included.
    let root = makeTree()
    defer { kitsuneRemove(root) }

    let rows = FileBrowser.rows(for: PathQuery(root.path + "/")!, spec: FileSpec())
    let directory = rows.first { $0.label == "projects" }
    let file = rows.first { $0.label == "notes.txt" }

    #expect(FileBrowser.path(for: directory!) == root.path + "/projects")
    #expect(FileBrowser.path(for: file!) == root.path + "/notes.txt")

    let actions = RowActions.entries(for: file!, query: "").map(\.label)
    #expect(actions.contains("Reveal in Finder"))
    #expect(actions.contains("Copy Path"))
    // A folder is worth revealing too, which is why directories carry the action as
    // well even though Return browses them.
    #expect(RowActions.entries(for: directory!, query: "").map(\.label).contains("Reveal in Finder"))
}

@Test func anAppBundleOpensRatherThanBeingBrowsedInto() {
    // A package is a directory the Finder presents as a file — the same rule AppIndex
    // applies when it declines to descend into one.
    let root = kitsuneTemporaryDirectory("kitsune-files")
    defer { kitsuneRemove(root) }
    try? FileManager.default.createDirectory(at: root.appendingPathComponent("Thing.app"), withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: root.appendingPathComponent("plain"), withIntermediateDirectories: true)

    let rows = FileBrowser.rows(for: PathQuery(root.path + "/")!, spec: FileSpec())
    #expect(rows.first { $0.label == "Thing.app" }?.kind == .action)
    #expect(rows.first { $0.label == "plain" }?.kind == .menu)
}

// MARK: - In the menu

@MainActor
private func pathController(nodes extra: [MenuNode] = []) -> MenuController {
    let controller = MenuController(appIndex: AppIndex(), runtime: LuaRuntime())
    controller.nodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "tools", parent: "root", kind: .menu, label: "Tools", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 1),
    ] + extra
    return controller
}

@MainActor
@Test func aPathTakesOverTheListAtRoot() async {
    // "Switches the list": a path is not a menu search that happens to start with a
    // slash, so the menu nodes go away while one is on screen.
    let root = makeTree()
    defer { kitsuneRemove(root) }
    let controller = pathController()
    let seen = Locked<[String]>([])
    let title = Locked("")
    controller.onRows = { header, rows in title.value = header; seen.value = rows.map(\.label) }

    controller.open()
    controller.update(query: root.path + "/")

    // The rows are enumerated off the main thread, so they arrive after the takeover.
    #expect(await kitsuneWaitUntil(timeout: 3) { seen.value.contains("notes.txt") })
    #expect(!seen.value.contains("Tools"))
    #expect(title.value == root.path)
}

@MainActor
@Test func aPathIsOnlyAPathAtRoot() async {
    // Inside a submenu a leading slash is just text to match, and has to stay that way.
    let root = makeTree()
    defer { kitsuneRemove(root) }
    let controller = pathController()
    let seen = Locked<[String]>([])
    controller.onRows = { _, rows in seen.value = rows.map(\.label) }

    controller.open(route: "tools")
    controller.update(query: root.path + "/")
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(!seen.value.contains("notes.txt"))
}

@MainActor
@Test func pathModeCanBeSwitchedOff() async {
    let root = makeTree()
    defer { kitsuneRemove(root) }
    let controller = pathController()
    controller.files = FileSpec(enabled: false)
    let seen = Locked<[String]>([])
    controller.onRows = { _, rows in seen.value = rows.map(\.label) }

    controller.open()
    controller.update(query: root.path + "/")
    try? await Task.sleep(nanoseconds: 300_000_000)
    // Nothing is enumerated, and the query is an ordinary menu search again — one
    // that happens to match no node.
    #expect(!seen.value.contains("notes.txt"))
    #expect(seen.value.isEmpty)
}

@MainActor
@Test func returnOnADirectoryExtendsTheQuery() async {
    // Browsing extends what was typed rather than replacing it with an absolute path,
    // so a `~/`-rooted query stays `~/`-rooted.
    let root = makeTree()
    defer { kitsuneRemove(root) }
    let controller = pathController()
    let queries = Locked<[String]>([])
    controller.onQuery = { queries.value.append($0) }

    controller.open()
    controller.update(query: root.path + "/pro")
    let directory = DisplayRow(id: FileBrowser.rowPrefix + root.path + "/projects", kind: .menu,
                               label: "projects", detail: "", symbol: "", image: nil, score: 0,
                               section: "files", action: .open(root.path + "/projects"))
    controller.activate(directory)

    #expect(queries.value.last == root.path + "/projects/")
}
