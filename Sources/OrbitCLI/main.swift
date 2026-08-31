import Foundation
import Darwin

struct Request: Codable { let command: String; let argument: String? }
struct Response: Codable { let ok: Bool; let message: String }

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--help" || arguments.first == "help" {
    print("Usage: orbitctl [toggle|show|hide|invoke|reload|theme|ping] [route-or-node]")
    exit(0)
}
let request = Request(command: arguments.first ?? "toggle", argument: arguments.dropFirst().first)
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
var buffer = [UInt8](repeating: 0, count: 4096)
let count = read(descriptor, &buffer, buffer.count)
guard count > 0, let response = try? JSONDecoder().decode(Response.self, from: Data(buffer.prefix(count))) else { fputs("orbitctl: invalid response\n", stderr); exit(1) }
print(response.message)
exit(response.ok ? 0 : 1)
