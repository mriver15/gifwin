import AppKit
import Carbon.HIToolbox
import Foundation
import GifwinCore

/// The human way in: a menu-bar item and a global hotkey, hosted by the same helper app.
///
/// It is a status readout, not a control panel. While recording it shows the time and the file size so
/// far; otherwise it offers one action, record the front window, and one setting-free way to stop.
/// Opt-in and not resident by default: `gifwin menubar --install` is what makes the helper stay running.
final class MenuBar: NSObject {
    static let shared = MenuBar()

    /// Control-Option-Command-G.
    private static let hotkeyLabel = "\u{2303}\u{2325}\u{2318}G"
    private static let seconds = 5

    private var item: NSStatusItem?
    private let statusLine = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private var recordItem: NSMenuItem?
    private var stopItem: NSMenuItem?
    private var revealItem: NSMenuItem?
    private var timer: Timer?
    private var hotkey: EventHotKeyRef?
    private var recording = false
    private var lastCapture: String?
    private var flash: (text: String, until: Date)?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Gifwin")
        item.button?.imagePosition = .imageLeft

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let record = NSMenuItem(title: "Record front window (\(Self.seconds) s)", action: #selector(recordFront), keyEquivalent: "")
        record.target = self
        let stop = NSMenuItem(title: "Stop and save", action: #selector(stopNow), keyEquivalent: "")
        stop.target = self
        stop.isHidden = true
        let reveal = NSMenuItem(title: "Reveal last capture", action: #selector(revealLast), keyEquivalent: "")
        reveal.target = self
        reveal.isHidden = true
        for m in [record, stop, reveal] { menu.addItem(m) }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Hotkey: \(Self.hotkeyLabel)", action: nil, keyEquivalent: ""))
        menu.items.last?.isEnabled = false
        menu.addItem(NSMenuItem(title: "Quit Gifwin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        (recordItem, stopItem, revealItem) = (record, stop, reveal)
        self.item = item

        let hotkeyResult = registerHotkey()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        writeState(hotkey: hotkeyResult)
    }

    // MARK: - Hotkey

    /// Carbon's hotkey API needs no Accessibility permission, which is why it is used.
    private func registerHotkey() -> OSStatus {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { MenuBar.shared.recordFront() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4746_494E), id: 1) // 'GFIN'
        return RegisterEventHotKey(UInt32(kVK_ANSI_G), UInt32(cmdKey | optionKey | controlKey), id,
                                   GetApplicationEventTarget(), 0, &hotkey)
    }

    // MARK: - Actions

    @objc func recordFront() {
        guard !recording else { return }
        guard let windowID = Self.frontWindowID() else {
            show("No window to record")
            return
        }
        recording = true
        refresh()
        let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Gifwin").path
        let request = Request(args: ["--json", "--window", "id:\(windowID)", "--seconds", String(Self.seconds), "--out", out, "--clipboard"],
                              cwd: out, env: [:], caller: "menubar")
        Task {
            var resident = request
            resident.env["GIFWIN_RESIDENT"] = "1"
            let outcome = await Command.run(resident)
            if let path = outcome.clipboardPath { Clipboard.copy(path: path) }
            let json = (try? JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8))) as? [String: Any]
            await MainActor.run {
                self.recording = false
                if outcome.code == 0 || outcome.code == ExitCode.windowClosed.rawValue, let path = json?["path"] as? String {
                    self.lastCapture = path
                    let kb = (json?["bytes"] as? Int ?? 0) / 1024
                    self.show("Copied \(kb) KB")
                } else {
                    self.show((json?["message"] as? String).map { String($0.prefix(60)) } ?? "Failed (\(outcome.code))")
                }
                self.refresh()
            }
        }
    }

    @objc private func stopNow() { CaptureProgress.requestStop() }

    @objc private func revealLast() {
        guard let path = lastCapture else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func show(_ text: String) { flash = (text, Date().addingTimeInterval(4)) }

    // MARK: - Display

    private func refresh() {
        if let live = CaptureProgress.current {
            let text = String(format: "%.1f s \u{00B7} %d KB", live.seconds, live.bytes / 1024)
            item?.button?.title = " " + text
            item?.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            statusLine.title = "Recording \(text)"
            stopItem?.isHidden = false
            recordItem?.isHidden = true
        } else {
            item?.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Gifwin")
            if let flash, flash.until > Date() {
                item?.button?.title = " " + flash.text
                statusLine.title = flash.text
            } else {
                flash = nil
                item?.button?.title = ""
                statusLine.title = recording ? "Starting\u{2026}" : "Idle"
            }
            stopItem?.isHidden = true
            recordItem?.isHidden = recording
        }
        revealItem?.isHidden = lastCapture == nil
    }

    /// The front-most ordinary window of the front-most app, by window server order.
    static func frontWindowID() -> UInt32? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for w in list {   // ordered front to back
            guard (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Double], (b["Width"] ?? 0) >= 100, (b["Height"] ?? 0) >= 60,
                  let id = w[kCGWindowNumber as String] as? UInt32 else { continue }
            return id
        }
        return nil
    }

    // MARK: - State file

    /// Lets `gifwin doctor` say whether the menu bar and hotkey are really up, which nothing else can see.
    static var stateURL: URL { Socket.directory.appendingPathComponent("menubar.json") }

    private func writeState(hotkey status: OSStatus) {
        let state: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier), "hotkey": Self.hotkeyLabel,
                                    "hotkey_registered": status == noErr, "hotkey_status": Int(status)]
        try? FileManager.default.createDirectory(at: Socket.directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) { try? data.write(to: Self.stateURL) }
    }
}

/// `gifwin menubar --install | --uninstall | --status`: a LaunchAgent that starts the helper with the menu bar at login.
enum MenuBarAgent {
    static let label = "io.github.mriver15.gifwin.menubar"
    static var plistURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist") }

    static func run(_ args: [String], bundle: String?) -> (code: Int32, text: String) {
        switch args.first {
        case "--install":
            guard let bundle else { return (70, "gifwin: Gifwin.app not found. Run scripts/bundle.sh --install first.\n") }
            // LaunchServices starts it, so the app is its own responsible process and keeps its Screen Recording grant.
            let plist: [String: Any] = ["Label": label, "RunAtLoad": true,
                                        "ProgramArguments": ["/usr/bin/open", "-g", "-j", "-a", bundle, "--args", "--serve", "--menubar"]]
            do {
                try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
            } catch { return (73, "gifwin: cannot write \(plistURL.path): \(error.localizedDescription)\n") }
            _ = launchctl(["bootout", domain, plistURL.path])   // replace a previous one quietly
            let r = launchctl(["bootstrap", domain, plistURL.path])
            return r.code == 0 ? (0, "menu bar installed: it starts at login and is running now\nremove with: gifwin menubar --uninstall\n")
                               : (70, "gifwin: launchctl failed: \(r.output)\n")
        case "--uninstall":
            _ = launchctl(["bootout", domain, plistURL.path])
            try? FileManager.default.removeItem(at: plistURL)
            try? FileManager.default.removeItem(at: MenuBar.stateURL)
            return (0, "menu bar removed\n")
        case "--status", nil:
            let installed = FileManager.default.fileExists(atPath: plistURL.path)
            var text = "login item: \(installed ? "installed" : "not installed")\n"
            if let data = try? Data(contentsOf: MenuBar.stateURL),
               let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let pid = s["pid"] as? Int, kill(pid_t(pid), 0) == 0 {
                text += "running: pid \(pid), hotkey \(s["hotkey"] ?? "") \((s["hotkey_registered"] as? Bool) == true ? "registered" : "NOT registered (status \(s["hotkey_status"] ?? "?"))")\n"
            } else {
                text += "running: no\n"
            }
            return (0, text)
        default:
            return (64, "usage: gifwin menubar --install | --uninstall | --status\n")
        }
    }

    private static var domain: String { "gui/\(getuid())" }

    private static func launchctl(_ args: [String]) -> (code: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (1, "could not run launchctl") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
