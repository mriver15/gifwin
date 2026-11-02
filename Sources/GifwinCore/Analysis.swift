import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a finished GIF looks like over time, measured once and reused by everything downstream.
public struct ClipIndex {
    let imageAt: (Int) -> CGImage?
    public let width: Int
    public let height: Int
    /// Seconds each frame stays on screen.
    public let delays: [Double]
    /// How much each frame differs from the one before, 0...1. `energy[0]` is 0.
    public let energy: [Double]

    public var count: Int { delays.count }
    public var duration: Double { delays.reduce(0, +) }
    public func start(of frame: Int) -> Double { delays[..<frame].reduce(0, +) }
    public func image(_ frame: Int) -> CGImage? { imageAt(frame) }
}

/// Frames pulled out of a video, kept so each is decoded once however many times it is asked for.
final class FrameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Int: CGImage] = [:]

    func image(_ index: Int, _ make: () -> CGImage?) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = frames[index] { return cached }
        let made = make()
        if let made { frames[index] = made }
        return made
    }
}

public enum Analysis {
    /// Decodes every frame at thumbnail size to measure change. Cheap next to the capture itself.
    public static func index(_ url: URL) throws -> ClipIndex {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let first = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw GifwinError(.internalFailure, "Cannot read \(url.lastPathComponent) as an animated GIF")
        }
        let aw = 160, ah = max(1, first.height * 160 / max(first.width, 1))
        var delays: [Double] = [], energy: [Double] = []
        var previous: [UInt32]?
        for i in 0..<CGImageSourceGetCount(src) {
            guard let image = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let small = Fit.bgra(image, width: aw, height: ah)
            energy.append(previous.map { meanChange($0, small) } ?? 0)
            delays.append(Fit.delay(src, i))
            previous = small
        }
        guard !delays.isEmpty else { throw GifwinError(.internalFailure, "\(url.lastPathComponent) has no decodable frames") }
        return ClipIndex(imageAt: { CGImageSourceCreateImageAtIndex(src, $0, nil) },
                         width: first.width, height: first.height, delays: delays, energy: energy)
    }

    /// A GIF or a video, whichever `url` is. A video is sampled, not decoded in full: enough frames to
    /// see how it changes, which is all the contact sheet and keyframe choice need.
    public static func indexAny(_ url: URL) async throws -> ClipIndex {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v": return try await indexVideo(url)
        case "webm": throw GifwinError(.internalFailure, "macOS cannot read WebM; analyse the MP4 it was made from instead.")
        default: return try index(url)
        }
    }

    static func indexVideo(_ url: URL) async throws -> ClipIndex {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let length = try? await asset.load(.duration), length.seconds > 0 else {
            throw GifwinError(.internalFailure, "Cannot read \(url.lastPathComponent) as a video")
        }
        let duration = length.seconds
        let samples = min(48, max(6, Int(duration * 4)))
        let times = (0..<samples).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(samples), preferredTimescale: 600) }

        let small = AVAssetImageGenerator(asset: asset)
        small.appliesPreferredTrackTransform = true
        small.maximumSize = CGSize(width: 160, height: 160 * size.height / max(size.width, 1))
        small.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        small.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        var energy: [Double] = []
        var previous: [UInt32]?
        for t in times {
            guard let image = try? await small.image(at: t).image else { energy.append(0); continue }
            let px = Fit.bgra(image, width: image.width, height: image.height)
            energy.append(previous.flatMap { $0.count == px.count ? meanChange($0, px) : nil } ?? 0)
            previous = px
        }

        let full = AVAssetImageGenerator(asset: asset)
        full.appliesPreferredTrackTransform = true
        full.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        full.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let cache = FrameCache()
        return ClipIndex(imageAt: { i in
            guard times.indices.contains(i) else { return nil }
            // Synchronous on purpose, and serialised by the cache's lock: the generator is not safe to
            // call from several threads at once. copyCGImage is deprecated but is the only blocking API.
            return cache.image(i) { try? full.copyCGImage(at: times[i], actualTime: nil) }
        }, width: Int(size.width), height: Int(size.height),
           delays: [Double](repeating: duration / Double(samples), count: samples), energy: energy)
    }

    private static func meanChange(_ a: [UInt32], _ b: [UInt32]) -> Double {
        var sum = 0
        for i in 0..<a.count where a[i] != b[i] {
            sum += abs(Int((a[i] >> 16) & 255) - Int((b[i] >> 16) & 255))
                + abs(Int((a[i] >> 8) & 255) - Int((b[i] >> 8) & 255))
                + abs(Int(a[i] & 255) - Int(b[i] & 255))
        }
        return Double(sum) / Double(a.count * 3 * 255)
    }

    /// Frames worth looking at: the first, the last, and the ones where the cumulative change crosses
    /// even steps, so keyframes land where something happened rather than at even time intervals.
    /// A clip that never changes yields just its first and last frame.
    public static func keyframes(_ clip: ClipIndex, count k: Int = 6) -> [Int] {
        let n = clip.count
        if n <= k { return Array(0..<n) }
        var cumulative: [Double] = []
        var running = 0.0
        for e in clip.energy { running += e; cumulative.append(running) }
        guard let total = cumulative.last, total > 0 else { return [0, n - 1] }

        var picks: Set<Int> = [0, n - 1]
        for j in 1..<(k - 1) {
            let target = total * Double(j) / Double(k - 1)
            picks.insert(cumulative.firstIndex { $0 >= target } ?? n - 1)
        }
        // Two targets can land on one frame; fill the gap with the biggest unused change.
        while picks.count < k {
            guard let extra = (0..<n).filter({ !picks.contains($0) }).max(by: { clip.energy[$0] < clip.energy[$1] }) else { break }
            picks.insert(extra)
        }
        return picks.sorted()
    }

    // MARK: - Contact sheet

    /// One PNG holding the keyframes in a grid, each stamped with its time in the clip. This is what a
    /// model looks at instead of a hundred frames: sized to be read in a single image.
    public static func contactSheet(_ clip: ClipIndex, frames: [Int], footer: String) -> Data? {
        guard !frames.isEmpty else { return nil }
        let cols = min(3, frames.count), rows = (frames.count + cols - 1) / cols
        // The time label sits in its own strip above each tile, never over the window's own pixels.
        let box = (w: 480.0, h: 360.0), gutter = 8.0, footerHeight = 30.0, labelHeight = 24.0
        let aspect = Double(clip.width) / Double(clip.height)
        let tile = aspect >= box.w / box.h ? (w: box.w, h: (box.w / aspect).rounded()) : (w: (box.h * aspect).rounded(), h: box.h)
        let cellW = tile.w, cellH = tile.h
        let width = Int(Double(cols) * cellW + Double(cols + 1) * gutter)
        let height = Int(Double(rows) * (cellH + labelHeight) + Double(rows + 1) * gutter + footerHeight)

        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high

        for (slot, frame) in frames.enumerated() {
            guard let image = clip.image(frame) else { continue }
            let col = slot % cols, row = slot / cols
            let x = gutter + Double(col) * (cellW + gutter)
            let topY = gutter + Double(row) * (cellH + labelHeight + gutter)
            let y = Double(height) - topY - labelHeight - cellH // CoreGraphics counts from the bottom
            ctx.draw(image, in: CGRect(x: x, y: y, width: cellW, height: cellH))
            label(ctx, String(format: "%.2fs  #%d", clip.start(of: frame), frame), x: x + 2, y: y + cellH + 7, pill: false)
        }
        label(ctx, footer, x: gutter, y: 9, size: 13, pill: false)

        guard let out = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func label(_ ctx: CGContext, _ text: String, x: Double, y: Double, size: Double = 13, pill: Bool = true) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        guard let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(string)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        if pill {
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.72))
            ctx.addPath(CGPath(roundedRect: CGRect(x: x - 5, y: y - 4, width: bounds.width + 10, height: bounds.height + 8),
                               cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
        }
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }
}
