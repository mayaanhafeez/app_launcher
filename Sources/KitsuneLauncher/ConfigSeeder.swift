import Foundation

/// Copies the shipped templates into `~/.config/kitsune` on first launch.
///
/// `scripts/build-app.sh` copies `Config/` into the bundle's `Resources/`, and this is
/// the only thing that reads it. Without it a fresh install has no config at all and
/// falls back to `LuaRuntime.defaultNodes`, which is the near-empty launcher a new
/// user would otherwise meet first.
///
/// **It only acts when `config.lua` is missing**, and even then never overwrites a
/// file: a user who deleted `menus/learn.lua` has made a decision, and copying it back
/// on every launch would undo it. Tying the seed to the one file every config has is
/// what makes it a first-run step rather than a sync. A `theme.lua` written before the
/// first `config.lua` survives it for the same reason.
enum ConfigSeeder {
    /// Where `build-app.sh` puts the templates. Nil for a bare `swift build` binary,
    /// which has no bundle resources, and seeding is skipped.
    static var bundledTemplates: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Config"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("config.lua").path)
        else { return nil }
        return url
    }

    /// Returns the files copied, relative to `directory`; empty when nothing was seeded.
    @discardableResult
    static func seed(from templates: URL?, to directory: URL) -> [String] {
        let files = FileManager.default
        guard let templates,
              !files.fileExists(atPath: directory.appendingPathComponent("config.lua").path),
              let entries = files.enumerator(atPath: templates.path)
        else { return [] }

        var copied: [String] = []
        for case let relative as String in entries {
            // `.DS_Store` and friends: a Finder visit to the source checkout is not config.
            if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            let source = templates.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard files.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let destination = directory.appendingPathComponent(relative)
            guard !files.fileExists(atPath: destination.path) else { continue }
            do {
                try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.copyItem(at: source, to: destination)
                copied.append(relative)
            } catch {
                NSLog("Kitsune: could not seed %@: %@", relative, error.localizedDescription)
            }
        }
        return copied.sorted()
    }
}
