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

@MainActor
final class PanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let blur = NSVisualEffectView()
    private let card = NSView()
    private let prompt = NSTextField(labelWithString: "Go...")
    private let input = LauncherField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No matches")
    private var rows: [DisplayRow] = []
    private var theme = Theme()
    private var title = "Go"
    var onQuery: ((String) -> Void)?
    var onActivate: ((DisplayRow) -> Void)?
    var onBack: (() -> Bool)?

    init() {
        let panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 548), styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        super.init(window: panel)
        buildUI(panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(route: String = "root") {
        guard let panel = window else { return }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2, y: screen.visibleFrame.midY - panel.frame.height / 2 + 28))
        }
        input.stringValue = ""
        updatePrompt()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(input)
    }

    func hide() { window?.orderOut(nil) }

    func update(title: String, rows: [DisplayRow]) {
        self.title = title
        self.rows = rows
        updatePrompt()
        table.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
        if rows.isEmpty { table.deselectAll(nil) }
        else { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); table.scrollRowToVisible(0) }
    }

    func showNotice(_ message: String) {
        notice.stringValue = message
        notice.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.notice.isHidden = true }
    }

    func apply(theme: Theme) {
        self.theme = theme
        blur.material = theme.blur > 0.5 ? .hudWindow : .menu
        card.layer?.backgroundColor = theme.bg.withAlphaComponent(0.88).cgColor
        card.layer?.cornerRadius = theme.radius
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = theme.border.cgColor
        prompt.textColor = theme.fgMuted
        prompt.font = font(size: theme.fontSize + 3, weight: .medium)
        input.textColor = theme.fg
        input.font = font(size: theme.fontSize + 3, weight: .medium)
        notice.textColor = theme.fg
        table.rowHeight = 48
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = RowView()
        cell.configure(item: rows[row], theme: theme)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row].detail.isEmpty || input.stringValue.isEmpty ? 48 : 58
    }

    func controlTextDidChange(_ obj: Notification) {
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
        switch event.keyCode {
        case 53: escape(); return true
        case 125: moveSelection(1); return true
        case 126: moveSelection(-1); return true
        case 36, 76: activateSelection(); return true
        case 123 where input.stringValue.isEmpty: return goBack()
        default: return false
        }
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

    private func activateSelection() {
        let index = table.selectedRow < 0 ? 0 : table.selectedRow
        if rows.indices.contains(index) { onActivate?(rows[index]) }
    }

    private func updatePrompt() {
        prompt.stringValue = input.stringValue.isEmpty ? "\(title)..." : ""
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }

    private func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont(name: theme.font, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    private func buildUI(_ panel: NSPanel) {
        blur.state = .active
        blur.blendingMode = .behindWindow
        panel.contentView = blur
        blur.wantsLayer = true
        card.wantsLayer = true
        [card].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; blur.addSubview($0) }
        [prompt, input, scroll, emptyLabel, notice].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; card.addSubview($0) }

        input.isBordered = false
        input.isBezeled = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.delegate = self
        input.cell?.isScrollable = true
        input.routeKey = { [weak self] event in self?.routeKey(event) ?? false }
        prompt.lineBreakMode = .byTruncatingTail

        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.delegate = self
        table.dataSource = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.target = self
        table.doubleAction = #selector(doubleClick)
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        emptyLabel.textColor = theme.fgMuted
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        notice.wantsLayer = true
        notice.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.92).cgColor
        notice.layer?.cornerRadius = 8
        notice.alignment = .center
        notice.isHidden = true

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: blur.leadingAnchor), card.trailingAnchor.constraint(equalTo: blur.trailingAnchor), card.topAnchor.constraint(equalTo: blur.topAnchor), card.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            input.topAnchor.constraint(equalTo: card.topAnchor, constant: 18), input.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22), input.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22), input.heightAnchor.constraint(equalToConstant: 34),
            prompt.leadingAnchor.constraint(equalTo: input.leadingAnchor), prompt.trailingAnchor.constraint(equalTo: input.trailingAnchor), prompt.centerYAnchor.constraint(equalTo: input.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 13), scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12), scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12), scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            emptyLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            notice.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14), notice.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14), notice.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14), notice.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
        ])
    }

    @objc private func doubleClick() { if rows.indices.contains(table.clickedRow) { onActivate?(rows[table.clickedRow]) } }
}

final class RowView: NSTableCellView {
    private let divider = NSBox()
    private let iconView = NSImageView()
    private let symbol = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        [divider, iconView, symbol, label, detail, chevron].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        divider.boxType = .separator
        iconView.imageScaling = .scaleProportionallyUpOrDown
        detail.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), divider.topAnchor.constraint(equalTo: topAnchor),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), iconView.centerYAnchor.constraint(equalTo: centerYAnchor), iconView.widthAnchor.constraint(equalToConstant: 28), iconView.heightAnchor.constraint(equalToConstant: 28),
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15), symbol.centerYAnchor.constraint(equalTo: centerYAnchor), symbol.widthAnchor.constraint(equalToConstant: 21), symbol.heightAnchor.constraint(equalToConstant: 21),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 51), label.topAnchor.constraint(equalTo: topAnchor, constant: 7), label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: label.leadingAnchor), detail.topAnchor.constraint(equalTo: label.bottomAnchor), detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), chevron.centerYAnchor.constraint(equalTo: centerYAnchor), chevron.widthAnchor.constraint(equalToConstant: 9),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: DisplayRow, theme: Theme) {
        iconView.image = item.image
        iconView.isHidden = item.image == nil
        symbol.image = item.image == nil && !item.symbol.isEmpty ? NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) : nil
        symbol.contentTintColor = theme.fg
        symbol.isHidden = symbol.image == nil
        label.stringValue = item.label
        label.textColor = theme.fg
        label.font = NSFont(name: theme.font, size: theme.fontSize) ?? .systemFont(ofSize: theme.fontSize, weight: .medium)
        detail.stringValue = item.detail
        detail.textColor = theme.fgMuted
        detail.font = NSFont(name: theme.font, size: theme.fontSize - 3) ?? .systemFont(ofSize: theme.fontSize - 3)
        detail.isHidden = item.detail.isEmpty
        chevron.contentTintColor = theme.fgMuted
        chevron.isHidden = item.kind != .menu
        divider.isHidden = item.section != "drilldown-start"
        layer?.cornerRadius = max(8, theme.radius - 7)
        layer?.cornerCurve = .continuous
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { layer?.backgroundColor = backgroundStyle == .emphasized ? NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor : NSColor.clear.cgColor }
    }
}
