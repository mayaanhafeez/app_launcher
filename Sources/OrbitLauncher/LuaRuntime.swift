import AppKit
import CLua

private let instructionStep: Int32 = 10_000
private let instructionLimit = 1_000_000

private final class ExecutionBudget {
    var instructions = 0
    let deadline: DispatchTime?
    init(timeout: TimeInterval? = nil) { deadline = timeout.map { .now() + $0 } }
}

nonisolated(unsafe) private let budgets = NSMapTable<NSValue, ExecutionBudget>(keyOptions: .strongMemory, valueOptions: .strongMemory)
private let budgetsLock = NSLock()

private func stateKey(_ state: OpaquePointer) -> NSValue { NSValue(pointer: UnsafeRawPointer(state)) }

private let luaBudgetHook: lua_Hook = { state, _ in
    guard let state else { return }
    budgetsLock.lock()
    let budget = budgets.object(forKey: stateKey(state))
    budgetsLock.unlock()
    guard let budget else { return }
    budget.instructions += Int(instructionStep)
    if budget.instructions > instructionLimit || budget.deadline.map({ DispatchTime.now() > $0 }) == true {
        _ = clua_error(state, "script execution limit exceeded")
    }
}

private func withBudget<T>(_ state: OpaquePointer, timeout: TimeInterval? = nil, _ body: () throws -> T) rethrows -> T {
    budgetsLock.lock()
    budgets.setObject(ExecutionBudget(timeout: timeout), forKey: stateKey(state))
    budgetsLock.unlock()
    lua_sethook(state, luaBudgetHook, LUA_MASKCOUNT, instructionStep)
    defer {
        lua_sethook(state, nil, 0, 0)
        budgetsLock.lock()
        budgets.removeObject(forKey: stateKey(state))
        budgetsLock.unlock()
    }
    return try body()
}

private func luaString(_ state: OpaquePointer, _ index: Int32) -> String? {
    guard lua_type(state, index) == LUA_TSTRING || lua_type(state, index) == LUA_TNUMBER,
          let pointer = lua_tolstring(state, index, nil) else { return nil }
    return String(cString: pointer)
}

private func terminalScript(_ command: String) -> String {
    let encoded = Data(command.utf8).base64EncodedString()
    // The decoded script is `eval`-ed in the window's own shell rather than piped
    // into a new one. Piping puts the script on stdin, which is the very thing
    // `read` reads from: a one-line `read -r '?Formula: ' name; brew install $name`
    // saw EOF and installed nothing, and a multi-line script had `read` swallow its
    // own next line. `eval` leaves stdin on the tty, and because that shell is
    // interactive it is also what makes zsh print `read`'s `?prompt` at all.
    let shell = "eval \"$(printf %s \(encoded) | base64 -D)\""
    return "tell application \"Terminal\"\nactivate\ndo script \"\(ScriptAction.appleScriptQuoted(shell))\"\nend tell"
}

private func launchTerminal(_ command: String) {
    NSLog("OrbitLauncher terminal: %@", command)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", terminalScript(command)]
    do { try task.run() } catch { NSLog("OrbitLauncher terminal failed: %@", error.localizedDescription) }
}

private func launchAppleScript(_ source: String) {
    NSLog("OrbitLauncher osascript invoked")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", source]
    do { try task.run() } catch { NSLog("OrbitLauncher osascript failed: %@", error.localizedDescription) }
}

private let terminalRun: lua_CFunction = { state in
    guard let state, let command = luaString(state, 1) else { return 0 }
    launchTerminal(command)
    return 0
}

private let appleScriptRun: lua_CFunction = { state in
    guard let state, let source = luaString(state, 1) else { return 0 }
    launchAppleScript(source)
    return 0
}

final class LuaRuntime: @unchecked Sendable {
    private var state: OpaquePointer?
    private let queue = DispatchQueue(label: "orbit.lua", qos: .userInitiated)
    private var configDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/orbit")
    private(set) var nodes: [MenuNode] = []
    private var providers: [String: Int32] = [:]
    var onReload: ((Result<[MenuNode], Error>) -> Void)?
    var onSettings: ((Settings) -> Void)?

    func load(file: URL) {
        queue.async { [weak self] in self?.reload(file: file) }
    }

    /// Lua handlers receive the live query as their first argument, so a single
    /// entry can act on what the user typed.
    func invoke(reference: Int32, query: String = "") {
        queue.async { [weak self] in
            guard let self, let state else { return }
            lua_rawgeti(state, CLUA_REGISTRYINDEX, lua_Integer(reference))
            lua_pushstring(state, query)
            let status = withBudget(state) { lua_pcallk(state, 1, 0, 0, 0, nil) }
            if status != LUA_OK { self.reportError(state, prefix: "Action") }
        }
    }

    /// An empty target is treated as "do nothing" rather than handed to the system,
    /// which would surface a "file can't be found" dialog for a blank config value.
    func invoke(scriptAction: ScriptAction, query: String = "") {
        switch scriptAction.resolved(query: query) {
        case .shell(let command) where !command.isBlank: launchTerminal(command)
        case .appleScript(let source) where !source.isBlank: launchAppleScript(source)
        case .open(let target) where !target.isBlank:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: (target as NSString).expandingTildeInPath), configuration: .init())
        case .url(let target) where !target.isBlank:
            if let url = URL(string: target), url.scheme != nil { NSWorkspace.shared.open(url) }
        default: break
        }
    }

    func provider(name: String, menuID: String, query: String, timeout: TimeInterval = 0.15, completion: @escaping @Sendable (Result<[DisplayRow], Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, let reference = providers[name], let sourceState = state else { completion(.success([])); return }
            guard let dump = dumpFunction(sourceState, reference: reference) else { completion(.failure(RuntimeError.message("Provider is not serializable"))); return }
            guard let providerState = Self.makeState(allowActions: false, configDirectory: configDirectory) else { completion(.failure(RuntimeError.message("Unable to create provider state"))); return }
            defer { lua_close(providerState) }
            let loadStatus = dump.withUnsafeBytes { bytes in
                luaL_loadbufferx(providerState, bytes.bindMemory(to: CChar.self).baseAddress, bytes.count, "provider", "b")
            }
            guard loadStatus == LUA_OK else { completion(.failure(RuntimeError.message("Unable to load provider"))); return }
            lua_pushstring(providerState, query)
            let status = withBudget(providerState, timeout: timeout) { lua_pcallk(providerState, 1, 1, 0, 0, nil) }
            guard status == LUA_OK else {
                completion(.failure(RuntimeError.message(luaString(providerState, -1) ?? "Provider failed")))
                return
            }
            completion(.success(Self.decodeRows(providerState, menuID: menuID)))
        }
    }

    private func reload(file: URL) {
        configDirectory = file.deletingLastPathComponent()
        if let state { lua_close(state) }
        state = nil
        nodes = []
        providers = [:]
        guard let next = Self.makeState(allowActions: true, configDirectory: configDirectory) else { publish(.failure(RuntimeError.message("Unable to initialize Lua"))); return }
        state = next
        guard FileManager.default.fileExists(atPath: file.path) else {
            nodes = Self.defaultNodes
            publishSettings(Settings())
            publish(.success(nodes))
            return
        }
        guard luaL_loadfilex(next, file.path, nil) == LUA_OK else { reportError(next, prefix: "Config"); return }
        let status = withBudget(next) { lua_pcallk(next, 0, 1, 0, 0, nil) }
        guard status == LUA_OK, lua_type(next, -1) == LUA_TTABLE else {
            reportError(next, prefix: "Config")
            return
        }
        decodeConfig(next)
        publish(.success(nodes))
    }

    /// Every state loses `io` and `os.execute`; only the config state gets the
    /// execution helpers. Both get `package.path` pointed at the config directory so
    /// `require "plugins.git"` resolves the way a Neovim config would.
    private static func makeState(allowActions: Bool, configDirectory: URL) -> OpaquePointer? {
        guard let state = luaL_newstate() else { return nil }
        luaL_openlibs(state)
        lua_pushnil(state); lua_setglobal(state, "io")
        lua_getglobal(state, "os")
        if lua_type(state, -1) == LUA_TTABLE { lua_pushnil(state); lua_setfield(state, -2, "execute") }
        lua_settop(state, 0)

        let root = configDirectory.path
        lua_getglobal(state, "package")
        if lua_type(state, -1) == LUA_TTABLE {
            let searchPath = [
                "\(root)/?.lua",
                "\(root)/?/init.lua",
                "\(root)/plugins/?.lua",
                "\(root)/plugins/?/init.lua",
                "\(root)/lua/?.lua",
                "\(root)/lua/?/init.lua",
            ].joined(separator: ";")
            lua_pushstring(state, searchPath); lua_setfield(state, -2, "path")
            // No C modules: a launcher config has no business dlopen-ing.
            lua_pushstring(state, ""); lua_setfield(state, -2, "cpath")
        }
        lua_settop(state, 0)

        lua_createtable(state, 0, 3)
        lua_pushstring(state, root); lua_setfield(state, -2, "config_dir")
        lua_pushstring(state, "\(root)/plugins"); lua_setfield(state, -2, "plugin_dir")
        lua_pushstring(state, FileManager.default.homeDirectoryForCurrentUser.path); lua_setfield(state, -2, "home")
        lua_pushboolean(state, allowActions ? 1 : 0); lua_setfield(state, -2, "can_execute")
        lua_setglobal(state, "orbit")

        if allowActions {
            lua_pushcclosure(state, terminalRun, 0); lua_setglobal(state, "terminal")
            lua_pushcclosure(state, terminalRun, 0); lua_setglobal(state, "run")
            lua_pushcclosure(state, appleScriptRun, 0); lua_setglobal(state, "osascript")
        }
        return state
    }

    private func decodeConfig(_ state: OpaquePointer) {
        publishSettings(Self.decodeSettings(state))

        lua_getfield(state, -1, "providers")
        if lua_type(state, -1) == LUA_TTABLE {
            lua_pushnil(state)
            while lua_next(state, -2) != 0 {
                if lua_type(state, -2) == LUA_TSTRING, let name = luaString(state, -2), lua_type(state, -1) == LUA_TFUNCTION {
                    lua_pushvalue(state, -1)
                    providers[name] = luaL_ref(state, CLUA_REGISTRYINDEX)
                }
                lua_settop(state, -2)
            }
        }
        lua_settop(state, -2)
        lua_getfield(state, -1, "items")
        guard lua_type(state, -1) == LUA_TTABLE else { lua_settop(state, 0); return }
        let count = Int(lua_rawlen(state, -1))
        if count > 0 {
            for index in 1...count {
                lua_rawgeti(state, -1, lua_Integer(index))
                if let node = decodeNode(state, order: index) { nodes.append(node) }
                lua_settop(state, -2)
            }
        }
        lua_settop(state, 0)
        if !nodes.contains(where: { $0.id == "root" }) { nodes.insert(Self.defaultNodes[0], at: 0) }
    }

    private static func decodeSettings(_ state: OpaquePointer) -> Settings {
        var settings = Settings()
        lua_getfield(state, -1, "vim")
        if lua_type(state, -1) == LUA_TBOOLEAN { settings.vimMode = lua_toboolean(state, -1) != 0 }
        lua_settop(state, -2)
        // `back = false` is the short way to switch the row off; the table form
        // configures it. Decoded before `hotkey`, whose guard returns early.
        lua_getfield(state, -1, "back")
        if lua_type(state, -1) == LUA_TBOOLEAN {
            settings.back.enabled = lua_toboolean(state, -1) != 0
        } else if lua_type(state, -1) == LUA_TTABLE {
            func field(_ name: String) -> String? {
                lua_getfield(state, -1, name); defer { lua_settop(state, -2) }; return luaString(state, -1)
            }
            lua_getfield(state, -1, "enabled")
            if lua_type(state, -1) == LUA_TBOOLEAN { settings.back.enabled = lua_toboolean(state, -1) != 0 }
            lua_settop(state, -2)
            if let label = field("label"), !label.isEmpty { settings.back.label = label }
            if let symbol = field("symbol") { settings.back.symbol = symbol }
            if let detail = field("detail") { settings.back.detail = detail }
            if let position = field("position"), !position.isEmpty { settings.back.position = position }
        }
        lua_settop(state, -2)

        // `shortcuts = false` switches the positional keys off; the table form
        // re-maps them. Decoded before `hotkey`, whose guard returns early.
        lua_getfield(state, -1, "shortcuts")
        if lua_type(state, -1) == LUA_TBOOLEAN {
            settings.shortcuts.enabled = lua_toboolean(state, -1) != 0
        } else if lua_type(state, -1) == LUA_TTABLE {
            lua_getfield(state, -1, "enabled")
            if lua_type(state, -1) == LUA_TBOOLEAN { settings.shortcuts.enabled = lua_toboolean(state, -1) != 0 }
            lua_settop(state, -2)
            lua_getfield(state, -1, "hints")
            if lua_type(state, -1) == LUA_TBOOLEAN { settings.shortcuts.hints = lua_toboolean(state, -1) != 0 }
            lua_settop(state, -2)
            if let mods = stringList(state, field: "mods") { settings.shortcuts.modifiers = mods }
            if let keys = stringList(state, field: "keys") { settings.shortcuts.keys = keys }
        }
        lua_settop(state, -2)

        lua_getfield(state, -1, "apps")
        if lua_type(state, -1) == LUA_TTABLE {
            if let paths = stringList(state, field: "paths") { settings.apps.paths = paths }
            lua_getfield(state, -1, "depth")
            if lua_type(state, -1) == LUA_TNUMBER { settings.apps.depth = max(1, Int(lua_tonumberx(state, -1, nil))) }
            lua_settop(state, -2)
        }
        lua_settop(state, -2)

        lua_getfield(state, -1, "hotkey")
        defer { lua_settop(state, -2) }
        guard lua_type(state, -1) == LUA_TTABLE else { return settings }
        lua_getfield(state, -1, "key")
        if let key = luaString(state, -1), !key.isEmpty { settings.hotKey.key = key }
        lua_settop(state, -2)
        if let mods = stringList(state, field: "mods") { settings.hotKey.modifiers = mods }
        return settings
    }

    /// The array under `field` on the table at the top of the stack, or nil when the
    /// key is absent or isn't a table — a missing key has to leave the default in
    /// place rather than blanking it.
    private static func stringList(_ state: OpaquePointer, field: String) -> [String]? {
        lua_getfield(state, -1, field)
        defer { lua_settop(state, -2) }
        guard lua_type(state, -1) == LUA_TTABLE else { return nil }
        var values: [String] = []
        let count = Int(lua_rawlen(state, -1))
        if count > 0 {
            for index in 1...count {
                lua_rawgeti(state, -1, lua_Integer(index))
                if let value = luaString(state, -1) { values.append(value) }
                lua_settop(state, -2)
            }
        }
        return values
    }

    private func decodeNode(_ state: OpaquePointer, order: Int) -> MenuNode? {
        guard lua_type(state, -1) == LUA_TTABLE else { return nil }
        func field(_ name: String) -> String? { lua_getfield(state, -1, name); defer { lua_settop(state, -2) }; return luaString(state, -1) }
        func list(_ name: String) -> [String] {
            lua_getfield(state, -1, name)
            defer { lua_settop(state, -2) }
            guard lua_type(state, -1) == LUA_TTABLE else { return [] }
            var values: [String] = []
            let count = Int(lua_rawlen(state, -1))
            if count > 0 {
                for index in 1...count {
                    lua_rawgeti(state, -1, lua_Integer(index))
                    if let value = luaString(state, -1) { values.append(value) }
                    lua_settop(state, -2)
                }
            }
            return values
        }
        guard let id = field("id"), !id.isEmpty else { return nil }
        let parent = field("parent") ?? (id.contains(".") ? String(id.split(separator: ".").dropLast().joined(separator: ".")) : "root")
        let label = field("label") ?? id
        let title = field("title") ?? ""
        let detail = field("detail") ?? ""
        let symbol = field("symbol") ?? ""
        let iconPath = field("icon") ?? ""
        let aliases = list("aliases")
        let provider = field("provider")
        let shell = field("shell")
        let appleScript = field("applescript")
        let open = field("open")
        let url = field("url")
        lua_getfield(state, -1, "action")
        var actionReference: Int32?
        if lua_type(state, -1) == LUA_TFUNCTION {
            lua_pushvalue(state, -1)
            actionReference = luaL_ref(state, CLUA_REGISTRYINDEX)
        }
        lua_settop(state, -2)
        let scriptAction = shell.map(ScriptAction.shell)
            ?? appleScript.map(ScriptAction.appleScript)
            ?? open.map(ScriptAction.open)
            ?? url.map(ScriptAction.url)
        let kind: RowKind = actionReference != nil || scriptAction != nil ? .action : .menu
        return MenuNode(
            id: id,
            parent: id == "root" ? "" : parent,
            kind: kind,
            label: label,
            title: title,
            detail: detail,
            symbol: symbol,
            iconPath: iconPath,
            aliases: aliases,
            provider: provider,
            actionReference: actionReference,
            scriptAction: scriptAction,
            order: order
        )
    }

    private func dumpFunction(_ state: OpaquePointer, reference: Int32) -> Data? {
        lua_rawgeti(state, CLUA_REGISTRYINDEX, lua_Integer(reference))
        defer { lua_settop(state, -2) }
        var data = Data()
        let writer: lua_Writer = { _, pointer, size, userData in
            guard let pointer, let userData else { return 1 }
            Unmanaged<NSMutableData>.fromOpaque(userData).takeUnretainedValue().append(pointer, length: size)
            return 0
        }
        let mutable = NSMutableData()
        guard lua_dump(state, writer, Unmanaged.passUnretained(mutable).toOpaque(), 0) == 0 else { return nil }
        data.append(mutable as Data)
        return data
    }

    /// Provider rows describe an action rather than performing one — the provider
    /// state has no execution globals, so the host runs what comes back.
    private static func decodeRows(_ state: OpaquePointer, menuID: String) -> [DisplayRow] {
        guard lua_type(state, -1) == LUA_TTABLE else { return [] }
        var rows: [DisplayRow] = []
        var used = Set<String>()
        let count = Int(lua_rawlen(state, -1))
        guard count > 0 else { return [] }
        for index in 1...count {
            lua_rawgeti(state, -1, lua_Integer(index))
            defer { lua_settop(state, -2) }
            guard lua_type(state, -1) == LUA_TTABLE else { continue }
            func field(_ name: String) -> String? { lua_getfield(state, -1, name); defer { lua_settop(state, -2) }; return luaString(state, -1) }
            guard let label = field("label"), !label.isEmpty else { continue }
            let action = field("shell").map(ScriptAction.shell)
                ?? field("applescript").map(ScriptAction.appleScript)
                ?? field("open").map(ScriptAction.open)
                ?? field("url").map(ScriptAction.url)
            let iconPath = field("icon") ?? ""
            var identifier = "\(menuID).\(slug(field("value") ?? label))"
            while used.contains(identifier) { identifier += "-" }
            used.insert(identifier)
            rows.append(DisplayRow(
                id: identifier,
                kind: action == nil ? .notice : .action,
                label: label,
                detail: field("detail") ?? "",
                symbol: field("symbol") ?? "",
                image: iconPath.isEmpty ? nil : NSImage(contentsOfFile: (iconPath as NSString).expandingTildeInPath),
                score: index,
                section: "provider",
                action: action
            ))
        }
        return rows
    }

    private static func slug(_ value: String) -> String {
        let mapped = value.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }

    private func reportError(_ state: OpaquePointer, prefix: String) {
        publish(.failure(RuntimeError.message("\(prefix): \(luaString(state, -1) ?? "unknown Lua error")")))
        lua_settop(state, 0)
    }

    private func publish(_ result: Result<[MenuNode], Error>) { DispatchQueue.main.async { [weak self] in self?.onReload?(result) } }
    private func publishSettings(_ settings: Settings) { DispatchQueue.main.async { [weak self] in self?.onSettings?(settings) } }

    private static let defaultNodes = [
        MenuNode(id: "root", parent: "", kind: .menu, label: "Go", detail: "", symbol: "", provider: nil, actionReference: nil, scriptAction: nil, order: 0),
        MenuNode(id: "apps", parent: "root", kind: .menu, label: "Applications", detail: "Installed applications", symbol: "square.grid.2x2", provider: nil, actionReference: nil, scriptAction: nil, order: 1),
        MenuNode(id: "system", parent: "root", kind: .menu, label: "System", detail: "Settings and session", symbol: "gearshape", provider: nil, actionReference: nil, scriptAction: nil, order: 2),
        MenuNode(id: "tools", parent: "root", kind: .menu, label: "Tools", detail: "Everyday utilities", symbol: "hammer", provider: nil, actionReference: nil, scriptAction: nil, order: 3),
    ]
}

enum RuntimeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { value } else { nil } }
}

final class ThemeRuntime: @unchecked Sendable {
    private(set) var paletteName = ""

    func load(file: URL) -> Theme {
        paletteName = ""
        guard FileManager.default.fileExists(atPath: file.path), let state = luaL_newstate() else { return Theme() }
        defer { lua_close(state) }
        luaL_openlibs(state)
        for global in ["io", "os", "package", "debug"] { lua_pushnil(state); lua_setglobal(state, global) }
        guard luaL_loadfilex(state, file.path, nil) == LUA_OK,
              withBudget(state, { lua_pcallk(state, 0, 1, 0, 0, nil) }) == LUA_OK,
              lua_type(state, -1) == LUA_TTABLE else { return Theme() }
        var theme = Theme()
        func string(_ key: String) -> String? { lua_getfield(state, -1, key); defer { lua_settop(state, -2) }; return luaString(state, -1) }
        // The palette seeds the colour roles; explicit keys below still override it.
        if let reference = string("palette"), !reference.isEmpty,
           let palette = Palette.resolve(reference, configDirectory: file.deletingLastPathComponent()) {
            theme.apply(palette: palette)
            paletteName = palette.name
        }
        func number(_ key: String) -> Double? { lua_getfield(state, -1, key); defer { lua_settop(state, -2) }; return lua_type(state, -1) == LUA_TNUMBER ? lua_tonumberx(state, -1, nil) : nil }
        func color(_ key: String, _ target: inout NSColor) { if let value = string(key) { target = NSColor(hex: value) } }
        func optionalColor(_ key: String, _ target: inout NSColor?) { if let value = string(key) { target = NSColor(hex: value) } }
        func alpha(_ key: String, _ target: inout CGFloat) { if let value = number(key) { target = min(1, max(0, value)) } }
        func size(_ key: String, minimum: Double = 0, _ target: inout CGFloat) { if let value = number(key), value >= minimum { target = value } }

        color("bg", &theme.bg)
        color("surface", &theme.surface)
        color("fg", &theme.fg)
        color("fg_muted", &theme.fgMuted)
        color("accent", &theme.accent)
        color("border", &theme.border)
        optionalColor("selection_bg", &theme.selectionBg)
        optionalColor("selection_fg", &theme.selectionFg)

        alpha("bg_alpha", &theme.bgAlpha)
        alpha("border_alpha", &theme.borderAlpha)
        alpha("selection_alpha", &theme.selectionAlpha)
        alpha("detail_alpha", &theme.detailAlpha)
        alpha("chevron_alpha", &theme.chevronAlpha)
        alpha("divider_alpha", &theme.dividerAlpha)
        if let value = number("blur") { theme.blur = min(1, max(0, value)) }

        size("radius", &theme.radius)
        size("row_radius", &theme.rowRadius)
        size("width", minimum: 220, &theme.width)
        if let value = number("max_height"), value > 0 { theme.maxHeight = min(1, value) }
        size("border_width", &theme.borderWidth)
        if let value = number("offset_y") { theme.offsetY = value }

        if let value = number("spacing_scale"), value > 0 { theme.spacingScale = value }
        size("panel_padding", &theme.panelPadding)
        size("row_gap", &theme.rowGap)
        size("row_padding_x", &theme.rowPaddingX)
        size("icon_slot", &theme.iconSlot)
        size("icon_gap", &theme.iconGap)
        size("label_gap", &theme.labelGap)
        size("row_height", minimum: 20, &theme.rowHeight)
        size("row_height_detail", minimum: 20, &theme.rowHeightDetail)
        size("divider_height", &theme.dividerHeight)
        size("header_gap", &theme.headerGap)
        size("selection_inset", &theme.selectionInset)
        size("selection_bar", &theme.selectionBar)

        if let value = string("font") { theme.family = value }
        size("font_size", minimum: 6, &theme.fontSize)
        if let value = string("detail_mode"), ["search", "always", "never"].contains(value) { theme.detailMode = value }
        if let value = string("label_weight"), let weight = Theme.weight(named: value) { theme.labelWeight = weight }
        if let value = string("detail_weight"), let weight = Theme.weight(named: value) { theme.detailWeight = weight }
        return theme
    }
}
