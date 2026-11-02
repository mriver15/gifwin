import CoreGraphics
import Foundation
import ImageIO

/// Re-encodes a finished GIF at lower cost until it fits a byte budget.
///
/// The ladder follows what the eye notices least: colours first, then frame rate, then size.
/// The first pass is encoded once at the requested preset; only an overshoot pays for more.
/// Re-encoding reads the GIF back through ImageIO one frame at a time, so memory stays near
/// one frame however long the clip is.
public enum Fit {
    struct Step {
        var colors: Int
        var minInterval: Double
        var scale: Double
    }

    static func ladder(from base: EncoderSettings) -> [Step] {
        var steps: [Step] = []
        for c in [96, 64, 48, 32] where c < base.colors {
            steps.append(Step(colors: c, minInterval: 0, scale: 1))
        }
        let floorColors = min(base.colors, 32)
        for fps in [10.0, 8.0] where fps < base.fps {
            steps.append(Step(colors: floorColors, minInterval: 1 / fps, scale: 1))
        }
        let lastInterval = steps.last?.minInterval ?? 0
        for s in [0.85, 0.7, 0.55] {
            steps.append(Step(colors: floorColors, minInterval: max(lastInterval, 1 / 8), scale: s))
        }
        return steps
    }

    /// Replaces `url` with the largest ladder step that fits, or the smallest one tried.
    public static func toBudget(_ result: CaptureResult, maxBytes: Int, settings: EncoderSettings) throws -> CaptureResult {
        guard result.bytes > maxBytes else { return result }
        var best = result
        let scratch = result.url.deletingLastPathComponent().appendingPathComponent(".\(result.url.lastPathComponent).fit")
        defer { try? FileManager.default.removeItem(at: scratch) }

        var steps = 0
        for step in ladder(from: settings) {
            steps += 1
            var tuned = settings
            tuned.colors = step.colors
            let attempt = try reencode(source: result.url, to: scratch, settings: tuned,
                                       minInterval: step.minInterval, scale: step.scale)
            if attempt.bytes < best.bytes {
                best = attempt
                try FileManager.default.removeItem(at: result.url)
                try FileManager.default.copyItem(at: scratch, to: result.url)
                best.url = result.url
            }
            if best.bytes <= maxBytes { break }
        }
        best.budgetSteps = steps
        best.budgetMet = best.bytes <= maxBytes
        best.truncated = result.truncated
        return best
    }

    public static func reencode(source: URL, to destination: URL, settings: EncoderSettings,
                                minInterval: Double, scale: Double) throws -> CaptureResult {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let first = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw GifwinError(.internalFailure, "Could not read \(source.lastPathComponent) back for re-encoding")
        }
        let w = max(1, Int((Double(first.width) * scale).rounded()))
        let h = max(1, Int((Double(first.height) * scale).rounded()))
        let writer = try GIFWriter(url: destination, width: w, height: h)
        let encoder = FrameEncoder(writer: writer, settings: settings, minInterval: minInterval)

        var t = 0.0
        for i in 0..<CGImageSourceGetCount(src) {
            guard let image = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            try encoder.add(bgra(image, width: w, height: h), at: t)
            t += delay(src, i)
        }
        guard let stats = try encoder.finish(endTime: t) else {
            throw GifwinError(.internalFailure, "Re-encode produced no frames")
        }
        return CaptureResult(url: destination, width: stats.width, height: stats.height, frames: stats.frames,
                             bytes: stats.bytes, seconds: stats.duration, truncated: false)
    }

    public static func delay(_ src: CGImageSource, _ index: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        return (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? 0.1
    }

    /// Draws `image` into a tightly packed BGRA array at `width` x `height`.
    public static func bgra(_ image: CGImage, width: Int, height: Int) -> [UInt32] {
        var pixels = [UInt32](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}
