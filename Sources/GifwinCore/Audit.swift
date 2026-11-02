import Darwin
import Foundation

/// An append-only record of everything Gifwin was asked to record: who asked, of what, and what happened,
/// including requests that were refused. It is local, one JSON object per line, and Gifwin never rewrites it.
///
/// The file carries the user-append flag, so even a bug in Gifwin cannot truncate it; removing it takes an
/// explicit `chflags nouappnd`. Lines are written with a single `write` in append mode, which keeps
/// concurrent captures from interleaving.
public enum Audit {
    public struct Entry: Sendable {
        public var op = ""                  // capture | watch_start | save_last | list_text
        public var phase = "result"         // start | result | refused
        public var caller = "cli"
        public var decision = "allowed"
        public var bundleID = ""
        public var app = ""
        public var windowTitle = ""
        public var seconds: Double?
        public var out: String?
        public var code: Int32?
        public var error: String?
        public var bytes: Int?
        public var sha256: String?
        public init() {}
    }

    public static func url(_ env: [String: String] = [:]) -> URL { Paths.state(env).appendingPathComponent("log.jsonl") }

    public static func write(_ e: Entry, env: [String: String] = [:]) {
        var obj: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "op": e.op, "phase": e.phase,
                                  "caller": e.caller, "decision": e.decision, "pid": Int(getpid())]
        if !e.bundleID.isEmpty { obj["bundle_id"] = e.bundleID }
        if !e.app.isEmpty { obj["app"] = e.app }
        if !e.windowTitle.isEmpty { obj["window_title"] = e.windowTitle }
        if let v = e.seconds { obj["seconds"] = v }
        if let v = e.out { obj["out"] = v }
        if let v = e.code { obj["code"] = Int(v) }
        if let v = e.error { obj["error"] = v }
        if let v = e.bytes { obj["bytes"] = v }
        if let v = e.sha256 { obj["sha256"] = v }
        guard var line = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        line.append(10)

        let file = url(env)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        // Set once the file exists; harmless to repeat.
        _ = chflags(file.path, UInt32(UF_APPEND))
    }

    /// The last `count` entries, oldest first.
    public static func tail(_ count: Int, env: [String: String] = [:]) -> [String] {
        guard let text = try? String(contentsOf: url(env), encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(count).map(String.init))
    }
}
