import Foundation
import Testing
@testable import KitsuneLauncher

// First-run seeding of ~/.config/kitsune from the bundled templates. Everything runs
// against temp directories standing in for the bundle and the config directory.

private func write(_ text: String, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

private func templates() -> URL {
    let root = kitsuneTemporaryDirectory("kitsune-templates")
    write("return {}", to: root.appendingPathComponent("config.lua"))
    write("return {}", to: root.appendingPathComponent("theme.lua"))
    write("return {}", to: root.appendingPathComponent("plugins/smart.lua"))
    write("background = \"#000000\"", to: root.appendingPathComponent("colour_schemes/kitsune.toml"))
    write("junk", to: root.appendingPathComponent(".DS_Store"))
    return root
}

@Test func aFreshConfigDirectoryIsSeededWithTheWholeTree() {
    let source = templates(), target = kitsuneTemporaryDirectory("kitsune-seed")
    defer { kitsuneRemove(source); kitsuneRemove(target) }
    kitsuneRemove(target)   // a first launch: the directory does not exist at all

    let copied = ConfigSeeder.seed(from: source, to: target)

    #expect(copied == ["colour_schemes/kitsune.toml", "config.lua", "plugins/smart.lua", "theme.lua"])
    #expect(read(target.appendingPathComponent("plugins/smart.lua")) == "return {}")
    #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent(".DS_Store").path))
}

// An existing config.lua means the user has a config, and it is theirs: nothing is
// added back, not even a file they deleted.
@Test func anExistingConfigIsNeverTouched() {
    let source = templates(), target = kitsuneTemporaryDirectory("kitsune-seed")
    defer { kitsuneRemove(source); kitsuneRemove(target) }
    write("-- mine", to: target.appendingPathComponent("config.lua"))

    #expect(ConfigSeeder.seed(from: source, to: target).isEmpty)
    #expect(read(target.appendingPathComponent("config.lua")) == "-- mine")
    #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("theme.lua").path))
}

// Seeding fills in around a file written before the first config.lua, never over it.
@Test func seedingNeverOverwritesAFile() {
    let source = templates(), target = kitsuneTemporaryDirectory("kitsune-seed")
    defer { kitsuneRemove(source); kitsuneRemove(target) }
    write("-- my theme", to: target.appendingPathComponent("theme.lua"))

    let copied = ConfigSeeder.seed(from: source, to: target)

    #expect(!copied.contains("theme.lua"))
    #expect(copied.contains("config.lua"))
    #expect(read(target.appendingPathComponent("theme.lua")) == "-- my theme")
}

// A bare `swift build` binary has no bundle resources.
@Test func noTemplatesMeansNoSeeding() {
    let target = kitsuneTemporaryDirectory("kitsune-seed")
    defer { kitsuneRemove(target) }
    #expect(ConfigSeeder.seed(from: nil, to: target).isEmpty)
}

// The shipped templates are what a new user gets, so they must load as they are — and
// load without the plugins that need something on the author's machine.
@Test func theShippedTemplatesSeedAConfigThatLoads() async {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let target = kitsuneTemporaryDirectory("kitsune-seed")
    defer { kitsuneRemove(target) }
    kitsuneRemove(target)

    let copied = ConfigSeeder.seed(from: repo.appendingPathComponent("Config"), to: target)
    var files: [String: String] = [:]
    for name in copied where name != "config.lua" { files[name] = read(target.appendingPathComponent(name)) }
    let (runtime, load, directory) = await kitsuneLoadConfig(read(target.appendingPathComponent("config.lua")), files: files)
    defer { kitsuneRemove(directory); _ = runtime }

    #expect(load.error == nil)
    for id in ["root", "apps", "search", "install", "system.lock", "setup.config"] {
        #expect(load.node(id) != nil, "\(id) is missing from the shipped config")
    }
    for id in ["project", "style.scheme", "wm", "dev", "update.kitsune"] {
        #expect(load.node(id) == nil, "\(id) needs the author's machine and should not ship on")
    }
}
