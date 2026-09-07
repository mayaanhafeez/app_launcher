import AppKit
import Testing
@testable import KitsuneLauncher

// Placement is pure: the visible frame, the pointer and the focused window all come
// in as values, so every anchor and every clamp is checkable without a screen.

private let left = NSRect(x: 0, y: 0, width: 1440, height: 900)
private let right = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
private let card = NSSize(width: 380, height: 300)

private func place(
    _ anchor: PanelAnchor,
    visible: NSRect = left,
    offset: CGPoint = .zero,
    pointer: NSPoint = NSPoint(x: 700, y: 500),
    focusedWindow: NSRect? = nil
) -> NSRect {
    PanelPlacement.frame(size: card, visible: visible, anchor: anchor,
                         offset: offset, pointer: pointer, focusedWindow: focusedWindow)
}

@Test func centerReproducesTheHistoricalPlacement() {
    // What the panel did before any of this was configurable: centred, plus offset_y.
    let frame = place(.center, offset: CGPoint(x: 0, y: 28))
    #expect(frame.midX == left.midX)
    #expect(frame.origin.y == (left.midY - card.height / 2 + 28).rounded())
}

@Test func topSitsFlushWithTheTopOfTheVisibleFrame() {
    let frame = place(.top)
    #expect(frame.maxY == left.maxY)
    #expect(frame.midX == left.midX)
}

@Test func mouseHangsBelowThePointer() {
    // Like a context menu: the top edge is the pointer, so the list grows downwards
    // and the card's top stays put as rows come and go.
    let pointer = NSPoint(x: 700, y: 500)
    let frame = place(.mouse, pointer: pointer)
    #expect(frame.maxY == pointer.y)
    #expect(frame.midX == pointer.x)
}

@Test func activeWindowCentresOnTheFocusedWindow() {
    let window = NSRect(x: 200, y: 100, width: 800, height: 600)
    let frame = place(.activeWindow, focusedWindow: window)
    #expect(frame.midX == window.midX)
    #expect(frame.midY == window.midY)
}

@Test func activeWindowFallsBackToThePointer() {
    // Accessibility can be ungranted or have nothing to report; the anchor degrades
    // rather than guessing a frame.
    let pointer = NSPoint(x: 300, y: 800)
    #expect(place(.activeWindow, pointer: pointer, focusedWindow: nil) == place(.mouse, pointer: pointer))
}

@Test func noOffsetCanPushTheCardOffScreen() {
    // The whole point of clamping: a large offset, or a pointer at the very edge,
    // still leaves the card fully inside the visible frame.
    for anchor in PanelAnchor.allCases {
        for offset in [CGPoint(x: 9000, y: 9000), CGPoint(x: -9000, y: -9000)] {
            let frame = place(anchor, offset: offset, pointer: NSPoint(x: left.maxX, y: left.minY))
            #expect(left.contains(frame), "\(anchor) drifted off-screen with offset \(offset)")
        }
    }
}

@Test func aCardLargerThanTheDisplayShrinksToFitIt() {
    let tiny = NSRect(x: 0, y: 0, width: 200, height: 150)
    let frame = PanelPlacement.frame(size: card, visible: tiny, anchor: .center,
                                     offset: .zero, pointer: .zero, focusedWindow: nil)
    #expect(frame == tiny)
}

// MARK: - Screen choice

@Test func mouseScreenFollowsThePointer() {
    let screens = [left, right]
    #expect(PanelPlacement.screenIndex(.mouse, screens: screens, pointer: NSPoint(x: 2000, y: 500), focusedWindow: nil) == 1)
    #expect(PanelPlacement.screenIndex(.mouse, screens: screens, pointer: NSPoint(x: 100, y: 500), focusedWindow: nil) == 0)
}

@Test func mainIsAlwaysTheFirstScreen() {
    // NSScreen.screens leads with the primary display, wherever the pointer is.
    #expect(PanelPlacement.screenIndex(.main, screens: [left, right], pointer: NSPoint(x: 2000, y: 500), focusedWindow: nil) == 0)
}

@Test func activeScreenFollowsTheFocusedWindowThenThePointer() {
    let screens = [left, right]
    let onTheRight = NSRect(x: 1600, y: 200, width: 600, height: 400)
    #expect(PanelPlacement.screenIndex(.active, screens: screens, pointer: NSPoint(x: 100, y: 100), focusedWindow: onTheRight) == 1)

    // A window straddling both belongs to the display showing most of it.
    let mostlyLeft = NSRect(x: 1200, y: 200, width: 400, height: 400)
    #expect(PanelPlacement.screenIndex(.active, screens: screens, pointer: NSPoint(x: 2000, y: 100), focusedWindow: mostlyLeft) == 0)

    // No focused window: the pointer decides, exactly as `.mouse` would.
    #expect(PanelPlacement.screenIndex(.active, screens: screens, pointer: NSPoint(x: 2000, y: 100), focusedWindow: nil) == 1)
}

@Test func anUnmatchedLookupFallsBackToThePrimaryDisplay() {
    // A pointer on a display that just disconnected, or no screens at all.
    #expect(PanelPlacement.screenIndex(.mouse, screens: [left], pointer: NSPoint(x: 5000, y: 5000), focusedWindow: nil) == 0)
    #expect(PanelPlacement.screenIndex(.active, screens: [], pointer: .zero, focusedWindow: nil) == 0)
}

// MARK: - theme.lua

private func loadPlacement(_ source: String) -> Theme {
    let directory = kitsuneTemporaryDirectory("kitsune-theme")
    defer { kitsuneRemove(directory) }
    let file = directory.appendingPathComponent("theme.lua")
    try? source.write(to: file, atomically: true, encoding: .utf8)
    return ThemeRuntime().load(file: file)
}

@Test func placementKeysComeFromTheTheme() {
    let theme = loadPlacement("""
    return { position = "top", screen = "active", offset_x = -12, offset_y = 40 }
    """)
    #expect(theme.position == .top)
    #expect(theme.screen == .active)
    #expect(theme.offsetX == -12)
    #expect(theme.offsetY == 40)
}

@Test func theActiveWindowAnchorTakesEitherSpelling() {
    // Config keys are snake_case, so `active_window` is what a user reaches for.
    #expect(loadPlacement("return { position = \"active_window\" }").position == .activeWindow)
    #expect(loadPlacement("return { position = \"active-window\" }").position == .activeWindow)
}

@Test func anUnknownAnchorLeavesTheDefaultStanding() {
    // Same rule as an unparseable colour or an unknown menu-bar symbol: a typo costs
    // the key, never the panel.
    let theme = loadPlacement("return { position = \"middle-ish\", screen = \"projector\" }")
    #expect(theme.position == .center)
    #expect(theme.screen == .mouse)
}
