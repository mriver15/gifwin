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

    public init(op: String = "run", args: [String] = [], cwd: String = "", env: [String: String] = [:]) {
        self.op = op
        self.args = args
        self.cwd = cwd
        self.env = env
    }

    public static let forwardedEnvironment = ["GIFWIN_OUT", "GIFWIN_FAULT"]
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
           gifwin describe <file.gif> [--json] [--no-ai]
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
          --trim <auto|none>    cap still footage at the start and end (default auto)
          --no-ai               skip OCR and the caption model; the sheet and manifest are still written
          --no-sidecar          write only the GIF, no contact sheet or manifest
          --clipboard           put the finished file on the pasteboard
          --list                print capturable windows and exit (--ocr adds what each shows)
          --dry-run             resolve the window, print the plan, capture nothing
          --json                machine-readable result on stdout
          --direct              capture in this process instead of through Gifwin.app
          --version

    exit codes: 0 ok, 64 usage, 65 no or ambiguous window, 69 Screen Recording not granted,
                70 internal, 73 output unwritable, 74 window closed (partial file kept),
                75 byte budget unreachable (smallest file kept)
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
        var noAI = false
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
        do {
            try await execute(request, &out)
        } catch {
            fail(error, json: json, &out)
        }
        return out
    }

    private static func execute(_ req: Request, _ out: inout Outcome) async throws {
        if req.args == ["doctor"] {
            doctor(&out)
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
        if let fault = req.env["GIFWIN_FAULT"] {
            switch fault {
            case "tcc": throw GifwinError.permission("Screen Recording permission is not granted (simulated).")
            case "internal": throw GifwinError(.internalFailure, "Simulated internal failure.")
            case "window-closed": throw GifwinError(.windowClosed, "The window closed during capture (simulated).")
            default: throw GifwinError(.usage, "unknown GIFWIN_FAULT '\(fault)'")
            }
        }

        // Usage errors come before anything that needs a permission, so they report as usage.
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
            let text = o.ocr ? await WindowText.index(all) : [:]
            func excerpt(_ id: UInt32) -> String { String((text[id] ?? []).prefix(8).joined(separator: " | ").prefix(240)) }
            if o.json {
                let rows = all.map { (_, w) -> [String: Any] in
                    var row: [String: Any] = ["id": Int(w.id), "app": w.app, "bundle_id": w.bundleID, "title": w.title,
                                              "width": w.width, "height": w.height]
                    if o.ocr { row["text"] = excerpt(w.id) }
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
        let (window, info) = lowered.hasPrefix("text:") || lowered.hasPrefix("ask:")
            ? try await WindowResolver.resolveByContent(selector, in: all)
            : try WindowResolver.resolve(selector, in: all)
        let final = dir.appendingPathComponent(fileName(app: info.app, override: o.name))

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

        // Write beside the target, then rename, so a partial GIF never appears at the final path.
        let temp = dir.appendingPathComponent(".\(final.lastPathComponent).partial")
        defer { try? FileManager.default.removeItem(at: temp) }
        var r = try await Capture.record(window: window, seconds: o.seconds, to: temp, settings: settings)
        if let budget = o.maxBytes { r = try Fit.toBudget(r, maxBytes: budget, settings: settings) }
        _ = try? FileManager.default.removeItem(at: final)
        do { try FileManager.default.moveItem(at: r.url, to: final) }
        catch { throw GifwinError(.outputUnwritable, "Cannot write \(final.path): \(error.localizedDescription)") }

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
                let side = try await Sidecar.write(gif: final, capture: meta, result: finished, ai: !o.noAI)
                extras = sidecarFields(side)
                out.stderr += "contact sheet: \(side.contactSheetURL?.path ?? "-")\nmanifest: \(side.manifestURL.path)\n"
            } catch {
                extras["sidecar_error"] = (error as? GifwinError)?.message ?? error.localizedDescription
                out.stderr += "gifwin: could not write the contact sheet or manifest: \(extras["sidecar_error"] ?? "")\n"
            }
        }

        if o.json {
            var result: [String: Any] = ["path": final.path, "bytes": r.bytes, "frames": r.frames, "width": r.width,
                                         "height": r.height, "seconds": r.seconds, "truncated": r.truncated,
                                         "quality": o.quality.rawValue, "app": info.app, "bundle_id": info.bundleID,
                                         "window_title": info.title, "budget_met": r.budgetMet, "budget_steps": r.budgetSteps,
                                         "trimmed_head_seconds": r.trimmedHead, "trimmed_tail_seconds": r.trimmedTail]
            result.merge(extras) { _, new in new }
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
                "keyframes": m.analysis.keyframes.map { ["index": $0.index, "time_seconds": $0.timeSeconds, "text": $0.text] as [String: Any] }]
    }

    // MARK: - doctor

    /// Reports whether this process may record the screen, without triggering the system prompt.
    private static func doctor(_ out: inout Outcome) {
        let granted = CGPreflightScreenCaptureAccess()
        out.stdout += "process: \(ProcessInfo.processInfo.processIdentifier)  \(ProcessInfo.processInfo.arguments.first ?? "")\n"
        out.stdout += "screen recording: \(granted ? "granted" : "NOT granted")\n"
        out.stdout += "caption model: \(Describe.modelStatus())  (without it, captions come from metadata and OCR text)\n"
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
            case "--no-ai": o.noAI = true
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

    static func fileName(app: String, override: String?) -> String {
        if let override { return override.hasSuffix(".gif") ? override : override + ".gif" }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let safe = app.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return "\(safe)-\(f.string(from: Date())).gif"
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
            var payload: [String: Any] = ["error": e.code.slug, "code": Int(e.code.rawValue), "message": e.message]
            if let r = e.remediation { payload["remediation"] = r }
            if e.code == .permissionDenied { payload["settings_url"] = GifwinError.settingsURL }
            out.stdout += (try? jsonString(payload)) ?? ""
        } else {
            out.stderr += "gifwin: \(e.message)\n"
            if let r = e.remediation { out.stderr += "        \(r)\n" }
        }
    }
}
