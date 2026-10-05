import Foundation
import MuxbarCore

/// Local control socket (`~/.muxbar/ctl.sock`, mode 0600) so `Muxbar --cli` drives the running
/// app's SessionStore — the same code the UI uses. One JSON request line in, one JSON line out.
final class ControlServer: @unchecked Sendable {
    private let path: String
    private var fd: Int32 = -1
    private let handler: @Sendable ([String: Any]) async -> [String: Any]

    init(path: String = MuxbarPaths.ipcSocket, handler: @escaping @Sendable ([String: Any]) async -> [String: Any]) {
        self.path = path
        self.handler = handler
    }

    func start() {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { Log.error("control socket: socket() failed \(errno)"); return }
        // Built-in terminal panes fork child processes; they must not inherit our sockets, or a
        // client never sees EOF while that pane runs.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Log.error("control socket path too long: \(path)"); return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard ok == 0 else { Log.error("control socket: bind failed \(errno)"); return }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { Log.error("control socket: listen failed \(errno)"); return }
        let listenFD = fd
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(listenFD, nil, nil)
                if c < 0 { if errno == EINTR { continue }; Log.error("control socket: accept failed \(errno)"); return }
                _ = fcntl(c, F_SETFD, FD_CLOEXEC)
                Thread.detachNewThread { self.serve(c) }
            }
        }
        Log.info("control socket listening at \(path)")
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0A) {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        let line = data.split(separator: 0x0A).first.map { Data($0) } ?? Data()
        let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
        let sem = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        Task {
            box.value = await handler(req)
            sem.signal()
        }
        sem.wait()
        var out = (try? JSONSerialization.data(withJSONObject: box.value, options: [.sortedKeys]))
            ?? Data("{\"ok\":false,\"error\":\"encode failed\"}".utf8)
        out.append(0x0A)
        out.withUnsafeBytes { p in _ = write(c, p.baseAddress, out.count) }
    }

    func stop() {
        if fd >= 0 { close(fd) }
        unlink(path)
    }
}

private final class ResponseBox: @unchecked Sendable {
    var value: [String: Any] = [:]
}

/// Client side used by `--cli`.
enum ControlClient {
    static func send(_ req: [String: Any], path: String = MuxbarPaths.ipcSocket) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StoreError("socket() failed") }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard rc == 0 else {
            throw StoreError("Muxbar isn't running. Start it with: open ~/Applications/Muxbar.app")
        }
        var payload = try JSONSerialization.data(withJSONObject: req)
        payload.append(0x0A)
        payload.withUnsafeBytes { p in _ = write(fd, p.baseAddress, payload.count) }
        // The reply is one JSON line; stop at the newline rather than waiting for EOF.
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while !data.contains(0x0A) {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        let line = data.split(separator: 0x0A).first.map { Data($0) } ?? data
        guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw StoreError("Bad response from Muxbar")
        }
        return obj
    }
}
