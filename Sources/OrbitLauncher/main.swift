import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/orbit")
    private let appIndex = AppIndex()
    private let runtime = LuaRuntime()
    private let themeRuntime = ThemeRuntime()
    private lazy var menu = MenuController(appIndex: appIndex, runtime: runtime)
    private let panel = PanelController()
    private var hotKey: GlobalHotKey?
    private var watcher: ConfigWatcher?
    private var themePointerWatcher: ConfigWatcher?
    private var ipc: IPCServer?
    private var menuBar: MenuBarItem?
    /// The last value acted on, so an unrelated config save doesn't undo a toggle
    /// made from the menu bar. A real change in `config.lua` still wins.
    private var appliedLoginItem: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        wireUI()
        reloadAll()
        appIndex.start()
        let hotKey = GlobalHotKey()
        hotKey.action = { [weak self] in self?.toggle(route: "root") }
        hotKey.register(HotKeySpec())
        self.hotKey = hotKey
        startWatcher()
        startIPC()
        startMenuBar()
    }

    private func wireUI() {
        runtime.onSettings = { [weak self] settings in
            guard let self else { return }
            panel.vimEnabled = settings.vimMode
            menu.backRow = settings.back
            panel.shortcuts = settings.shortcuts
            appIndex.apply(scan: settings.apps)
            if appliedLoginItem != settings.loginItem {
                appliedLoginItem = settings.loginItem
                setLoginItem(settings.loginItem)
            }
            if hotKey?.register(settings.hotKey) == false {
                panel.showNotice("Unknown hotkey: \(settings.hotKey.key)")
            }
        }
        menu.onRows = { [weak panel] title, rows in panel?.update(title: title, rows: rows) }
        menu.onNotice = { [weak panel] message in panel?.showNotice(message) }
        menu.onDismiss = { [weak panel] in panel?.hide() }
        panel.onQuery = { [weak menu] query in menu?.update(query: query) }
        panel.onActivate = { [weak menu] row in menu?.activate(row) }
        panel.onBack = { [weak menu] in menu?.back() ?? false }
    }

    private func reloadAll() {
        runtime.load(file: configDirectory.appendingPathComponent("config.lua"))
        panel.apply(theme: themeRuntime.load(file: configDirectory.appendingPathComponent("theme.lua")))
    }

    private func startWatcher() {
        let watcher = ConfigWatcher(directory: configDirectory)
        watcher.onChange = { [weak self] in Task { @MainActor in self?.reloadChangedFiles() } }
        do { try watcher.start(); self.watcher = watcher } catch { panel.showNotice(error.localizedDescription) }

        // `palette = "auto"` follows ~/.config/theme, so a `set-theme` switch has to
        // retint the panel the same way editing theme.lua does.
        let pointer = ConfigWatcher(
            directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config"),
            filenames: ["theme"],
            watchesDirectory: false
        )
        pointer.onChange = { [weak self] in Task { @MainActor in self?.reloadTheme() } }
        do { try pointer.start(); themePointerWatcher = pointer } catch { /* no pointer file: palette stays as written */ }
    }

    private func reloadTheme() {
        panel.apply(theme: themeRuntime.load(file: configDirectory.appendingPathComponent("theme.lua")))
    }

    private func reloadChangedFiles() {
        runtime.load(file: configDirectory.appendingPathComponent("config.lua"))
        reloadTheme()
    }

    private func startMenuBar() {
        let menuBar = MenuBarItem()
        menuBar.onOpenConfig = { [weak self] in self?.openConfigDirectory() }
        menuBar.onReload = { [weak self] in self?.reloadAll() }
        menuBar.onToggleLoginItem = { [weak self] in
            guard let self else { return }
            let enabled = !LoginItem.isEnabled
            appliedLoginItem = enabled
            setLoginItem(enabled)
        }
        self.menuBar = menuBar
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            // Registering can succeed and still leave the item switched off until the
            // user approves it, which looks like a silent failure otherwise.
            if enabled, LoginItem.requiresApproval {
                panel.showNotice("Approve Orbit in System Settings › General › Login Items")
            }
        } catch {
            panel.showNotice("Login item failed: \(error.localizedDescription)")
        }
    }

    /// A fresh install has no `~/.config/orbit` until the templates are copied, and
    /// opening a path that isn't there does nothing at all, so create it first.
    private func openConfigDirectory() {
        panel.hide()
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(configDirectory)
    }

    private func startIPC() {
        let container = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.orbit.launcher/Data/tmp")
        let server = IPCServer(socketURL: container.appendingPathComponent("orbit.sock"))
        server.handler = { [weak self] request in self?.handle(request) ?? IPCResponse(ok: false, message: "Host unavailable") }
        do { try server.start(); ipc = server } catch { panel.showNotice(error.localizedDescription) }
    }

    /// The verb table itself lives in `IPCCommands`, which needs no NSApplication;
    /// this only binds each effect to the delegate's objects.
    private func handle(_ request: IPCRequest) -> IPCResponse {
        IPCCommands(
            toggle: { [weak self] route in self?.toggle(route: route) },
            show: { [weak self] route in self?.show(route: route) },
            hide: { [weak self] in self?.panel.hide() },
            reload: { [weak self] in self?.reloadAll() },
            paletteName: { [weak self] in self?.themeRuntime.paletteName ?? "" },
            version: { Self.bundleVersion },
            invoke: { [weak self] id in self?.menu.invoke(id: id) ?? false }
        ).handle(request)
    }

    /// `CFBundleShortVersionString (CFBundleVersion)`, or a plain marker when running
    /// the bare `swift build` binary, which has no Info.plist at all.
    private static var bundleVersion: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "unbundled" }
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    private func toggle(route: String) { panel.window?.isVisible == true ? panel.hide() : show(route: route) }
    private func show(route: String) { menu.open(route: route); panel.show(route: route) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
