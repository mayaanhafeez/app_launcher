import Foundation
import Testing
@testable import OrbitLauncher

// How a `shell = ...` entry reaches Terminal. The construction looks fussy and is
// load-bearing twice over: base64 keeps the payload intact through an AppleScript
// string literal, and `eval` keeps it off the new shell's stdin.

/// The encoded payload from a generated script, decoded back to the command.
private func decodedPayload(_ script: String) -> String? {
    guard let start = script.range(of: "printf %s "),
          let end = script.range(of: " | base64 -D", range: start.upperBound..<script.endIndex) else { return nil }
    let encoded = String(script[start.upperBound..<end.lowerBound])
    guard let data = Data(base64Encoded: encoded) else { return nil }
    return String(data: data, encoding: .utf8)
}

@Test func terminalScriptEvalsRatherThanPipingToAShell() {
    let script = terminalScript("read -r '?Formula: ' name; brew install $name")

    // The bug this guards: piping the decoded script into a shell puts it on stdin,
    // which is exactly where `read` reads from — so the prompt saw EOF and `brew
    // install` got an empty name. `eval` runs it in the window's own interactive
    // shell, leaving stdin on the tty.
    #expect(script.contains("do script \"eval \\\"$(printf %s "))
    #expect(script.contains("| base64 -D)\\\"\""))
    for piped in ["| sh", "| bash", "| zsh", "| /bin/sh"] {
        #expect(!script.contains(piped), "the decoded script must never be piped into a shell's stdin")
    }
}

@Test func terminalScriptRoundTripsQuotesNewlinesPipesAndRedirects() {
    let command = """
    read -r '?Formula: ' name
    echo "picked $name" | tee /tmp/orbit-test.log > /dev/null
    grep -e 'a b' --color=never <<'EOF' || true
    it's "quoted"; rm -rf /
    EOF
    """
    let script = terminalScript(command)
    #expect(decodedPayload(script) == command)
}

@Test func terminalScriptCannotBreakOutOfTheAppleScriptString() {
    // A command carrying a double quote and a newline is exactly what would end the
    // `do script "..."` literal early if it were interpolated instead of encoded.
    let command = "echo \"hi\"\nend tell\ndisplay dialog \"pwned\""
    let script = terminalScript(command)

    #expect(decodedPayload(script) == command)
    // tell / activate / do script / end tell, and nothing else: the payload
    // contributed no lines of its own.
    #expect(script.split(separator: "\n", omittingEmptySubsequences: false).count == 4)
    #expect(!script.contains("display dialog"))
    #expect(script.hasSuffix("\nend tell"))
}

@Test func terminalScriptPayloadIsASingleUnquotedWord() {
    // `printf %s <payload>` is written without quotes, which is only safe because
    // base64 output is one whitespace-free word of [A-Za-z0-9+/=].
    let script = terminalScript("echo 'a b'\t| cat\n")
    guard let start = script.range(of: "printf %s "),
          let end = script.range(of: " | base64 -D", range: start.upperBound..<script.endIndex) else {
        Issue.record("expected a base64 payload"); return
    }
    let encoded = String(script[start.upperBound..<end.lowerBound])
    #expect(!encoded.isEmpty)
    #expect(encoded.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" })
}

@Test func queryIsSubstitutedBeforeEncoding() {
    // `{query}` resolution happens on the action, so what gets encoded is the final
    // command — a shell-quoted query included.
    guard case .shell(let command) = ScriptAction.shell("brew install {query}").resolved(query: "it's fine") else {
        Issue.record("expected a shell action"); return
    }
    #expect(decodedPayload(terminalScript(command)) == "brew install 'it'\\''s fine'")
}
