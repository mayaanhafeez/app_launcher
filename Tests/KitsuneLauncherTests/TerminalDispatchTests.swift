import Foundation
import Testing
@testable import KitsuneLauncher

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
    echo "picked $name" | tee /tmp/kitsune-test.log > /dev/null
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

// Where that script is sent, once `terminal = ...` can move it. The two families are
// asserted separately because they carry the command by different means: AppleScript
// through a base64 payload inside a string literal, `open --args` through argv.

@Test func defaultSpecStillDrivesTerminalApp() {
    guard case .appleScript(let source) = terminalLaunch("echo hi", spec: TerminalSpec()) else {
        Issue.record("expected the scripted path"); return
    }
    #expect(source == terminalScript("echo hi"))
}

@Test func iTermIsScriptedThroughWriteText() {
    // iTerm has no `do script`. `write text` puts the line into a session already
    // running the interactive shell, so the tty contract is the same one Terminal has.
    for name in ["iTerm", "iterm2"] {
        guard case .appleScript(let source) = terminalLaunch("brew install jq", spec: TerminalSpec(app: name)) else {
            Issue.record("expected the scripted path for \(name)"); return
        }
        #expect(source.contains("tell application \"iTerm\""))
        #expect(source.contains("write text \"eval "))
        #expect(decodedPayload(source) == "brew install jq")
    }
}

@Test func spawnedTerminalCarriesTheCommandAsOneArgument() {
    // The whole point of the `open --args` path: argv is exact, so a command with
    // quotes, a newline and a pipe needs no encoding and cannot be re-split.
    let command = "read -r '?Formula: ' name\necho \"got $name\" | cat"
    guard case .open(let argv) = terminalLaunch(command, spec: TerminalSpec(app: "Ghostty", shell: "/bin/zsh")) else {
        Issue.record("expected the spawned path"); return
    }
    #expect(argv == ["-na", "Ghostty", "--args", "-e", "/bin/zsh", "-ic", command])
}

@Test func knownTerminalsGetTheirOwnArgv() {
    // kitty takes the program positionally and wezterm needs `start --`; everything
    // else is the `-e` majority. A terminal Kitsune has never heard of gets that.
    guard case .open(let kitty) = terminalLaunch("ls", spec: TerminalSpec(app: "kitty", shell: "/bin/zsh")),
          case .open(let wezterm) = terminalLaunch("ls", spec: TerminalSpec(app: "WezTerm", shell: "/bin/zsh")),
          case .open(let unknown) = terminalLaunch("ls", spec: TerminalSpec(app: "Rio", shell: "/bin/zsh")) else {
        Issue.record("expected the spawned path"); return
    }
    #expect(kitty == ["-na", "kitty", "--args", "/bin/zsh", "-ic", "ls"])
    #expect(wezterm == ["-na", "WezTerm", "--args", "start", "--", "/bin/zsh", "-ic", "ls"])
    #expect(unknown == ["-na", "Rio", "--args", "-e", "/bin/zsh", "-ic", "ls"])
}

@Test func explicitArgumentsWinOverTheScriptedPath() {
    // An argv template written by hand is a statement of intent: use it even for an
    // app that would otherwise be driven by AppleScript.
    let spec = TerminalSpec(app: "Terminal", arguments: ["--profile", "{shell}", "{command}"], shell: "/bin/bash")
    guard case .open(let argv) = terminalLaunch("ls", spec: spec) else {
        Issue.record("expected the spawned path"); return
    }
    #expect(argv == ["-na", "Terminal", "--args", "--profile", "/bin/bash", "ls"])
}

@Test func anEmptyShellResolvesToALoginShell() {
    // Resolved at launch, not at decode: `TerminalSpec()` stays a plain value that a
    // test can compare, and the user's $SHELL is read when the window is opened.
    guard case .open(let argv) = terminalLaunch("ls", spec: TerminalSpec(app: "Ghostty")) else {
        Issue.record("expected the spawned path"); return
    }
    #expect(argv[4].hasPrefix("/"))
    #expect(!argv[4].isEmpty)
}

@Test func interactiveShellFlagIsKept() {
    // `-i` is load-bearing for the same reason `eval` is on the scripted path: a
    // non-interactive shell prints no prompt, so `read -r '?Formula: '` would sit
    // there silently.
    guard case .open(let argv) = terminalLaunch("ls", spec: TerminalSpec(app: "Ghostty")) else {
        Issue.record("expected the spawned path"); return
    }
    #expect(argv.contains("-ic"))
}
