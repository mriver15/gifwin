import AppKit
import Foundation
import GifwinCore

/// The helper: runs inside Gifwin.app, so macOS attributes Screen Recording to the app and not to
/// whichever shell or agent asked for the capture. Nothing stays resident between uses; it exits
/// after `idleSeconds` with no work.
enum Server {
    static var idleSeconds: Double {
        ProcessInfo.processInfo.environment["GIFWIN_IDLE"].flatMap(Double.init) ?? 30
    }

    private static let lock = NSLock()
    private static var busy = 0
    private static var lastActivity = Date()

    static func run() -> Never {
        let listener: Int32
        do {
            listener = try Socket.listen()
        } catch SocketError.alreadyRunning {
            exit(0) // another helper is serving; nothing to do
        } catch {
            FileHandle.standardError.write(Data("gifwin helper: cannot listen: \(error)\n".utf8))
            exit(70)
        }

        // An accessory app has no Dock icon or menu, but is a proper app to LaunchServices and TCC.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { continue }
                Task.detached { await handle(client) }
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler {
            lock.lock()
            let idle = busy == 0 && Date().timeIntervalSince(lastActivity) >= idleSeconds
            lock.unlock()
            if idle { shutdown() }
        }
        timer.resume()

        app.run()
        exit(0)
    }

    private static func shutdown() -> Never {
        unlink(Socket.path)
        exit(0)
    }

    private static func touch(_ delta: Int) {
        lock.lock()
        busy += delta
        lastActivity = Date()
        lock.unlock()
    }

    private static func handle(_ fd: Int32) async {
        touch(1)
        defer { close(fd); touch(-1) }
        guard Socket.peerIsCurrentUser(fd), let line = Socket.readLine(fd),
              let request = try? JSONDecoder().decode(Request.self, from: line) else { return }

        if request.op == "quit" {
            Socket.writeAll(fd, (try? JSONEncoder().encode(Outcome())) ?? Data())
            shutdown()
        }

        let outcome = await Command.run(request)
        if let path = outcome.clipboardPath { Clipboard.copy(path: path) }
        Socket.writeAll(fd, (try? JSONEncoder().encode(outcome)) ?? Data())
    }
}
