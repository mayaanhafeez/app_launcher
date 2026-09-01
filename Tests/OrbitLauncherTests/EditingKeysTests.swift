import AppKit
import Testing
@testable import OrbitLauncher

@Test func editingKeysMapTheEditMenuChords() {
    func action(_ key: String, _ mods: NSEvent.ModifierFlags) -> EditingAction? {
        EditingKeys.action(characters: key, modifiers: mods)
    }
    #expect(action("a", [.command]) == .selectAll)
    #expect(action("c", [.command]) == .copy)
    #expect(action("v", [.command]) == .paste)
    #expect(action("x", [.command]) == .cut)
    #expect(action("z", [.command]) == .undo)
    // `charactersIgnoringModifiers` still applies shift, so ⌘⇧Z arrives uppercased.
    #expect(action("Z", [.command, .shift]) == .redo)
    // Caps lock and the numeric-pad bit ride along on ordinary presses.
    #expect(action("v", [.command, .capsLock]) == .paste)
}

@Test func editingKeysIgnoreEverythingButTheirOwnChord() {
    func action(_ key: String, _ mods: NSEvent.ModifierFlags) -> EditingAction? {
        EditingKeys.action(characters: key, modifiers: mods)
    }
    // Plain letters are query text, not commands.
    #expect(action("c", []) == nil)
    // A richer chord is somebody else's shortcut, not copy.
    #expect(action("c", [.command, .option]) == nil)
    #expect(action("c", [.command, .shift]) == nil)
    #expect(action("v", [.control]) == nil)
    // Unmapped keys fall through to the list shortcuts.
    #expect(action("1", [.command]) == nil)
    #expect(action("k", [.command]) == nil)
    #expect(action("", [.command]) == nil)
}

/// The precedence `routeKey` implements: the editing chords win, everything else in
/// `shortcuts.keys` is untouched — including the digits it defaults to.
@Test func listShortcutsKeepEveryChordEditingDoesNotClaim() {
    let spec = ShortcutSpec()
    for position in 0..<10 {
        let key = spec.keys[position]
        #expect(EditingKeys.action(characters: key, modifiers: [.command]) == nil)
        #expect(spec.position(for: key, modifiers: [.command]) == position)
    }
    // A config that puts letters on ⌘ loses only the five editing chords.
    let letters = ShortcutSpec(keys: ["q", "c", "w", "v"])
    #expect(EditingKeys.action(characters: "q", modifiers: [.command]) == nil)
    #expect(letters.position(for: "q", modifiers: [.command]) == 0)
    #expect(EditingKeys.action(characters: "c", modifiers: [.command]) == .copy)
    // Move those keys off ⌘ and they are shortcuts again — editing never sees them.
    let optionLetters = ShortcutSpec(modifiers: ["control", "option"], keys: ["c", "v"])
    #expect(EditingKeys.action(characters: "c", modifiers: [.control, .option]) == nil)
    #expect(optionLetters.position(for: "c", modifiers: [.control, .option]) == 0)
}

/// Vim's normal mode must not eat the editing chords on their way to the field: the
/// key monitor consumes a key only when this says so.
@Test func vimNormalModePassesEditingChordsThrough() {
    for key in ["a", "c", "v", "x", "z"] {
        #expect(VimKeys.normalModeAction(characters: key, modifiers: [.command]) == .passThrough)
    }
}
