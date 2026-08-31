import AppKit
import Testing
@testable import OrbitLauncher

@Test func spacingScaleMultipliesEveryToken() {
    var theme = Theme()
    theme.spacingScale = 2
    #expect(theme.space(theme.panelPadding) == theme.panelPadding * 2)
    #expect(theme.space(0) == 0)
}

@Test func fontSizeDrivesTheWholeScale() {
    var theme = Theme()
    theme.fontSize = 20
    #expect(theme.bodySize == 20)
    #expect(theme.headingSize == 27)   // 20 * 1.333
    #expect(theme.captionSize == 17)   // 20 * 0.833
    #expect(theme.iconSize == 30)      // 20 * 1.5
}

@Test func rowHeightFollowsTheDetailLine() {
    var theme = Theme()
    theme.rowHeight = 40
    theme.rowHeightDetail = 60
    #expect(theme.rowHeight(hasDetail: false) == 40)
    #expect(theme.rowHeight(hasDetail: true) == 60)
}

@Test func selectionDefaultsToAWashPlusAccentText() {
    let theme = Theme()
    #expect(theme.selectionText == theme.accent)
    #expect(theme.selectionFill.alphaComponent == theme.selectionAlpha)
}

@Test func namedFontKeepsItsRequestedWeight() {
    var theme = Theme()
    theme.family = "Helvetica"
    #expect(theme.font(size: 13, weight: .bold).pointSize == 13)
    // An unresolvable family falls back to the system font rather than nil.
    theme.family = "No Such Family"
    #expect(theme.font(size: 13, weight: .medium) == .systemFont(ofSize: 13, weight: .medium))
}

@Test func hotkeyNamesResolveToKeyCodes() {
    #expect(GlobalHotKey.keyCode(for: "space") != nil)
    #expect(GlobalHotKey.keyCode(for: "K") == GlobalHotKey.keyCode(for: "k"))
    #expect(GlobalHotKey.keyCode(for: "f5") != nil)
    #expect(GlobalHotKey.keyCode(for: "nonsense") == nil)
    #expect(GlobalHotKey.modifierMask(for: ["option"]) != GlobalHotKey.modifierMask(for: ["option", "shift"]))
    #expect(GlobalHotKey.modifierMask(for: ["cmd"]) == GlobalHotKey.modifierMask(for: ["command"]))
}

@Test func vimNormalModeKeyMap() {
    func action(_ key: String, _ mods: NSEvent.ModifierFlags = []) -> VimAction {
        VimKeys.normalModeAction(characters: key, modifiers: mods)
    }
    #expect(action("j") == .moveDown)
    #expect(action("k") == .moveUp)
    #expect(action("/") == .beginSearch)
    #expect(action("i") == .insertAtCursor)
    #expect(action("a") == .insertAtEnd)
    #expect(action("s") == .substitute)
}

@Test func vimNormalModeSwallowsUnmappedKeysButNotShortcuts() {
    func action(_ key: String, _ mods: NSEvent.ModifierFlags = []) -> VimAction {
        VimKeys.normalModeAction(characters: key, modifiers: mods)
    }
    // Unmapped letters are eaten, so normal mode never types into the field.
    #expect(action("x") == .ignore)
    #expect(action("J") == .ignore)   // vim is case-sensitive; shift+j is not moveDown
    #expect(action("") == .ignore)
    // Modified keys stay with AppKit so cmd-Q and friends still work.
    #expect(action("q", .command) == .passThrough)
    #expect(action("a", .command) == .passThrough)
    #expect(action("j", .control) == .passThrough)
    // Option is not a system-shortcut modifier here, so it is still swallowed.
    #expect(action("j", .option) == .moveDown)
}
