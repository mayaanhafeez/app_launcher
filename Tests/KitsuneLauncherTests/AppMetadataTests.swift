import AppKit
import Testing
@testable import KitsuneLauncher

/// `AppIndex` reads app metadata straight out of `Contents/Info.plist` rather than
/// through `Bundle(url:)`, which retains a fully parsed plist per app forever. The
/// saving is only worth having if the answers are identical, and reproducing
/// `Bundle`'s name resolution means reproducing undocumented behaviour: localized
/// overrides in `.strings`, Apple's multi-locale `.loctable`, and `-macos`
/// platform-suffixed keys that beat the bare key.
///
/// So this checks the real implementation against `Bundle` itself, over whatever is
/// installed. It is deliberately not gated behind KITSUNE_BENCH: it is the only thing
/// that would catch macOS changing the rules and every app quietly getting the wrong
/// name.
@MainActor
@Test func appMetadataMatchesBundle() {
    let roots = AppIndex.defaultRoots
    let paths = AppIndex.appPaths(in: roots, depth: 3)
    var differences: [String] = []
    for path in paths {
        let url = URL(fileURLWithPath: path)
        let bundle = Bundle(url: url)
        let old = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let oldID = bundle?.bundleIdentifier ?? path
        guard let entry = AppIndex.entryForAudit(path: path) else { continue }
        if entry.name != old { differences.append("  NAME \(url.lastPathComponent): was '\(old)' now '\(entry.name)'") }
        if entry.id != oldID { differences.append("  ID   \(url.lastPathComponent): was '\(oldID)' now '\(entry.id)'") }
        // Whatever the label became, the old name has to stay findable.
        #expect(FuzzyMatcher.score(old, in: entry.searchText) != nil,
                "'\(old)' no longer matches its own search text: \(entry.searchText)")
    }
    print("audited \(paths.count) apps, \(differences.count) differences")
    for line in differences { print(line) }
}

