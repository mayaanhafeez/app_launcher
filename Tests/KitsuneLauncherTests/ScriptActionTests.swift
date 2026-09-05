import Testing
@testable import KitsuneLauncher

@Test func queryIsShellQuoted() {
    guard case .shell(let command) = ScriptAction.shell("brew install {query}").resolved(query: "foo bar") else {
        Issue.record("expected a shell action"); return
    }
    #expect(command == "brew install 'foo bar'")
}

@Test func shellQuotingSurvivesEmbeddedQuotes() {
    guard case .shell(let command) = ScriptAction.shell("echo {query}").resolved(query: "it's \"fine\"; rm -rf /") else {
        Issue.record("expected a shell action"); return
    }
    // The whole payload stays inside one single-quoted word, so `;` cannot start a
    // second command.
    #expect(command == "echo 'it'\\''s \"fine\"; rm -rf /'")
}

@Test func urlQueriesArePercentEncoded() {
    guard case .url(let target) = ScriptAction.url("https://example.com/?q={query}").resolved(query: "a b&c") else {
        Issue.record("expected a url action"); return
    }
    #expect(target == "https://example.com/?q=a%20b%26c")
}

@Test func appleScriptQueriesEscapeQuotes() {
    guard case .appleScript(let source) = ScriptAction.appleScript("display dialog \"{query}\"").resolved(query: "say \"hi\"") else {
        Issue.record("expected an applescript action"); return
    }
    #expect(source == "display dialog \"say \\\"hi\\\"\"")
}

@Test func actionsWithoutTokensAreUntouched() {
    let action = ScriptAction.shell("brew update")
    #expect(!action.wantsQuery)
    guard case .shell(let command) = action.resolved(query: "ignored") else { Issue.record("expected a shell action"); return }
    #expect(command == "brew update")
}
