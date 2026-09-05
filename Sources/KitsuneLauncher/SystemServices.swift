import AppKit
import Carbon
import Darwin
import ServiceManagement

/// Launch at login, via the bundle's own `SMAppService`. There is no helper target
/// and no legacy `SMLoginItemSetEnabled`: `mainApp` registers the app itself.
///
/// This only works from a real bundle — the bare `swift build` binary has no
/// Info.plist for launchd to register, so registration there throws rather than
/// silently doing nothing. Registration is also tied to the bundle's signature and
/// location, so re-signing or moving the app can orphan the login item.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// macOS can park a registration in "requires approval": the app is registered
    /// but stays off until the user enables it in System Settings.
    static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled else { return }
            try service.unregister()
        }
    }
}

/// The only persistent UI outside the panel. The app is an accessory (`LSUIElement`),
/// so without this there is no way to reach the config, force a reload, or quit
/// except `kitsunectl` and `kill`.
///
/// The status item is created on demand rather than at init, because `menu_bar =
/// { enabled = false }` has to be able to remove it outright: an `NSStatusItem` held
/// in a stored property exists from the moment the object does.
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let loginToggle = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
    /// Built once and reattached to each status item, so re-enabling the menu bar
    /// does not rebuild the entries or lose their targets.
    private let menu = NSMenu()
    private var applied: MenuBarSpec?
    var onOpenConfig: (() -> Void)?
    var onReload: (() -> Void)?
    var onToggleLoginItem: (() -> Void)?

    override init() {
        super.init()
        menu.addItem(withTitle: "Open Config Folder", action: #selector(openConfig), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Reload Config", action: #selector(reload), keyEquivalent: "r").target = self
        loginToggle.target = self
        menu.addItem(loginToggle)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kitsune", action: #selector(quit), keyEquivalent: "q").target = self
        menu.delegate = self
    }

    /// Republished on every config reload. Unchanged specs are ignored so a save that
    /// touches something else never tears the status item down and puts it back.
    func apply(_ spec: MenuBarSpec) {
        guard spec != applied else { return }
        applied = spec
        guard spec.enabled else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let item = self.item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        item.menu = menu
        // An unknown symbol name yields nil, which would blank the button and leave no
        // way to find it. Keep whatever it is drawing, as `GlobalHotKey` keeps its
        // previous binding for an unknown key.
        if let image = NSImage(named: "MenuBarIconTemplate")
            ?? NSImage(systemSymbolName: spec.symbol, accessibilityDescription: "Kitsune") {
            image.isTemplate = true   // so it tracks the menu bar's light/dark appearance
            image.size = NSSize(width: 18, height: 18)
            item.button?.image = image
        }
        item.button?.title = spec.title
        item.button?.toolTip = "Kitsune"
    }

    /// The login item can be switched off in System Settings without telling the app,
    /// so the checkmark is resolved every time the menu opens rather than cached.
    func menuNeedsUpdate(_ menu: NSMenu) {
        loginToggle.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func toggleLoginItem() { onToggleLoginItem?() }
    @objc private func openConfig() { onOpenConfig?() }
    @objc private func reload() { onReload?() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Every global chord the launcher holds, as a set. A slot is a position in the
/// configured list, and registrations are added, replaced and dropped per slot on
/// each reload — an all-or-nothing fallback is too coarse once there is more than
/// one binding to lose.
@MainActor
final class GlobalHotKey {
    private struct Binding {
        let spec: HotKeySpec
        let reference: EventHotKeyRef
    }

    /// Keyed by slot, which is the chord's index in `config.lua`.
    private var bindings: [UInt32: Binding] = [:]
    private var handler: EventHandlerRef?
    /// What is actually registered right now, in slot order. Readable so a test can
    /// assert that a rejected key name leaves the previous binding in place rather
    /// than clearing it.
    private(set) var current: [HotKeySpec] = []
    var action: ((HotKeyTarget) -> Void)?

    /// Key names accepted in `config.lua`. Letters and digits resolve on their own.
    nonisolated private static let namedKeys: [String: Int] = [
        "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab,
        "escape": kVK_Escape, "esc": kVK_Escape, "delete": kVK_Delete, "backspace": kVK_Delete,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "grave": kVK_ANSI_Grave, "backtick": kVK_ANSI_Grave, "period": kVK_ANSI_Period,
        "comma": kVK_ANSI_Comma, "slash": kVK_ANSI_Slash, "semicolon": kVK_ANSI_Semicolon,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]

    nonisolated private static let letterKeys: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8,
        "9": kVK_ANSI_9,
    ]

    nonisolated static func keyCode(for name: String) -> Int? {
        let clean = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let named = namedKeys[clean] { return named }
        guard clean.count == 1, let character = clean.first else { return nil }
        return letterKeys[character]
    }

    nonisolated static func modifierMask(for names: [String]) -> UInt32 {
        names.reduce(into: UInt32(0)) { mask, name in
            switch name.lowercased() {
            case "option", "opt", "alt": mask |= UInt32(optionKey)
            case "command", "cmd", "super": mask |= UInt32(cmdKey)
            case "control", "ctrl": mask |= UInt32(controlKey)
            case "shift": mask |= UInt32(shiftKey)
            default: break
            }
        }
    }

    nonisolated private static let signature = OSType(0x4f524254)

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The event carries which chord fired, which one binding never had to ask.
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalHotKey.signature else { return noErr }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            let slot = id.id
            Task { @MainActor in owner.fire(slot: slot) }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func fire(slot: UInt32) {
        guard let binding = bindings[slot] else { return }
        action?(binding.spec.target)
    }

    /// Re-registers the whole set on config reload, and returns the specs it could not
    /// bind so the caller can name them. A rejected chord costs only its own slot: the
    /// binding already in that slot survives, because a typo in one line of
    /// `config.lua` must not take away the chord that opens the launcher.
    @discardableResult
    func register(_ specs: [HotKeySpec]) -> [HotKeySpec] {
        guard specs != current else { return [] }
        var next: [UInt32: Binding] = [:]
        var resolved: [HotKeySpec] = []
        var rejected: [HotKeySpec] = []

        for (index, spec) in specs.enumerated() {
            let slot = UInt32(index)
            let existing = bindings.removeValue(forKey: slot)
            // An unchanged chord keeps the registration it already holds, so an
            // unrelated config save doesn't churn every binding in the set.
            if let existing, existing.spec == spec {
                next[slot] = existing
                resolved.append(spec)
                continue
            }
            // Validated *before* anything is torn down: an unknown key name is a config
            // typo, and must not cost the user a working binding.
            guard Self.keyCode(for: spec.key) != nil else {
                rejected.append(spec)
                if let existing { next[slot] = existing; resolved.append(existing.spec) }
                continue
            }
            if let existing { UnregisterEventHotKey(existing.reference) }
            if let reference = Self.claim(spec, slot: slot) {
                next[slot] = Binding(spec: spec, reference: reference)
                resolved.append(spec)
            } else {
                // The chord is valid but held by something else on the system. Put back
                // whatever this slot had, if it will still take.
                rejected.append(spec)
                if let existing, let reference = Self.claim(existing.spec, slot: slot) {
                    next[slot] = Binding(spec: existing.spec, reference: reference)
                    resolved.append(existing.spec)
                }
            }
        }
        // Whatever is left is a slot the new config dropped entirely.
        for binding in bindings.values { UnregisterEventHotKey(binding.reference) }
        bindings = next
        current = resolved
        return rejected
    }

    private static func claim(_ spec: HotKeySpec, slot: UInt32) -> EventHotKeyRef? {
        guard let code = keyCode(for: spec.key) else { return nil }
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: slot)
        let status = RegisterEventHotKey(UInt32(code), modifierMask(for: spec.modifiers), id,
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return nil }
        return reference
    }
}

final class ConfigWatcher: @unchecked Sendable {
    private let directory: URL
    private let filenames: [String]
    private let queue = DispatchQueue(label: "kitsune.config-watch")
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSources: [DispatchSourceFileSystemObject] = []
    var onChange: (() -> Void)?

    private let watchesDirectory: Bool

    private var debounce: TimeInterval = 0.08

    init(directory: URL, filenames: [String] = ["config.lua", "theme.lua"], watchesDirectory: Bool = true) {
        self.directory = directory
        self.filenames = filenames
        self.watchesDirectory = watchesDirectory
    }

    /// Republished from `watch = { debounce }` on every config reload. Set on the
    /// watcher's own queue, which is the only place `scheduleChange` reads it.
    func setDebounce(_ interval: TimeInterval) {
        queue.async { [weak self] in self?.debounce = max(0, interval) }
    }

    func start() throws {
        if watchesDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { throw RuntimeError.message("Unable to watch config directory") }
            let source = makeSource(descriptor: descriptor)
            directorySource = source
            source.resume()
        }
        queue.async { [weak self] in self?.rearmFileWatches() }
    }

    private func makeSource(descriptor: Int32) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.scheduleChange() }
        source.setCancelHandler { close(descriptor) }
        return source
    }

    /// A directory vnode event only fires when an entry is added, removed or renamed.
    /// Rewriting a file in place — `cat > config.lua`, or any editor that saves
    /// without a temp-file swap — never touches the directory, so each file is also
    /// watched directly. The file watches are re-armed after every event because an
    /// editor that saves via rename leaves the old descriptor pointing at a dead inode.
    private func rearmFileWatches() {
        fileSources.forEach { $0.cancel() }
        fileSources = filenames.compactMap { name in
            let descriptor = open(directory.appendingPathComponent(name).path, O_EVTONLY)
            guard descriptor >= 0 else { return nil }
            let source = makeSource(descriptor: descriptor)
            source.resume()
            return source
        }
    }

    private func scheduleChange() {
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self else { return }
            rearmFileWatches()
            onChange?()
        }
    }
}

struct IPCRequest: Codable { let command: String; let argument: String? }
struct IPCResponse: Codable { let ok: Bool; let message: String }

/// The JSON `kitsunectl list` prints. `DisplayRow` holds an `NSImage`, so it is
/// projected onto a codable shape rather than made `Codable` itself.
struct ListingPayload: Codable {
    struct Row: Codable {
        let id: String
        let kind: String
        let label: String
        let detail: String
        let symbol: String
        let section: String
        let score: Int
    }

    let title: String
    let rows: [Row]

    init(_ listing: (title: String, rows: [DisplayRow])) {
        title = listing.title
        rows = listing.rows.map {
            Row(id: $0.id, kind: $0.kind.rawValue, label: $0.label, detail: $0.detail,
                symbol: $0.symbol, section: $0.section, score: $0.score)
        }
    }
}

/// The IPC verb table, lifted out of `AppDelegate` so the command surface can be
/// exercised without an `NSApplication`: the delegate supplies each effect as a
/// closure and this stays a pure switch over the request. Adding a command means
/// editing this switch — `kitsunectl` forwards whatever verb it is given.
@MainActor
struct IPCCommands {
    var toggle: (String) -> Void = { _ in }
    var show: (String) -> Void = { _ in }
    var hide: () -> Void = {}
    var reload: () -> Void = {}
    /// The resolved palette name, or empty when the theme set none.
    var paletteName: () -> String = { "" }
    var version: () -> String = { "unbundled" }
    var invoke: (String) -> Bool = { _ in false }
    /// The rows a route would show. Returns nil when there is no menu to ask.
    var list: (_ route: String, _ query: String) -> (title: String, rows: [DisplayRow])? = { _, _ in nil }

    func handle(_ request: IPCRequest) -> IPCResponse {
        switch request.command {
        case "ping": return IPCResponse(ok: true, message: "ok")
        case "toggle": toggle(request.argument ?? "root"); return IPCResponse(ok: true, message: "ok")
        case "show": show(request.argument ?? "root"); return IPCResponse(ok: true, message: "ok")
        case "hide": hide(); return IPCResponse(ok: true, message: "ok")
        case "reload": reload(); return IPCResponse(ok: true, message: "ok")
        case "theme":
            let name = paletteName()
            return IPCResponse(ok: true, message: name.isEmpty ? "(no palette)" : name)
        // Reads the bundle, not a constant: scripts/build-app.sh stamps the plist
        // from `git describe`, so a compiled-in string would drift from the tag.
        case "version": return IPCResponse(ok: true, message: version())
        case "invoke": return invoke(request.argument ?? "") ? IPCResponse(ok: true, message: "ok") : IPCResponse(ok: false, message: "unknown node")
        // `list [route] [query…]` — the argument is split on the first space, so the
        // rest is the query. Provider rows are absent: they arrive asynchronously and
        // this is a synchronous snapshot of the static list.
        case "list":
            let parts = (request.argument ?? "").split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let route = parts.first.map(String.init) ?? "root"
            let query = parts.count > 1 ? String(parts[1]) : ""
            guard let listing = list(route.isEmpty ? "root" : route, query) else {
                return IPCResponse(ok: false, message: "no menu")
            }
            guard let data = try? JSONEncoder().encode(ListingPayload(listing)),
                  let json = String(data: data, encoding: .utf8) else {
                return IPCResponse(ok: false, message: "unable to encode listing")
            }
            return IPCResponse(ok: true, message: json)
        default: return IPCResponse(ok: false, message: "unknown command")
        }
    }
}

final class IPCServer: @unchecked Sendable {
    let socketURL: URL
    private let queue = DispatchQueue(label: "kitsune.ipc")
    private var socket: Int32 = -1
    private var source: DispatchSourceRead?
    var handler: (@MainActor (IPCRequest) -> IPCResponse)?

    init(socketURL: URL) { self.socketURL = socketURL }

    func start() throws {
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(socketURL.path)
        socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw RuntimeError.message("Unable to create IPC socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = socketURL.path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw RuntimeError.message("IPC path too long") }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in _ = bytes.withUnsafeBufferPointer { strcpy(destination, $0.baseAddress!) } }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, listen(socket, 8) == 0 else { throw RuntimeError.message("Unable to bind IPC socket") }
        chmod(socketURL.path, 0o600)
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        self.source = source
        source.resume()
    }

    private func acceptClient() {
        let client = accept(socket, nil, nil)
        guard client >= 0 else { return }
        queue.async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = read(client, &buffer, buffer.count)
            guard count > 0, let request = try? JSONDecoder().decode(IPCRequest.self, from: Data(buffer.prefix(count))) else { close(client); return }
            Task { @MainActor [weak self] in
                defer { close(client) }
                let response = self?.handler?(request) ?? IPCResponse(ok: false, message: "No handler")
                // A `list` reply is far larger than a socket buffer, and `write` is
                // free to accept only part of it. Loop until it is all gone, or a
                // long listing arrives at the client as truncated JSON.
                if let data = try? JSONEncoder().encode(response) {
                    data.withUnsafeBytes { buffer in
                        guard var pointer = buffer.baseAddress else { return }
                        var remaining = buffer.count
                        while remaining > 0 {
                            let written = write(client, pointer, remaining)
                            guard written > 0 else { break }
                            pointer += written
                            remaining -= written
                        }
                    }
                }
            }
        }
    }
}
