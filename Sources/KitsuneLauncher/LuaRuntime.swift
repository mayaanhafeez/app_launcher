import AppKit
import CLua

private let instructionStep: Int32 = 10_000
private let instructionLimit = 1_000_000

private final class ExecutionBudget {
    var instructions = 0
    let limit: Int
    let deadline: DispatchTime?
    init(timeout: TimeInterval? = nil, limit: Int = instructionLimit) {
        self.limit = limit
        deadline = timeout.map { .now() + $0 }
    }
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
    if budget.instructions > budget.limit || budget.deadline.map({ DispatchTime.now() > $0 }) == true {
        _ = clua_error(state, "script execution limit exceeded")
    }
}

private func withBudget<T>(_ state: OpaquePointer, timeout: TimeInterval? = nil, limit: Int = instructionLimit, _ body: () throws -> T) rethrows -> T {
    budgetsLock.lock()
    budgets.setObject(ExecutionBudget(timeout: timeout, limit: limit), forKey: stateKey(state))
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

/// The command, wrapped so a scripted terminal can be handed one word. The decoded
/// script is `eval`-ed in the window's own shell rather than piped into a new one.
/// Piping puts the script on stdin, which is the very thing `read` reads from: a
/// one-line `read -r '?Formula: ' name; brew install $name` saw EOF and installed
/// nothing, and a multi-line script had `read` swallow its own next line. `eval`
/// leaves stdin on the tty, and because that shell is interactive it is also what
/// makes zsh print `read`'s `?prompt` at all.
///
/// The spawned path needs none of this — `open --args` carries argv exactly — so the
/// encoding lives here rather than in `terminalLaunch`.
private func evalPayload(_ command: String) -> String {
    "eval \"$(printf %s \(Data(command.utf8).base64EncodedString()) | base64 -D)\""
}

/// Internal rather than private so the encoding contract below can be tested
/// directly: the shipped bug this guards against is invisible from the outside,
/// since `launchTerminal` only ever hands the string to `osascript`.
func terminalScript(_ command: String) -> String {
    "tell application \"Terminal\"\nactivate\ndo script \"\(ScriptAction.appleScriptQuoted(evalPayload(command)))\"\nend tell"
}

/// iTerm has no `do script`. `write text` is its equivalent — it types the line into
/// a session that is already running the user's interactive shell, so the tty and
/// `read` behave exactly as they do in Terminal.
func iTermScript(_ command: String) -> String {
    let quoted = ScriptAction.appleScriptQuoted(evalPayload(command))
    return """
    tell application "iTerm"
    activate
    set kitsuneWindow to (create window with default profile)
    tell current session of kitsuneWindow to write text "\(quoted)"
    end tell
    """
}

/// Where a `shell = ...` command is sent, and how. Kept a value — like `ScriptAction`
/// and `RowAction` — so the whole mapping from a `TerminalSpec` to a process is
/// testable without spawning one.
enum TerminalLaunch: Equatable, Sendable {
    /// AppleScript source for `/usr/bin/osascript`.
    case appleScript(String)
    /// argv for `/usr/bin/open`. Exact, so the command needs no quoting at all.
    case open([String])
}

/// The login shell for the spawned path. Resolved here rather than baked into
/// `TerminalSpec()`'s default so the spec stays a plain value.
private func loginShell() -> String {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
    return shell.isEmpty ? "/bin/zsh" : shell
}

func terminalLaunch(_ command: String, spec: TerminalSpec) -> TerminalLaunch {
    let name = spec.app.lowercased()
    // An explicit `args` is what forces the spawned path: a user who wrote an argv
    // template for an app meant it to be used, even for one Kitsune would script.
    if spec.arguments.isEmpty, TerminalSpec.scripted.contains(name) {
        return .appleScript(name.hasPrefix("iterm") ? iTermScript(command) : terminalScript(command))
    }
    let template = spec.arguments.isEmpty
        ? (TerminalSpec.knownArguments[name] ?? TerminalSpec.defaultArguments)
        : spec.arguments
    let shell = spec.shell.isEmpty ? loginShell() : spec.shell
    let argv = template.map {
        $0.replacingOccurrences(of: "{shell}", with: shell)
            .replacingOccurrences(of: "{command}", with: command)
    }
    // `-n`: a new window even when the app is already running, which is what the
    // scripted path does too.
    return .open(["-na", spec.app, "--args"] + argv)
}

/// The terminal every `shell = ...` opens in, held process-wide. `terminalRun` is a
/// bare C function pointer with nowhere to hang a reference, and `invoke(scriptAction:)`
/// has to read the same value, so the spec lives here and every settings publish
/// replaces it.
private let terminalSpecLock = NSLock()
nonisolated(unsafe) private var terminalSpecStorage = TerminalSpec()

func setActiveTerminal(_ spec: TerminalSpec) {
    terminalSpecLock.lock(); defer { terminalSpecLock.unlock() }
    terminalSpecStorage = spec
}

func activeTerminal() -> TerminalSpec {
    terminalSpecLock.lock(); defer { terminalSpecLock.unlock() }
    return terminalSpecStorage
}

private func launchTerminal(_ command: String) {
    let spec = activeTerminal()
    NSLog("KitsuneLauncher terminal (%@): %@", spec.app, command)
    let task = Process()
    switch terminalLaunch(command, spec: spec) {
    case .appleScript(let source):
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]
    case .open(let argv):
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = argv
    }
    do { try task.run() } catch { NSLog("KitsuneLauncher terminal failed: %@", error.localizedDescription) }
}

private func launchAppleScript(_ source: String) {
    NSLog("KitsuneLauncher osascript invoked")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", source]
    do { try task.run() } catch { NSLog("KitsuneLauncher osascript failed: %@", error.localizedDescription) }
}

private let terminalRun: lua_CFunction = { state in
    guard let state, let command = luaString(state, 1) else { return 0 }
    launchTerminal(command)
    return 0
}

/// Module failures the config *caught*, collected in the state that caught them.
///
/// The shipped template loads plugins with `pcall(require, ...)` so one broken plugin
/// does not take the whole menu down — which also means a syntax error in
/// `plugins/themes.lua` was swallowed whole: the config loaded, nothing was reported
/// anywhere, and the plugin's rows simply never appeared. The host has to see what the
/// config chose to ignore, so `require` records every failure before re-raising it,
/// and the config's own `pcall` goes on working exactly as it did.
///
/// The list lives in the state's own registry rather than in a Swift global: a state
/// is built per load, so it cannot carry one load's problems into the next, and a
/// second `LuaRuntime` in the same process (a test, a theme) has its own.
private let warningsKey = "kitsune.warnings"
/// Where the real `require` is kept while the reporting one stands in for it.
private let originalRequireKey = "kitsune.require"

private func recordConfigWarning(_ state: OpaquePointer, _ message: String) {
    lua_getfield(state, CLUA_REGISTRYINDEX, warningsKey)
    if lua_type(state, -1) != LUA_TTABLE {
        lua_settop(state, -2)
        lua_createtable(state, 0, 0)
        lua_pushvalue(state, -1)
        lua_setfield(state, CLUA_REGISTRYINDEX, warningsKey)
    }
    let count = lua_rawlen(state, -1)
    lua_pushstring(state, message)
    lua_rawseti(state, -2, lua_Integer(count + 1))
    lua_settop(state, -2)
}

private let reportingRequire: lua_CFunction = { state in
    guard let state else { return 0 }
    let argumentCount = lua_gettop(state)
    lua_getfield(state, CLUA_REGISTRYINDEX, originalRequireKey)
    for index in 1...max(argumentCount, 1) { lua_pushvalue(state, index) }
    guard lua_pcallk(state, argumentCount, LUA_MULTRET, 0, 0, nil) == LUA_OK else {
        let message = luaString(state, -1) ?? "module failed to load"
        recordConfigWarning(state, message)
        // Re-raised, so a config that wraps this in `pcall` behaves exactly as before
        // and one that does not still fails the load outright.
        return clua_error(state, message)
    }
    return lua_gettop(state) - argumentCount
}

private let appleScriptRun: lua_CFunction = { state in
    guard let state, let source = luaString(state, 1) else { return 0 }
    launchAppleScript(source)
    return 0
}

final class LuaRuntime: @unchecked Sendable {
    private var state: OpaquePointer?
    private let queue = DispatchQueue(label: "kitsune.lua", qos: .userInitiated)
    private var configDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/kitsune")
    private(set) var nodes: [MenuNode] = []
    private var providers: [String: Int32] = [:]
    var onReload: ((Result<[MenuNode], Error>) -> Void)?
    var onSettings: ((Settings) -> Void)?
    /// How the load itself went — nil on success, the Lua error otherwise. Separate
    /// from `onReload` because the node set has one consumer (`MenuController`) and
    /// the error state has another: the menu bar has to keep showing it long after a
    /// five-second toast would have gone.
    var onLoadOutcome: ((String?) -> Void)?

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

    func provider(name: String, menuID: String, query: String, timeout: TimeInterval = 0.15, instructions: Int = instructionLimit, completion: @escaping @Sendable (Result<[DisplayRow], Error>) -> Void) {
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
            let status = withBudget(providerState, timeout: timeout, limit: instructions) { lua_pcallk(providerState, 1, 1, 0, 0, nil) }
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
        publish(.success(nodes), warnings: Self.warnings(next))
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
        lua_setglobal(state, "kitsune")

        // Only the config state gets any of this. A provider state is re-created per
        // keystroke and reports its own failures through the provider error path.
        if allowActions {
            lua_getglobal(state, "require")
            lua_setfield(state, CLUA_REGISTRYINDEX, originalRequireKey)
            lua_pushcclosure(state, reportingRequire, 0); lua_setglobal(state, "require")
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

        lua_getfield(state, -1, "login_item")
        if lua_type(state, -1) == LUA_TBOOLEAN { settings.loginItem = lua_toboolean(state, -1) != 0 }
        lua_settop(state, -2)

        lua_getfield(state, -1, "apps")
        if lua_type(state, -1) == LUA_TTABLE {
            if let paths = stringList(state, field: "paths") { settings.apps.paths = paths }
            lua_getfield(state, -1, "depth")
            if lua_type(state, -1) == LUA_TNUMBER { settings.apps.depth = max(1, Int(lua_tonumberx(state, -1, nil))) }
            lua_settop(state, -2)
        }
        lua_settop(state, -2)

        // `ranking = false` switches frecency off; the table form tunes it.
        lua_getfield(state, -1, "ranking")
        if lua_type(state, -1) == LUA_TBOOLEAN {
            settings.ranking.enabled = lua_toboolean(state, -1) != 0
        } else if lua_type(state, -1) == LUA_TTABLE {
            if let enabled = boolean(state, field: "enabled") { settings.ranking.enabled = enabled }
            if let value = number(state, field: "half_life"), value > 0 { settings.ranking.halfLife = value }
            if let value = number(state, field: "weight"), value >= 0 { settings.ranking.weight = value }
        }
        lua_settop(state, -2)

        lua_getfield(state, -1, "search")
        if lua_type(state, -1) == LUA_TTABLE {
            if let value = number(state, field: "app_limit") { settings.search.appLimit = max(1, Int(value)) }
            if let value = number(state, field: "row_limit") { settings.search.rowLimit = max(0, Int(value)) }
            if let value = number(state, field: "depth") { settings.search.depth = max(1, Int(value)) }
            if let value = boolean(state, field: "match_detail") { settings.search.matchDetail = value }
        }
        lua_settop(state, -2)

        // Deliberately *not* `providers`: that key already holds the provider
        // functions themselves, and overloading it would put two unrelated meanings
        // on one name.
        lua_getfield(state, -1, "provider_limits")
        if lua_type(state, -1) == LUA_TTABLE {
            if let value = number(state, field: "timeout"), value > 0 { settings.providers.timeout = value }
            if let value = number(state, field: "instructions") { settings.providers.instructions = max(10_000, Int(value)) }
            if let value = number(state, field: "debounce"), value >= 0 { settings.providers.debounce = value }
        }
        lua_settop(state, -2)

        lua_getfield(state, -1, "commands")
        if lua_type(state, -1) == LUA_TTABLE {
            if let value = number(state, field: "timeout"), value > 0 { settings.commands.timeout = value }
            if let value = number(state, field: "debounce"), value >= 0 { settings.commands.debounce = value }
            if let value = number(state, field: "max_rows") { settings.commands.maxRows = max(1, Int(value)) }
            if let value = number(state, field: "max_bytes") { settings.commands.maxBytes = max(1024, Int(value)) }
            if let value = number(state, field: "cache_size") { settings.commands.cacheSize = max(0, Int(value)) }
            lua_getfield(state, -1, "shell")
            if let shell = luaString(state, -1), !shell.isEmpty { settings.commands.shell = shell }
            lua_settop(state, -2)
            if let value = boolean(state, field: "login") { settings.commands.login = value }
        }
        lua_settop(state, -2)

        lua_getfield(state, -1, "watch")
        if lua_type(state, -1) == LUA_TTABLE {
            if let value = number(state, field: "debounce"), value >= 0 { settings.watchDebounce = value }
        }
        lua_settop(state, -2)

        // `menu_bar = false` removes the status item; the table form restyles it.
        // Decoded before `hotkey`, whose guard returns early.
        lua_getfield(state, -1, "menu_bar")
        if lua_type(state, -1) == LUA_TBOOLEAN {
            settings.menuBar.enabled = lua_toboolean(state, -1) != 0
        } else if lua_type(state, -1) == LUA_TTABLE {
            func field(_ name: String) -> String? {
                lua_getfield(state, -1, name); defer { lua_settop(state, -2) }; return luaString(state, -1)
            }
            lua_getfield(state, -1, "enabled")
            if lua_type(state, -1) == LUA_TBOOLEAN { settings.menuBar.enabled = lua_toboolean(state, -1) != 0 }
            lua_settop(state, -2)
            if let symbol = field("symbol"), !symbol.isEmpty { settings.menuBar.symbol = symbol }
            if let title = field("title") { settings.menuBar.title = title }
        }
        lua_settop(state, -2)

        // Which terminal a `shell = ...` entry opens in. `terminal = "Ghostty"` is the
        // short form; the table form adds an argv template for one Kitsune has no
        // entry for. Decoded before `hotkey`, whose guard returns early.
        lua_getfield(state, -1, "terminal")
        if let app = luaString(state, -1), !app.isEmpty {
            settings.terminal.app = app
        } else if lua_type(state, -1) == LUA_TTABLE {
            lua_getfield(state, -1, "app")
            if let app = luaString(state, -1), !app.isEmpty { settings.terminal.app = app }
            lua_settop(state, -2)
            if let args = stringList(state, field: "args") { settings.terminal.arguments = args }
            lua_getfield(state, -1, "shell")
            if let shell = luaString(state, -1), !shell.isEmpty { settings.terminal.shell = shell }
            lua_settop(state, -2)
        }
        lua_settop(state, -2)

        // `clipboard = false` is the default in all but name; the table form turns it
        // on and tunes it. Decoded before `hotkey`, whose guard returns early.
        lua_getfield(state, -1, "clipboard")
        if lua_type(state, -1) == LUA_TBOOLEAN {
            settings.clipboard.enabled = lua_toboolean(state, -1) != 0
        } else if lua_type(state, -1) == LUA_TTABLE {
            if let enabled = boolean(state, field: "enabled") { settings.clipboard.enabled = enabled }
            if let value = number(state, field: "limit") { settings.clipboard.limit = max(1, Int(value)) }
            if let value = number(state, field: "poll_interval") { settings.clipboard.pollInterval = max(0.1, value) }
            if let persist = boolean(state, field: "persist") { settings.clipboard.persist = persist }
        }
        lua_settop(state, -2)

        // `files = false` switches path completion off; the table form tunes it.
        lua_getfield(state, -1, "files")
        if lua_type(state, -1) == LUA_TBOOLEAN {
            settings.files.enabled = lua_toboolean(state, -1) != 0
        } else if lua_type(state, -1) == LUA_TTABLE {
            if let enabled = boolean(state, field: "enabled") { settings.files.enabled = enabled }
            if let hidden = boolean(state, field: "show_hidden") { settings.files.showHidden = hidden }
            if let value = number(state, field: "limit") { settings.files.limit = max(1, Int(value)) }
        }
        lua_settop(state, -2)

        // A list of chords, each of which may open a route or fire a node outright.
        // `hotkey = { ... }` below stays a single-entry alias so a config written
        // before this existed keeps working; an explicit `hotkeys` wins over it.
        var sawList = false
        lua_getfield(state, -1, "hotkeys")
        if lua_type(state, -1) == LUA_TTABLE {
            var specs: [HotKeySpec] = []
            let count = Int(lua_rawlen(state, -1))
            if count > 0 {
                for index in 1...count {
                    lua_rawgeti(state, -1, lua_Integer(index))
                    if lua_type(state, -1) == LUA_TTABLE { specs.append(decodeHotKey(state)) }
                    lua_settop(state, -2)
                }
            }
            // An empty or malformed list leaves the default binding alone rather than
            // leaving the launcher with no way to open at all.
            if !specs.isEmpty { settings.hotKeys = specs; sawList = true }
        }
        lua_settop(state, -2)

        lua_getfield(state, -1, "hotkey")
        defer { lua_settop(state, -2) }
        guard !sawList, lua_type(state, -1) == LUA_TTABLE else { return settings }
        settings.hotKeys = [decodeHotKey(state)]
        return settings
    }

    /// One chord, from a table already on top of the stack. Shared by `hotkeys` and by
    /// the `hotkey` alias, so both accept exactly the same fields.
    private static func decodeHotKey(_ state: OpaquePointer) -> HotKeySpec {
        var spec = HotKeySpec()
        lua_getfield(state, -1, "key")
        if let key = luaString(state, -1), !key.isEmpty { spec.key = key }
        lua_settop(state, -2)
        if let mods = stringList(state, field: "mods") { spec.modifiers = mods }

        lua_getfield(state, -1, "invoke")
        let invoke = luaString(state, -1)
        lua_settop(state, -2)
        lua_getfield(state, -1, "route")
        let route = luaString(state, -1)
        lua_settop(state, -2)
        // `invoke` wins over `route`: it is the more specific statement of intent, and
        // a config that set both plainly meant the action rather than the menu.
        if let invoke, !invoke.isEmpty { spec.target = .invoke(invoke) }
        else if let route, !route.isEmpty { spec.target = .toggle(route) }
        return spec
    }

    /// The number under `field` on the table at the top of the stack. Nil for a
    /// missing key, which — like `stringList` — has to leave the default alone.
    private static func number(_ state: OpaquePointer, field: String) -> Double? {
        lua_getfield(state, -1, field)
        defer { lua_settop(state, -2) }
        guard lua_type(state, -1) == LUA_TNUMBER else { return nil }
        return lua_tonumberx(state, -1, nil)
    }

    private static func boolean(_ state: OpaquePointer, field: String) -> Bool? {
        lua_getfield(state, -1, field)
        defer { lua_settop(state, -2) }
        guard lua_type(state, -1) == LUA_TBOOLEAN else { return nil }
        return lua_toboolean(state, -1) != 0
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
        func flag(_ name: String) -> Bool {
            lua_getfield(state, -1, name)
            defer { lua_settop(state, -2) }
            return lua_type(state, -1) == LUA_TBOOLEAN && lua_toboolean(state, -1) != 0
        }
        let keep = flag("keep")
        let hidden = flag("hidden")
        let provider = field("provider")
        let command = field("command") ?? ""
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
            command: command,
            actionReference: actionReference,
            scriptAction: scriptAction,
            order: order,
            keep: keep,
            hidden: hidden
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
        publish(
            .failure(RuntimeError.message("\(prefix): \(luaString(state, -1) ?? "unknown Lua error")")),
            warnings: Self.warnings(state)
        )
        lua_settop(state, 0)
    }

    /// Every exit from `reload` lands here exactly once, which is what makes the
    /// outcome a reliable "the load finished, and this is how" signal rather than
    /// something each error path has to remember to send.
    ///
    /// A load that *succeeded* can still have a problem to report: a plugin the config
    /// caught with `pcall` loaded nothing, and saying so is the difference between a
    /// missing menu and a missing menu you can explain.
    private func publish(_ result: Result<[MenuNode], Error>, warnings: [String] = []) {
        DispatchQueue.main.async { [weak self] in
            self?.onReload?(result)
            let failure = if case let .failure(error) = result { error.localizedDescription } else { String?.none }
            // A failure that came *from* a swallowed module error is one problem, not
            // two: the same Lua message arrives on both paths when the config did not
            // catch it.
            let extra = warnings.filter { failure?.contains($0) != true }
            let outcome = ([failure].compactMap { $0 } + extra).joined(separator: "\n")
            self?.onLoadOutcome?(outcome.isEmpty ? nil : outcome)
        }
    }

    /// What `require` recorded on its way past. Deduplicated: a `require` in a loop can
    /// fail the same way many times over, and the user has one file to fix either way.
    private static func warnings(_ state: OpaquePointer) -> [String] {
        lua_getfield(state, CLUA_REGISTRYINDEX, warningsKey)
        defer { lua_settop(state, -2) }
        guard lua_type(state, -1) == LUA_TTABLE else { return [] }
        let count = Int(lua_rawlen(state, -1))
        guard count > 0 else { return [] }
        var messages: [String] = []
        for index in 1...count {
            lua_rawgeti(state, -1, lua_Integer(index))
            if let message = luaString(state, -1), !messages.contains(message) { messages.append(message) }
            lua_settop(state, -2)
        }
        return messages
    }

    /// The terminal spec is installed here rather than in `AppDelegate`, because the
    /// thing that reads it is a C function pointer inside this file, and because a
    /// missing config publishes `Settings()` — which has to put Terminal.app back.
    private func publishSettings(_ settings: Settings) {
        setActiveTerminal(settings.terminal)
        DispatchQueue.main.async { [weak self] in self?.onSettings?(settings) }
    }

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
        // Parsed by `Palette.color(from:)`, the same lenient reader the scheme files
        // use, so a value copied out of a palette (`0xaarrggbb`, `#rgb`) means here
        // what it meant there. `NSColor(hex:)` alone accepts only 6 digits and
        // silently yields black on anything else, which turned a shorthand override
        // into an unreadable panel with no error. An unparseable value now leaves the
        // palette-seeded colour standing rather than blacking it out.
        func color(_ key: String, _ target: inout NSColor) { if let value = string(key), let parsed = Palette.color(from: value) { target = parsed } }
        func optionalColor(_ key: String, _ target: inout NSColor?) { if let value = string(key), let parsed = Palette.color(from: value) { target = parsed } }
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
        if let value = number("offset_x") { theme.offsetX = value }
        if let value = number("offset_y") { theme.offsetY = value }
        // Underscores normalise to dashes, as they do for routes, so `active_window`
        // and `active-window` both name the anchor.
        func choice(_ key: String) -> String? { string(key)?.replacingOccurrences(of: "_", with: "-") }
        if let value = choice("position"), let anchor = PanelAnchor(rawValue: value) { theme.position = anchor }
        if let value = choice("screen"), let screen = PanelScreenChoice(rawValue: value) { theme.screen = screen }

        if let value = number("spacing_scale"), value > 0 { theme.spacingScale = value }
        size("panel_padding", &theme.panelPadding)
        if let value = number("padding_top"), value >= 0 { theme.paddingTop = value }
        if let value = number("padding_bottom"), value >= 0 { theme.paddingBottom = value }
        if let value = number("padding_sides"), value >= 0 { theme.paddingSides = value }
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
