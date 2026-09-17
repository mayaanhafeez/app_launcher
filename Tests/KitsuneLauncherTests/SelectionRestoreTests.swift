import AppKit
import Testing
@testable import KitsuneLauncher

// `NSTableView.reloadData()` drops the selection, and `PanelController.update` — the only
// thing that ever put one back — early-returns when the rows are unchanged, which a
// config reload usually leaves them. So a reload left the panel with nothing selected:
// no highlight, and Return acting on nothing. This is the rule both reload paths share.

private func row(_ id: String, kind: RowKind = .action) -> DisplayRow {
    DisplayRow(id: id, kind: kind, label: id, detail: "", symbol: "", image: nil, score: 0, section: "")
}

@Test func anEmptyListSelectsNothing() {
    #expect(PanelController.selectionTarget(in: [], preferring: nil) == nil)
    #expect(PanelController.selectionTarget(in: [], preferring: 3) == nil)
}

@Test func afreshListStartsOnTheFirstRowThatIsNotTheBackRow() {
    // Return on a freshly opened submenu has to activate something in it rather than
    // walking straight back out, which is why the back row is skipped at either end.
    #expect(PanelController.selectionTarget(in: [row("a"), row("b")], preferring: nil) == 0)
    #expect(PanelController.selectionTarget(in: [row("back", kind: .back), row("a")], preferring: nil) == 1)
    #expect(PanelController.selectionTarget(in: [row("a"), row("back", kind: .back)], preferring: nil) == 0)
}

@Test func aThemeReloadKeepsTheUserWhereTheyWere() {
    // Restyling a list someone is already navigating must not move their place.
    let rows = [row("a"), row("b"), row("c")]
    #expect(PanelController.selectionTarget(in: rows, preferring: 2) == 2)
    #expect(PanelController.selectionTarget(in: rows, preferring: 1) == 1)
}

@Test func aPreviousIndexThatNoLongerFitsFallsBackToTheTop() {
    let rows = [row("a"), row("b")]
    #expect(PanelController.selectionTarget(in: rows, preferring: 7) == 0)   // list shrank
    // -1 is what an NSTableView with no selection reports, so it must not be honoured.
    #expect(PanelController.selectionTarget(in: rows, preferring: -1) == 0)
}

@Test func thePreviousIndexIsNotHonouredWhenItLandsOnTheBackRow() {
    // Rows can be replaced under a held index, and landing on the back row would make
    // Return walk out of the menu the user is looking at.
    let rows = [row("a"), row("back", kind: .back)]
    #expect(PanelController.selectionTarget(in: rows, preferring: 1) == 0)
}

@Test func aListOfNothingButABackRowStillSelectsIt() {
    // There is nothing else to land on, and leaving it unselected would mean Return
    // does nothing at all.
    #expect(PanelController.selectionTarget(in: [row("back", kind: .back)], preferring: nil) == 0)
}
