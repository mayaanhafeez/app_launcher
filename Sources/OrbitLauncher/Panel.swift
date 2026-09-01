import AppKit

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class LauncherField: NSTextField {
    var routeKey: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if routeKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Hover selection rides on `mouseMoved` alone. An enter/exit pair also fires when
/// the list is rebuilt or scrolled under a stationary pointer, and acting on those
/// would let a stale cursor position snatch the selection back from the keyboard;
/// only genuine movement means the mouse is the input device in use.
final class LauncherTable: NSTableView {
    var onHover: ((Int) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

@MainActor
final class PanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let blur = NSVisualEffectView()
    private let card = NSView()
    private let input = LauncherField()
    private let table = LauncherTable()
    private let scroll = NSScrollView()
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let modeLabel = NSTextField(labelWithString: "NORMAL")
    private let emptyLabel = NSTextField(labelWithString: "No matches")
    private var rows: [DisplayRow] = []
    private var theme = Theme()
    private var title = "Go"
    private let rowIdentifier = NSUserInterfaceItemIdentifier("orbit-row")

    // Constraints whose constants are theme-derived and updated on reload.
    private var inputTop: NSLayoutConstraint!
    private var inputLeading: NSLayoutConstraint!
    private var inputTrailing: NSLayoutConstraint!
    private var inputHeight: NSLayoutConstraint!
    private var scrollTop: NSLayoutConstraint!
    private var scrollLeading: NSLayoutConstraint!
    private var scrollTrailing: NSLayoutConstraint!
    private var scrollBottom: NSLayoutConstraint!
    private var noticeLeading: NSLayoutConstraint!
    private var noticeTrailing: NSLayoutConstraint!
    private var noticeBottom: NSLayoutConstraint!
    private var modeTrailing: NSLayoutConstraint!
    private var modeWidth: NSLayoutConstraint!

    /// Modal navigation. `mode` is meaningless while this is false — every key goes
    /// straight to the field, exactly as before.
    var vimEnabled = false {
        didSet {
            guard vimEnabled != oldValue else { return }
            mode = .normal
            refreshModeIndicator()
        }
    }
    /// Positional list shortcuts, republished on every config reload.
    var shortcuts = ShortcutSpec() {
        didSet {
            guard shortcuts != oldValue else { return }
            rebuildHints()
            table.reloadData()
        }
    }
    /// One hint per row, parallel to `rows`. Precomputed rather than derived in
    /// `viewFor`, which would re-count the rows above every row it builds.
    private var hints: [String] = []
    private var mode: InputMode = .normal
    /// Held for the process lifetime: the panel controller is owned by the app
    /// delegate and outlives every other object, so there is nothing to tear down.
    private var keyMonitor: Any?

    var onQuery: ((String) -> Void)?
    var onActivate: ((DisplayRow) -> Void)?
    var onBack: (() -> Bool)?

    init() {
        let panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300), styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        super.init(window: panel)
        buildUI(panel)
        apply(theme: theme)
        installKeyMonitor()
    }

    /// Normal mode has to intercept plain characters, and `performKeyEquivalent` is
    /// never sent for them — unmodified keys go straight to the field editor, which is
    /// why the arrow/return handling lives in `doCommandBy`. A local key-down monitor
    /// is the one hook that runs before the field editor sees the event.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.consumesInNormalMode(event) } ? nil : event
        }
    }

    private func consumesInNormalMode(_ event: NSEvent) -> Bool {
        guard vimEnabled, let panel = window, panel.isVisible, panel.isKeyWindow else { return false }
        if event.keyCode == 53 {
            // Escape leaves insert mode; in normal mode it keeps its usual meaning, so
            // it is handed on to the existing cancelOperation path.
            guard mode == .insert else { return false }
            enterNormalMode()
            return true
        }
        guard mode == .normal else { return false }
        switch event.keyCode {
        case 125, 126, 36, 76, 123: return false   // arrows and return keep working
        default: return handleNormalMode(event)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(route: String = "root") {
        guard let panel = window else { return }
        input.stringValue = ""
        mode = .normal
        refreshModeIndicator()
        updatePrompt()
        resizeToContent()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(input)
    }

    func hide() { window?.orderOut(nil) }

    func update(title: String, rows: [DisplayRow]) {
        self.title = title
        self.rows = rows
        rebuildHints()
        updatePrompt()
        // Reload first: `resizeToContent` ends in `setFrame(display: true)`, which lays
        // the table out synchronously and asks for row heights. Resizing before the
        // reload asks with the table's previous, larger row count against the new,
        // shorter `rows` — an out-of-bounds read whenever the list shrinks.
        table.reloadData()
        resizeToContent()
        emptyLabel.isHidden = !rows.isEmpty
        if rows.isEmpty { table.deselectAll(nil) }
        else {
            // Never land on the back row: Return on a freshly opened submenu has to
            // activate something in it, not walk straight back out.
            let first = rows.firstIndex { $0.kind != .back } ?? 0
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
            table.scrollRowToVisible(first)
        }
        repaintSelection()
    }

    /// The back row carries no shortcut and takes no number, so the hints stay in
    /// step with what `activate(position:)` counts.
    private func rebuildHints() {
        var position = 0
        hints = rows.map { row in
            guard row.kind != .back else { return "" }
            let hint = shortcuts.hint(at: position) ?? ""
            position += 1
            return hint
        }
    }

    func showNotice(_ message: String) {
        notice.stringValue = message
        notice.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.notice.isHidden = true }
    }

    func apply(theme: Theme) {
        self.theme = theme
        blur.material = theme.blur > 0.66 ? .hudWindow : (theme.blur > 0.33 ? .menu : .windowBackground)
        blur.alphaValue = theme.blur <= 0 ? 0 : 1
        // The effect view fills the whole window, so without a mask its square material
        // stays visible in the four corners the card rounds away.
        blur.maskImage = Self.roundedMask(radius: theme.radius)

        card.layer?.backgroundColor = theme.cardBackground.cgColor
        card.layer?.cornerRadius = theme.radius
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = theme.borderWidth
        card.layer?.borderColor = theme.borderColor.cgColor

        let headingFont = theme.font(size: theme.headingSize, weight: theme.labelWeight)
        input.textColor = theme.fg
        input.font = headingFont

        emptyLabel.textColor = theme.detailColor
        emptyLabel.font = theme.font(size: theme.bodySize, weight: theme.detailWeight)

        modeLabel.font = theme.font(size: theme.captionSize, weight: .semibold)
        // Pinned to the wider of the two words so the field never jitters on a mode change.
        modeWidth.constant = ("NORMAL" as NSString)
            .size(withAttributes: [.font: modeLabel.font as Any]).width.rounded(.up)

        notice.textColor = theme.bg
        notice.font = theme.font(size: theme.smallSize, weight: theme.detailWeight)
        notice.layer?.cornerRadius = theme.rowRadius

        let sides = theme.sidePadding
        inputTop.constant = theme.topPadding
        inputLeading.constant = sides + theme.space(theme.rowPaddingX)
        inputTrailing.constant = -(sides + theme.space(theme.rowPaddingX))
        inputHeight.constant = theme.headerHeight
        scrollTop.constant = theme.space(theme.headerGap)
        scrollLeading.constant = sides
        scrollTrailing.constant = -sides
        scrollBottom.constant = -theme.bottomPadding
        noticeLeading.constant = sides
        noticeTrailing.constant = -sides
        noticeBottom.constant = -theme.bottomPadding
        modeTrailing.constant = -(sides + theme.space(theme.rowPaddingX))
        refreshModeIndicator()

        table.intercellSpacing = NSSize(width: 0, height: theme.space(theme.rowGap))
        table.rowHeight = theme.rowHeight(hasDetail: false)
        table.reloadData()
        updatePrompt()
        resizeToContent()
    }

    // MARK: - Sizing

    /// The card is content-sized like the omarchy menu: it shrinks to the rows it
    /// holds and only scrolls once it hits the screen-fraction cap.
    private func resizeToContent() {
        guard let panel = window else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let edges = theme.topPadding + theme.bottomPadding
        let chrome = edges + theme.headerHeight + theme.space(theme.headerGap)
        let cap = max(theme.headerHeight + edges, visible.height * theme.maxHeight)
        let height = min(chrome + contentHeight(), cap).rounded()
        let width = min(theme.width, visible.width - theme.sidePadding * 2).rounded()

        let origin = NSPoint(
            x: (visible.midX - width / 2).rounded(),
            y: (visible.midY - height / 2 + theme.offsetY).rounded()
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        // The shadow is derived from the masked content, so it has to be recomputed
        // whenever the card resizes or it keeps the previous outline.
        panel.invalidateShadow()
    }

    /// A resizable rounded-rect mask: the centre stretches, the corners don't.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func contentHeight() -> CGFloat {
        guard !rows.isEmpty else { return theme.rowHeight(hasDetail: false) }
        let spacing = theme.space(theme.rowGap)
        return rows.indices.reduce(CGFloat.zero) { total, index in total + height(ofRow: index) + spacing }
    }

    private func showsDetail(_ row: DisplayRow) -> Bool {
        guard !row.detail.isEmpty else { return false }
        switch theme.detailMode {
        case "always": return true
        case "never": return false
        default: return !input.stringValue.isEmpty
        }
    }

    private func height(ofRow index: Int) -> CGFloat {
        // AppKit can ask about a row that no longer exists mid-reload.
        guard rows.indices.contains(index) else { return theme.rowHeight(hasDetail: false) }
        let row = rows[index]
        let base = theme.rowHeight(hasDetail: showsDetail(row))
        // The drilldown divider gets its own strip of height above the row it marks.
        return row.section == "drilldown-start" && index > 0 ? base + theme.space(theme.dividerHeight) : base
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: rowIdentifier, owner: self) as? RowView) ?? RowView(identifier: rowIdentifier)
        cell.configure(item: rows[row], theme: theme, showDetail: showsDetail(rows[row]),
                       showDivider: rows[row].section == "drilldown-start" && row > 0,
                       shortcut: hints.indices.contains(row) ? hints[row] : "")
        cell.setSelected(row == table.selectedRow, theme: theme)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { repaintSelection() }

    /// Selection is painted by the row itself, so every realized row has to be told.
    /// `makeIfNecessary: false` keeps this to the handful the table has built.
    private func repaintSelection() {
        let selected = table.selectedRow
        for row in rows.indices {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RowView)?.setSelected(row == selected, theme: theme)
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { height(ofRow: row) }

    // MARK: - Input

    func controlTextDidChange(_ obj: Notification) {
        // Text reaching the field means we are typing: a dead key or IME commit can
        // bypass the monitor, and the indicator must never claim NORMAL while it edits.
        if vimEnabled, mode == .normal {
            mode = .insert
            refreshModeIndicator()
        }
        updatePrompt()
        onQuery?(input.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.insertNewline(_:)): activateSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)): escape(); return true
        case #selector(NSResponder.moveLeft(_:)) where input.stringValue.isEmpty: _ = goBack(); return true
        default: return false
        }
    }

    private func routeKey(_ event: NSEvent) -> Bool {
        // Editing keys are resolved *before* list shortcuts, and that precedence is the
        // deliberate half of this: `shortcuts.keys` defaults to digits, which collide
        // with nothing, but a config that puts letters there would otherwise swallow
        // ⌘C — and with no Edit menu in the process there is no second way to copy,
        // whereas the row that chord would have picked is still an arrow key away.
        // `sendAction(to: nil)` walks the responder chain from the field editor exactly
        // as a nil-targeted Edit menu item does, so `NSTextView` does the actual work
        // and its selection and undo registration stay consistent. No editor means the
        // panel is not taking text, and the chord is somebody else's.
        if input.currentEditor() != nil,
           let editing = EditingKeys.action(characters: event.charactersIgnoringModifiers ?? "",
                                            modifiers: event.modifierFlags),
           NSApp.sendAction(editing.selector, to: nil, from: input) {
            return true
        }
        // Shortcuts are modified keys, so `performKeyEquivalent` does deliver them and
        // this runs before the plain-key cases below can claim one.
        if let position = shortcuts.position(for: event.charactersIgnoringModifiers ?? "",
                                             modifiers: event.modifierFlags) {
            return activate(position: position)
        }
        switch event.keyCode {
        case 53: escape(); return true
        case 125: moveSelection(1); return true
        case 126: moveSelection(-1); return true
        case 36, 76: activateSelection(); return true
        case 123 where input.stringValue.isEmpty: return goBack()
        default: break
        }
        guard vimEnabled, mode == .normal else { return false }
        return handleNormalMode(event)
    }

    private func handleNormalMode(_ event: NSEvent) -> Bool {
        switch VimKeys.normalModeAction(characters: event.charactersIgnoringModifiers ?? "",
                                        modifiers: event.modifierFlags) {
        case .moveDown: moveSelection(1)
        case .moveUp: moveSelection(-1)
        case .beginSearch, .substitute: enterInsertMode(clearing: true)
        case .insertAtCursor: enterInsertMode()
        case .insertAtEnd: enterInsertMode(cursorAtEnd: true)
        case .ignore: break
        case .passThrough: return false
        }
        return true
    }

    private func enterNormalMode() {
        mode = .normal
        refreshModeIndicator()
    }

    private func enterInsertMode(clearing: Bool = false, cursorAtEnd: Bool = false) {
        if clearing {
            input.stringValue = ""
            onQuery?("")
        }
        mode = .insert
        window?.makeFirstResponder(input)
        if let editor = input.currentEditor(), clearing || cursorAtEnd {
            let end = (input.stringValue as NSString).length
            editor.selectedRange = NSRange(location: end, length: 0)
        }
        refreshModeIndicator()
        updatePrompt()
    }

    private func refreshModeIndicator() {
        modeLabel.isHidden = !vimEnabled
        guard vimEnabled else {
            inputTrailing.constant = -(theme.sidePadding + theme.space(theme.rowPaddingX))
            return
        }
        modeLabel.stringValue = mode == .normal ? "NORMAL" : "INSERT"
        modeLabel.textColor = mode == .normal ? theme.fgMuted : theme.accent
        inputTrailing.constant = -(theme.sidePadding + theme.space(theme.rowPaddingX)
                                   + modeWidth.constant + theme.space(theme.iconGap))
    }

    private func escape() {
        input.stringValue = ""
        updatePrompt()
        onQuery?("")
        _ = goBack()
    }

    private func goBack() -> Bool {
        let handled = onBack?() == true
        if !handled { hide() }
        return true
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let current = table.selectedRow < 0 ? 0 : table.selectedRow
        let next = (current + delta + rows.count) % rows.count
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    /// Positional shortcuts count the rows the user can act on, so the back row —
    /// chrome rather than an item — is skipped and the first key stays on the first
    /// real row whichever end the back row sits at. A key past the end of the list is
    /// still swallowed: it is a shortcut the user pressed, not text for the field.
    private func activate(position: Int) -> Bool {
        let actionable = rows.indices.filter { rows[$0].kind != .back }
        guard actionable.indices.contains(position) else { return true }
        let index = actionable[position]
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        onActivate?(rows[index])
        return true
    }

    private func activateSelection() {
        let index = table.selectedRow < 0 ? 0 : table.selectedRow
        if rows.indices.contains(index) { onActivate?(rows[index]) }
    }

    /// The prompt is the field's own placeholder rather than a label laid over the
    /// field: a label can only approximate the field editor's text origin, and the
    /// couple of points it was off by showed up as the caret sitting inside the "G".
    private func updatePrompt() {
        input.placeholderAttributedString = NSAttributedString(
            string: "\(title)...",
            attributes: [.font: input.font as Any, .foregroundColor: theme.fgMuted]
        )
        if !rows.isEmpty { table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count)) }
    }

    private func buildUI(_ panel: NSPanel) {
        blur.state = .active
        blur.blendingMode = .behindWindow
        panel.contentView = blur
        blur.wantsLayer = true
        card.wantsLayer = true
        [card].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; blur.addSubview($0) }
        [input, scroll, emptyLabel, notice, modeLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; card.addSubview($0) }

        input.isBordered = false
        input.isBezeled = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.delegate = self
        input.cell?.isScrollable = true
        input.routeKey = { [weak self] event in self?.routeKey(event) ?? false }

        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.delegate = self
        table.dataSource = self
        table.style = .plain
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.target = self
        table.action = #selector(click)
        table.onHover = { [weak self] row in self?.hover(row: row) }
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        modeLabel.alignment = .right
        modeLabel.isHidden = true

        notice.wantsLayer = true
        notice.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.92).cgColor
        notice.alignment = .center
        notice.isHidden = true

        inputTop = input.topAnchor.constraint(equalTo: card.topAnchor)
        inputLeading = input.leadingAnchor.constraint(equalTo: card.leadingAnchor)
        inputTrailing = input.trailingAnchor.constraint(equalTo: card.trailingAnchor)
        inputHeight = input.heightAnchor.constraint(equalToConstant: 30)
        scrollTop = scroll.topAnchor.constraint(equalTo: input.bottomAnchor)
        scrollLeading = scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor)
        scrollTrailing = scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor)
        scrollBottom = scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        noticeLeading = notice.leadingAnchor.constraint(equalTo: card.leadingAnchor)
        noticeTrailing = notice.trailingAnchor.constraint(equalTo: card.trailingAnchor)
        noticeBottom = notice.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        modeTrailing = modeLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor)
        modeWidth = modeLabel.widthAnchor.constraint(equalToConstant: 48)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: blur.leadingAnchor), card.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            card.topAnchor.constraint(equalTo: blur.topAnchor), card.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            inputTop, inputLeading, inputTrailing, inputHeight,
            scrollTop, scrollLeading, scrollTrailing, scrollBottom,
            emptyLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            modeTrailing, modeWidth, modeLabel.centerYAnchor.constraint(equalTo: input.centerYAnchor),
            noticeLeading, noticeTrailing, noticeBottom,
            notice.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
    }

    /// Single click activates: the panel is a menu, and a menu opens on one click.
    @objc private func click() {
        guard rows.indices.contains(table.clickedRow) else { return }
        onActivate?(rows[table.clickedRow])
    }

    /// Hover and the arrow keys drive the same single cursor — whichever moved last wins.
    private func hover(row index: Int) {
        guard rows.indices.contains(index), index != table.selectedRow else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }
}

final class RowView: NSTableCellView {
    private let selectionBackground = NSView()
    private let selectionBar = NSView()
    private let divider = NSView()
    private let iconView = NSImageView()
    private let symbol = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private let column = NSStackView()
    private let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
    private var theme = Theme()

    private var selectionTop: NSLayoutConstraint!
    private var selectionLeading: NSLayoutConstraint!
    private var selectionTrailing: NSLayoutConstraint!
    private var dividerHeight: NSLayoutConstraint!
    private var dividerTop: NSLayoutConstraint!
    private var columnTrailing: NSLayoutConstraint!
    private var barWidth: NSLayoutConstraint!
    private var barLeading: NSLayoutConstraint!
    private var iconLeading: NSLayoutConstraint!
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!
    private var symbolLeading: NSLayoutConstraint!
    private var symbolWidth: NSLayoutConstraint!
    private var symbolHeight: NSLayoutConstraint!
    private var columnLeading: NSLayoutConstraint!
    private var chevronTrailing: NSLayoutConstraint!
    private var chevronWidth: NSLayoutConstraint!
    private var shortcutTrailing: NSLayoutConstraint!

    convenience init(identifier: NSUserInterfaceItemIdentifier) {
        self.init(frame: .zero)
        self.identifier = identifier
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        [selectionBackground, divider].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; $0.wantsLayer = true; addSubview($0) }
        [selectionBar, iconView, symbol, column, shortcut, chevron].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        selectionBar.wantsLayer = true

        iconView.imageScaling = .scaleProportionallyUpOrDown
        shortcut.alignment = .right
        // The hint is fixed-size chrome: the label column truncates around it.
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcut.setContentHuggingPriority(.required, for: .horizontal)
        detail.lineBreakMode = .byTruncatingTail
        label.lineBreakMode = .byTruncatingTail

        column.orientation = .vertical
        column.alignment = .leading
        column.distribution = .fill
        column.setViews([label, detail], in: .top)
        column.setHuggingPriority(.defaultHigh, for: .vertical)
        // Long labels truncate inside the column instead of pushing the chevron out.
        [label, detail].forEach {
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        selectionTop = selectionBackground.topAnchor.constraint(equalTo: topAnchor)
        selectionLeading = selectionBackground.leadingAnchor.constraint(equalTo: leadingAnchor)
        selectionTrailing = selectionBackground.trailingAnchor.constraint(equalTo: trailingAnchor)
        dividerHeight = divider.heightAnchor.constraint(equalToConstant: 1)
        dividerTop = divider.topAnchor.constraint(equalTo: topAnchor)
        columnTrailing = column.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor)
        // Hung off the chevron rather than the row edge, so a hint sits the same
        // distance from the edge whether or not its row draws a chevron — the
        // chevron keeps its width when hidden.
        shortcutTrailing = shortcut.trailingAnchor.constraint(equalTo: chevron.leadingAnchor)
        barWidth = selectionBar.widthAnchor.constraint(equalToConstant: 0)
        barLeading = selectionBar.leadingAnchor.constraint(equalTo: selectionBackground.leadingAnchor)
        iconLeading = iconView.leadingAnchor.constraint(equalTo: selectionBackground.leadingAnchor)
        iconWidth = iconView.widthAnchor.constraint(equalToConstant: 24)
        iconHeight = iconView.heightAnchor.constraint(equalToConstant: 24)
        symbolLeading = symbol.leadingAnchor.constraint(equalTo: selectionBackground.leadingAnchor)
        symbolWidth = symbol.widthAnchor.constraint(equalToConstant: 18)
        symbolHeight = symbol.heightAnchor.constraint(equalToConstant: 18)
        columnLeading = column.leadingAnchor.constraint(equalTo: leadingAnchor)
        chevronTrailing = chevron.trailingAnchor.constraint(equalTo: selectionBackground.trailingAnchor)
        chevronWidth = chevron.widthAnchor.constraint(equalToConstant: 9)

        NSLayoutConstraint.activate([
            selectionTop, selectionLeading, selectionTrailing,
            selectionBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor), divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            dividerTop, dividerHeight,
            barWidth, barLeading,
            selectionBar.centerYAnchor.constraint(equalTo: selectionBackground.centerYAnchor),
            selectionBar.heightAnchor.constraint(equalTo: selectionBackground.heightAnchor, multiplier: 0.55),
            iconLeading, iconWidth, iconHeight, iconView.centerYAnchor.constraint(equalTo: selectionBackground.centerYAnchor),
            symbolLeading, symbolWidth, symbolHeight, symbol.centerYAnchor.constraint(equalTo: selectionBackground.centerYAnchor),
            columnLeading, column.centerYAnchor.constraint(equalTo: selectionBackground.centerYAnchor), columnTrailing,
            shortcutTrailing, shortcut.centerYAnchor.constraint(equalTo: selectionBackground.centerYAnchor),
            chevronTrailing, chevronWidth, chevron.centerYAnchor.constraint(equalTo: selectionBackground.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: DisplayRow, theme: Theme, showDetail: Bool, showDivider: Bool, shortcut hint: String) {
        self.theme = theme

        let dividerStrip = showDivider ? theme.space(theme.dividerHeight) : 0
        selectionTop.constant = dividerStrip
        dividerTop.constant = (dividerStrip / 2).rounded()
        dividerHeight.constant = showDivider ? 1 : 0
        divider.isHidden = !showDivider
        divider.layer?.backgroundColor = theme.dividerColor.cgColor

        let inset = theme.space(theme.selectionInset)
        selectionLeading.constant = inset
        selectionTrailing.constant = -inset

        let gutter = theme.space(theme.rowPaddingX)
        let slot = theme.space(theme.iconSlot)
        barWidth.constant = theme.space(theme.selectionBar)
        barLeading.constant = 0
        columnLeading.constant = inset + theme.labelInset
        chevronTrailing.constant = -gutter
        chevronWidth.constant = theme.captionSize
        columnTrailing.constant = -theme.space(theme.iconGap)

        iconView.image = item.image
        iconView.isHidden = item.image == nil
        iconWidth.constant = theme.iconSize + theme.space(6)
        iconHeight.constant = theme.iconSize + theme.space(6)
        iconLeading.constant = gutter + (slot - iconWidth.constant) / 2

        symbol.image = item.image == nil && !item.symbol.isEmpty ? NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) : nil
        symbol.isHidden = symbol.image == nil
        symbolWidth.constant = theme.iconSize
        symbolHeight.constant = theme.iconSize
        symbolLeading.constant = gutter + (slot - theme.iconSize) / 2

        label.stringValue = item.label
        label.font = theme.font(size: theme.bodySize, weight: theme.labelWeight)
        detail.stringValue = item.detail
        detail.font = theme.font(size: theme.smallSize, weight: theme.detailWeight)
        detail.isHidden = !showDetail
        column.spacing = theme.space(theme.labelGap)

        // Empty and hidden, the label measures zero wide, which puts the column's
        // trailing limit back exactly where the chevron alone used to put it.
        shortcut.stringValue = hint
        shortcut.isHidden = hint.isEmpty
        shortcut.font = theme.font(size: theme.captionSize, weight: .semibold)
        shortcutTrailing.constant = hint.isEmpty ? 0 : -theme.space(theme.iconGap)

        selectionBackground.layer?.cornerRadius = theme.rowRadius
        selectionBackground.layer?.cornerCurve = .continuous
        selectionBar.layer?.cornerRadius = min(theme.rowRadius, barWidth.constant / 2)
        chevron.isHidden = item.kind != .menu
        layer?.cornerRadius = theme.rowRadius
        layer?.cornerCurve = .continuous
    }

    /// Omarchy's selection: a low-alpha fill plus accent-tinted text, rather than an
    /// inverted accent slab.
    func setSelected(_ selected: Bool, theme: Theme) {
        selectionBackground.layer?.backgroundColor = selected ? theme.selectionFill.cgColor : NSColor.clear.cgColor
        selectionBar.layer?.backgroundColor = selected ? theme.selectionText.cgColor : NSColor.clear.cgColor
        label.textColor = selected ? theme.selectionText : theme.fg
        detail.textColor = selected ? theme.selectionText.withAlphaComponent(theme.detailAlpha) : theme.detailColor
        symbol.contentTintColor = selected ? theme.selectionText : theme.fg
        shortcut.textColor = selected ? theme.selectionText : theme.chevronColor
        chevron.contentTintColor = selected ? theme.selectionText : theme.chevronColor
    }
}
