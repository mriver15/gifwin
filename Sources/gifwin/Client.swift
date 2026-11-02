import Darwin
import Foundation
import GifwinCore

/// The `gifwin` a user types. It never records anything itself: it finds Gifwin.app, makes sure its
/// helper is running, hands over the request and relays the answer, so the Screen Recording grant
/// belongs to one stable app however the command was invoked.
enum Client {
    static func run(_ args: [String]) async -> Int32 {
        var args = args
        let direct = args.contains("--direct") || ProcessInfo.processInfo.environment["GIFWIN_DIRECT"] == "1"
        args.removeAll { $0 == "--direct" }
        let request = Request(op: args == ["quit"] ? "quit" : "run", args: args,
                              cwd: FileManager.default.currentDirectoryPath, env: forwardedEnvironment())
        let outcome = await dispatch(request, direct: direct)
        let bundle = direct ? nil : bundlePath()
        return emit(outcome, prefix: args == ["doctor"] ? bundle.map { "app: \($0)\n" } ?? "" : "")
    }

    static func forwardedEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        for key in Request.forwardedEnvironment {
            if let v = ProcessInfo.processInfo.environment[key] { env[key] = v }
        }
        return env
    }

    /// Runs a request in the Gifwin.app helper, or in this process when asked to or when no app is
    /// installed. Failures to reach the helper come back as an `Outcome`, never a crash, so the CLI and
    /// the MCP server report them the same way.
    static func dispatch(_ request: Request, direct: Bool = false) async -> Outcome {
        if direct { return await runLocally(request) }
        guard let bundle = bundlePath() else {
            var outcome = await runLocally(request)
            if request.op != "quit" {
                outcome.stderr = "gifwin: Gifwin.app not found, capturing in this process: Screen Recording will attach to your terminal. Run scripts/bundle.sh --install.\n" + outcome.stderr
            }
            return outcome
        }
        guard let fd = connectOrLaunch(bundle: bundle, launch: request.op != "quit") else {
            var outcome = Outcome()
            if request.op != "quit" {
                outcome.code = ExitCode.internalFailure.rawValue
                outcome.stderr = "gifwin: could not start the Gifwin helper from \(bundle)\n"
            }
            return outcome
        }
        defer { close(fd) }
        var failed = Outcome()
        failed.code = ExitCode.internalFailure.rawValue
        guard let payload = try? JSONEncoder().encode(request) else { return failed }
        Socket.writeAll(fd, payload + Data([10]))
        shutdown(fd, SHUT_WR)
        guard let outcome = try? JSONDecoder().decode(Outcome.self, from: Socket.readAll(fd)) else {
            failed.stderr = "gifwin: the Gifwin helper closed the connection without an answer\n"
            return failed
        }
        return outcome
    }

    private static func runLocally(_ request: Request) async -> Outcome {
        if request.op == "quit" { return Outcome() }
        let outcome = await Command.run(request)
        if let path = outcome.clipboardPath { Clipboard.copy(path: path) }
        return outcome
    }

    private static func emit(_ outcome: Outcome, prefix: String = "") -> Int32 {
        FileHandle.standardOutput.write(Data((prefix + outcome.stdout).utf8))
        FileHandle.standardError.write(Data(outcome.stderr.utf8))
        return outcome.code
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("gifwin: \(message)\n".utf8))
    }

    // MARK: - Finding and starting the helper

    /// The Gifwin.app this binary belongs to or, failing that, an installed one.
    static func bundlePath() -> String? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) == 0, let real = realpath(buffer, nil) {
            defer { free(real) }
            // <name>.app/Contents/MacOS/gifwin
            let app = URL(fileURLWithPath: String(cString: real)).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if app.pathExtension == "app" { return app.path }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [ProcessInfo.processInfo.environment["GIFWIN_APP"], "\(home)/Applications/Gifwin.app", "/Applications/Gifwin.app"]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func connectOrLaunch(bundle: String, launch: Bool) -> Int32? {
        if let fd = Socket.connect() { return fd }
        guard launch else { return nil }
        // LaunchServices, not a child process: that is what makes the app its own responsible process.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-j", "-a", bundle, "--args", "--serve"]
        guard (try? open.run()) != nil else { return nil }
        open.waitUntilExit()
        for _ in 0..<100 {
            if let fd = Socket.connect() { return fd }
            usleep(100_000)
        }
        return nil
    }
}
