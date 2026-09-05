import AppKit

/// Rows supplied by a subprocess, for the `command` field on a menu node.
///
/// This is the one thing a Lua provider can never do. A provider is re-loaded into a
/// throwaway state on every keystroke with `io` nil'd out and no execution globals,
/// so it is a pure function of the query — arithmetic, string munging, nothing more.
/// `brew search`, `rg`, `kubectl config get-contexts` and anything else that has to
/// *look at the machine* has to be spawned by the host.
///
/// The sandbox story is unchanged: the host spawns and logs it, exactly as `shell`
/// does on activation. What is new is that this runs while the user is typing, so it
/// is debounced, deadlined, byte-capped and cancellable, and a `command` belongs in a
/// config only if it is a read-only query.
@MainActor
final class CommandRunner {
    var spec = CommandSpec()

    private var cache: [String: [DisplayRow]] = [:]
    private var cacheOrder: [String] = []
    private var pending: DispatchWorkItem?
    private var live = ProcessBox()
    /// Bumped by every new request and by `cancel`, so a result that arrives after
    /// the query moved on is dropped instead of repainting the list.
    private var generation = 0

    /// Runs `command` for `query` and calls back on the main actor. A cache hit answers
    /// synchronously, which is what keeps backspacing through a query from respawning
    /// a process per keystroke.
    func rows(command: String, menuID: String, query: String, completion: @escaping @MainActor ([DisplayRow]) -> Void) {
        // Reuses the shell quoting `ScriptAction` already applies to `shell = ...`, so
        // a query containing quotes, spaces or a semicolon cannot break out of its
        // argument.
        guard case .shell(let script) = ScriptAction.shell(command).resolved(query: query) else { return }
        let key = "\(menuID)\u{0}\(script)"
        if let cached = cache[key] {
            completion(cached)
            return
        }

        cancel()
        generation += 1
        let mine = generation
        let spec = self.spec
        let box = live
        let item = DispatchWorkItem {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let output = Self.run(script: script, spec: spec, box: box)
                let rows = Self.parse(output, menuID: menuID, limit: spec.maxRows)
                DispatchQueue.main.async {
                    guard let self, mine == self.generation else { return }
                    self.store(rows, forKey: key)
                    completion(rows)
                }
            }
        }
        pending = item
        if spec.debounce > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + spec.debounce, execute: item)
        } else {
            item.perform()
        }
    }

    /// Drops a pending run, discards whatever is in flight, and kills a process that
    /// already started — leaving a `brew search` running for a menu the user has
    /// navigated away from is exactly the cost this feature has to avoid.
    func cancel() {
        pending?.cancel()
        pending = nil
        generation += 1
        live.terminate()
    }

    func clearCache() {
        cache = [:]
        cacheOrder = []
    }

    private func store(_ rows: [DisplayRow], forKey key: String) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = rows
        while cacheOrder.count > spec.cacheSize, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    // MARK: - Spawning

    /// Holds the running process so `cancel` can reach across the queue boundary and
    /// kill it.
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?

        func adopt(_ value: Process?) {
            lock.lock()
            process = value
            lock.unlock()
        }

        func terminate() {
            lock.lock()
            let running = process
            process = nil
            lock.unlock()
            if let running, running.isRunning { running.terminate() }
        }
    }

    nonisolated private static func run(script: String, spec: CommandSpec, box: ProcessBox) -> String {
        NSLog("KitsuneLauncher command: %@", script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.shell)
        process.arguments = [spec.login ? "-lc" : "-c", script]
        // A GUI app inherits a minimal PATH from launchd, so `brew` and anything else
        // in a package manager's prefix is simply not found. `login = true` sources the
        // user's own profile instead, at the cost of whatever that profile does.
        var environment = ProcessInfo.processInfo.environment
        if !spec.login {
            let existing = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            environment["PATH"] = "\(existing):/opt/homebrew/bin:/usr/local/bin"
        }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        // Diagnostics belong in the log, not in the row list, and a command that reads
        // from stdin must see EOF rather than block forever.
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch {
            NSLog("KitsuneLauncher command failed: %@", error.localizedDescription)
            return ""
        }
        box.adopt(process)
        defer { box.adopt(nil) }

        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + spec.timeout, execute: deadline)
        defer { deadline.cancel() }

        // Read in bounded chunks rather than to EOF: a command that prints without
        // stopping would otherwise be free to exhaust memory before the deadline fires.
        var data = Data()
        let handle = pipe.fileHandleForReading
        while data.count < spec.maxBytes {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return String(data: data.prefix(spec.maxBytes), encoding: .utf8) ?? ""
    }

    // MARK: - Parsing

    private struct JSONRow: Decodable {
        var label: String
        var detail: String?
        var symbol: String?
        var value: String?
        var shell: String?
        var url: String?
        var open: String?
        var applescript: String?
    }

    /// One row per line. A line starting with `{` is JSON, anything else is tab
    /// separated `label`, `detail`, `shell` — so the cheap case is `printf` or an
    /// `awk` one-liner, and the full case is still available without a second format.
    ///
    /// Order is preserved and scored by position: `brew search` already ranks its own
    /// output, and re-sorting it would throw that away.
    nonisolated static func parse(_ text: String, menuID: String, limit: Int) -> [DisplayRow] {
        var rows: [DisplayRow] = []
        var used = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard rows.count < limit else { break }
            let raw = String(line).replacingOccurrences(of: "\r", with: "")
            guard !raw.isBlank else { continue }

            var label = ""
            var detail = ""
            var symbol = ""
            var value: String?
            var action: ScriptAction?

            if raw.hasPrefix("{") {
                guard let decoded = try? JSONDecoder().decode(JSONRow.self, from: Data(raw.utf8)) else { continue }
                label = decoded.label
                detail = decoded.detail ?? ""
                symbol = decoded.symbol ?? ""
                value = decoded.value
                action = decoded.shell.map(ScriptAction.shell)
                    ?? decoded.applescript.map(ScriptAction.appleScript)
                    ?? decoded.open.map(ScriptAction.open)
                    ?? decoded.url.map(ScriptAction.url)
            } else {
                let fields = raw.components(separatedBy: "\t")
                label = fields[0].trimmingCharacters(in: .whitespaces)
                detail = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : ""
                if fields.count > 2, !fields[2].isBlank { action = .shell(fields[2]) }
            }

            guard !label.isBlank else { continue }
            var identifier = "\(menuID).cmd.\(slug(value ?? label))"
            while used.contains(identifier) { identifier += "-" }
            used.insert(identifier)
            rows.append(DisplayRow(
                id: identifier,
                // A row with nothing to run is a notice, matching how provider rows
                // without an action are treated.
                kind: action == nil ? .notice : .action,
                label: label,
                detail: detail,
                symbol: symbol,
                image: nil,
                score: rows.count,
                section: "command",
                action: action
            ))
        }
        return rows
    }

    nonisolated private static func slug(_ value: String) -> String {
        let mapped = value.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }
}
