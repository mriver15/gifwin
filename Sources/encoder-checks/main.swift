import CoreGraphics
import Foundation
import AVFoundation
import CoreMedia
import CoreText
import Darwin
import ImageIO
import GifwinCore

// Dev-only encoder checks. Swift Testing and XCTest both need full Xcode; the Command Line
// Tools alone ship neither working. Run with `swift run -c release encoder-checks`.

setvbuf(stdout, nil, _IONBF, 0)   // a check that hangs should still show how far it got
var failures = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String) {
    if !ok { failures += 1; print("  FAIL  \(what())") }
}

// MARK: - Helpers

func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("gifwin-\(UUID().uuidString).gif")
}

func pack(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
    UInt32(b & 255) | UInt32(g & 255) << 8 | UInt32(r & 255) << 16 | 0xFF00_0000
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct Decoded {
    var frames: [[UInt32]]
    var starts: [Double]
    var total: Double
}

func decode(_ url: URL, _ w: Int, _ h: Int) -> Decoded? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    var frames: [[UInt32]] = [], starts: [Double] = []
    var t = 0.0
    for i in 0..<CGImageSourceGetCount(src) {
        guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { return nil }
        frames.append(Fit.bgra(img, width: w, height: h))
        starts.append(t)
        let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
        t += ((props?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? 0
    }
    return Decoded(frames: frames, starts: starts, total: t)
}

func psnr(_ a: [UInt32], _ b: [UInt32]) -> Double {
    var sum = 0.0
    for i in 0..<a.count {
        for shift in [0, 8, 16] {
            let d = Double(Int((a[i] >> UInt32(shift)) & 255) - Int((b[i] >> UInt32(shift)) & 255))
            sum += d * d
        }
    }
    let mse = sum / Double(a.count * 3)
    return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
}

func size(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }

// MARK: - Synthetic clips (320x200, 30 frames at 12.5 fps)

let W = 320, H = 200

func fill(_ px: inout [UInt32], _ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ c: UInt32) {
    for y in max(0, y0)..<min(H, y0 + h) { for x in max(0, x0)..<min(W, x0 + w) { px[y * W + x] = c } }
}

/// Text-like rows of grey bars scrolling up under a fixed coloured header.
func scrollClip() -> [[UInt32]] {
    var rng = SplitMix64(seed: 7)
    let rows = (0..<60).map { _ in (Int(rng.next() % 200) + 40, Int(rng.next() % 3)) }
    return (0..<30).map { f in
        var px = [UInt32](repeating: pack(250, 250, 250), count: W * H)
        for (i, row) in rows.enumerated() {
            let y = 28 + i * 18 - f * 4
            if y < 28 || y > H { continue }
            fill(&px, 16, y, row.0, 10, [pack(40, 40, 48), pack(90, 90, 100), pack(30, 90, 170)][row.1])
        }
        fill(&px, 0, 0, W, 28, pack(30, 60, 140))
        fill(&px, 12, 8, 80, 12, pack(255, 255, 255))
        return px
    }
}

/// Static window chrome with a small cursor sliding across it.
func cursorClip() -> [[UInt32]] {
    var base = [UInt32](repeating: pack(245, 245, 247), count: W * H)
    fill(&base, 0, 0, W, 24, pack(220, 220, 224))
    fill(&base, 0, 24, 70, H - 24, pack(232, 232, 236))
    for i in 0..<5 { fill(&base, 80, 40 + i * 30, 200, 20, [pack(255, 255, 255), pack(66, 133, 244), pack(52, 168, 83)][i % 3]) }
    return (0..<30).map { f in
        var px = base
        fill(&px, 20 + f * 9, 30 + (f * 5) % 140, 8, 12, pack(0, 0, 0))
        return px
    }
}

/// Diagonal gradient that drifts a little every frame; a worst case for banding.
func gradientClip() -> [[UInt32]] {
    (0..<30).map { f in
        (0..<(W * H)).map { i in
            let x = i % W, y = i / W
            return pack((x * 255 / W + f * 3) % 256, (y * 255 / H + f) % 256, ((x + y) * 255 / (W + H) + 60) % 256)
        }
    }
}

/// Three hard cuts between flat, blocky scenes.
func cutClip() -> [[UInt32]] {
    (0..<30).map { f in
        let scene = (f / 10) % 2
        var px = [UInt32](repeating: scene == 0 ? pack(20, 40, 120) : pack(230, 120, 30), count: W * H)
        for b in 0..<8 { fill(&px, 20 + b * 36, 40 + (b % 3) * 40, 28, 28, scene == 0 ? pack(200, 220, 255) : pack(60, 20, 10)) }
        return px
    }
}

/// Frames arrive one per tick of the preset's own rate, like a ScreenCaptureKit stream paced to it.
func times(_ count: Int, _ settings: EncoderSettings) -> [Double] { (0..<count).map { Double($0) / settings.fps } }

func encode(_ frames: [[UInt32]], settings: EncoderSettings, to url: URL) throws -> EncodeStats {
    let writer = try GIFWriter(url: url, width: W, height: H)
    let enc = FrameEncoder(writer: writer, settings: settings)
    let t = times(frames.count, settings)
    for (i, f) in frames.enumerated() { try enc.add(f, at: t[i]) }
    return try enc.finish(endTime: t.last! + 1 / settings.fps)!
}

// MARK: - Checks

/// Random data overflows the 4096-entry table many times and uses every code width.
func writerRoundTrip() throws {
    var rng = SplitMix64(seed: 42)
    for entries in [2, 4, 16, 100, 256] {
        let (w, h) = (96, 64)
        let palette = (0..<entries * 3).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let frame = (0..<w * h).map { _ in UInt8(rng.next() % UInt64(entries)) }
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try GIFWriter(url: url, width: w, height: h)
        try writer.addFrame(w: w, h: h, indices: frame, palette: palette, transparent: nil, delayCS: 8)
        try writer.finish()
        guard let d = decode(url, w, h), d.frames.count == 1 else { check(false, "\(entries) entries: decode failed"); continue }
        var bad = 0
        for p in 0..<w * h {
            let k = Int(frame[p])
            if d.frames[0][p] != pack(Int(palette[k * 3]), Int(palette[k * 3 + 1]), Int(palette[k * 3 + 2])) { bad += 1 }
        }
        check(bad == 0, "\(entries) entries: \(bad) of \(w * h) pixels differ")
    }
}

func transparencyAndRects() throws {
    let (w, h) = (64, 48)
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try GIFWriter(url: url, width: w, height: h)
    let red: [UInt8] = [255, 0, 0, 0, 255, 0, 0, 0, 0]  // red, green, (transparent slot)
    try writer.addFrame(w: w, h: h, indices: [UInt8](repeating: 0, count: w * h), palette: Array(red[0..<3]) + [0, 0, 0], transparent: nil, delayCS: 10)
    // A 10x6 green patch at (20, 12); everything else in the frame is the transparent slot.
    try writer.addFrame(x: 20, y: 12, w: 10, h: 6, indices: [UInt8](repeating: 1, count: 60), palette: Array(red[0..<6]) + [0, 0, 0], transparent: 2, delayCS: 10)
    try writer.finish()
    guard let d = decode(url, w, h), d.frames.count == 2 else { check(false, "decode failed"); return }
    check(d.frames[1][15 * w + 25] == pack(0, 255, 0), "patch pixel should be green")
    check(d.frames[1][0] == pack(255, 0, 0), "pixel outside the patch should keep the previous frame")
    check(d.frames[1][47 * w + 63] == pack(255, 0, 0), "far corner should keep the previous frame")
}

func delaysClamp() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try GIFWriter(url: url, width: 4, height: 4)
    for cs in [10, 25, 0] {
        try writer.addFrame(w: 4, h: 4, indices: [UInt8](repeating: 0, count: 16), palette: [1, 2, 3, 4, 5, 6], transparent: nil, delayCS: cs)
    }
    try writer.finish()
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let delays = (0..<3).map { Fit.delay(src, $0) }
    check(abs(delays[0] - 0.10) < 0.001 && abs(delays[1] - 0.25) < 0.001 && abs(delays[2] - 0.02) < 0.001, "delays were \(delays)")
}

func wuFindsExactColours() throws {
    let wu = Wu()
    let colours = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)]
    for (i, c) in colours.enumerated() { for _ in 0..<(100 + i * 50) { wu.add(r: c.0, g: c.1, b: c.2) } }
    let r = wu.build(maxColors: 4)
    check(r.count == 4, "expected 4 colours, got \(r.count)")
    for c in colours {
        let k = Int(r.tag[(c.0 >> 3) << 10 | (c.1 >> 3) << 5 | (c.2 >> 3)])
        check(r.palette[k * 3] == UInt8(c.0) && r.palette[k * 3 + 1] == UInt8(c.1) && r.palette[k * 3 + 2] == UInt8(c.2),
              "colour \(c) not reproduced exactly")
    }
    let two = wu.build(maxColors: 2)
    check(two.count == 2, "forced to 2 colours, got \(two.count)")
}

/// Fidelity floors are PSNR of what the viewer sees at each source frame's timestamp; size
/// ceilings are bytes. Both are set from measured results with headroom, so a regression fails.
struct Expect { var minPSNR: Double; var maxBytes: Int }

func clipChecks(_ name: String, _ frames: [[UInt32]], _ quality: Quality, _ expect: Expect) throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let stats = try encode(frames, settings: quality.settings, to: url)
    guard let d = decode(url, W, H), !d.frames.isEmpty else { check(false, "\(name): decode failed"); return }

    var worst = 99.0
    let t0 = times(frames.count, quality.settings)
    for (i, t) in t0.enumerated() {
        let shown = d.starts.lastIndex(where: { $0 <= t + 0.005 }) ?? 0
        worst = min(worst, psnr(d.frames[shown], frames[i]))
    }
    let last = psnr(d.frames.last!, frames.last!)
    let line = "\(name) @\(quality.rawValue): \(stats.frames)/\(frames.count) frames, \(stats.bytes) B, worst \(String(format: "%.1f", worst)) dB, last \(String(format: "%.1f", last)) dB, \(String(format: "%.2f", d.total)) s"
    print("  " + line)
    check(worst >= expect.minPSNR, "\(line) -- worst PSNR below \(expect.minPSNR)")
    check(last >= expect.minPSNR, "\(line) -- final frame PSNR below \(expect.minPSNR)")
    check(stats.bytes <= expect.maxBytes, "\(line) -- over \(expect.maxBytes) B")
    let want = Double(frames.count) / quality.settings.fps
    check(abs(d.total - want) <= 0.05, "\(line) -- duration \(d.total) s, wanted \(want) s")
}

func deterministic() throws {
    let a = tempURL(), b = tempURL()
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    let frames = cursorClip()
    _ = try encode(frames, settings: Quality.balanced.settings, to: a)
    _ = try encode(frames, settings: Quality.balanced.settings, to: b)
    check(FileManager.default.contents(atPath: a.path) == FileManager.default.contents(atPath: b.path), "same input produced different bytes")
}

func ditherIsTemporallyStable() throws {
    // A still frame repeated must cost almost nothing: stable thresholds mean nothing changes.
    let still = gradientClip()[0]
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let one = try encode([still], settings: Quality.crisp.settings, to: url)
    let many = try encode([[UInt32]](repeating: still, count: 30), settings: Quality.crisp.settings, to: url)
    check(many.bytes <= one.bytes + 64, "30 identical gradient frames cost \(many.bytes) B vs \(one.bytes) B for one")
    check(many.frames == 1, "identical frames should coalesce into one, got \(many.frames)")
}

func budgetLadder() throws {
    let raw = tempURL()
    defer { try? FileManager.default.removeItem(at: raw) }
    let frames = gradientClip()
    let s = Quality.crisp.settings
    let stats = try encode(frames, settings: s, to: raw)
    let first = CaptureResult(url: raw, width: W, height: H, frames: stats.frames, bytes: stats.bytes, seconds: stats.duration, truncated: false)

    let target = stats.bytes / 2
    let fitted = try Fit.toBudget(first, maxBytes: target, settings: s)
    print("  budget: \(stats.bytes) B -> \(fitted.bytes) B for target \(target) B in \(fitted.budgetSteps) steps, met=\(fitted.budgetMet)")
    check(fitted.budgetMet && fitted.bytes <= target, "should reach half size, got \(fitted.bytes) of \(target)")
    check(size(raw) == fitted.bytes, "file on disk (\(size(raw))) should be the fitted result (\(fitted.bytes))")

    let impossible = try Fit.toBudget(fitted, maxBytes: 200, settings: s)
    check(!impossible.budgetMet, "200 B should be unreachable")
    check(impossible.bytes <= fitted.bytes, "an unreachable budget must not grow the file")
}


// MARK: - Agent layer: trim, keyframes, contact sheet, manifest, describe

/// Runs async work from the synchronous check harness.
final class Box<V>: @unchecked Sendable { var value: Result<V, Error>? }

func block<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let box = Box<T>()
    Task { do { box.value = .success(try await work()) } catch { box.value = .failure(error) } }
    // Pump the main run loop while waiting: AVFoundation's async calls need it, and a thread parked on a
    // semaphore would deadlock them. The real helper app runs the loop the same way.
    while box.value == nil { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005)) }
    return try box.value!.get()
}

/// A frame of solid colour with `lines` of large text, drawn with CoreText into BGRA pixels.
func textFrame(_ lines: [String], background: (Int, Int, Int), w: Int, h: Int, size: Double = 44) -> [UInt32] {
    var px = [UInt32](repeating: pack(background.0, background.1, background.2), count: w * h)
    px.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        for (i, text) in lines.enumerated() {
            let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!)
            ctx.textPosition = CGPoint(x: 40, y: Double(h) - 110 - Double(i) * 70)
            CTLineDraw(line, ctx)
        }
    }
    return px
}

func encodeClip(_ frames: [[UInt32]], w: Int, h: Int, settings: EncoderSettings, to url: URL, tick: Double? = nil) throws -> EncodeStats {
    let writer = try GIFWriter(url: url, width: w, height: h)
    let enc = FrameEncoder(writer: writer, settings: settings)
    let step = tick ?? 1 / settings.fps
    for (i, f) in frames.enumerated() { try enc.add(f, at: Double(i) * step) }
    return try enc.finish(endTime: Double(frames.count) * step)!
}

let sceneW = 640, sceneH = 360
let scenes: [(words: [String], bg: (Int, Int, Int))] = [
    (["COMPILING SOURCES"], (200, 220, 255)),
    (["RUNNING TESTS"], (255, 245, 200)),
    (["BUILD PASSED"], (200, 255, 210)),
]
/// Three scenes, each held for 8 frames: a stand-in for "something happens, then something else".
func sceneClip() -> [[UInt32]] {
    scenes.flatMap { sc in [[UInt32]](repeating: textFrame(sc.words, background: sc.bg, w: sceneW, h: sceneH), count: 8) }
}

func trimsStillHeadAndTail() throws {
    // 20 still frames, a burst of change, 15 still frames.
    var frames: [[UInt32]] = []
    let a = textFrame(["BEFORE"], background: (240, 240, 240), w: 320, h: 200)
    let b = textFrame(["AFTER"], background: (220, 240, 255), w: 320, h: 200)
    frames += [[UInt32]](repeating: a, count: 20)
    for i in 0..<5 { var f = a; for p in 0..<(320 * 200) where (p / 320) < 40 * (i + 1) { f[p] = b[p] }; frames.append(f) }
    frames += [[UInt32]](repeating: b, count: 15)

    var s = Quality.balanced.settings
    let plain = tempURL(), trimmed = tempURL()
    defer { try? FileManager.default.removeItem(at: plain); try? FileManager.default.removeItem(at: trimmed) }
    let before = try encodeClip(frames, w: 320, h: 200, settings: s, to: plain)
    s.trim = true
    let after = try encodeClip(frames, w: 320, h: 200, settings: s, to: trimmed)

    if let idx = try? Analysis.index(trimmed), let idx0 = try? Analysis.index(plain) {
        print("  delays plain:  ", idx0.delays.map { Int(($0 * 100).rounded()) })
        print("  delays trimmed:", idx.delays.map { Int(($0 * 100).rounded()) })
    }
    print("  untrimmed \(before.duration) s, trimmed \(after.duration) s (head \(after.trimmedHead) s, tail \(after.trimmedTail) s)")
    check(abs(before.duration - 3.2) < 0.05, "untrimmed duration \(before.duration)")
    check(abs(after.trimmedHead - 1.1) < 0.1, "head trim \(after.trimmedHead), wanted about 1.1")
    check(abs(after.trimmedTail - 0.4) < 0.1, "tail trim \(after.trimmedTail), wanted about 0.4")
    check(abs(after.duration - (before.duration - after.trimmedHead - after.trimmedTail)) < 0.05,
          "the burst in the middle must keep its timing: \(after.duration) vs \(before.duration - after.trimmedHead - after.trimmedTail)")
    check(after.frames == before.frames, "trimming must not drop frames")
}

func keyframesFollowTheChange() throws {
    // Big change in the first 6 frames, then 24 frames of only a small moving cursor.
    var frames: [[UInt32]] = []
    for i in 0..<6 { frames.append([UInt32](repeating: pack(i * 40, 255 - i * 40, 128), count: 320 * 200)) }
    let still = frames.last!
    for i in 0..<24 { var f = still; for y in 90..<100 { for x in (10 + i * 10)..<(18 + i * 10) { f[y * 320 + x] = pack(0, 0, 0) } }; frames.append(f) }
    var s = Quality.max.settings
    s.trim = false
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try encodeClip(frames, w: 320, h: 200, settings: s, to: url)
    let clip = try Analysis.index(url)
    let picks = Analysis.keyframes(clip)
    print("  \(clip.count) frames, keyframes \(picks)")
    check(picks.count == 6 && picks == picks.sorted() && Set(picks).count == 6, "want 6 ascending unique picks, got \(picks)")
    check(picks.first == 0 && picks.last == clip.count - 1, "first and last frame must both be shown: \(picks)")
    check(picks.filter { $0 <= 7 }.count >= 3, "at least half the picks should sit in the burst of change: \(picks)")

    // Fewer frames than tiles: show them all.
    let short = tempURL()
    defer { try? FileManager.default.removeItem(at: short) }
    _ = try encodeClip(scenes.map { textFrame($0.words, background: $0.bg, w: 320, h: 200) }, w: 320, h: 200, settings: s, to: short, tick: 0.5)
    check(Analysis.keyframes(try Analysis.index(short)) == [0, 1, 2], "a 3-frame clip should show all 3 frames")
}

func captionParsing() throws {
    let plain = Describe.parse("CAPTION: Tests fail then pass\nALT: A terminal shows a failing test, then a fix, then all tests passing.")
    check(plain?.caption == "Tests fail then pass" && plain?.altText.hasPrefix("A terminal shows") == true, "plain labels: \(String(describing: plain))")
    // What the on-device model actually returned in practice: bold labels.
    let bold = Describe.parse("**CAPTION:** Terminal shows test results\n**ALT:** The window lists a failure and then a pass.")
    check(bold?.caption == "Terminal shows test results" && bold?.altText == "The window lists a failure and then a pass.", "bold labels: \(String(describing: bold))")
    let bullets = Describe.parse("- caption: \"Quoted caption\"\n- Alt text: Something happens.")
    check(bullets?.caption == "Quoted caption" && bullets?.altText == "Something happens.", "bullets, quotes, case: \(String(describing: bullets))")
    check(Describe.parse("Here is a caption for you!") == nil, "prose with no labels must be rejected, not guessed at")
    check(Describe.parse("CAPTION: only one field") == nil, "a missing field must be rejected")
    check(Describe.parse("CAPTION:\nALT: x") == nil, "an empty field must be rejected")
}

func sidecarEndToEnd() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gifwin-sidecar-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let gif = dir.appendingPathComponent("demo.gif")
    var s = Quality.crisp.settings
    s.trim = true
    let stats = try encodeClip(sceneClip(), w: sceneW, h: sceneH, settings: s, to: gif)

    let meta = CaptureMeta(app: "Demo App", bundleID: "com.example.demo", appVersion: "2.4.1 (318)", windowID: 4242,
                           windowTitle: "Build output", windowWidth: 800, windowHeight: 450, displayScale: 2,
                           startedAt: Date(timeIntervalSince1970: 1_800_000_000), requestedSeconds: 5, quality: "crisp", settings: s)
    var result = CaptureResult(url: gif, width: sceneW, height: sceneH, frames: stats.frames, bytes: stats.bytes,
                               seconds: stats.duration, truncated: false)
    result.trimmedHead = stats.trimmedHead
    let finished = result
    let side = try block { try await Sidecar.write(gif: gif, capture: meta, result: finished, ai: true) }
    let m = side.manifest

    // The evidence record is true to the file it describes.
    let bytes = try Data(contentsOf: gif)
    check(m.output.sha256 == Sidecar.sha256(bytes), "manifest sha256 does not match the GIF")
    check(m.output.bytes == bytes.count && m.output.frames == stats.frames, "manifest size/frames disagree with the GIF")
    check(abs(m.output.durationSeconds - stats.duration) < 0.02, "manifest duration \(m.output.durationSeconds) vs \(stats.duration)")
    check(m.output.delaysCentiseconds.reduce(0, +) == Int((stats.duration * 100).rounded()), "per-frame delays do not sum to the duration")
    check(m.os.build.count >= 4 && m.os.version.hasPrefix("macOS"), "OS block incomplete: \(m.os)")

    // Capture facts survive a trip through the file (snake_case keys, ISO dates).
    let back = Sidecar.existingCapture(for: gif)
    check(back?.bundleId == "com.example.demo" && back?.windowId == 4242 && back?.appVersion == "2.4.1 (318)", "capture facts lost on round trip: \(String(describing: back))")
    check(back?.startedAt == meta.startedAt && back?.settings == s, "date or settings lost on round trip")
    let raw = try String(contentsOf: side.manifestURL, encoding: .utf8)
    check(raw.contains("\"bundle_id\"") && raw.contains("\"sha256\"") && raw.contains("\"started_at\""), "manifest keys are not snake_case")

    // OCR reads the scenes, and each keyframe carries the words shown at that moment.
    let text = m.analysis.keyframes.map { $0.text.joined(separator: " ").uppercased() }
    print("  keyframes:", m.analysis.keyframes.map { "#\($0.index)@\($0.timeSeconds)s \($0.text.first ?? "-")" })
    for (i, scene) in scenes.enumerated() {
        let want = scene.words[0]
        check(text.contains { $0.contains(want) }, "scene \(i) '\(want)' never read by OCR; saw \(text)")
    }
    check(text.first?.contains("COMPILING") == true && text.last?.contains("PASSED") == true, "first/last keyframes should show first/last scenes: \(text)")

    // Caption and alt text are built only from what was read.
    print("  caption (\(m.analysis.captionSource)): \(m.analysis.caption)")
    check(!m.analysis.caption.isEmpty && !m.analysis.altText.isEmpty, "empty caption or alt text")
    check(m.analysis.caption.count <= 160, "caption too long: \(m.analysis.caption.count)")

    // The contact sheet is a real PNG with the first frame at the top left and the last at the bottom right.
    guard let sheetURL = side.contactSheetURL, let src = CGImageSourceCreateWithURL(sheetURL as CFURL, nil),
          let sheet = CGImageSourceCreateImageAtIndex(src, 0, nil) else { check(false, "no decodable contact sheet"); return }
    print("  contact sheet \(sheet.width)x\(sheet.height), \((try? Data(contentsOf: sheetURL).count) ?? 0) B")
    check(sheet.width >= 1000 && sheet.width <= 1600 && sheet.height >= 300, "unreasonable sheet size \(sheet.width)x\(sheet.height)")
    let pixels = Fit.bgra(sheet, width: sheet.width, height: sheet.height)
    func at(_ x: Int, _ y: Int) -> (Int, Int, Int) { let v = pixels[y * sheet.width + x]; return (Int((v >> 16) & 255), Int((v >> 8) & 255), Int(v & 255)) }
    let tileW = 480, tileH = 270, gutter = 8, strip = 24   // 640x360 fitted into 480x360, label strip above
    let first = at(gutter + 240, gutter + strip + tileH - 12)
    let lastSlot = m.analysis.keyframes.count - 1
    let lastX = gutter + (lastSlot % 3) * (tileW + gutter) + 240
    let lastY = gutter + (lastSlot / 3) * (tileH + strip + gutter) + strip + tileH - 12
    let last = at(lastX, lastY)
    check(abs(first.0 - 200) < 12 && abs(first.2 - 255) < 12, "top-left tile should be the first scene (pale blue), got \(first)")
    check(abs(last.1 - 255) < 12 && abs(last.0 - 200) < 12, "last tile should be the final scene (pale green), got \(last)")

    // describe on the finished file works from the command layer and returns the same evidence.
    let described = try block { await Command.run(Request(args: ["describe", gif.path, "--json"], cwd: "/")) }
    let d = try JSONSerialization.jsonObject(with: Data(described.stdout.utf8)) as? [String: Any]
    check(described.code == 0 && d?["sha256"] as? String == m.output.sha256, "describe --json should repeat the manifest's hash")
    check((d?["contact_sheet"] as? String).map { FileManager.default.fileExists(atPath: $0) } == true, "describe: contact sheet path not on disk")
    check(Sidecar.existingCapture(for: gif)?.bundleId == "com.example.demo", "describe must keep the original capture facts")

    // --no-ai keeps the sheet and manifest but reads nothing.
    let quiet = try block { try await Sidecar.write(gif: gif, capture: meta, result: finished, ai: false) }
    check(quiet.manifest.analysis.keyframes.allSatisfy { $0.text.isEmpty } && quiet.manifest.analysis.ocr == false, "--no-ai must not read text")
    check(quiet.manifest.analysis.captionSource == "deterministic" && quiet.contactSheetURL != nil, "--no-ai should fall back to a metadata caption and still make the sheet")

    let missing = try block { await Command.run(Request(args: ["describe", dir.appendingPathComponent("nope.gif").path], cwd: "/")) }
    check(missing.code == 64, "describe of a missing file should be a usage error")
}

// MARK: - Policy, consent, audit

func scratchDirs() throws -> (config: URL, state: URL, env: [String: String]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("gifwin-policy-\(UUID().uuidString)")
    let c = root.appendingPathComponent("config"), st = root.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: st, withIntermediateDirectories: true)
    return (c, st, ["GIFWIN_CONFIG_DIR": c.path, "GIFWIN_STATE_DIR": st.path])
}

/// The audit file is append-only by flag, so tidying up needs the flag cleared first.
func removeScratch(_ d: (config: URL, state: URL, env: [String: String])) {
    chflags(Audit.url(d.env).path, 0)
    try? FileManager.default.removeItem(at: d.config.deletingLastPathComponent())
}

func run(_ args: [String], caller: String? = nil, env: [String: String], cwd: String = "/tmp") throws -> (code: Int32, json: [String: Any]?, out: Outcome) {
    let o = try block { await Command.run(Request(args: args, cwd: cwd, env: env, caller: caller)) }
    return (o.code, (try? JSONSerialization.jsonObject(with: Data(o.stdout.utf8))) as? [String: Any], o)
}

func policyDecisions() throws {
    var consent = Consent()
    let none = Policy()
    func d(_ caller: String, _ bundle: String, _ title: String = "", force: Bool = false, policy: Policy = none) -> Decision {
        PolicyGate.decide(caller: caller, force: force, bundleID: bundle, title: title, policy: policy, consent: consent)
    }
    check(d("cli", "com.apple.Terminal") == .allow, "a person may record an ordinary app")
    check(d("mcp", "com.apple.Terminal") == .needsConsent("com.apple.Terminal"), "an agent must be given consent first")
    if case .deny = d("mcp", "com.1password.1password") {} else { check(false, "agents must never record a password manager") }
    if case .deny = d("cli", "com.1password.1password") {} else { check(false, "even a person is stopped without --force") }
    check(d("cli", "com.1password.1password", force: true) == .allow, "a person may override with --force")
    if case .deny = d("mcp", "com.1password.1password", force: true) {} else { check(false, "--force must not work for an agent") }
    if case .deny = d("mcp", "com.google.Chrome", "New Tab - Google Chrome (Incognito)") {} else { check(false, "private browser windows are refused") }
    if case .deny = d("mcp", "com.apple.Safari", "Private Browsing - Safari") {} else { check(false, "Safari private windows are refused") }
    check(d("cli", "com.google.Chrome", "New Tab - Google Chrome (Incognito)", force: true) == .allow, "--force overrides the private-window rule for a person")

    var allowing = Policy(); allowing.allow = ["com.apple.Terminal"]
    check(d("mcp", "com.apple.Terminal", policy: allowing) == .allow, "the allowlist admits an agent")
    allowing.deny = ["com.apple.Terminal"]
    if case .deny = d("mcp", "com.apple.Terminal", policy: allowing) {} else { check(false, "deny beats allow") }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    consent.grant("com.apple.Notes", hours: 24, now: now)
    check(PolicyGate.decide(caller: "mcp", force: false, bundleID: "com.apple.Notes", title: "", policy: none, consent: consent, now: now.addingTimeInterval(23 * 3600)) == .allow, "consent holds inside its window")
    check(PolicyGate.decide(caller: "mcp", force: false, bundleID: "com.apple.Notes", title: "", policy: none, consent: consent, now: now.addingTimeInterval(25 * 3600)) == .needsConsent("com.apple.Notes"), "consent expires")
    consent.revoke("com.apple.Notes")
    check(!consent.isValid("com.apple.Notes", now: now), "revoked consent is gone")
}

func policyFile() throws {
    let d = try scratchDirs()
    defer { removeScratch(d) }
    let file = d.config.appendingPathComponent("policy.toml")
    try """
    # which apps an agent may record without asking
    [agent]
    allow = ["com.apple.Terminal", "com.microsoft.VSCode"]   # my editor and shell
    deny = [
        "com.example.secret",
        "com.example.other",
    ]
    consent_hours = 8
    """.write(to: file, atomically: true, encoding: .utf8)
    let (p, err) = Policy.load(env: d.env)
    check(err == nil && p.allow == ["com.apple.Terminal", "com.microsoft.VSCode"], "allow list: \(p.allow) \(err ?? "")")
    check(p.deny == ["com.example.secret", "com.example.other"], "a list over several lines: \(p.deny)")
    check(p.consentHours == 8, "number read: \(p.consentHours)")

    for (name, bad) in [("unquoted value", "[agent]\nallow = com.apple.Terminal"), ("a list of numbers", "[agent]\nallow = [1, 2]"),
                        ("no equals sign", "[agent]\nallow"), ("unclosed list", "[agent]\nallow = [\"a\"")] {
        try bad.write(to: file, atomically: true, encoding: .utf8)
        check(Policy.load(env: d.env).error != nil, "\(name) must be an error, not a silent default")
    }
    try FileManager.default.removeItem(at: file)
    check(Policy.load(env: d.env).error == nil && Policy.load(env: d.env).policy == Policy(), "no file means the default policy")
}

func consentPersists() throws {
    let d = try scratchDirs()
    defer { removeScratch(d) }
    var c = Consent()
    c.grant("com.apple.Terminal", hours: 2)
    try c.save(env: d.env)
    check(Consent.load(env: d.env).isValid("com.apple.Terminal"), "consent survives a save and load")
    check(!Consent.load(env: d.env).isValid("com.apple.Notes"), "and does not leak to other apps")
    let mode = (try FileManager.default.attributesOfItem(atPath: Consent.url(d.env).path)[.posixPermissions] as? Int) ?? 0
    check(mode & 0o077 == 0, "the consent file is private (mode \(String(mode, radix: 8)))")
}

func auditIsAppendOnly() throws {
    let d = try scratchDirs()
    defer { removeScratch(d) }
    var e = Audit.Entry(); e.op = "capture"; e.bundleID = "com.apple.Terminal"; e.app = "Terminal"; e.code = 0
    Audit.write(e, env: d.env)
    let path = Audit.url(d.env).path
    var st = stat(); stat(path, &st)
    check(st.st_mode & 0o077 == 0, "log file is private (mode \(String(st.st_mode & 0o777, radix: 8)))")
    check(st.st_flags & UInt32(UF_APPEND) != 0, "the append-only flag is set")

    // Truncating or rewriting must fail, appending must not.
    errno = 0
    let trunc = open(path, O_WRONLY | O_TRUNC)
    check(trunc < 0 && errno == EPERM, "truncate is refused (errno \(errno))")
    if trunc >= 0 { close(trunc) }
    errno = 0
    let rewrite = open(path, O_WRONLY)
    if rewrite >= 0 { close(rewrite) }
    check(rewrite < 0, "opening without O_APPEND is refused")
    check(Audit.tail(10, env: d.env).count == 1, "the first entry is still there")

    // 200 concurrent writers: every line must arrive whole.
    DispatchQueue.concurrentPerform(iterations: 200) { i in
        var x = Audit.Entry(); x.op = "capture"; x.app = "App \(i)"; x.windowTitle = String(repeating: "t", count: 300); x.code = 0
        Audit.write(x, env: d.env)
    }
    let lines = Audit.tail(1000, env: d.env)
    check(lines.count == 201, "201 lines, got \(lines.count)")
    check(lines.allSatisfy { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil }, "every line is a whole JSON object")
}

func policyThroughTheCommand() throws {
    let d = try scratchDirs()
    defer { removeScratch(d) }
    func fake(_ bundle: String, _ title: String = "", caller: String, _ extra: [String] = []) throws -> (code: Int32, json: [String: Any]?, out: Outcome) {
        var env = d.env
        env["GIFWIN_FAULT"] = "fake-window:\(bundle):\(title)"
        return try run(["--json", "--window", "x", "--seconds", "1"] + extra, caller: caller, env: env)
    }
    func log() -> [[String: Any]] { Audit.tail(1000, env: d.env).compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] } }

    // A password manager, asked for by an agent.
    var r = try fake("com.1password.1password", "Vault", caller: "mcp")
    check(r.code == 77 && r.json?["error"] as? String == "policy_denied", "agent vs password manager: \(r.code) \(String(describing: r.json?["error"]))")
    check(log().last?["phase"] as? String == "refused" && log().last?["bundle_id"] as? String == "com.1password.1password", "the refusal is logged")

    // An ordinary app, no consent yet: the answer tells the agent what to ask the person.
    r = try fake("com.apple.Terminal", "zsh", caller: "mcp")
    check(r.code == 77 && r.json?["error"] as? String == "consent_required", "needs consent: \(String(describing: r.json?["error"]))")
    check((r.json?["grant_command"] as? String) == "gifwin consent grant com.apple.Terminal", "it names the exact command: \(String(describing: r.json?["grant_command"]))")
    check((r.json?["remediation"] as? String)?.contains("gifwin consent grant") == true, "and says it in words")

    // The person grants it (not available to the agent).
    let denied = try run(["consent", "grant", "com.apple.Terminal"], caller: "mcp", env: d.env)
    check(denied.code == 77, "an agent cannot grant itself consent")
    let grant = try run(["consent", "grant", "com.apple.Terminal", "--hours", "1"], env: d.env)
    check(grant.code == 0 && grant.out.stdout.contains("1 hours"), "the person can: \(grant.out.stdout)")
    let before = log().count
    r = try fake("com.apple.Terminal", "zsh", caller: "mcp")
    check(r.code == 70, "with consent it proceeds as far as the fake window allows (70), got \(r.code)")
    let tail = Array(log().suffix(log().count - before))
    check(tail.map { $0["phase"] as? String } == ["start", "result"], "a capture that began logs start then result: \(tail.map { $0["phase"] ?? "?" })")
    check(tail.last?["code"] as? Int == 70 && tail.first?["decision"] as? String == "allowed", "the result line carries the outcome")

    // A person at the keyboard: ordinary app is fine, password manager needs --force.
    r = try fake("com.apple.Notes", "Todo", caller: "cli")
    check(r.code == 70, "a person needs no consent, got \(r.code)")
    r = try fake("com.1password.1password", "Vault", caller: "cli")
    check(r.code == 77, "a person is still stopped without --force")
    r = try fake("com.1password.1password", "Vault", caller: "cli", ["--force"])
    check(r.code == 70, "--force lets a person through, got \(r.code)")
    r = try fake("com.1password.1password", "Vault", caller: "mcp", ["--force"])
    check(r.code == 77, "--force means nothing to an agent")

    // Policy file: allowlist admits, invalid file fails closed for agents only.
    let policy = d.config.appendingPathComponent("policy.toml")
    try "[agent]\nallow = [\"com.microsoft.VSCode\"]\n".write(to: policy, atomically: true, encoding: .utf8)
    r = try fake("com.microsoft.VSCode", "main.swift", caller: "mcp")
    check(r.code == 70, "an allowlisted app proceeds without consent, got \(r.code)")
    try "[agent\nallow = ".write(to: policy, atomically: true, encoding: .utf8)
    r = try fake("com.microsoft.VSCode", "main.swift", caller: "mcp")
    check(r.code == 77 && r.json?["error"] as? String == "policy_invalid", "a broken policy file fails closed for agents: \(String(describing: r.json?["error"]))")
    r = try fake("com.apple.Notes", "Todo", caller: "cli")
    check(r.code == 70, "but does not lock a person out, got \(r.code)")

    // Dry runs are questions, not captures: answered, not logged.
    try FileManager.default.removeItem(at: policy)
    let n = log().count
    r = try fake("com.apple.Notes", "Todo", caller: "cli", ["--dry-run"])
    check(r.code == 0 && log().count == n, "a dry run is allowed and writes no log line")

    // Coverage: every refused or begun capture above has a line, and every begun one has an end.
    let entries = log()
    let starts = entries.filter { $0["phase"] as? String == "start" }.count
    let results = entries.filter { $0["phase"] as? String == "result" }.count
    check(starts == results && starts >= 4, "every start has a result: \(starts) starts, \(results) results")
    check(entries.allSatisfy { $0["ts"] != nil && $0["caller"] != nil && $0["op"] != nil }, "every line says when, who and what")
    let shown = try run(["log", "--tail", "3"], env: d.env)
    check(shown.code == 0 && shown.out.stdout.split(separator: "\n").count == 3, "gifwin log shows the last 3")
}

// MARK: - Secrets, redaction, predicates

func secretPatterns() throws {
    let github = "ghp_" + String(repeating: "aB3dE6", count: 6)
    let must: [(String, String)] = [
        ("AWS key id", "key AKIAIOSFODNN7EXAMPLE in env"),
        ("GitHub token", "token \(github) pasted"),
        ("API key", "ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123"),
        ("Slack token", "xox" + "b-123456789012-abcdefghijklmnop"),
        ("JWT", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1rwW1gFWFOEjXk"),
        ("bearer header", "Authorization: Bearer abcdef0123456789abcdef"),
        ("email", "write to jane.doe@example.com today"),
        ("password assignment", "password: hunter2hunter2"),
        ("api_key assignment", "api_key = zzzzzzzzzzzz"),
        ("card number", "card 4111 1111 1111 1111 exp 12/29"),
        ("card, dashes", "4111-1111-1111-1111"),
        ("private key", "-----BEGIN RSA PRIVATE KEY-----"),
    ]
    for (name, text) in must {
        let m = Secrets.mask(text)
        check(m.count >= 1 && m.text.contains("[REDACTED]"), "\(name) not caught: \(text)")
    }
    let mustNot: [(String, String)] = [
        ("plain log line", "Build succeeded in 3.2s"),
        ("commit hash", "commit 3fce642 M0 walking skeleton"),
        ("number failing Luhn", "4111 1111 1111 1112"),
        ("twelve digits", "order #123456789012"),
        ("version", "gifwin 0.2.0 build 1.2.3.4567"),
        ("word 'token' alone", "token expired, please sign in again"),
        ("short assignment", "token = abc"),
        ("a path", "/Users/river/Projects/showcase/Sources/main.swift"),
    ]
    for (name, text) in mustNot {
        let m = Secrets.mask(text)
        check(m.count == 0 && m.text == text, "\(name) wrongly masked: \(m.text)")
    }
    check(Secrets.mask("email me at jane.doe@example.com today").text == "email me at [REDACTED] today", "only the secret is replaced, not the sentence")
    check(Secrets.mask("password: hunter2hunter2").text == "password: [REDACTED]", "a credential keeps its label: \(Secrets.mask("password: hunter2hunter2").text)")
    check(Secrets.mask("a@b.example and c@d.example").count == 2, "two matches in one line are both found")
}

func redactorBlanksSecrets() throws {
    let (w, h) = (1280, 360)
    let github = "ghp_" + String(repeating: "aB3dE6", count: 6)
    let lines = ["Build succeeded in 3.2s", "token: \(github)", "owner: jane.doe@example.com"]
    let original = textFrame(lines, background: (255, 255, 255), w: w, h: h, size: 34)

    let redactor = Redactor(width: w, height: h)
    var frame = original
    let started = Date()
    redactor.process(&frame)
    print("  first frame redacted in \(Int(Date().timeIntervalSince(started) * 1000)) ms, \(redactor.applied) region(s)")
    check(redactor.applied >= 2, "expected the token and the email to be masked, got \(redactor.applied) regions")

    guard let image = Redactor.image(frame, width: w, rowRange: 0..<h) else { check(false, "no image"); return }
    let seen = OCR.lines(in: image).joined(separator: "\n")
    check(!seen.contains("ghp_") && !seen.lowercased().contains("jane.doe"), "a secret is still readable after redaction:\n\(seen)")
    check(seen.contains("Build succeeded"), "ordinary text must stay readable:\n\(seen)")

    // The untouched line is byte for byte what it was; only the secret rows changed.
    let top = 0..<(h - 110 + 40)   // rows above the second line's text
    _ = top
    var changedRows = Set<Int>()
    for y in 0..<h where (0..<w).contains(where: { original[y * w + $0] != frame[y * w + $0] }) { changedRows.insert(y) }
    check(!changedRows.isEmpty && changedRows.count < h * 3 / 4, "redaction should touch some rows, not all: \(changedRows.count) of \(h)")

    // A second frame that changes only a small spot elsewhere: the mask must persist without being re-read.
    var next = original
    for y in 330..<350 { for x in 1200..<1220 { next[y * w + x] = pack(0, 0, 0) } }
    let before = redactor.applied
    redactor.process(&next)
    check(redactor.applied > before, "boxes persist across frames")
    guard let image2 = Redactor.image(next, width: w, rowRange: 0..<h) else { return }
    check(!OCR.lines(in: image2).joined().contains("ghp_"), "the token must stay masked on later frames")

    // A secret that appears later is caught in the strip that changed.
    let later = textFrame(lines + ["secret: sk-live-abcdefghijklmnopqrstuvwx"], background: (255, 255, 255), w: w, h: h, size: 34)
    var third = later
    redactor.process(&third)
    guard let image3 = Redactor.image(third, width: w, rowRange: 0..<h) else { return }
    let seen3 = OCR.lines(in: image3).joined(separator: "\n")
    check(!seen3.contains("abcdefghijklmnop"), "a newly appearing secret must be masked:\n\(seen3)")
}

func redactionEndToEnd() throws {
    // Whole path: redact while recording, encode, then verify nothing readable survives and the manifest says so.
    let (w, h) = (1280, 360)
    let github = "ghp_" + String(repeating: "aB3dE6", count: 6)
    let frames = (0..<6).map { i in textFrame(["Step \(i): deploying", "token: \(github)", "contact jane.doe@example.com"], background: (255, 255, 255), w: w, h: h, size: 34) }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gifwin-redact-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    var s = Quality.crisp.settings
    s.trim = false
    let plain = dir.appendingPathComponent("plain.gif"), safe = dir.appendingPathComponent("safe.gif")
    let source = { SyntheticSource(frames: frames, width: w, height: h, fps: s.fps) }
    _ = try block { try await Capture.record(source: source(), seconds: 5, to: plain, settings: s, redact: false) }
    let r = try block { try await Capture.record(source: source(), seconds: 5, to: safe, settings: s, redact: true) }
    check(r.maskedRegions > 0, "the capture should report masked regions")

    let leaky = try block { try await Sidecar.write(gif: plain, capture: nil, result: nil, ai: true, redacted: false) }
    let clean = try block { try await Sidecar.write(gif: safe, capture: nil, result: r, ai: true, redacted: true) }
    check(leaky.manifest.analysis.redaction.textMasked > 0, "unredacted pixels: OCR does find the secrets (\(leaky.manifest.analysis.redaction.textMasked)), and the manifest masks them")
    check(clean.manifest.analysis.redaction.residualInOutput == 0, "redacted clip: \(clean.manifest.analysis.redaction.residualInOutput) secrets still readable")
    let manifestText = try String(contentsOf: clean.manifestURL, encoding: .utf8) + (try String(contentsOf: leaky.manifestURL, encoding: .utf8))
    check(!manifestText.contains("ghp_") && !manifestText.contains("jane.doe"), "no manifest may contain a secret, redacted clip or not")
    check(clean.manifest.analysis.redaction.pixels == true, "manifest records that pixels were redacted")
    check(!clean.manifest.analysis.altText.contains("ghp_") && !leaky.manifest.analysis.altText.contains("jane.doe"), "captions and alt text must not carry secrets")
    check(clean.manifest.analysis.keyframes.flatMap(\.text).contains { $0.contains("deploying") }, "ordinary text is still read in the redacted clip")
}

func predicatesStopEarly() throws {
    let (w, h) = (640, 360)
    let compiling = textFrame(["COMPILING"], background: (230, 230, 255), w: w, h: h)
    let passed = textFrame(["BUILD PASSED"], background: (225, 255, 225), w: w, h: h)
    var s = Quality.balanced.settings
    s.fps = 2   // 0.5 s per frame: 20 frames is a 10 s script
    s.trim = false
    let dir = FileManager.default.temporaryDirectory
    func record(_ frames: [[UInt32]], _ until: StopCondition?, after: Double = 1) throws -> CaptureResult {
        let url = dir.appendingPathComponent("gifwin-pred-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        return try block { try await Capture.record(source: SyntheticSource(frames: frames, width: w, height: h, fps: 2), seconds: 60, to: url, settings: s, until: until, after: after) }
    }

    let script = [[UInt32]](repeating: compiling, count: 10) + [[UInt32]](repeating: passed, count: 10)  // text appears at t = 5.0
    var r = try record(script, .text("build passed"))
    print("  text:    stopped_by \(r.stoppedBy), predicate at \(r.predicateTime ?? -1) s, clip \(r.seconds) s")
    check(r.stoppedBy == "predicate" && abs((r.predicateTime ?? 0) - 5.0) < 0.6, "text should fire when 'BUILD PASSED' appears (t=5): \(String(describing: r.predicateTime))")
    check(abs(r.seconds - 6.0) < 0.7, "and the clip should end 1 s later (about 6 s), not at 10: \(r.seconds)")

    r = try record(script, .text("BUILD PASSED"), after: 0)
    check(abs(r.seconds - 5.0) < 0.7, "--after 0 ends at the moment: \(r.seconds)")

    r = try record(script, .text("never appears"))
    check(r.stoppedBy == "ended" && r.predicateTime == nil && r.seconds > 9, "a predicate that never fires records everything: \(r.stoppedBy) \(r.seconds)")

    r = try record(script, nil)
    check(r.stoppedBy == "ended", "no predicate: \(r.stoppedBy)")

    // change: ten still frames, then something moves.
    var moving = [[UInt32]](repeating: compiling, count: 6)
    moving += [[UInt32]](repeating: passed, count: 10)
    r = try record(moving, .change, after: 0)
    check(r.stoppedBy == "predicate" && abs((r.predicateTime ?? 0) - 3.0) < 0.6, "change fires when the screen changes (t=3): \(String(describing: r.predicateTime))")

    // quiet: busy for 4 s, then still. Should stop 2 s after the last change.
    var busy: [[UInt32]] = []
    for i in 0..<8 { var f = compiling; for y in 100..<140 { for x in (20 + i * 60)..<(60 + i * 60) { f[y * w + x] = pack(200, 0, 0) } }; busy.append(f) }
    busy += [[UInt32]](repeating: busy.last!, count: 12)
    r = try record(busy, .quiet(2), after: 0)
    print("  quiet:2  stopped_by \(r.stoppedBy), predicate at \(r.predicateTime ?? -1) s")
    check(r.stoppedBy == "predicate" && abs((r.predicateTime ?? 0) - 5.5) < 0.8, "quiet:2 fires 2 s after the last change (~5.5): \(String(describing: r.predicateTime))")

    // quiet never fires on a screen that never changes (nothing happened to wait out).
    r = try record([[UInt32]](repeating: compiling, count: 12), .quiet(2))
    check(r.stoppedBy == "ended", "a screen that never changed is not 'quiet after something': \(r.stoppedBy)")

    check(StopCondition.parse("text:Build succeeded") == .text("Build succeeded") && StopCondition.parse("quiet:2.5") == .quiet(2.5) && StopCondition.parse("CHANGE") == .change, "predicate syntax")
    check(StopCondition.parse("quiet:abc") == nil && StopCondition.parse("text:") == nil && StopCondition.parse("later") == nil, "bad predicates are rejected")
}

// MARK: - Rolling buffer

/// Every frame differs from the last: a counter bar grows and a block moves, over a fixed background.
func movingClip(_ count: Int, w: Int = 320, h: Int = 200) -> [[UInt32]] {
    var base = [UInt32](repeating: pack(245, 245, 247), count: w * h)
    for y in 0..<24 { for x in 0..<w { base[y * w + x] = pack(30, 60, 140) } }
    return (0..<count).map { i in
        var f = base
        for y in 40..<56 { for x in 10..<(10 + (i * 3) % 280) { f[y * w + x] = pack(52, 168, 83) } }
        let bx = 10 + (i * 7) % (w - 50), by = 90 + (i * 5) % 80
        for y in by..<(by + 30) { for x in bx..<(bx + 30) { f[y * w + x] = pack(200, 40 + (i * 9) % 150, 40) } }
        return f
    }
}

let fakeInfo = WindowInfo(id: 77, app: "Demo App", bundleID: "com.example.demo", pid: 1, title: "Demo", width: 320, height: 200)

func ringKeepsTheRecentPast() throws {
    var s = Quality.balanced.settings
    s.fps = 10
    let settings = s
    let frames = movingClip(120)   // 12 s at 10 fps
    let watcher = try block { try await Watcher.start(source: SyntheticSource(frames: frames, width: 320, height: 200, fps: 10, staysOpen: true),
                                                      info: fakeInfo, rolling: 5, settings: settings) }
    print("  ring holds \(String(format: "%.1f", watcher.heldSeconds)) s in \(watcher.heldFrames) frames, \(watcher.heldBytes / 1024) KB")
    check(watcher.heldSeconds >= 5 && watcher.heldSeconds <= 5 + Watcher.keyframeInterval + 0.6, "ring should hold 5 s plus at most one segment, holds \(watcher.heldSeconds)")
    check(watcher.startsOnKeyframe, "the oldest frame in the ring must stand alone")
    check(watcher.heldBytes < 1_500_000, "ring is \(watcher.heldBytes) bytes")

    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let saved = try watcher.save(lastSeconds: 3, to: url)
    print("  saved last 3 s -> \(saved.seconds) s, \(saved.frames) frames, \(saved.bytes / 1024) KB")
    check(saved.seconds >= 3 && saved.seconds <= 3 + Watcher.keyframeInterval + 0.6, "asked for 3 s, got \(saved.seconds)")

    // The proof that the deltas chain: decode the saved clip and compare it with what was on screen.
    guard let clip = decode(url, 320, 200), clip.frames.count > 3 else { check(false, "saved clip does not decode"); return }
    let end = psnr(clip.frames.last!, frames.last!)
    let startIndex = max(0, Int(((12.0 - saved.seconds) * 10).rounded()))
    let begin = psnr(clip.frames.first!, frames[startIndex])
    print("  saved clip: first frame vs source #\(startIndex): \(String(format: "%.1f", begin)) dB, last vs final: \(String(format: "%.1f", end)) dB")
    check(end >= 30, "the clip must end on what was on screen last (\(end) dB)")
    check(begin >= 30, "and start on a full frame from the right moment (\(begin) dB)")
    check(abs(clip.total - saved.seconds) < 0.05, "the file's own duration \(clip.total) vs reported \(saved.seconds)")

    // Asking for more than exists returns what exists.
    let whole = try watcher.save(lastSeconds: 600, to: url)
    check(abs(whole.seconds - watcher.heldSeconds - 0.1) < 0.35, "asking for 10 minutes returns the ring: \(whole.seconds) vs \(watcher.heldSeconds)")

    // Saving does not disturb the recording: it can be done again.
    let again = try watcher.save(lastSeconds: 3, to: url)
    check(again.frames == saved.frames, "a second save is the same clip")
}

func ringStaysWithinItsMemoryBudget() throws {
    // The performance budget: 30 s of rolling footage of a busy window, under 20 MB. Real windows
    // change less than this clip does, so it is a ceiling.
    var s = Quality.balanced.settings
    s.fps = 12.5
    let settings = s
    let watcher = try block { try await Watcher.start(source: SyntheticSource(frames: movingClip(1000, w: 1024, h: 640), width: 1024, height: 640, fps: 12.5, staysOpen: true),
                                                      info: fakeInfo, rolling: 30, settings: settings) }
    let mb = Double(watcher.heldBytes) / 1_048_576
    print("  80 s fed, ring holds \(String(format: "%.1f", watcher.heldSeconds)) s = \(String(format: "%.2f", mb)) MB")
    check(watcher.heldSeconds >= 30 && watcher.heldSeconds <= 30 + Watcher.keyframeInterval + 0.6, "holds about 30 s: \(watcher.heldSeconds)")
    check(mb < 20, "30 s of a busy 1024x640 window is \(mb) MB, budget 20 MB")
}

func watchersAreFoundByName() throws {
    var s = Quality.balanced.settings
    s.fps = 10
    let settings = s
    func make(_ id: UInt32, _ app: String, _ bundle: String) throws -> Watcher {
        let info = WindowInfo(id: id, app: app, bundleID: bundle, pid: 1, title: "", width: 320, height: 200)
        return try block { try await Watcher.start(source: SyntheticSource(frames: movingClip(5), width: 320, height: 200, fps: 10, staysOpen: true), info: info, rolling: 5, settings: settings) }
    }
    for w in Watchers.active() { _ = Watchers.remove(w.info.id) }
    if case .success = Watchers.find(nil) { check(false, "nothing watched should not resolve") }
    let a = try make(101, "Terminal", "com.apple.Terminal")
    Watchers.add(a)
    if case .success(let w) = Watchers.find(nil) { check(w.info.id == 101, "the only watcher is the default") } else { check(false, "a single watcher should be the default") }
    let b = try make(102, "Safari", "com.apple.Safari")
    Watchers.add(b)
    if case .success = Watchers.find(nil) { check(false, "two watchers must not resolve without a name") }
    for (sel, want) in [("id:102", 102), ("safari", 102), ("com.apple.Terminal", 101), ("Term", 101)] {
        if case .success(let w) = Watchers.find(sel) { check(w.info.id == UInt32(want), "\(sel) -> \(w.info.id), wanted \(want)") } else { check(false, "\(sel) not found") }
    }
    if case .success = Watchers.find("nope") { check(false, "unknown name must fail") }
    check(Watchers.count == 2, "two active, got \(Watchers.count)")
    try block { await b.stop() }
    check(Watchers.count == 1, "a watcher whose window closed is dropped: \(Watchers.count)")
    for w in Watchers.active() { _ = Watchers.remove(w.info.id) }
}

func saveLastThroughTheCommand() throws {
    let d = try scratchDirs()
    let out = d.config.deletingLastPathComponent().appendingPathComponent("out")
    defer { removeScratch(d); for w in Watchers.active() { _ = Watchers.remove(w.info.id) } }
    for w in Watchers.active() { _ = Watchers.remove(w.info.id) }

    var s = Quality.balanced.settings
    s.fps = 10
    let settings = s
    let watcher = try block { try await Watcher.start(source: SyntheticSource(frames: movingClip(80), width: 320, height: 200, fps: 10, staysOpen: true),
                                                      info: fakeInfo, rolling: 5, settings: settings) }
    Watchers.add(watcher)
    var resident = d.env
    resident["GIFWIN_RESIDENT"] = "1"
    func log() -> [[String: Any]] { Audit.tail(1000, env: d.env).compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] } }

    // Outside the helper there is no buffer that could survive, so these must refuse plainly.
    var r = try run(["save-last", "3", "--json"], env: d.env)
    check(r.code == 70 && (r.json?["message"] as? String)?.contains("helper") == true, "outside the helper: \(r.code) \(String(describing: r.json?["message"]))")
    r = try run(["watch", "--status"], env: d.env)
    check(r.code == 70, "watch --status outside the helper: \(r.code)")

    r = try run(["watch", "--status", "--json"], env: resident)
    let rows = (try? JSONSerialization.jsonObject(with: Data(r.out.stdout.utf8))) as? [[String: Any]]
    check(r.code == 0 && rows?.count == 1 && rows?.first?["app"] as? String == "Demo App", "status lists the watcher: \(r.out.stdout)")

    // An agent: no consent yet, so the buffer stays shut. The person grants it, then it works.
    r = try run(["save-last", "3", "--json", "--out", out.path], caller: "mcp", env: resident)
    check(r.code == 77 && r.json?["error"] as? String == "consent_required", "agent without consent: \(r.code) \(String(describing: r.json?["error"]))")
    check(log().last?["op"] as? String == "save_last" && log().last?["phase"] as? String == "refused", "the refusal is logged as save_last")
    _ = try run(["consent", "grant", "com.example.demo"], env: d.env)
    r = try run(["save-last", "3", "--json", "--out", out.path, "--name", "moment", "--no-ai"], caller: "mcp", env: resident)
    check(r.code == 0, "with consent it saves, got \(r.code): \(r.out.stderr)")
    let gif = out.appendingPathComponent("moment.gif")
    check(FileManager.default.fileExists(atPath: gif.path), "the GIF is at the named path")
    check((r.json?["contact_sheet"] as? String).map { FileManager.default.fileExists(atPath: $0) } == true, "it comes with a contact sheet")
    check((r.json?["sha256"] as? String) == Sidecar.sha256((try? Data(contentsOf: gif)) ?? Data()), "and a manifest hash that matches the file")
    check(Sidecar.existingCapture(for: gif)?.bundleId == "com.example.demo", "the manifest records which app it was")
    let seconds = r.json?["duration_seconds"] as? Double ?? 0
    check(seconds >= 3 && seconds <= 5.5, "about the last 3 s: \(seconds)")
    let ops = log().compactMap { $0["op"] as? String }
    check(ops.suffix(2) == ["save_last", "save_last"] && log().last?["phase"] as? String == "result" && log().last?["code"] as? Int == 0, "start and result lines for the save: \(ops.suffix(3))")

    // Asking for a watcher that is not there.
    r = try run(["save-last", "3", "--window", "nonexistent", "--json"], env: resident)
    check(r.code == 65, "unknown watched window is 65, got \(r.code)")

    // Stopping.
    r = try run(["watch", "--stop", "--json"], env: resident)
    check(r.code == 0 && (r.json?["stopped"] as? Int) == 1 && Watchers.count == 0, "stop ends the watcher: \(r.out.stdout)")
    r = try run(["save-last", "3", "--json"], env: resident)
    check(r.code == 65, "nothing left to save from: \(r.code)")
}

// MARK: - Video

func ffprobe(_ file: URL, _ entries: String) -> [String: String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
    p.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", entries, "-of", "default=nw=1", file.path]
    let pipe = Pipe()
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return [:] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    var out: [String: String] = [:]
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
        if kv.count == 2 { out[kv[0]] = kv[1] }
    }
    return out
}

func mp4Records() throws {
    let (w, h) = (641, 361)   // odd on purpose: H.264 needs even sizes
    let scenesW = scenes.flatMap { sc in [[UInt32]](repeating: textFrame(sc.words, background: sc.bg, w: w, h: h), count: 8) }
    var s = Quality.balanced.settings
    s.fps = 12.5
    s.trim = false
    let settings = s
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gifwin-video-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("clip.mp4")
    let r = try block { try await Capture.record(source: SyntheticSource(frames: scenesW, width: w, height: h, fps: 12.5), seconds: 60, to: url, settings: settings, format: .mp4) }
    print("  mp4: \(r.width)x\(r.height), \(r.frames) frames kept of \(scenesW.count), \(r.bytes) B, \(r.seconds) s")

    let asset = AVURLAsset(url: url)
    let duration = try block { try await asset.load(.duration).seconds }
    let track = try block { try await asset.loadTracks(withMediaType: .video).first }
    let size = try block { try await track!.load(.naturalSize) }
    check(abs(duration - 24 / 12.5) < 0.25, "duration \(duration) s, wanted 1.92 s")
    check(Int(size.width) == 640 && Int(size.height) == 360, "odd frame size rounds down to even: \(size)")
    let description = try block { try await track!.load(.formatDescriptions).first }
    check(description.map { CMFormatDescriptionGetMediaSubType($0) } == kCMVideoCodecType_H264, "the video is H.264")
    check(r.frames == 3, "a window that shows three scenes writes three frames, not \(r.frames)")
    check(r.bytes < 40_000, "three still scenes should be tiny: \(r.bytes) B")

    // The same evidence as a GIF: a sheet to look at, text read, a manifest that matches the file.
    let side = try block { try await Sidecar.write(gif: url, capture: nil, result: r, ai: true) }
    let words = side.manifest.analysis.keyframes.map { $0.text.joined(separator: " ").uppercased() }.joined(separator: " | ")
    print("  video keyframes read: \(words)")
    check(["COMPILING", "TESTS", "PASSED"].allSatisfy { words.contains($0) }, "OCR should read all three scenes from the video: \(words)")
    let fileBytes = try Data(contentsOf: url)
    check(side.manifest.output.format == "mp4" && side.manifest.output.sha256 == Sidecar.sha256(fileBytes), "manifest names the format and hashes the file")
    check(side.contactSheetURL.map { FileManager.default.fileExists(atPath: $0.path) } == true, "a contact sheet exists")
    check(side.manifest.output.delaysCentiseconds.isEmpty, "a video has no GIF delays")

    // A frame that never changes costs nothing.
    let still = dir.appendingPathComponent("still.mp4")
    let sr = try block { try await Capture.record(source: SyntheticSource(frames: [[UInt32]](repeating: scenesW[0], count: 100), width: w, height: h, fps: 12.5), seconds: 60, to: still, settings: settings, format: .mp4) }
    check(sr.frames == 1 && sr.bytes < 25_000, "100 identical frames write one: \(sr.frames) frames, \(sr.bytes) B")
}

func webmNeedsFfmpegAndSaysSo() throws {
    guard WebM.ffmpeg() != nil else { print("  skip  ffmpeg is not installed here"); return }
    let (w, h) = (640, 360)
    var s = Quality.balanced.settings
    s.fps = 12.5
    let settings = s
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gifwin-webm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let mp4 = dir.appendingPathComponent("clip.mp4"), webm = dir.appendingPathComponent("clip.webm")
    let frames = scenes.flatMap { sc in [[UInt32]](repeating: textFrame(sc.words, background: sc.bg, w: w, h: h), count: 8) }
    _ = try block { try await Capture.record(source: SyntheticSource(frames: frames, width: w, height: h, fps: 12.5), seconds: 60, to: mp4, settings: settings, format: .mp4) }

    try WebM.transcode(mp4, to: webm, settings: settings)
    let probe = ffprobe(webm, "stream=codec_name,width,height")
    print("  webm: \(probe), \((try? Data(contentsOf: webm).count) ?? 0) B")
    check(probe["codec_name"] == "vp9" && probe["width"] == "640" && probe["height"] == "360", "a VP9 WebM of the same size: \(probe)")

    // No ffmpeg: say so, keep the MP4, and name it.
    do {
        try WebM.transcode(mp4, to: dir.appendingPathComponent("x.webm"), settings: settings, env: ["GIFWIN_FFMPEG": "none"])
        check(false, "should have failed without ffmpeg")
    } catch let e as GifwinError {
        check(e.slug == "ffmpeg_missing" && e.details["fallback"] == mp4.path && e.remediation?.contains("brew install ffmpeg") == true, "plain failure with the MP4's path: \(e.message)")
        check(FileManager.default.fileExists(atPath: mp4.path), "the MP4 is still there")
    }
    // A corrupt input fails cleanly rather than hanging or leaving a half file.
    let bad = dir.appendingPathComponent("bad.mp4")
    try Data("not a video".utf8).write(to: bad)
    do { try WebM.transcode(bad, to: dir.appendingPathComponent("bad.webm"), settings: settings); check(false, "garbage input should fail") }
    catch let e as GifwinError { check(e.slug == "ffmpeg_failed", "garbage input: \(e.slug ?? "?")") }
}

func formatFlagsAreValidated() throws {
    var r = try run(["1", "-w", "x", "--format", "avi"], env: [:])
    check(r.code == 64, "unknown format is a usage error: \(r.code)")
    r = try run(["1", "-w", "x", "--format", "mp4", "--max-bytes", "1k"], env: [:])
    check(r.code == 64 && r.out.stderr.contains("only applies"), "--max-bytes with a video is refused: \(r.code) \(r.out.stderr)")
    check(Command.fileNameForTests(app: "My App", override: "demo", ext: "mp4") == "demo.mp4", "an override gets the right extension")
    check(Command.fileNameForTests(app: "My App", override: "demo.webm", ext: "webm") == "demo.webm", "and keeps a matching one")
}

// MARK: - Run

let all: [(String, () throws -> Void)] = [
    ("writer round-trips every palette size exactly", writerRoundTrip),
    ("transparent index and sub-rectangles composite", transparencyAndRects),
    ("delays round and clamp", delaysClamp),
    ("Wu reproduces exact colours", wuFindsExactColours),
    ("scrolling text @balanced", { try clipChecks("scroll", scrollClip(), .balanced, Expect(minPSNR: 45, maxBytes: 27_000)) }),
    ("cursor over chrome @balanced", { try clipChecks("cursor", cursorClip(), .balanced, Expect(minPSNR: 60, maxBytes: 4_800)) }),
    ("gradient @balanced", { try clipChecks("gradient", gradientClip(), .balanced, Expect(minPSNR: 27, maxBytes: 300_000)) }),
    ("hard cuts @balanced", { try clipChecks("cuts", cutClip(), .balanced, Expect(minPSNR: 60, maxBytes: 3_200)) }),
    ("scrolling text @draft", { try clipChecks("scroll", scrollClip(), .draft, Expect(minPSNR: 45, maxBytes: 27_000)) }),
    ("scrolling text @max", { try clipChecks("scroll", scrollClip(), .max, Expect(minPSNR: 45, maxBytes: 27_000)) }),
    ("identical output for identical input", deterministic),
    ("dither is temporally stable", ditherIsTemporallyStable),
    ("byte budget ladder", budgetLadder),
    ("trim caps still head and tail, keeps the middle's timing", trimsStillHeadAndTail),
    ("keyframes follow the change", keyframesFollowTheChange),
    ("policy decisions: who may record what", policyDecisions),
    ("policy.toml parses strictly", policyFile),
    ("consent persists and expires", consentPersists),
    ("audit log is append-only and whole under concurrency", auditIsAppendOnly),
    ("policy and audit through the real command", policyThroughTheCommand),
    ("secret patterns catch credentials, spare ordinary text", secretPatterns),
    ("redactor blanks secrets in pixels, keeps the rest", redactorBlanksSecrets),
    ("redaction end to end: clip, manifest, caption", redactionEndToEnd),
    ("predicates stop a recording early", predicatesStopEarly),
    ("ring keeps the recent past and saves it as a valid clip", ringKeepsTheRecentPast),
    ("ring stays within its memory budget", ringStaysWithinItsMemoryBudget),
    ("watchers are found by name", watchersAreFoundByName),
    ("save-last through the command: policy, audit, evidence", saveLastThroughTheCommand),
    ("mp4: valid H.264, small, analysed like a GIF", mp4Records),
    ("webm needs ffmpeg and says so", webmNeedsFfmpegAndSaysSo),
    ("format flags are validated", formatFlagsAreValidated),
    ("caption replies parse however the model dresses them", captionParsing),
    ("sheet, manifest, OCR, caption, describe", sidecarEndToEnd),
]
// CHECK_ONLY=<text> runs just the checks whose name contains it.
let only = ProcessInfo.processInfo.environment["CHECK_ONLY"]
for (name, run) in all {
    if let only, !name.contains(only) { continue }
    let before = failures
    print(name)
    do { try run() } catch { failures += 1; print("  FAIL  threw \(error)") }
    print(failures == before ? "  ok" : "  FAILED")
}
print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
