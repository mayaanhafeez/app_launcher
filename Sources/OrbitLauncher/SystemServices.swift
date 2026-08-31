import AppKit
import Carbon
import Darwin

@MainActor
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in owner.action?() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x4f524254), id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &reference)
    }
}

final class ConfigWatcher: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "orbit.config-watch")
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    var onChange: (() -> Void)?

    init(directory: URL) { self.directory = directory }

    func start() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { throw RuntimeError.message("Unable to watch config directory") }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.onChange?() }
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        self.source = source
        source.resume()
    }
}

struct IPCRequest: Codable { let command: String; let argument: String? }
struct IPCResponse: Codable { let ok: Bool; let message: String }

final class IPCServer: @unchecked Sendable {
    let socketURL: URL
    private let queue = DispatchQueue(label: "orbit.ipc")
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
                if let data = try? JSONEncoder().encode(response) { data.withUnsafeBytes { _ = write(client, $0.baseAddress, data.count) } }
            }
        }
    }
}
