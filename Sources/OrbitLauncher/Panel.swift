import AppKit

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let blur = NSVisualEffectView()
    private let search = NSSearchField()
    private let titleLabel = NSTextField(labelWithString: "Go")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let notice = NSTextField(labelWithString: "")
    private var rows: [DisplayRow] = []
    private var theme = Theme()
    var onQuery: ((String) -> Void)?
    var onActivate: ((DisplayRow) -> Void)?
    var onBack: (() -> Bool)?

    init() {
        let panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 570), styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        super.init(window: panel)
        buildUI(panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(route: String = "root") {
        guard let panel = window else { return }
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - panel.frame.width / 2
            let y = screen.visibleFrame.midY - panel.frame.height / 2 + 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        search.stringValue = ""
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(search)
    }

    func hide() { window?.orderOut(nil) }
    func toggle() { window?.isVisible == true ? hide() : show() }

    func update(title: String, rows: [DisplayRow]) {
        titleLabel.stringValue = title
        self.rows = rows
        table.reloadData()
        if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); table.scrollRowToVisible(0) }
    }

    func showNotice(_ message: String) {
        notice.stringValue = message
        notice.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.notice.isHidden = true }
    }

    func apply(theme: Theme) {
        self.theme = theme
        blur.material = theme.blur > 0.5 ? .hudWindow : .menu
        blur.layer?.backgroundColor = theme.bg.withAlphaComponent(0.82).cgColor
        blur.layer?.cornerRadius = theme.radius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = theme.border.cgColor
        titleLabel.textColor = theme.fgMuted
        titleLabel.font = NSFont(name: theme.font, size: theme.fontSize - 2) ?? .systemFont(ofSize: theme.fontSize - 2, weight: .medium)
        search.font = NSFont(name: theme.font, size: theme.fontSize + 5) ?? .systemFont(ofSize: theme.fontSize + 5, weight: .medium)
        notice.textColor = theme.fg
        table.rowHeight = theme.rowHeight
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let cell = RowView()
        cell.configure(item: item, theme: theme)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {}

    func controlTextDidChange(_ obj: Notification) { onQuery?(search.stringValue) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            if !search.stringValue.isEmpty { search.stringValue = ""; onQuery?("") }
            else { hide() }
        case 125: moveSelection(1)
        case 126: moveSelection(-1)
        case 36, 76:
            let index = max(0, table.selectedRow)
            if rows.indices.contains(index) { onActivate?(rows[index]) }
        case 123 where search.stringValue.isEmpty:
            if onBack?() != true { hide() }
        default: super.keyDown(with: event)
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let next = (max(0, table.selectedRow) + delta + rows.count) % rows.count
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func buildUI(_ panel: NSPanel) {
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        panel.contentView = blur
        [search, titleLabel, scroll, notice].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; blur.addSubview($0) }
        titleLabel.stringValue = "Go"
        search.placeholderString = "Search apps and commands"
        search.focusRingType = .none
        search.delegate = self
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 5)
        table.delegate = self
        table.dataSource = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        table.target = self
        table.doubleAction = #selector(doubleClick)
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        notice.wantsLayer = true
        notice.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.92).cgColor
        notice.layer?.cornerRadius = 8
        notice.alignment = .center
        notice.isHidden = true
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: blur.topAnchor, constant: 22), titleLabel.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 24),
            search.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8), search.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 20), search.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -20), search.heightAnchor.constraint(equalToConstant: 44),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 14), scroll.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 16), scroll.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -16), scroll.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -16),
            notice.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 20), notice.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -20), notice.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -20), notice.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
    }

    @objc private func doubleClick() { if rows.indices.contains(table.clickedRow) { onActivate?(rows[table.clickedRow]) } }
}

final class RowView: NSTableCellView {
    private let iconView = NSImageView()
    private let symbol = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        [iconView, symbol, label, detail, chevron].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        symbol.contentTintColor = .labelColor
        detail.lineBreakMode = .byTruncatingTail
        chevron.contentTintColor = .tertiaryLabelColor
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), iconView.centerYAnchor.constraint(equalTo: centerYAnchor), iconView.widthAnchor.constraint(equalToConstant: 32), iconView.heightAnchor.constraint(equalToConstant: 32),
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), symbol.centerYAnchor.constraint(equalTo: centerYAnchor), symbol.widthAnchor.constraint(equalToConstant: 23), symbol.heightAnchor.constraint(equalToConstant: 23),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 58), label.topAnchor.constraint(equalTo: topAnchor, constant: 8), label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -10),
            detail.leadingAnchor.constraint(equalTo: label.leadingAnchor), detail.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1), detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -35),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), chevron.centerYAnchor.constraint(equalTo: centerYAnchor), chevron.widthAnchor.constraint(equalToConstant: 11),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: DisplayRow, theme: Theme) {
        iconView.image = item.image
        iconView.isHidden = item.image == nil
        symbol.image = item.image == nil && !item.symbol.isEmpty ? NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) : nil
        symbol.isHidden = symbol.image == nil
        label.stringValue = item.label
        label.textColor = theme.fg
        label.font = NSFont(name: theme.font, size: theme.fontSize) ?? .systemFont(ofSize: theme.fontSize, weight: .medium)
        detail.stringValue = item.detail
        detail.textColor = theme.fgMuted
        detail.font = NSFont(name: theme.font, size: theme.fontSize - 2) ?? .systemFont(ofSize: theme.fontSize - 2)
        chevron.isHidden = item.kind != .menu
        layer?.cornerRadius = max(8, theme.radius - 6)
        layer?.cornerCurve = .continuous
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { layer?.backgroundColor = backgroundStyle == .emphasized ? NSColor.controlAccentColor.withAlphaComponent(0.32).cgColor : NSColor.clear.cgColor }
    }
}
