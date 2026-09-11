import Foundation
import Testing
@testable import KitsuneLauncher

// Loads the shipped plugins through the real runtime. They are the documentation for
// `command` + `on_select`, so a syntax error or a stale action key in one is a bug in
// the templates users copy.
@Test func shippedCommandPluginsLoadAndCarryTheirOnSelect() async {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let plugins = repo.appendingPathComponent("Config/plugins")
    let lua = repo.appendingPathComponent("Config/lua")
    let (runtime, load, directory) = await kitsuneLoadConfig("""
    package.path = "\(plugins.path)/?.lua;\(lua.path)/?.lua;" .. package.path
    local items = {{ id = "root", label = "Kitsune" }}
    for _, name in ipairs({ "aerospace", "find", "currency" }) do
      for _, item in ipairs(require(name).items) do items[#items + 1] = item end
    end
    return { items = items }
    """)
    defer { kitsuneRemove(directory); _ = runtime }

    #expect(load.error == nil)
    for id in ["wm.switch", "wm.workspace", "wm.send", "wm.summon", "find.name", "find.content", "find.home", "currency.convert"] {
        #expect(load.node(id)?.onSelect != nil, "\(id) lost its on_select")
        #expect(load.node(id)?.command.isEmpty == false, "\(id) lost its command")
    }

    // The window row's value is a bare id, spliced through `quoted form of` — the
    // shell layer inside `do shell script`, which the host does not escape for.
    if case .appleScript(let script)? = load.node("wm.switch")?.onSelect {
        #expect(script.contains("quoted form of \"{value}\""))
        #expect(script.hasPrefix("do shell script \""))
    } else { Issue.record("expected an applescript on_select") }
    #expect(load.node("find.name")?.onSelect == .open("{value}"))
}


/// Runs `script` under /bin/sh with `home` standing in for the user's, the way
/// `CommandRunner` spawns it, and returns stdout. The plugin resolves its binary with
/// `command -v`, and its own PATH line puts `$HOME/.local/bin` ahead of Homebrew's
/// prefix — which is what lets a stand-in win over a real window manager installed on
/// the machine running the test.
private func kitsuneRunScript(_ script: String, home: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = home.path
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

@Test func aHostileWindowTitleCannotIntroduceACommand() async {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let (runtime, load, configDirectory) = await kitsuneLoadConfig("""
    package.path = "\(repo.path)/Config/plugins/?.lua;\(repo.path)/Config/lua/?.lua;" .. package.path
    local items = {{ id = "root", label = "Kitsune" }}
    for _, item in ipairs(require("aerospace").items) do items[#items + 1] = item end
    return { items = items }
    """)
    defer { kitsuneRemove(configDirectory); _ = runtime }
    guard let node = load.node("wm.switch"), let onSelect = node.onSelect else {
        Issue.record("wm.switch did not load"); return
    }

    // A stand-in for the window manager. The second line is what a browser tab whose
    // `document.title` carries a newline and tabs splits into: a whole second record,
    // indistinguishable from a real window, whose first field used to be taken
    // positionally as the row's command.
    let directory = kitsuneTemporaryDirectory("kitsune-wm-injection")
    defer { kitsuneRemove(directory) }
    let binaries = directory.appendingPathComponent(".local/bin")
    try? FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
    let canary = directory.appendingPathComponent("pwned").path
    for name in ["aerospace", "hyprspace"] {
        let fake = binaries.appendingPathComponent(name)
        try? """
        #!/bin/sh
        printf '%s\\t%s\\t%s\\t%s\\n' 12 1 Safari 'GitHub'
        printf '%s\\t%s\\t%s\\t%s\\n' '99; touch \(canary); #' 2 Safari 'Evil'
        """.write(to: fake, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    }

    let script = node.command.replacingOccurrences(of: ScriptAction.queryToken, with: "''")
    let output = kitsuneRunScript(script, home: directory)
    let rows = CommandRunner.parse(output, menuID: "wm.switch", limit: 100, onSelect: onSelect)

    // The real window, plus the crafted line — which still becomes a row, since nothing
    // filters it and nothing has to.
    #expect(rows.count == 2, "unexpected rows from: \(output)")
    for row in rows {
        guard case .appleScript(let script)? = row.action else { Issue.record("expected an applescript action"); continue }
        // Whatever the line said, the command is the node's, and the line's content
        // reaches it only inside `quoted form of` — one shell argument, never a second
        // command. `touch` is a word in an argument here, not a program that runs.
        #expect(script.hasPrefix("do shell script \""))
        #expect(script.contains("& quoted form of \""))
        #expect(script.components(separatedBy: "do shell script").count == 2)
    }
    #expect(!FileManager.default.fileExists(atPath: canary))
}
