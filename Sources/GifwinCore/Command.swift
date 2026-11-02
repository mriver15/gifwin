import CoreGraphics
import Foundation

/// A CLI invocation, shipped from the thin client to whichever process will capture.
public struct Request: Codable, Sendable {
    /// `run` executes `args`; `quit` asks a helper to exit.
    public var op: String
    public var args: [String]
    /// The caller's working directory: a relative `--out` means relative to this, not to the helper's.
    public var cwd: String
    /// Only the variables the command reads (`GIFWIN_OUT`, `GIFWIN_FAULT`), never the whole environment.
    public var env: [String: String]
    /// Who is asking: `cli` (a person in a terminal), `mcp` (an agent) or `menubar`. Agents get the strict policy.
    public var caller: String?

    public init(op: String = "run", args: [String] = [], cwd: String = "", env: [String: String] = [:], caller: String? = nil) {
        self.op = op
        self.args = args
        self.cwd = cwd
        self.env = env
        self.caller = caller
    }

    public static let forwardedEnvironment = ["GIFWIN_OUT", "GIFWIN_FAULT", "GIFWIN_CONFIG_DIR", "GIFWIN_STATE_DIR", "GIFWIN_FFMPEG"]
}

/// What a command produced. Output is collected rather than printed so the same code can run in a
/// helper process and have its result relayed to the client's terminal unchanged.
public struct Outcome: Codable, Sendable {
    public var code: Int32 = 0
    public var stdout = ""
    public var stderr = ""
    /// Set when `--clipboard` was given and the capture succeeded.
    public var clipboardPath: String?

    public init() {}
}

public enum Command {
    public static let version = "0.2.0"

    public static let usage = """
    usage: gifwin [seconds] --window <selector> [options]
           gifwin watch --window <selector> [--rolling 30]   keep the last N seconds of a window
           gifwin watch --status | --stop [--window <selector>]
           gifwin save-last [seconds] [--window <selector>] [options]
           gifwin describe <file.gif> [--json] [--no-ai]
           gifwin consent grant|revoke <bundle-id> | consent list
           gifwin log [--tail N]
           gifwin menubar --install | --uninstall | --status
           gifwin bench [--seconds N] [--size WxH] [--quality Q]   measure the encoder on a synthetic window
           gifwin doctor | quit | mcp

      -w, --window <selector>   <app name> | <bundle-id> | id:<n> | title~<text>
                                text:<words> (on-screen text) | ask:<words> (best match)
      -s, --seconds <float>     default 5
      -q, --quality <preset>    draft | balanced | crisp | max   (default balanced)
          --colors <2-256>      override the preset's palette size
          --fps <rate>          10 | 12.5 | 16.67 | 20
          --scale <px>          cap on the long edge, in pixels
          --max-bytes <n>       degrade quality until the file fits (accepts 500k, 2m)
      -o, --out <dir>           default $GIFWIN_OUT, else the current directory
          --name <file>         default "<app>-<yyyyMMdd-HHmmss>.gif"
          --until <condition>   stop early: text:<words> | quiet:<seconds> | change (seconds is then the longest)
          --after <seconds>     keep recording this long after --until is met (default 1)
          --redact <auto|none>  blank credentials and personal data out of the pixels while recording
          --format <fmt>        gif (default) | mp4 | webm (needs ffmpeg; the MP4 is kept if it is missing)
          --trim <auto|none>    cap still footage at the start and end (default auto)
          --no-ai               skip OCR and the caption model; the sheet and manifest are still written
          --no-sidecar          write only the GIF, no contact sheet or manifest
          --force               record an app on the never-record list (people only, never agents)
          --clipboard           put the finished file on the pasteboard
          --list                print capturable windows and exit (--ocr adds what each shows)
          --dry-run             resolve the window, print the plan, capture nothing
          --json                machine-readable result on stdout
          --direct              capture in this process instead of through Gifwin.app
          --version

    exit codes: 0 ok, 64 usage, 65 no or ambiguous window, 69 Screen Recording not granted,
                70 internal, 73 output unwritable, 74 window closed (partial file kept),
                75 byte budget unreachable (smallest file kept),
                77 refused by policy: a sensitive app, or an agent without consent
    """

    struct Options {
        var seconds = 5.0
        var window: String?
        var quality = Quality.balanced
        var colors: Int?
        var fps: Double?
        var scale: Int?
        var maxBytes: Int?
        var out: String?
        var name: String?
        var clipboard = false
        var trim = true
        var redact = false
        var format = OutputFormat.gif
        var rolling = 30.0
        var stop = false
        var status = false
        var until: StopCondition?
        var after = 1.0
        var noAI = false
        var force = false
        var noSidecar = false
        var ocr = false
        var list = false
        var dryRun = false
        var json = false
        var version = false
    }

    // MARK: - Entry point

    public static func run(_ request: Request) async -> Outcome {
        var out = Outcome()
        let json = request.args.contains("--json")
        let state = AuditState()
        do {
            try await execute(request, &out, state)
        } catch {
            fail(error, json: json, &out)
        }
        // A capture that began gets a closing line whatever happened, so the log never shows a start with no end.
        if state.started, var entry = state.entry {
            entry.phase = "result"
            entry.code = out.code
            if let r = state.result {
                entry.bytes = r.bytes
                entry.sha256 = r.sha256
                entry.out = r.path
            }
            if out.code != 0 && out.code != ExitCode.windowClosed.rawValue && out.code != ExitCode.budgetUnreachable.rawValue {
                entry.error = (ExitCode(rawValue: out.code)?.slug) ?? "error"
            }
            Audit.write(entry, env: request.env)
        }
        return out
    }

    /// What `execute` tells `run` about a capture it began, for the audit log.
    final class AuditState {
        var entry: Audit.Entry?
        var started = false
        var result: (bytes: Int, sha256: String, path: String)?
    }

    private static func execute(_ req: Request, _ out: inout Outcome, _ audit: AuditState) async throws {
        if req.args == ["doctor"] {
            doctor(&out)
            return
        }
        if req.args.first == "bench" {
            try await bench(req, &out)
            return
        }
        if req.args.first == "consent" || req.args.first == "log" {
            try admin(req, &out)
            return
        }
        if req.args.first == "watch" || req.args.first == "save-last" {
            try await watching(req, &out, audit)
            return
        }
        if req.args.first == "describe" {
            try await describe(req, &out)
            return
        }
        let o = try parse(req.args)
        if o.version {
            out.stdout += "gifwin \(version)\n"
            return
        }

        // Test hooks: let every exit code be reached without arranging the real failure.
        if let fault = req.env["GIFWIN_FAULT"], fault.hasPrefix("fake-window:") {
            // Test hook: pretend this window exists, so policy and audit run without Screen Recording.
            let parts = fault.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            let info = WindowInfo(id: 1, app: parts.count > 1 ? parts[1] : "Fake", bundleID: parts.count > 1 ? parts[1] : "fake",
                                  pid: 0, title: parts.count > 2 ? parts[2] : "", width: 800, height: 600)
            guard o.window != nil else { throw GifwinError(.usage, "missing --window\n\n\(usage)") }
            let path = URL(fileURLWithPath: req.cwd.isEmpty ? "/tmp" : req.cwd).appendingPathComponent("fake.gif")
            var entry = try authorize(info, o, req, path: path, audit)
            if o.dryRun {
                out.stdout += o.json ? try jsonString(["window_id": 1, "app": info.app, "allowed": true] as [String: Any]) : "allowed: \(info.app)\n"
                return
            }
            entry.phase = "start"
            Audit.write(entry, env: req.env)
            audit.entry = entry
            audit.started = true
            throw GifwinError(.internalFailure, "The fake window passed the policy but cannot be recorded.")
        }
        if let fault = req.env["GIFWIN_FAULT"] {
            switch fault {
            case "tcc": throw GifwinError.permission("Screen Recording permission is not granted (simulated).")
            case "internal": throw GifwinError(.internalFailure, "Simulated internal failure.")
            case "window-closed": throw GifwinError(.windowClosed, "The window closed during capture (simulated).")
            default: throw GifwinError(.usage, "unknown GIFWIN_FAULT '\(fault)'")
            }
        }

        // Usage errors come before anything that needs a permission, so they report as usage.
        if o.maxBytes != nil && o.format != .gif { throw GifwinError(.usage, "--max-bytes only applies to --format gif") }
        if !o.list && o.window == nil { throw GifwinError(.usage, "missing --window\n\n\(usage)") }

        let base = URL(fileURLWithPath: req.cwd.isEmpty ? FileManager.default.currentDirectoryPath : req.cwd, isDirectory: true)
        let dir: URL
        if let path = o.out ?? req.env["GIFWIN_OUT"] {
            dir = URL(fileURLWithPath: path, isDirectory: true, relativeTo: base).standardizedFileURL
        } else {
            dir = base
        }

        // Fail on an unwritable destination before spending a capture on it.
        if !o.list && !o.dryRun {
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { throw GifwinError(.outputUnwritable, "Cannot create \(dir.path): \(error.localizedDescription)") }
            guard FileManager.default.isWritableFile(atPath: dir.path) else {
                throw GifwinError(.outputUnwritable, "\(dir.path) is not writable")
            }
        }

        let all = try await WindowResolver.candidates()

        if o.list {
            // Reading what a window shows is recording it. Only windows the caller may record are read.
            let readable = all.filter { refusal(for: $0.1, caller: req.caller ?? "cli", force: false, env: req.env) == nil }
            let text = o.ocr ? await WindowText.index(readable) : [:]
            if o.ocr {
                var e = Audit.Entry()
                e.op = "list_text"
                e.caller = req.caller ?? "cli"
                e.seconds = 0
                e.windowTitle = "\(readable.count) of \(all.count) windows read"
                Audit.write(e, env: req.env)
            }
            func excerpt(_ id: UInt32) -> String { String((text[id] ?? []).prefix(8).joined(separator: " | ").prefix(240)) }
            if o.json {
                let rows = all.map { (_, w) -> [String: Any] in
                    var row: [String: Any] = ["id": Int(w.id), "app": w.app, "bundle_id": w.bundleID, "title": w.title,
                                              "width": w.width, "height": w.height]
                    if o.ocr {
                        row["text"] = excerpt(w.id)
                        if text[w.id] == nil { row["text_restricted"] = true }
                    }
                    return row
                }
                out.stdout += try jsonString(rows)
            } else {
                for (_, w) in all {
                    out.stdout += "id:\(w.id)\t\(w.app)\t\(w.title)\t\(w.width)x\(w.height)" + (o.ocr ? "\t\(excerpt(w.id))" : "") + "\n"
                }
            }
            return
        }

        let selector = o.window!
        let lowered = selector.lowercased()
        let readableWindows = all.filter { refusal(for: $0.1, caller: req.caller ?? "cli", force: false, env: req.env) == nil }
        let (window, info) = lowered.hasPrefix("text:") || lowered.hasPrefix("ask:")
            ? try await WindowResolver.resolveByContent(selector, in: readableWindows)
            : try WindowResolver.resolve(selector, in: all)
        let final = dir.appendingPathComponent(fileName(app: info.app, override: o.name, ext: o.format.fileExtension))

        let entry = try authorize(info, o, req, path: final, audit)

        if o.dryRun {
            if o.json {
                out.stdout += try jsonString(["window_id": Int(info.id), "app": info.app, "bundle_id": info.bundleID,
                                              "title": info.title, "width": info.width, "height": info.height,
                                              "seconds": o.seconds, "path": final.path, "quality": o.quality.rawValue] as [String: Any])
            } else {
                out.stdout += "window id:\(info.id)  \(info.app) \u{2014} \(info.title)  \(info.width)x\(info.height)\n"
                out.stdout += "seconds \(o.seconds)  ->  \(final.path)\n"
            }
            return
        }

        var settings = o.quality.settings
        if let c = o.colors { settings.colors = c }
        if let f = o.fps { settings.fps = f }
        if let px = o.scale { settings.longEdge = px }
        settings.trim = o.trim
        let startedAt = Date()

        var started = entry
        started.phase = "start"
        Audit.write(started, env: req.env)
        audit.entry = started
        audit.started = true

        // Write beside the target, then rename, so a partial file never appears at the final path.
        let recordExt = o.format == .gif ? "gif" : "mp4"
        let temp = dir.appendingPathComponent(".\(final.deletingPathExtension().lastPathComponent).partial.\(recordExt)")
        defer { try? FileManager.default.removeItem(at: temp) }
        var r = try await Capture.record(window: window, seconds: o.seconds, to: temp, settings: settings,
                                         redact: o.redact, format: o.format == .gif ? .gif : .mp4,
                                         until: o.until, after: o.after)
        if let budget = o.maxBytes { r = try Fit.toBudget(r, maxBytes: budget, settings: settings) }

        // WebM is the MP4 converted. The MP4 stays beside it if the conversion cannot happen.
        var intermediate: URL?
        if o.format == .webm {
            let mp4 = final.deletingPathExtension().appendingPathExtension("mp4")
            _ = try? FileManager.default.removeItem(at: mp4)
            do { try FileManager.default.moveItem(at: r.url, to: mp4) }
            catch { throw GifwinError(.outputUnwritable, "Cannot write \(mp4.path): \(error.localizedDescription)") }
            try WebM.transcode(mp4, to: final, settings: settings, env: req.env)
            intermediate = mp4
            r.url = final
            r.bytes = (try? FileManager.default.attributesOfItem(atPath: final.path)[.size] as? Int) ?? r.bytes
        } else {
            _ = try? FileManager.default.removeItem(at: final)
            do { try FileManager.default.moveItem(at: r.url, to: final) }
            catch { throw GifwinError(.outputUnwritable, "Cannot write \(final.path): \(error.localizedDescription)") }
        }
        defer { if let intermediate { try? FileManager.default.removeItem(at: intermediate) } }

        try await deliver(r, to: final, info: info, o, settings: settings, startedAt: startedAt, &out, audit, analyzing: intermediate)
    }

    /// Everything after a clip exists: clipboard, contact sheet and manifest, the audit result, and the answer.
    /// A capture and a clip saved from the rolling buffer are delivered identically.
    private static func deliver(_ r: CaptureResult, to final: URL, info: WindowInfo, _ o: Options, settings: EncoderSettings,
                                startedAt: Date, _ out: inout Outcome, _ audit: AuditState, analyzing: URL? = nil) async throws {
        if o.clipboard { out.clipboardPath = final.path }

        // Everything an agent needs to check and cite the clip, written beside it. A failure here never
        // fails the capture: the GIF is already safely at its final path.
        var extras: [String: Any] = [:]
        if !o.noSidecar {
            let meta = CaptureMeta(app: info.app, bundleID: info.bundleID, appVersion: AppInfo.version(pid: info.pid),
                                   windowID: info.id, windowTitle: info.title, windowWidth: info.width, windowHeight: info.height,
                                   displayScale: r.displayScale, startedAt: startedAt, requestedSeconds: o.seconds,
                                   quality: o.quality.rawValue, settings: settings)
            do {
                var finished = r
                finished.url = final
                let side = try await Sidecar.write(gif: final, capture: meta, result: finished, ai: !o.noAI, redacted: o.redact, analyzing: analyzing)
                extras = sidecarFields(side)
                if o.redact, side.manifest.analysis.redaction.residualInOutput > 0 {
                    extras["redaction_warning"] = "\(side.manifest.analysis.redaction.residualInOutput) secret-looking string(s) are still readable in the clip's keyframes; check it before sharing"
                    out.stderr += "gifwin: warning: \(extras["redaction_warning"] ?? "")\n"
                }
                out.stderr += "contact sheet: \(side.contactSheetURL?.path ?? "-")\nmanifest: \(side.manifestURL.path)\n"
            } catch {
                extras["sidecar_error"] = (error as? GifwinError)?.message ?? error.localizedDescription
                out.stderr += "gifwin: could not write the contact sheet or manifest: \(extras["sidecar_error"] ?? "")\n"
            }
        }

        if let data = try? Data(contentsOf: final) { audit.result = (data.count, Sidecar.sha256(data), final.path) }

        if o.json {
            var result: [String: Any] = ["path": final.path, "bytes": r.bytes, "frames": r.frames, "width": r.width,
                                         "height": r.height, "seconds": r.seconds, "truncated": r.truncated,
                                         "quality": o.quality.rawValue, "app": info.app, "bundle_id": info.bundleID,
                                         "window_title": info.title, "budget_met": r.budgetMet, "budget_steps": r.budgetSteps,
                                         "trimmed_head_seconds": r.trimmedHead, "trimmed_tail_seconds": r.trimmedTail,
                                         "stopped_by": r.stoppedBy, "redacted_regions": r.maskedRegions]
            if let t = r.predicateTime { result["predicate_time_seconds"] = (t * 100).rounded() / 100 }
            result.merge(extras) { _, new in new }
            result["format"] = o.format.rawValue
            out.stdout += try jsonString(result)
        } else {
            out.stdout += final.path + "\n"
            out.stderr += "\(r.frames) frames, \(r.width)x\(r.height), \(r.bytes / 1024) KB, \(String(format: "%.1f", r.seconds)) s\n"
        }
        if !r.budgetMet {
            out.stderr += "gifwin: could not reach \(o.maxBytes ?? 0) bytes; smallest result is \(r.bytes)\n"
            out.code = ExitCode.budgetUnreachable.rawValue
        } else if r.truncated {
            out.stderr += "gifwin: the window closed early; kept what was captured\n"
            out.code = ExitCode.windowClosed.rawValue
        }
    }

    /// Applies the policy to a window before anything is recorded and logs a refusal like any other attempt.
    /// Returns the audit entry for the capture that is about to begin.
    private static func authorize(_ info: WindowInfo, _ o: Options, _ req: Request, path: URL?, _ audit: AuditState,
                                  op: String = "capture") throws -> Audit.Entry {
        let caller = req.caller ?? "cli"
        var entry = Audit.Entry()
        entry.op = op
        entry.caller = caller
        entry.bundleID = info.bundleID
        entry.app = info.app
        entry.windowTitle = info.title
        entry.seconds = o.seconds
        entry.out = path?.path
        if let refusal = refusal(for: info, caller: caller, force: o.force, env: req.env) {
            entry.phase = "refused"
            entry.decision = refusal.slug ?? "policy_denied"
            entry.code = refusal.code.rawValue
            if !o.dryRun { Audit.write(entry, env: req.env) }
            throw refusal
        }
        return entry
    }

    // MARK: - policy

    /// nil when the caller may record this window; otherwise the error to return.
    static func refusal(for info: WindowInfo, caller: String, force: Bool, env: [String: String]) -> GifwinError? {
        let (policy, policyError) = Policy.load(env: env)
        // A policy file that cannot be read must not become "no policy" for an agent.
        if caller == "mcp", let policyError {
            return GifwinError(.policyDenied, "Agent captures are refused because the policy file is invalid: \(policyError)",
                               remediation: "Fix \(Paths.config(env).appendingPathComponent("policy.toml").path).", slug: "policy_invalid")
        }
        switch PolicyGate.decide(caller: caller, force: force, bundleID: info.bundleID, title: info.title,
                                 policy: policy, consent: Consent.load(env: env)) {
        case .allow:
            return nil
        case .deny(let why):
            return GifwinError(.policyDenied, "Not recording \(info.app): \(why).", slug: "policy_denied")
        case .needsConsent(let id):
            let grant = "gifwin consent grant \(id)"
            return GifwinError(.policyDenied, "An agent has not been given permission to record \(info.app) yet.",
                               remediation: "If you want that, run `\(grant)` in a terminal. It lasts \(Int(policy.consentHours)) hours.",
                               slug: "consent_required", details: ["bundle_id": id, "grant_command": grant])
        }
    }

    /// `consent` and `log`: the person's controls over what agents may do and the record of what they did.
    private static func admin(_ req: Request, _ out: inout Outcome) throws {
        guard (req.caller ?? "cli") != "mcp" else { throw GifwinError(.policyDenied, "Agents cannot change consent.", slug: "policy_denied") }
        let args = req.args
        if args.first == "log" {
            var n = 20
            if let i = args.firstIndex(of: "--tail"), i + 1 < args.count, let v = Int(args[i + 1]) { n = v }
            let lines = Audit.tail(n, env: req.env)
            out.stdout += lines.isEmpty ? "(no captures recorded yet)\n" : lines.joined(separator: "\n") + "\n"
            out.stderr += "log: \(Audit.url(req.env).path)  (append-only; to remove it: chflags nouappnd <file>)\n"
            return
        }
        var consent = Consent.load(env: req.env)
        let (policy, _) = Policy.load(env: req.env)
        switch args.dropFirst().first {
        case "grant":
            guard args.count >= 3 else { throw GifwinError(.usage, "consent grant needs a bundle id (see: gifwin --list --json)") }
            var hours = policy.consentHours
            if let i = args.firstIndex(of: "--hours"), i + 1 < args.count, let h = Double(args[i + 1]), h > 0 { hours = h }
            consent.grant(args[2], hours: hours)
            try consent.save(env: req.env)
            out.stdout += "agents may record \(args[2]) for \(Int(hours)) hours\n"
        case "revoke":
            guard args.count >= 3 else { throw GifwinError(.usage, "consent revoke needs a bundle id") }
            consent.revoke(args[2])
            try consent.save(env: req.env)
            out.stdout += "revoked \(args[2])\n"
        case "list":
            let now = Date()
            let live = consent.entries.filter { $0.expires > now }
            out.stdout += live.isEmpty ? "(no app has agent consent)\n" : live.map { "\($0.bundleID)\texpires \(ISO8601DateFormatter().string(from: $0.expires))" }.joined(separator: "\n") + "\n"
            if !policy.allow.isEmpty { out.stdout += "always allowed by policy.toml: \(policy.allow.sorted().joined(separator: ", "))\n" }
        default:
            throw GifwinError(.usage, "consent takes grant, revoke or list\n\n\(usage)")
        }
    }

    // MARK: - watch and save-last

    /// `watch` keeps a window's last N seconds in memory; `save-last` writes them out. The buffer has to outlive
    /// the command, so both run only in the resident helper.
    private static func watching(_ req: Request, _ out: inout Outcome, _ audit: AuditState) async throws {
        let isSave = req.args.first == "save-last"
        let o = try parse(Array(req.args.dropFirst()))
        guard req.env["GIFWIN_RESIDENT"] == "1" else {
            throw GifwinError(.internalFailure, "\(isSave ? "save-last" : "watch") needs the Gifwin.app helper, because a rolling buffer has to outlive the command.",
                              remediation: "Run scripts/bundle.sh --install, then try again.")
        }
        if isSave { try await saveLast(o, req, &out, audit); return }

        if o.status {
            let rows = Watchers.active().map { w -> [String: Any] in
                ["window_id": Int(w.info.id), "app": w.info.app, "title": w.info.title, "rolling_seconds": w.rolling,
                 "held_seconds": (w.heldSeconds * 10).rounded() / 10, "held_bytes": w.heldBytes, "since": ISO8601DateFormatter().string(from: w.startedAt)]
            }
            out.stdout += o.json ? try jsonString(rows) : (rows.isEmpty ? "(nothing is being watched)\n"
                : rows.map { "id:\($0["window_id"] ?? 0)\t\($0["app"] ?? "")\t\($0["held_seconds"] ?? 0) s held\t\(($0["held_bytes"] as? Int ?? 0) / 1024) KB" }.joined(separator: "\n") + "\n")
            return
        }
        if o.stop {
            var stopped: [Watcher] = []
            switch o.window {
            case nil: stopped = Watchers.active()
            case let selector?:
                switch Watchers.find(selector) {
                case .success(let w): stopped = [w]
                case .failure(let e): throw e
                }
            }
            for w in stopped {
                if let removed = Watchers.remove(w.info.id) { await removed.stop() }
                var e = Audit.Entry(); e.op = "watch_stop"; e.caller = req.caller ?? "cli"; e.bundleID = w.info.bundleID; e.app = w.info.app; e.code = 0
                Audit.write(e, env: req.env)
            }
            out.stdout += o.json ? try jsonString(["stopped": stopped.count] as [String: Any]) : "stopped \(stopped.count) watcher(s)\n"
            return
        }

        // Start watching.
        guard let selector = o.window else { throw GifwinError(.usage, "watch needs --window\n\n\(usage)") }
        let all = try await WindowResolver.candidates()
        let readable = all.filter { refusal(for: $0.1, caller: req.caller ?? "cli", force: false, env: req.env) == nil }
        let lowered = selector.lowercased()
        let (window, info) = lowered.hasPrefix("text:") || lowered.hasPrefix("ask:")
            ? try await WindowResolver.resolveByContent(selector, in: readable) : try WindowResolver.resolve(selector, in: all)
        var entry = try authorize(info, o, req, path: nil, audit, op: "watch_start")
        if Watchers.active().contains(where: { $0.info.id == info.id }) { throw GifwinError(.usage, "\(info.app) is already being watched.") }

        entry.phase = "start"
        entry.seconds = o.rolling
        Audit.write(entry, env: req.env)
        audit.entry = entry
        audit.started = true

        var settings = o.quality.settings
        if let c = o.colors { settings.colors = c }
        if let f = o.fps { settings.fps = f }
        if let px = o.scale { settings.longEdge = px }
        let source = SCKFrameSource(window: window, settings: settings)
        let watcher = try await Watcher.start(source: source, info: info, rolling: o.rolling, settings: settings,
                                              redact: o.redact, displayScale: source.displayScale)
        Watchers.add(watcher)
        let facts: [String: Any] = ["watching": true, "window_id": Int(info.id), "app": info.app, "bundle_id": info.bundleID,
                                    "window_title": info.title, "rolling_seconds": o.rolling, "redact": o.redact]
        out.stdout += o.json ? try jsonString(facts) : "watching \(info.app) (id:\(info.id)), keeping the last \(Int(o.rolling)) s in memory\n"
        out.stderr += "the macOS recording indicator stays on until: gifwin watch --stop\n"
    }

    private static func saveLast(_ o: Options, _ req: Request, _ out: inout Outcome, _ audit: AuditState) async throws {
        let watcher: Watcher
        switch Watchers.find(o.window) {
        case .success(let w): watcher = w
        case .failure(let e): throw e
        }
        let base = URL(fileURLWithPath: req.cwd.isEmpty ? FileManager.default.currentDirectoryPath : req.cwd, isDirectory: true)
        let dir = (o.out ?? req.env["GIFWIN_OUT"]).map { URL(fileURLWithPath: $0, isDirectory: true, relativeTo: base).standardizedFileURL } ?? base
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw GifwinError(.outputUnwritable, "Cannot create \(dir.path): \(error.localizedDescription)") }
        let final = dir.appendingPathComponent(fileName(app: watcher.info.app, override: o.name))

        // The buffer may hold a window the caller was never cleared to record.
        var entry = try authorize(watcher.info, o, req, path: final, audit, op: "save_last")
        entry.phase = "start"
        Audit.write(entry, env: req.env)
        audit.entry = entry
        audit.started = true

        let startedAt = Date().addingTimeInterval(-watcher.heldSeconds)
        let r = try watcher.save(lastSeconds: o.seconds, to: final)
        var settings = o.quality.settings
        settings.trim = false
        try await deliver(r, to: final, info: watcher.info, o, settings: settings, startedAt: startedAt, &out, audit)
    }

    // MARK: - bench

    private static func bench(_ req: Request, _ out: inout Outcome) async throws {
        var seconds = 10.0, size = (1024, 640), runs = 10, quality = Quality.balanced
        var i = 1
        let a = req.args
        while i < a.count {
            switch a[i] {
            case "--seconds": i += 1; if i < a.count, let v = Double(a[i]), v > 0 { seconds = v }
            case "--runs": i += 1; if i < a.count, let v = Int(a[i]), v > 0 { runs = v }
            case "--quality": i += 1; if i < a.count, let q = Quality(rawValue: a[i]) { quality = q }
            case "--size":
                i += 1
                let parts = i < a.count ? a[i].split(separator: "x").compactMap { Int($0) } : []
                guard parts.count == 2, parts.allSatisfy({ $0 >= 64 }) else { throw GifwinError(.usage, "--size takes WIDTHxHEIGHT such as 1024x640") }
                size = (parts[0], parts[1])
            case "--json", "--ring": break
            default: throw GifwinError(.usage, "unknown argument '\(a[i])'\n\n\(usage)")
            }
            i += 1
        }
        if a.contains("--ring") {
            out.stdout += try jsonString(await Bench.ring(rolling: 30, feedSeconds: 90, width: size.0, height: size.1))
            return
        }
        let report = await Bench.run(seconds: seconds, width: size.0, height: size.1, runs: runs, quality: quality)
        out.stdout += try jsonString(report)
    }

    // MARK: - describe

    /// Analyses a GIF that already exists: writes its contact sheet and manifest, keeping the capture
    /// facts from an earlier manifest if there is one.
    private static func describe(_ req: Request, _ out: inout Outcome) async throws {
        var path: String?, json = false, ai = true
        for a in req.args.dropFirst() {
            switch a {
            case "--json": json = true
            case "--no-ai": ai = false
            default:
                if a.hasPrefix("-") { throw GifwinError(.usage, "unknown argument '\(a)'\n\n\(usage)") }
                path = a
            }
        }
        guard let path else { throw GifwinError(.usage, "describe needs a GIF path\n\n\(usage)") }
        let base = URL(fileURLWithPath: req.cwd.isEmpty ? FileManager.default.currentDirectoryPath : req.cwd, isDirectory: true)
        let gif = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        guard FileManager.default.fileExists(atPath: gif.path) else { throw GifwinError(.usage, "no such file: \(gif.path)") }

        let side = try await Sidecar.write(gif: gif, capture: Sidecar.existingCapture(for: gif), result: nil, ai: ai)
        if json {
            var fields = sidecarFields(side)
            fields["path"] = gif.path
            out.stdout += try jsonString(fields)
        } else {
            out.stdout += side.manifest.analysis.caption + "\n" + side.manifest.analysis.altText + "\n"
            out.stderr += "contact sheet: \(side.contactSheetURL?.path ?? "-")\nmanifest: \(side.manifestURL.path)\n"
        }
    }

    /// The part of a result an agent reads: where the evidence is, and what it says.
    static func sidecarFields(_ side: SidecarResult) -> [String: Any] {
        let m = side.manifest
        return ["contact_sheet": side.contactSheetURL?.path ?? NSNull(), "manifest": side.manifestURL.path,
                "caption": m.analysis.caption, "alt_text": m.analysis.altText, "caption_source": m.analysis.captionSource,
                "caption_note": m.analysis.captionNote ?? NSNull(),
                "sha256": m.output.sha256, "duration_seconds": m.output.durationSeconds,
                "redaction": ["pixels": m.analysis.redaction.pixels, "text_masked": m.analysis.redaction.textMasked,
                              "residual_in_output": m.analysis.redaction.residualInOutput] as [String: Any],
                "keyframes": m.analysis.keyframes.map { ["index": $0.index, "time_seconds": $0.timeSeconds, "text": $0.text] as [String: Any] }]
    }

    // MARK: - doctor

    /// Reports whether this process may record the screen, without triggering the system prompt.
    private static func doctor(_ out: inout Outcome) {
        let granted = CGPreflightScreenCaptureAccess()
        out.stdout += "process: \(ProcessInfo.processInfo.processIdentifier)  \(ProcessInfo.processInfo.arguments.first ?? "")\n"
        out.stdout += "screen recording: \(granted ? "granted" : "NOT granted")\n"
        out.stdout += "caption model: \(Describe.modelStatus())  (without it, captions come from metadata and OCR text)\n"
        let (policy, policyError) = Policy.load(env: [:])
        let consent = Consent.load(env: [:]).entries.filter { $0.expires > Date() }
        out.stdout += "policy: \(policyError ?? "ok") | never-record apps: \(Policy.builtinDeny.count + policy.deny.count) | agent allowlist: \(policy.allow.count) | live consents: \(consent.count)\n"
        out.stdout += "ffmpeg (for webm): \(WebM.ffmpeg()?.path ?? "not found")\n"
        out.stdout += "audit log: \(Audit.url().path) (\(Audit.tail(1_000_000).count) entries)\n"
        if !granted {
            out.stdout += "fix: grant Screen Recording to Gifwin in System Settings > Privacy & Security > Screen & System Audio Recording\n"
            out.stdout += "     open \(GifwinError.settingsURL)\n"
            out.code = ExitCode.permissionDenied.rawValue
        }
    }

    // MARK: - Parsing and output

    static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw GifwinError(.usage, "\(flag) needs a value\n\n\(usage)") }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "-w", "--window": o.window = try value(a)
            case "-s", "--seconds":
                guard let s = Double(try value(a)), s > 0 else { throw GifwinError(.usage, "seconds must be a positive number") }
                o.seconds = s
            case "-q", "--quality":
                let v = try value(a)
                guard let q = Quality(rawValue: v) else {
                    throw GifwinError(.usage, "unknown quality '\(v)'; use draft, balanced, crisp or max")
                }
                o.quality = q
            case "--colors":
                guard let c = Int(try value(a)), (2...256).contains(c) else { throw GifwinError(.usage, "--colors takes 2 to 256") }
                o.colors = c
            case "--fps":
                guard let f = Double(try value(a)),
                      let match = EncoderSettings.allowedFPS.first(where: { abs($0 - f) < 0.05 }) else {
                    throw GifwinError(.usage, "--fps takes 10, 12.5, 16.67 or 20 (rates that divide evenly into GIF centiseconds)")
                }
                o.fps = match
            case "--scale":
                guard let px = Int(try value(a)), px >= 64 else { throw GifwinError(.usage, "--scale takes a pixel count of at least 64") }
                o.scale = px
            case "--max-bytes":
                let v = try value(a).lowercased()
                let mult = v.hasSuffix("k") ? 1024 : v.hasSuffix("m") ? 1_048_576 : 1
                guard let n = Int(v.trimmingCharacters(in: CharacterSet(charactersIn: "km"))), n > 0 else {
                    throw GifwinError(.usage, "--max-bytes takes a byte count such as 800000, 800k or 2m")
                }
                o.maxBytes = n * mult
            case "-o", "--out": o.out = try value(a)
            case "--name": o.name = try value(a)
            case "--clipboard": o.clipboard = true
            case "--trim":
                switch try value(a) {
                case "auto": o.trim = true
                case "none": o.trim = false
                default: throw GifwinError(.usage, "--trim takes auto or none")
                }
            case "--redact":
                switch try value(a) {
                case "auto": o.redact = true
                case "none": o.redact = false
                default: throw GifwinError(.usage, "--redact takes auto or none")
                }
            case "--format", "-f":
                let v = try value(a)
                guard let f = OutputFormat(rawValue: v) else { throw GifwinError(.usage, "--format takes gif, mp4 or webm, not '\(v)'") }
                o.format = f
            case "--until":
                let v = try value(a)
                guard let p = StopCondition.parse(v) else {
                    throw GifwinError(.usage, "--until takes text:<words>, quiet:<seconds> or change, not '\(v)'")
                }
                o.until = p
            case "--after":
                guard let n = Double(try value(a)), n >= 0 else { throw GifwinError(.usage, "--after takes a number of seconds, 0 or more") }
                o.after = n
            case "--rolling":
                guard let n = Double(try value(a)), (5...300).contains(n) else { throw GifwinError(.usage, "--rolling takes 5 to 300 seconds") }
                o.rolling = n
            case "--stop": o.stop = true
            case "--status": o.status = true
            case "--no-ai": o.noAI = true
            case "--force": o.force = true
            case "--no-sidecar": o.noSidecar = true
            case "--ocr": o.ocr = true
            case "--list": o.list = true
            case "--dry-run": o.dryRun = true
            case "--json": o.json = true
            case "--direct": break // consumed by the client; harmless if it arrives here
            case "--version": o.version = true
            case "-h", "--help":
                throw GifwinError(.ok, usage)
            default:
                if let s = Double(a), s > 0 { o.seconds = s }
                else { throw GifwinError(.usage, "unknown argument '\(a)'\n\n\(usage)") }
            }
            i += 1
        }
        return o
    }

    public static func fileNameForTests(app: String, override: String?, ext: String) -> String { fileName(app: app, override: override, ext: ext) }

    static func fileName(app: String, override: String?, ext: String = "gif") -> String {
        if let override { return override.hasSuffix("." + ext) ? override : override + "." + ext }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let safe = app.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return "\(safe)-\(f.string(from: Date())).\(ext)"
    }

    static func jsonString(_ object: Any) throws -> String {
        let d = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: d, as: UTF8.self) + "\n"
    }

    private static func fail(_ error: Error, json: Bool, _ out: inout Outcome) {
        let e = (error as? GifwinError) ?? GifwinError(.internalFailure, error.localizedDescription)
        out.code = e.code.rawValue
        if e.code == .ok { // --help travels as an error to unwind the parser
            out.stdout += e.message + "\n"
            return
        }
        if json {
            var payload: [String: Any] = ["error": e.slug ?? e.code.slug, "code": Int(e.code.rawValue), "message": e.message]
            if let r = e.remediation { payload["remediation"] = r }
            for (k, v) in e.details { payload[k] = v }
            if e.code == .permissionDenied { payload["settings_url"] = GifwinError.settingsURL }
            out.stdout += (try? jsonString(payload)) ?? ""
        } else {
            out.stderr += "gifwin: \(e.message)\n"
            if let r = e.remediation { out.stderr += "        \(r)\n" }
        }
    }
}
