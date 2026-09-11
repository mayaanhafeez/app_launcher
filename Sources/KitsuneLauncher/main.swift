import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/kitsune")
    private let appIndex = AppIndex()
    private let runtime = LuaRuntime()
    private let themeRuntime = ThemeRuntime()
    private let usage = UsageStore(url: UsageStore.defaultURL)
    private let clipboard = ClipboardHistory(url: ClipboardHistory.defaultURL)
    private lazy var menu = MenuController(appIndex: appIndex, runtime: runtime, usage: usage, clipboard: clipboard)
    private let panel = PanelController()
    private var hotKey: GlobalHotKey?
    private var watcher: ConfigWatcher?
    private var themePointerWatcher: ConfigWatcher?
    private var ipc: IPCServer?
    private var menuBar: MenuBarItem?
    /// The last value acted on, so an unrelated config save doesn't undo a toggle
    /// made from the menu bar. A real change in `config.lua` still wins.
    private var appliedLoginItem: Bool?
    /// Whether the menu bar item has already been switched off once, so the notice
    /// explaining what that costs is raised on the transition and not on every save.
    private var appliedMenuBarEnabled: Bool?
    /// The error from the last config load, held until a load succeeds. A save that
    /// breaks `config.lua` normally happens with the panel closed, so a five-second
    /// toast is shown to nobody and the launcher looks like it ignored the edit.
    private var configError: String?
    /// The same thing, framed for reading: paths relative to the config directory, the
    /// named source lines quoted, and — for a parse error — the warning that Lua names
    /// the line where it gave up rather than the line to fix.
    private var configReport: [ConfigError] = []
    /// `kitsunectl reload` answers with the outcome of the load *it* asked for. The
    /// load is asynchronous, so the reply waits here for the next outcome.
    private var pendingReloads: [(String?) -> Void] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        wireUI()
        // Before `reloadAll`: the menu bar spec arrives with the first settings
        // publish, and there would be nothing to apply it to otherwise.
        startMenuBar()
        reloadAll()
        appIndex.start()
        let hotKey = GlobalHotKey()
        hotKey.action = { [weak self] target in self?.trigger(target) }
        hotKey.register([HotKeySpec()])
        self.hotKey = hotKey
        startWatcher()
        startIPC()
    }

    private func wireUI() {
        runtime.onSettings = { [weak self] settings in
            guard let self else { return }
            panel.vimEnabled = settings.vimMode
            // Both halves of `show_search_only`: the controller withholds root's rows,
            // the panel collapses the card around the empty list that produces.
            panel.showSearchOnly = settings.showSearchOnly
            menu.showSearchOnly = settings.showSearchOnly
            menu.backRow = settings.back
            menu.search = settings.search
            menu.files = settings.files
            menu.providerLimits = settings.providers
            menu.commands.spec = settings.commands
            usage.spec = settings.ranking
            panel.shortcuts = settings.shortcuts
            appIndex.apply(scan: settings.apps)
            menuBar?.apply(settings.menuBar)
            if appliedMenuBarEnabled != settings.menuBar.enabled {
                appliedMenuBarEnabled = settings.menuBar.enabled
                if !settings.menuBar.enabled { warnAboutHiddenMenuBar() }
            }
            menu.clipboardSpec = settings.clipboard
            watcher?.setDebounce(settings.watchDebounce)
            themePointerWatcher?.setDebounce(settings.watchDebounce)
            if appliedLoginItem != settings.loginItem {
                appliedLoginItem = settings.loginItem
                setLoginItem(settings.loginItem)
            }
            // Only the chords that failed are named — the rest are bound, and saying
            // otherwise would send the user hunting through a config that is fine.
            if let rejected = hotKey?.register(settings.hotKeys), !rejected.isEmpty {
                panel.showNotice("Hotkey unavailable: " + rejected.map(\.chord).joined(separator: ", "))
            }
        }
        runtime.onLoadOutcome = { [weak self] error in self?.noteConfigOutcome(error) }
        menu.onRows = { [weak panel] title, rows in panel?.update(title: title, rows: rows) }
        menu.onQuery = { [weak panel] query in panel?.setQuery(query) }
        menu.onNotice = { [weak panel] message in panel?.showNotice(message) }
        menu.onDismiss = { [weak self] in self?.dismiss() }
        panel.onQuery = { [weak menu] query in menu?.update(query: query) }
        panel.onActivate = { [weak menu] row in menu?.activate(row) }
        panel.onBack = { [weak menu] in menu?.back() ?? false }
        panel.onRowActions = { [weak menu] row in menu?.showActions(for: row) }
        panel.onDismiss = { [weak self] in self?.dismiss() }
    }

    private func reloadAll() {
        runtime.load(file: configDirectory.appendingPathComponent("config.lua"))
        reloadTheme()
    }

    /// The one place the config error state changes: a failure is held and shown in
    /// the menu bar until a load succeeds, and every waiting `reload` reply is
    /// answered with what this load actually did.
    private func noteConfigOutcome(_ error: String?) {
        configError = error
        configReport = error.map { ConfigErrorFormatter.describeAll($0, directory: configDirectory) } ?? []
        menuBar?.apply(error: error)
        // Printed where the user actually goes, not only behind a menu item: the banner
        // stays up for as long as the problem does, so opening the launcher at all is
        // enough to find out that a save did not take.
        panel.persistentNotice = ConfigErrorFormatter.banner(for: configReport)
        pendingReloads.forEach { $0(error) }
        pendingReloads.removeAll()
    }

    /// Full text, in a modal alert: the message is a Lua traceback and a status-item
    /// tooltip cannot hold one. An accessory app has to activate to be seen.
    ///
    /// The title does not claim the config failed to load: a plugin caught by the
    /// config's own `pcall` is reported here too, and in that case the rest of the menu
    /// loaded fine.
    private func showLastError() {
        guard !configReport.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Kitsune found a problem in your config"
        alert.informativeText = configReport.map(\.full).joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            // The framed text, not the raw one: it is what the alert showed, and it is
            // what a bug report wants — the message plus the lines it named.
            NSPasteboard.general.setString(configReport.map(\.full).joined(separator: "\n\n"), forType: .string)
        }
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
        let theme = themeRuntime.load(file: configDirectory.appendingPathComponent("theme.lua"))
        panel.apply(theme: theme)
        // Icons are flattened at scan time, so the index needs the size the panel is
        // about to draw them at; `apply` no-ops unless it actually changed.
        appIndex.apply(iconPoints: theme.iconSlot)
    }

    private func reloadChangedFiles() {
        runtime.load(file: configDirectory.appendingPathComponent("config.lua"))
        reloadTheme()
    }

    private func startMenuBar() {
        let menuBar = MenuBarItem()
        menuBar.onOpenConfig = { [weak self] in self?.openConfigDirectory() }
        menuBar.onReload = { [weak self] in self?.reloadAll() }
        menuBar.onShowLastError = { [weak self] in self?.showLastError() }
        menuBar.onToggleLoginItem = { [weak self] in
            guard let self else { return }
            let enabled = !LoginItem.isEnabled
            appliedLoginItem = enabled
            setLoginItem(enabled)
        }
        self.menuBar = menuBar
    }

    /// Raised the first time the status item is switched off, and never again. The
    /// panel's own notice is no use here: it auto-hides after five seconds and the
    /// panel is shut when a config save lands, so nobody would ever see it. An
    /// accessory app has to activate before a modal alert is visible.
    private static let menuBarNoticeKey = "kitsune.menuBarNoticeShown"

    private func warnAboutHiddenMenuBar() {
        guard !UserDefaults.standard.bool(forKey: Self.menuBarNoticeKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.menuBarNoticeKey)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Kitsune's menu bar item is now hidden"
        alert.informativeText = """
        Kitsune keeps running in the background, but it has no Dock icon and no menu bar \
        item, so the only ways left to reload or quit it are `kitsunectl reload`, \
        `kitsunectl hide` and killing the process.

        Set `menu_bar = { enabled = true }` in config.lua to bring it back.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            // Registering can succeed and still leave the item switched off until the
            // user approves it, which looks like a silent failure otherwise.
            if enabled, LoginItem.requiresApproval {
                panel.showNotice("Approve Kitsune in System Settings › General › Login Items")
            }
        } catch {
            panel.showNotice("Login item failed: \(error.localizedDescription)")
        }
    }

    /// A fresh install has no `~/.config/kitsune` until the templates are copied, and
    /// opening a path that isn't there does nothing at all, so create it first.
    private func openConfigDirectory() {
        dismiss()
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(configDirectory)
    }

    private func startIPC() {
        // Derived from the running bundle rather than hardcoded, so `Kitsune (Dev)`
        // (`com.kitsune.launcher.dev`) binds its own socket in its own container and
        // the two builds can be resident side by side without one shadowing the
        // other's. The literal is only the fallback for a bare `swift build` binary,
        // which has no Info.plist to carry an identifier.
        let identifier = Bundle.main.bundleIdentifier ?? "com.kitsune.launcher"
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(identifier)/Data/tmp")
        let server = IPCServer(socketURL: container.appendingPathComponent("kitsune.sock"))
        server.handler = { [weak self] request, reply in
            guard let self else { return reply(IPCResponse(ok: false, message: "Host unavailable")) }
            handle(request, reply)
        }
        do { try server.start(); ipc = server } catch { panel.showNotice(error.localizedDescription) }
    }

    /// The verb table itself lives in `IPCCommands`, which needs no NSApplication;
    /// this only binds each effect to the delegate's objects.
    private func handle(_ request: IPCRequest, _ reply: @escaping (IPCResponse) -> Void) {
        IPCCommands(
            toggle: { [weak self] route in self?.toggle(route: route) },
            show: { [weak self] route in self?.show(route: route) },
            hide: { [weak self] in self?.dismiss() },
            reload: { [weak self] answer in
                guard let self else { return answer("Host unavailable") }
                pendingReloads.append(answer)
                reloadAll()
            },
            paletteName: { [weak self] in self?.themeRuntime.paletteName ?? "" },
            version: { Self.bundleVersion },
            invoke: { [weak self] id in self?.menu.invoke(id: id) ?? false },
            list: { [weak self] route, query in self?.menu.rows(route: route, query: query) }
        ).handle(request, completion: reply)
    }

    /// `CFBundleShortVersionString (CFBundleVersion)`, or a plain marker when running
    /// the bare `swift build` binary, which has no Info.plist at all.
    private static var bundleVersion: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "unbundled" }
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    /// What a chord does. `invoke` never shows the panel, which is the point of it —
    /// so a failure has to be logged as well as noticed, or it is silent.
    private func trigger(_ target: HotKeyTarget) {
        switch target {
        case .toggle(let route): toggle(route: route)
        case .invoke(let id):
            guard !menu.invoke(id: id) else { return }
            NSLog("kitsune: hotkey could not invoke unknown or non-actionable node \(id)")
            panel.showNotice("Hotkey target not found: \(id)")
        }
    }

    private func toggle(route: String) { panel.window?.isVisible == true ? dismiss() : show(route: route) }
    private func show(route: String) { menu.open(route: route); panel.show(route: route) }
    private func dismiss() {
        panel.hide()
        menu.open()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
