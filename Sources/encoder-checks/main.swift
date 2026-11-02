import CoreGraphics
import Foundation
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
]
for (name, run) in all {
    let before = failures
    print(name)
    do { try run() } catch { failures += 1; print("  FAIL  threw \(error)") }
    print(failures == before ? "  ok" : "  FAILED")
}
print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
