import CoreGraphics
import Foundation
import CoreText
import ImageIO
import GifwinCore

// Dev-only encoder checks. Swift Testing and XCTest both need full Xcode; the Command Line
// Tools alone ship neither working. Run with `swift run -c release encoder-checks`.

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
    let done = DispatchSemaphore(value: 0)
    Task { do { box.value = .success(try await work()) } catch { box.value = .failure(error) }; done.signal() }
    done.wait()
    return try box.value!.get()
}

/// A frame of solid colour with `lines` of large text, drawn with CoreText into BGRA pixels.
func textFrame(_ lines: [String], background: (Int, Int, Int), w: Int, h: Int) -> [UInt32] {
    var px = [UInt32](repeating: pack(background.0, background.1, background.2), count: w * h)
    px.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 44, nil)
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
    ("caption replies parse however the model dresses them", captionParsing),
    ("sheet, manifest, OCR, caption, describe", sidecarEndToEnd),
]
for (name, run) in all {
    let before = failures
    print(name)
    do { try run() } catch { failures += 1; print("  FAIL  threw \(error)") }
    print(failures == before ? "  ok" : "  FAILED")
}
print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
