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
    guard let pointer = lua_tolstring(state, index, nil) else { return nil }
    return String(cString: pointer)
}

private func terminalScript(_ command: String) -> String {
    let encoded = Data(command.utf8).base64EncodedString()
    let shell = "printf %s \(encoded) | base64 -D | /bin/zsh"
    return "tell application \"Terminal\"\nactivate\ndo script \"\(shell)\"\nend tell"
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
    private(set) var nodes: [MenuNode] = []
    private var providers: [String: Int32] = [:]
    var onReload: ((Result<[MenuNode], Error>) -> Void)?

    func load(file: URL) {
        queue.async { [weak self] in self?.reload(file: file) }
    }

    func invoke(reference: Int32) {
        queue.async { [weak self] in
            guard let self, let state else { return }
            lua_rawgeti(state, CLUA_REGISTRYINDEX, lua_Integer(reference))
            let status = withBudget(state) { lua_pcallk(state, 0, 0, 0, 0, nil) }
            if status != LUA_OK { self.reportError(state, prefix: "Action") }
        }
    }

    func invoke(scriptAction: ScriptAction) {
        switch scriptAction {
        case .shell(let command): launchTerminal(command)
        case .appleScript(let source): launchAppleScript(source)
        }
    }

    func provider(name: String, query: String, timeout: TimeInterval = 0.15, completion: @escaping @Sendable (Result<[DisplayRow], Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, let reference = providers[name], let sourceState = state else { completion(.success([])); return }
            guard let dump = dumpFunction(sourceState, reference: reference) else { completion(.failure(RuntimeError.message("Provider is not serializable"))); return }
            guard let providerState = Self.makeState(allowActions: false) else { completion(.failure(RuntimeError.message("Unable to create provider state"))); return }
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
            completion(.success(Self.decodeRows(providerState)))
        }
    }

    private func reload(file: URL) {
        if let state { lua_close(state) }
        state = nil
        nodes = []
        providers = [:]
        guard let next = Self.makeState(allowActions: true) else { publish(.failure(RuntimeError.message("Unable to initialize Lua"))); return }
        state = next
        guard FileManager.default.fileExists(atPath: file.path) else {
            nodes = Self.defaultNodes
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

    private static func makeState(allowActions: Bool) -> OpaquePointer? {
        guard let state = luaL_newstate() else { return nil }
        luaL_openlibs(state)
        lua_pushnil(state); lua_setglobal(state, "io")
        lua_getglobal(state, "os")
        if lua_type(state, -1) == LUA_TTABLE { lua_pushnil(state); lua_setfield(state, -2, "execute") }
        lua_settop(state, 0)
        if allowActions {
            lua_pushcclosure(state, terminalRun, 0); lua_setglobal(state, "terminal")
            lua_pushcclosure(state, terminalRun, 0); lua_setglobal(state, "run")
            lua_pushcclosure(state, appleScriptRun, 0); lua_setglobal(state, "osascript")
        }
        return state
    }

    private func decodeConfig(_ state: OpaquePointer) {
        lua_getfield(state, -1, "providers")
        if lua_type(state, -1) == LUA_TTABLE {
            lua_pushnil(state)
            while lua_next(state, -2) != 0 {
                if let name = luaString(state, -2), lua_type(state, -1) == LUA_TFUNCTION {
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
        for index in 1...count {
            lua_rawgeti(state, -1, lua_Integer(index))
            if let node = decodeNode(state, order: index) { nodes.append(node) }
            lua_settop(state, -2)
        }
        lua_settop(state, 0)
        if !nodes.contains(where: { $0.id == "root" }) { nodes.insert(Self.defaultNodes[0], at: 0) }
    }

    private func decodeNode(_ state: OpaquePointer, order: Int) -> MenuNode? {
        guard lua_type(state, -1) == LUA_TTABLE else { return nil }
        func field(_ name: String) -> String? { lua_getfield(state, -1, name); defer { lua_settop(state, -2) }; return luaString(state, -1) }
        guard let id = field("id"), !id.isEmpty else { return nil }
        let parent = field("parent") ?? (id.contains(".") ? String(id.split(separator: ".").dropLast().joined(separator: ".")) : "root")
        let label = field("label") ?? id
        let detail = field("detail") ?? ""
        let symbol = field("symbol") ?? ""
        let provider = field("provider")
        let shell = field("shell")
        let appleScript = field("applescript")
        lua_getfield(state, -1, "action")
        var actionReference: Int32?
        if lua_type(state, -1) == LUA_TFUNCTION {
            lua_pushvalue(state, -1)
            actionReference = luaL_ref(state, CLUA_REGISTRYINDEX)
        }
        lua_settop(state, -2)
        let scriptAction = shell.map(ScriptAction.shell) ?? appleScript.map(ScriptAction.appleScript)
        let kind: RowKind = actionReference != nil || scriptAction != nil ? .action : .menu
        return MenuNode(id: id, parent: id == "root" ? "" : parent, kind: kind, label: label, detail: detail, symbol: symbol, provider: provider, actionReference: actionReference, scriptAction: scriptAction, order: order)
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

    private static func decodeRows(_ state: OpaquePointer) -> [DisplayRow] {
        guard lua_type(state, -1) == LUA_TTABLE else { return [] }
        var rows: [DisplayRow] = []
        for index in 1...Int(lua_rawlen(state, -1)) {
            lua_rawgeti(state, -1, lua_Integer(index))
            if lua_type(state, -1) == LUA_TTABLE {
                func field(_ name: String) -> String { lua_getfield(state, -1, name); defer { lua_settop(state, -2) }; return luaString(state, -1) ?? "" }
                let label = field("label")
                if !label.isEmpty { rows.append(DisplayRow(id: "provider:\(index)", kind: .notice, label: label, detail: field("detail"), symbol: field("symbol"), image: nil, score: index, section: "provider")) }
            }
            lua_settop(state, -2)
        }
        return rows
    }

    private func reportError(_ state: OpaquePointer, prefix: String) {
        publish(.failure(RuntimeError.message("\(prefix): \(luaString(state, -1) ?? "unknown Lua error")")))
        lua_settop(state, 0)
    }

    private func publish(_ result: Result<[MenuNode], Error>) { DispatchQueue.main.async { [weak self] in self?.onReload?(result) } }

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
    func load(file: URL) -> Theme {
        guard FileManager.default.fileExists(atPath: file.path), let state = luaL_newstate() else { return Theme() }
        defer { lua_close(state) }
        luaL_openlibs(state)
        for global in ["io", "os", "package", "debug"] { lua_pushnil(state); lua_setglobal(state, global) }
        guard luaL_loadfilex(state, file.path, nil) == LUA_OK,
              withBudget(state, { lua_pcallk(state, 0, 1, 0, 0, nil) }) == LUA_OK,
              lua_type(state, -1) == LUA_TTABLE else { return Theme() }
        var theme = Theme()
        func string(_ key: String) -> String? { lua_getfield(state, -1, key); defer { lua_settop(state, -2) }; return luaString(state, -1) }
        func number(_ key: String) -> Double? { lua_getfield(state, -1, key); defer { lua_settop(state, -2) }; return lua_type(state, -1) == LUA_TNUMBER ? lua_tonumberx(state, -1, nil) : nil }
        if let value = string("bg") { theme.bg = NSColor(hex: value) }
        if let value = string("surface") { theme.surface = NSColor(hex: value) }
        if let value = string("accent") { theme.accent = NSColor(hex: value) }
        if let value = string("fg") { theme.fg = NSColor(hex: value) }
        if let value = string("fg_muted") { theme.fgMuted = NSColor(hex: value) }
        if let value = string("border") { theme.border = NSColor(hex: value) }
        if let value = number("radius"), value >= 0 { theme.radius = value }
        if let value = number("row_height"), value >= 32 { theme.rowHeight = value }
        if let value = number("padding"), value >= 0 { theme.padding = value }
        if let value = string("font"), !value.isEmpty { theme.font = value }
        if let value = number("font_size"), value > 0 { theme.fontSize = value }
        if let value = number("blur") { theme.blur = min(1, max(0, value)) }
        return theme
    }
}
