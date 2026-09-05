import Darwin
import Foundation
import Testing
@testable import KitsuneLauncher

// One request, one response, connection closed — exercised over a real Unix socket
// in a temp directory, never the container path a running instance binds.

/// Mirrors `kitsunectl`'s client exactly (connect, write, read once), plus a receive
/// timeout so a handler that never answers fails the test instead of hanging CI.
private func ipcSendRaw(_ payload: Data, to path: String) -> Data {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return Data() }
    defer { close(descriptor) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return Data() }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
            _ = bytes.withUnsafeBufferPointer { strcpy(destination, $0.baseAddress!) }
        }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return Data() }
    payload.withUnsafeBytes { _ = write(descriptor, $0.baseAddress, payload.count) }
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = read(descriptor, &buffer, buffer.count)
    guard count > 0 else { return Data() }
    return Data(buffer.prefix(count))
}

/// The socket work has to leave the main actor: the handler runs *on* it, so a
/// blocking read from the main thread would deadlock against the reply.
private func ipcSend(_ payload: Data, to path: String) async -> Data {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: ipcSendRaw(payload, to: path)) }
    }
}

private func ipcSend(_ command: String, _ argument: String? = nil, to path: String) async -> IPCResponse? {
    guard let payload = try? JSONEncoder().encode(IPCRequest(command: command, argument: argument)) else { return nil }
    let raw = await ipcSend(payload, to: path)
    return try? JSONDecoder().decode(IPCResponse.self, from: raw)
}

/// Stands in for the delegate's objects, recording what each verb reached.
@MainActor
private final class CommandRecorder {
    var toggled: [String] = []
    var shown: [String] = []
    var hidden = 0
    var reloaded = 0
    var palette = ""
    var invoked: [String] = []
    let knownNodes: Set<String> = ["system.lock"]

    var commands: IPCCommands {
        IPCCommands(
            toggle: { [self] route in toggled.append(route) },
            show: { [self] route in shown.append(route) },
            hide: { [self] in hidden += 1 },
            reload: { [self] in reloaded += 1 },
            paletteName: { [self] in palette },
            version: { "9.9.9 (42)" },
            invoke: { [self] id in invoked.append(id); return knownNodes.contains(id) }
        )
    }
}

@MainActor
private func startIPCServer(_ recorder: CommandRecorder) throws -> (server: IPCServer, path: String, directory: URL) {
    let directory = kitsuneTemporaryDirectory("kitsune-ipc")
    let server = IPCServer(socketURL: directory.appendingPathComponent("kitsune.sock"))
    server.handler = { request in recorder.commands.handle(request) }
    try server.start()
    return (server, server.socketURL.path, directory)
}

@MainActor
@Test func ipcRoundTripsEveryCommand() async throws {
    let recorder = CommandRecorder()
    let (server, path, directory) = try startIPCServer(recorder)
    defer { kitsuneRemove(directory); _ = server }

    #expect(await ipcSend("ping", to: path)?.message == "ok")

    // A missing argument means the root menu, which is what the bare hotkey does.
    #expect(await ipcSend("toggle", to: path)?.ok == true)
    #expect(await ipcSend("toggle", "system", to: path)?.ok == true)
    #expect(recorder.toggled == ["root", "system"])

    #expect(await ipcSend("show", to: path)?.ok == true)
    #expect(await ipcSend("show", "apps", to: path)?.ok == true)
    #expect(recorder.shown == ["root", "apps"])

    #expect(await ipcSend("hide", to: path)?.ok == true)
    #expect(recorder.hidden == 1)

    #expect(await ipcSend("reload", to: path)?.ok == true)
    #expect(recorder.reloaded == 1)

    // `theme` is the quickest way to see what a config actually resolved, so an
    // unset palette has to say so rather than answering with an empty string.
    #expect(await ipcSend("theme", to: path)?.message == "(no palette)")
    recorder.palette = "kanagawa"
    #expect(await ipcSend("theme", to: path)?.message == "kanagawa")

    #expect(await ipcSend("version", to: path)?.message == "9.9.9 (42)")

    let invoked = await ipcSend("invoke", "system.lock", to: path)
    #expect(invoked?.ok == true)
    #expect(invoked?.message == "ok")
    let missing = await ipcSend("invoke", "nope", to: path)
    #expect(missing?.ok == false)
    #expect(missing?.message == "unknown node")
    // `invoke` with no argument is a miss, not a crash or a root open.
    #expect(await ipcSend("invoke", to: path)?.ok == false)
    #expect(recorder.invoked == ["system.lock", "nope", ""])
}

@MainActor
@Test func ipcRejectsUnknownVerbs() async throws {
    let recorder = CommandRecorder()
    let (server, path, directory) = try startIPCServer(recorder)
    defer { kitsuneRemove(directory); _ = server }

    let response = await ipcSend("frobnicate", "x", to: path)
    #expect(response?.ok == false)
    #expect(response?.message == "unknown command")
    // An unknown verb must not have been dispatched as anything else.
    #expect(recorder.toggled.isEmpty)
    #expect(recorder.shown.isEmpty)
}

@MainActor
@Test func ipcSurvivesMalformedInput() async throws {
    let recorder = CommandRecorder()
    let (server, path, directory) = try startIPCServer(recorder)
    defer { kitsuneRemove(directory); _ = server }

    // Undecodable payloads are dropped with the connection closed and no reply.
    // (A client that connects and sends *nothing* is deliberately not in this list:
    // the server's read blocks until that client goes away, so it would cost the
    // suite a real timeout rather than testing the decode path.)
    for payload in ["not json at all", "{}", "[1,2,3]", "{\"command\":42}"] {
        let raw = await ipcSend(Data(payload.utf8), to: path)
        #expect(raw.isEmpty, "expected no response for \(payload)")
    }
    #expect(recorder.hidden == 0)

    // The listener has to stay up: one bad client cannot take the launcher's only
    // out-of-process control channel down with it.
    #expect(await ipcSend("ping", to: path)?.message == "ok")
}

@MainActor
@Test func ipcSocketIsOwnerOnly() async throws {
    let recorder = CommandRecorder()
    let (server, path, directory) = try startIPCServer(recorder)
    defer { kitsuneRemove(directory); _ = server }

    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    #expect(attributes[.posixPermissions] as? NSNumber == 0o600)
    #expect(attributes[.type] as? FileAttributeType == .typeSocket)
    #expect(attributes[.ownerAccountID] as? NSNumber == NSNumber(value: getuid()))
}

@MainActor
@Test func ipcRebindsOverAStaleSocketFile() async throws {
    let recorder = CommandRecorder()
    let directory = kitsuneTemporaryDirectory("kitsune-ipc")
    defer { kitsuneRemove(directory) }
    let url = directory.appendingPathComponent("kitsune.sock")
    // What a crashed instance leaves behind: bind(2) fails on an existing path, so
    // the server has to unlink first or never come back after a hard exit.
    try Data("stale".utf8).write(to: url)

    let server = IPCServer(socketURL: url)
    server.handler = { request in recorder.commands.handle(request) }
    try server.start()
    defer { _ = server }

    #expect(await ipcSend("ping", to: url.path)?.message == "ok")
}

/// Reads to EOF the way `kitsunectl` now does. The single-read client above is fine
/// for the short verbs, but a `list` reply is tens of kilobytes and neither one
/// `write` nor one `read` is guaranteed to carry it.
private func ipcSendLargeRaw(_ payload: Data, to path: String) -> Data {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return Data() }
    defer { close(descriptor) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return Data() }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
            _ = bytes.withUnsafeBufferPointer { strcpy(destination, $0.baseAddress!) }
        }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return Data() }
    payload.withUnsafeBytes { _ = write(descriptor, $0.baseAddress, payload.count) }

    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        if count > 0 { received.append(contentsOf: buffer.prefix(count)) } else { break }
    }
    return received
}

@MainActor
@Test func ipcDeliversRepliesLargerThanOneBuffer() async throws {
    let directory = kitsuneTemporaryDirectory("kitsune-ipc-big")
    let server = IPCServer(socketURL: directory.appendingPathComponent("kitsune.sock"))
    // 800 rows is the shape of `list apps` on a real machine, and comfortably past
    // both the socket buffer and the 4096 bytes the old client read.
    let rows = (0..<800).map {
        DisplayRow(id: "app:/Applications/App\($0).app", kind: .app, label: "Application \($0)",
                   detail: "/Applications/App\($0).app", symbol: "", image: nil, score: $0, section: "apps")
    }
    server.handler = { request in
        IPCCommands(list: { _, _ in (title: "Apps", rows: rows) }).handle(request)
    }
    try server.start()
    defer { kitsuneRemove(directory); _ = server }

    let payload = try JSONEncoder().encode(IPCRequest(command: "list", argument: "apps"))
    let raw = await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: ipcSendLargeRaw(payload, to: server.socketURL.path)) }
    }
    #expect(raw.count > 4096)

    let response = try? JSONDecoder().decode(IPCResponse.self, from: raw)
    #expect(response?.ok == true)
    let listing = try? JSONDecoder().decode(ListingPayload.self, from: Data(response?.message.utf8 ?? "".utf8))
    // Every row arrives, not just the first bufferful.
    #expect(listing?.rows.count == 800)
    #expect(listing?.rows.last?.label == "Application 799")
}
