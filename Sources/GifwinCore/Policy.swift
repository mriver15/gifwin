import Foundation

/// Where Gifwin keeps its configuration and its record of what it did. The directories can be moved with
/// `GIFWIN_CONFIG_DIR` and `GIFWIN_STATE_DIR`, which is how the tests stay out of a real home directory.
public enum Paths {
    public static func config(_ env: [String: String] = [:]) -> URL {
        if let dir = env["GIFWIN_CONFIG_DIR"] ?? ProcessInfo.processInfo.environment["GIFWIN_CONFIG_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/gifwin", isDirectory: true)
    }
    public static func state(_ env: [String: String] = [:]) -> URL {
        if let dir = env["GIFWIN_STATE_DIR"] ?? ProcessInfo.processInfo.environment["GIFWIN_STATE_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/gifwin", isDirectory: true)
    }
}

/// What an agent may record. A tool that lets a language model capture any window on command is an
/// exfiltration primitive: a prompt injection on a web page could steer it at a password manager.
/// So an agent starts from "no" for sensitive apps and from "ask first" for everything else.
public struct Policy: Sendable, Equatable {
    /// Bundle ids an agent may record without asking.
    public var allow: Set<String> = []
    /// Bundle ids that are never recorded, on top of the built-in list.
    public var deny: Set<String> = []
    public var consentHours = 24.0

    public init() {}

    /// Password managers, key stores, messaging and mail: apps whose windows are secrets by nature.
    public static let builtinDeny: Set<String> = [
        "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.MobileSMS", "com.apple.mail",
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx", "com.bitwarden.desktop",
        "org.keepassxc.keepassxc", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "com.authy.authy-mac",
        "com.yubico.yubioath", "com.apple.FaceTime", "com.tinyspeck.slackmacgap.inbox",
    ]

    /// Browser windows that announce they are private.
    public static let privateTitleMarkers = ["private browsing", "(incognito)", "incognito", "inprivate", "private window"]

    public static func isPrivateWindow(title: String) -> Bool {
        let t = title.lowercased()
        return privateTitleMarkers.contains { t.contains($0) }
    }

    /// Reads `policy.toml`. A missing file is the default policy; an unreadable one is an error the
    /// caller must treat as "refuse", never as "allow everything".
    public static func load(env: [String: String] = [:]) -> (policy: Policy, error: String?) {
        let url = Paths.config(env).appendingPathComponent("policy.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (Policy(), nil) }
        do {
            let table = try TOML.parse(text)
            var p = Policy()
            let agent = table["agent"] ?? [:]
            if let a = agent["allow"] { p.allow = Set(try a.strings("agent.allow")) }
            if let d = agent["deny"] { p.deny = Set(try d.strings("agent.deny")) }
            if let h = agent["consent_hours"] { p.consentHours = try h.number("agent.consent_hours") }
            return (p, nil)
        } catch {
            return (Policy(), "policy.toml: \(error)")
        }
    }
}

public enum Decision: Equatable, Sendable {
    case allow
    case deny(String)
    case needsConsent(String)
}

public enum PolicyGate {
    /// - Parameters:
    ///   - caller: `mcp` is an agent and gets the strict rules; `cli` and `menubar` are the person at the keyboard.
    ///   - force: lets the person override the sensitive-app list from a terminal. Never honoured for `mcp`.
    public static func decide(caller: String, force: Bool, bundleID: String, title: String,
                              policy: Policy, consent: Consent, now: Date = Date()) -> Decision {
        let sensitive = Policy.builtinDeny.contains(bundleID) || policy.deny.contains(bundleID)
        let priv = Policy.isPrivateWindow(title: title)
        let agent = caller == "mcp"

        if sensitive || priv {
            if !agent && force { return .allow }
            let why = sensitive ? "\(bundleID) is on the list of apps that are never recorded" : "this looks like a private browser window"
            return .deny(agent ? why + "; agents cannot override this" : why + "; pass --force to record it anyway")
        }
        guard agent else { return .allow }
        if policy.allow.contains(bundleID) || consent.isValid(bundleID, now: now) { return .allow }
        return .needsConsent(bundleID)
    }
}

/// Per-app consent with an expiry, so "yes, you may record Terminal" is not forever.
public struct Consent: Sendable {
    var expiry: [String: Date]

    public init(expiry: [String: Date] = [:]) { self.expiry = expiry }

    public func isValid(_ bundleID: String, now: Date = Date()) -> Bool { (expiry[bundleID] ?? .distantPast) > now }
    public var entries: [(bundleID: String, expires: Date)] { expiry.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 } }

    public static func url(_ env: [String: String]) -> URL { Paths.config(env).appendingPathComponent("consent.json") }

    public static func load(env: [String: String] = [:]) -> Consent {
        guard let data = try? Data(contentsOf: url(env)),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return Consent() }
        let f = ISO8601DateFormatter()
        return Consent(expiry: raw.compactMapValues { f.date(from: $0) })
    }

    public func save(env: [String: String] = [:]) throws {
        let f = ISO8601DateFormatter()
        let dir = Paths.config(env)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: expiry.mapValues { f.string(from: $0) }, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Consent.url(env), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Consent.url(env).path)
    }

    public mutating func grant(_ bundleID: String, hours: Double, now: Date = Date()) {
        expiry[bundleID] = now.addingTimeInterval(hours * 3600)
    }
    public mutating func revoke(_ bundleID: String) { expiry[bundleID] = nil }
}

// MARK: - A deliberately small TOML reader

/// The subset `policy.toml` needs: `[tables]`, `key = "string" | number | true | ["a", "b"]`, comments.
/// Anything outside it is an error, not silently ignored, because a policy that half-parses is a policy
/// that quietly does not apply.
enum TOML {
    enum Value {
        case string(String), number(Double), bool(Bool), array([Value])

        func strings(_ key: String) throws -> [String] {
            guard case .array(let items) = self else { throw TOMLError("\(key) must be a list of strings") }
            return try items.map { if case .string(let s) = $0 { return s } else { throw TOMLError("\(key) must contain only strings") } }
        }
        func number(_ key: String) throws -> Double {
            if case .number(let n) = self { return n }
            throw TOMLError("\(key) must be a number")
        }
    }
    struct TOMLError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    static func parse(_ text: String) throws -> [String: [String: Value]] {
        var tables: [String: [String: Value]] = ["": [:]]
        var current = ""
        var pending: (key: String, text: String)?
        for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = stripComment(String(raw)).trimmingCharacters(in: .whitespaces)
            if var p = pending {            // a list continuing over several lines
                p.text += " " + line
                if line.contains("]") { tables[current, default: [:]][p.key] = try value(p.text, n + 1); pending = nil } else { pending = p }
                continue
            }
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") && !line.contains("=") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                tables[current, default: [:]] = tables[current] ?? [:]
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { throw TOMLError("line \(n + 1): expected key = value") }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw TOMLError("line \(n + 1): missing key") }
            if rest.hasPrefix("[") && !rest.contains("]") { pending = (key, rest); continue }
            tables[current, default: [:]][key] = try value(rest, n + 1)
        }
        if let p = pending { throw TOMLError("list for '\(p.key)' is never closed") }
        return tables
    }

    private static func stripComment(_ line: String) -> String {
        var inString = false
        for (i, c) in line.enumerated() {
            if c == "\"" { inString.toggle() }
            if c == "#" && !inString { return String(line.prefix(i)) }
        }
        return line
    }

    private static func value(_ text: String, _ line: Int) throws -> Value {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[") && t.hasSuffix("]") {
            let inner = t.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .array([]) }
            return .array(try inner.split(separator: ",").map { try value(String($0), line) })
        }
        if t.count >= 2 && t.hasPrefix("\"") && t.hasSuffix("\"") { return .string(String(t.dropFirst().dropLast())) }
        if t == "true" { return .bool(true) }
        if t == "false" { return .bool(false) }
        if let n = Double(t) { return .number(n) }
        throw TOMLError("line \(line): cannot read value '\(t)'")
    }
}
