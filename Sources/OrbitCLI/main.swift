import Foundation
import Darwin

struct Request: Codable { let command: String; let argument: String? }
struct Response: Codable { let ok: Bool; let message: String }

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--help" || arguments.first == "help" {
    print("Usage: orbitctl [toggle|show|hide|invoke|list|reload|theme|version|ping] [route-or-node] [query...]")
    print("       orbitctl list apps            # rows the apps menu would show, as JSON")
    print("       orbitctl list root chrome     # rows for a query at the top level")
    exit(0)
}
// Joined rather than taking only the first: `list <route> <query…>` needs the tail,
// and joining a single argument leaves every other verb exactly as it was.
let argument = arguments.dropFirst().joined(separator: " ")
let request = Request(command: arguments.first ?? "toggle", argument: argument.isEmpty ? nil : argument)
let socketPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.orbit.launcher/Data/tmp/orbit.sock").path
let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
guard descriptor >= 0 else { fputs("orbitctl: socket failed\n", stderr); exit(1) }
defer { close(descriptor) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let bytes = socketPath.utf8CString
guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { fputs("orbitctl: socket path too long\n", stderr); exit(1) }
withUnsafeMutablePointer(to: &address.sun_path) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in _ = bytes.withUnsafeBufferPointer { strcpy(destination, $0.baseAddress!) } } }
let connected = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
guard connected == 0 else { fputs("orbitctl: OrbitLauncher is not running\n", stderr); exit(1) }
let data = try JSONEncoder().encode(request)
data.withUnsafeBytes { _ = write(descriptor, $0.baseAddress, data.count) }
// Read to EOF rather than once into a fixed buffer: the host closes the connection
// after replying, and a `list` response runs to tens of kilobytes. A single read
// would hand the decoder a truncated document.
var payload = Data()
var buffer = [UInt8](repeating: 0, count: 16_384)
while true {
    let count = read(descriptor, &buffer, buffer.count)
    if count > 0 { payload.append(contentsOf: buffer.prefix(count)) } else { break }
}
guard !payload.isEmpty, let response = try? JSONDecoder().decode(Response.self, from: payload) else { fputs("orbitctl: invalid response\n", stderr); exit(1) }
print(response.message)
exit(response.ok ? 0 : 1)
