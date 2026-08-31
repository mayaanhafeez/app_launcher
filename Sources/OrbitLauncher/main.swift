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
    }

    private func wireUI() {
        runtime.onSettings = { [weak self] settings in
            guard let self else { return }
            panel.vimEnabled = settings.vimMode
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

    private func startIPC() {
        let container = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.orbit.launcher/Data/tmp")
        let server = IPCServer(socketURL: container.appendingPathComponent("orbit.sock"))
        server.handler = { [weak self] request in self?.handle(request) ?? IPCResponse(ok: false, message: "Host unavailable") }
        do { try server.start(); ipc = server } catch { panel.showNotice(error.localizedDescription) }
    }

    private func handle(_ request: IPCRequest) -> IPCResponse {
        switch request.command {
        case "ping": return IPCResponse(ok: true, message: "ok")
        case "toggle": toggle(route: request.argument ?? "root"); return IPCResponse(ok: true, message: "ok")
        case "show": show(route: request.argument ?? "root"); return IPCResponse(ok: true, message: "ok")
        case "hide": panel.hide(); return IPCResponse(ok: true, message: "ok")
        case "reload": reloadAll(); return IPCResponse(ok: true, message: "ok")
        case "theme": return IPCResponse(ok: true, message: themeRuntime.paletteName.isEmpty ? "(no palette)" : themeRuntime.paletteName)
        case "invoke": return menu.invoke(id: request.argument ?? "") ? IPCResponse(ok: true, message: "ok") : IPCResponse(ok: false, message: "unknown node")
        default: return IPCResponse(ok: false, message: "unknown command")
        }
    }

    private func toggle(route: String) { panel.window?.isVisible == true ? panel.hide() : show(route: route) }
    private func show(route: String) { menu.open(route: route); panel.show(route: route) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
