import CoreGraphics
import Foundation
import GifwinCore

let usage = """
usage: gifwin [seconds] --window <selector> [options]

  -w, --window <selector>   <app name> | <bundle-id> | id:<n> | title~<text>
  -s, --seconds <float>     default 5
  -q, --quality <preset>    draft | balanced | crisp | max   (default balanced)
      --colors <2-256>      override the preset's palette size
      --fps <rate>          10 | 12.5 | 16.67 | 20
      --scale <px>          cap on the long edge, in pixels
      --max-bytes <n>       degrade quality until the file fits (accepts 500k, 2m)
  -o, --out <dir>           default $GIFWIN_OUT, else the current directory
      --name <file>         default "<app>-<yyyyMMdd-HHmmss>.gif"
      --list                print capturable windows and exit
      --dry-run             resolve the window, print the plan, capture nothing
      --json                machine-readable result on stdout
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
    var list = false
    var dryRun = false
    var json = false
}

func parse(_ args: [String]) throws -> Options {
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
        case "--list": o.list = true
        case "--dry-run": o.dryRun = true
        case "--json": o.json = true
        case "-h", "--help": print(usage); exit(0)
        default:
            if let s = Double(a), s > 0 { o.seconds = s } else { throw GifwinError(.usage, "unknown argument '\(a)'\n\n\(usage)") }
        }
        i += 1
    }
    return o
}

func fail(_ error: Error, json: Bool) -> Never {
    let e = (error as? GifwinError) ?? GifwinError(.internalFailure, error.localizedDescription)
    if json {
        let payload: [String: Any] = ["error": "\(e.code)", "code": Int(e.code.rawValue), "message": e.message]
        if let d = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            print(String(decoding: d, as: UTF8.self))
        }
    } else {
        FileHandle.standardError.write(Data("gifwin: \(e.message)\n".utf8))
    }
    exit(e.code.rawValue)
}

func fileName(app: String, override: String?) -> String {
    if let override { return override.hasSuffix(".gif") ? override : override + ".gif" }
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    f.locale = Locale(identifier: "en_US_POSIX")
    let safe = app.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    return "\(safe)-\(f.string(from: Date())).gif"
}

@main
struct Gifwin {
    static func main() async {
        // A bare CLI never connects to the window server, and ScreenCaptureKit then trips
        // CGS_REQUIRE_INIT. Touching CoreGraphics once up front initialises it without AppKit.
        _ = CGMainDisplayID()
        let args = Array(CommandLine.arguments.dropFirst())
        let json = args.contains("--json")
        do {
            let o = try parse(args)
            let all = try await WindowResolver.candidates()

            if o.list {
                for (_, w) in all { print("id:\(w.id)\t\(w.app)\t\(w.title)\t\(w.width)x\(w.height)") }
                exit(0)
            }
            guard let selector = o.window else { throw GifwinError(.usage, "missing --window\n\n\(usage)") }
            let (window, info) = try WindowResolver.resolve(selector, in: all)

            let dir = URL(fileURLWithPath: o.out ?? ProcessInfo.processInfo.environment["GIFWIN_OUT"] ?? FileManager.default.currentDirectoryPath,
                          isDirectory: true)
            let final = dir.appendingPathComponent(fileName(app: info.app, override: o.name))

            if o.dryRun {
                print("window id:\(info.id)  \(info.app) \u{2014} \(info.title)  \(info.width)x\(info.height)")
                print("seconds \(o.seconds)  ->  \(final.path)")
                exit(0)
            }
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { throw GifwinError(.outputUnwritable, "Cannot create \(dir.path): \(error.localizedDescription)") }

            // Write beside the target, then rename, so a partial GIF never appears at the final path.
            let temp = dir.appendingPathComponent(".\(final.lastPathComponent).partial")
            defer { try? FileManager.default.removeItem(at: temp) }
            var settings = o.quality.settings
            if let c = o.colors { settings.colors = c }
            if let f = o.fps { settings.fps = f }
            if let px = o.scale { settings.longEdge = px }
            var r = try await Capture.record(window: window, seconds: o.seconds, to: temp, settings: settings)
            if let budget = o.maxBytes {
                r = try Fit.toBudget(r, maxBytes: budget, settings: settings)
            }
            _ = try? FileManager.default.removeItem(at: final)
            do { try FileManager.default.moveItem(at: temp, to: final) }
            catch { throw GifwinError(.outputUnwritable, "Cannot write \(final.path): \(error.localizedDescription)") }

            if json {
                let payload: [String: Any] = ["path": final.path, "bytes": r.bytes, "frames": r.frames,
                                              "width": r.width, "height": r.height, "seconds": r.seconds,
                                              "truncated": r.truncated, "quality": o.quality.rawValue,
                                              "budget_met": r.budgetMet, "budget_steps": r.budgetSteps]
                let d = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                print(String(decoding: d, as: UTF8.self))
            } else {
                print(final.path)
                FileHandle.standardError.write(Data("\(r.frames) frames, \(r.width)x\(r.height), \(r.bytes / 1024) KB, \(String(format: "%.1f", r.seconds)) s\n".utf8))
            }
            if !r.budgetMet {
                FileHandle.standardError.write(Data("gifwin: could not reach \(o.maxBytes ?? 0) bytes; smallest result is \(r.bytes)\n".utf8))
                exit(ExitCode.budgetUnreachable.rawValue)
            }
            exit(r.truncated ? ExitCode.windowClosed.rawValue : 0)
        } catch {
            fail(error, json: json)
        }
    }
}
