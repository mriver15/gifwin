import CoreGraphics
import Foundation
import ImageIO
import GifwinCore

// Dev-only encoder checks. Swift Testing and XCTest both need full Xcode; the Command Line
// Tools alone ship neither working. These run with `swift run encoder-checks`.
var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL  \(what)") }
}
struct CheckError: Error { let what: String }
func unwrap<T>(_ v: T?) throws -> T { guard let v else { throw CheckError(what: "unexpected nil") }; return v }

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("gifwin-\(UUID().uuidString).gif")
}

/// Decodes frame `i` to RGBA bytes.
func decode(_ source: CGImageSource, _ i: Int, _ w: Int, _ h: Int) throws -> [UInt8] {
    let image = try unwrap(CGImageSourceCreateImageAtIndex(source, i, nil))
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = try unwrap(CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return rgba
}

enum Checks {
    /// Every pixel handed to the encoder must decode to that index's palette colour. Random data
    /// overflows the 4096-entry table, so this exercises code-size growth and clear-code resets.
    static func noisyFramesRoundTripExactly() throws {
        let (w, h) = (160, 120)
        var rng = SplitMix64(seed: 42)
        let frames: [[UInt8]] = (0..<3).map { _ in (0..<w * h).map { _ in UInt8(truncatingIfNeeded: rng.next()) } }

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try GIFWriter(url: url, width: w, height: h)
        for f in frames { try writer.addFrame(indices: f, delayCS: 8) }
        try writer.finish()

        let source = try unwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        check(CGImageSourceGetCount(source) == 3, "CGImageSourceGetCount(source) == 3")
        for (n, f) in frames.enumerated() {
            let rgba = try decode(source, n, w, h)
            var mismatches = 0
            for p in 0..<(w * h) {
                let c = GIFWriter.Palette.color(Int(f[p]))
                if [rgba[p * 4], rgba[p * 4 + 1], rgba[p * 4 + 2]] != [c.r, c.g, c.b] { mismatches += 1 }
            }
            check(mismatches == 0, "frame \(n): \(mismatches) of \(w * h) pixels differ")
        }
    }

    static func solidFramesAndDelays() throws {
        let (w, h) = (64, 48)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try GIFWriter(url: url, width: w, height: h)
        try writer.addFrame(indices: [UInt8](repeating: 0xE0, count: w * h), delayCS: 10) // red
        try writer.addFrame(indices: [UInt8](repeating: 0x1C, count: w * h), delayCS: 25) // green
        try writer.addFrame(indices: [UInt8](repeating: 0x00, count: w * h), delayCS: 0)  // clamped to 2
        try writer.finish()
        check(writer.frameCount == 3, "writer.frameCount == 3")

        let source = try unwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let delays = (0..<3).map { i -> Double in
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? -1
        }
        check(abs(delays[0] - 0.10) < 0.001, "abs(delays[0] - 0.10) < 0.001")
        check(abs(delays[1] - 0.25) < 0.001, "abs(delays[1] - 0.25) < 0.001")
        check(abs(delays[2] - 0.02) < 0.001, "abs(delays[2] - 0.02) < 0.001")

        let first = try decode(source, 0, w, h)
        check([first[0], first[1], first[2]] == [255, 0, 0], "[first[0], first[1], first[2]] == [255, 0, 0]")
        let second = try decode(source, 1, w, h)
        check([second[0], second[1], second[2]] == [0, 255, 0], "[second[0], second[1], second[2]] == [0, 255, 0]")
    }

    static func singlePixelFrame() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try GIFWriter(url: url, width: 1, height: 1)
        try writer.addFrame(indices: [0xFF], delayCS: 5)
        try writer.finish()
        let source = try unwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        check(CGImageSourceGetCount(source) == 1, "CGImageSourceGetCount(source) == 1")
    }
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

let all: [(String, () throws -> Void)] = [
    ("noisy frames round-trip exactly", Checks.noisyFramesRoundTripExactly),
    ("solid frames and delays", Checks.solidFramesAndDelays),
    ("single pixel frame", Checks.singlePixelFrame),
]
for (name, run) in all {
    let before = failures
    do { try run() } catch { failures += 1; print("FAIL  \(name): \(error)") }
    print(failures == before ? "ok    \(name)" : "FAIL  \(name)")
}
exit(failures == 0 ? 0 : 1)
