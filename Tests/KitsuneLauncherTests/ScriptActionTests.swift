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


// MARK: - {value}

@Test func valueIsSubstitutedAndEscapedPerDestination() {
    if case .shell(let command) = ScriptAction.shell("focus {value}").resolved(query: "", value: "a b; rm -rf /") {
        #expect(command == "focus 'a b; rm -rf /'")
    } else { Issue.record("expected a shell action") }

    if case .url(let url) = ScriptAction.url("https://x.example/?q={value}").resolved(query: "", value: "a b&c") {
        #expect(url == "https://x.example/?q=a%20b%26c")
    } else { Issue.record("expected a url action") }

    if case .appleScript(let script) = ScriptAction.appleScript("set the clipboard to \"{value}\"").resolved(query: "", value: "he said \"hi\"") {
        #expect(script == "set the clipboard to \"he said \\\"hi\\\"\"")
    } else { Issue.record("expected an applescript action") }
}

@Test func bothTokensAreSubstitutedInOnePass() {
    // A value containing the other token stays literal: output never gets a second
    // reading, whichever order the two appear in.
    if case .shell(let command) = ScriptAction.shell("note {query} {value}").resolved(query: "q", value: "{query}") {
        #expect(command == "note 'q' '{query}'")
    } else { Issue.record("expected a shell action") }

    if case .shell(let command) = ScriptAction.shell("note {value} {query}").resolved(query: "q", value: "v") {
        #expect(command == "note 'v' 'q'")
    } else { Issue.record("expected a shell action") }
}

@Test func valueIsLeftAloneWhenThereIsNone() {
    // `{value}` on an ordinary item has nothing to fill it: it is a command row's
    // token, and a static row must not have it silently emptied.
    #expect(ScriptAction.shell("focus {value}").resolved(query: "q") == .shell("focus {value}"))
}

@Test func appleScriptQuotingEscapesNewlines() {
    // A raw newline inside an AppleScript literal is a syntax error rather than an
    // injection — but it is still a value from outside deciding whether it compiles.
    #expect(ScriptAction.appleScriptQuoted("one\ntwo\r\\three\"four") == "one\\ntwo\\r\\\\three\\\"four")
}
