import Darwin
import Foundation

/// A private Unix-domain socket in the user's Application Support folder. Directory mode 0700 and
/// a peer-uid check on every connection keep other users out; any process of the same user can
/// drive the helper, exactly as it could run the CLI itself.
enum Socket {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/gifwin", isDirectory: true)
    }
    static var path: String {
        ProcessInfo.processInfo.environment["GIFWIN_SOCKET"] ?? directory.appendingPathComponent("gifwin.sock").path
    }

    private static func address() -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            for (i, b) in bytes.enumerated() { dest[i] = UInt8(bitPattern: b) }
        }
        return addr
    }

    /// Opens a connection, or returns nil when nothing is listening.
    static func connect() -> Int32? {
        guard var addr = address() else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if ok != 0 { close(fd); return nil }
        return fd
    }

    /// Binds and listens. A stale socket file left by a crashed helper is replaced; a live one is an error.
    static func listen() throws -> Int32 {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if let existing = connect() {
            close(existing)
            throw SocketError.alreadyRunning
        }
        unlink(path)
        guard var addr = address() else { throw SocketError.pathTooLong }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.failed("socket") }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(fd); throw SocketError.failed("bind") }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 8) == 0 else { close(fd); throw SocketError.failed("listen") }
        return fd
    }

    static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    /// Reads up to and including the first newline, or to EOF. Capped so a bad client cannot grow it forever.
    static func readLine(_ fd: Int32, limit: Int = 1 << 20) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { return nil }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if buffer[0..<n].contains(10) { break }
        }
        return data.isEmpty ? nil : data
    }

    static func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }
}

enum SocketError: Error {
    case alreadyRunning, pathTooLong
    case failed(String)
}
