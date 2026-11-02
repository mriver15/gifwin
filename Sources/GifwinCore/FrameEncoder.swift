import Foundation

public struct EncodeStats: Sendable {
    public let frames: Int
    public let bytes: Int
    public let width: Int
    public let height: Int
    /// Total playback time of the written clip, in seconds.
    public let duration: Double
    /// Seconds of still footage cut from the start and the end.
    public let trimmedHead: Double
    public let trimmedTail: Double
}

/// Anything that turns timestamped frames into a finished file. The GIF encoder is one; the video encoder is another.
public protocol FrameConsumer: AnyObject {
    /// How many frames were kept, and when the newest was, on the source's clock.
    var acceptedCount: Int { get }
    var lastAcceptedTime: Double { get }
    var bytesWritten: Int { get }
    func add(_ pixels: [UInt32], at time: Double) throws
    func finish(endTime: Double) throws -> EncodeStats?
}

/// Turns a stream of timestamped frames into a compact GIF.
///
/// - Changes are measured against `reference`, the source colour each pixel last had when it was
///   written, not against the previous captured frame. A slow fade therefore still updates once it
///   has drifted past the tolerance, instead of being dropped one imperceptible step at a time.
/// - Only the bounding box of changed pixels is quantized and written; unchanged pixels inside it
///   use the transparent index, so the viewer keeps the old pixel.
/// - Every frame gets its own Wu palette, built from the changed pixels alone.
/// - A frame is held back until the next one arrives so its delay is known when it is written.
public final class FrameEncoder: FrameConsumer {
    private struct Encoded {
        var x: Int, y: Int, w: Int, h: Int
        var indices: [UInt8]
        var palette: [UInt8]
        var transparent: Int?
    }

    public let width: Int
    public let height: Int
    public var bytesWritten: Int { writer.bytesWritten }
    private let writer: GIFFrameSink
    private let settings: EncoderSettings
    private let minInterval: Double
    private let keyframeInterval: Double?
    private var lastKeyTime = -Double.infinity
    /// When the newest frame was kept, and how many were. Used to tell "nothing has changed" from "nothing arrived".
    public private(set) var lastAcceptedTime = -Double.infinity
    public private(set) var acceptedCount = 0
    private let wu = Wu()

    private var reference: [UInt32] = []
    private var mask: [UInt8]
    private var pending: Encoded?
    private var pendingTime = 0.0
    private var firstTime = 0.0
    private var emittedCS = 0.0
    private var trimmedCS = 0.0
    private var trimmedHeadCS = 0.0
    private var trimmedTailCS = 0.0
    /// The newest frame that was dropped, kept so the clip can end on what was really on screen.
    private var heldBack: [UInt32]?
    private var heldBackTime = 0.0

    /// - Parameter minInterval: extra spacing (seconds) to enforce beyond the preset's own rate; used
    ///   when re-encoding at a lower rate to meet a byte budget.
    /// - Parameter keyframeInterval: force a full frame at least this often (seconds). A clip cut from the
    ///   middle can only start on a full frame, so a rolling buffer needs them.
    public init(writer: GIFFrameSink, settings: EncoderSettings, minInterval: Double = 0, keyframeInterval: Double? = nil) {
        self.writer = writer
        self.settings = settings
        self.keyframeInterval = keyframeInterval
        // Never accept frames faster than the preset's rate, whatever the source delivers; the
        // 0.9 leaves room for timestamp jitter on a source that is paced at exactly that rate.
        self.minInterval = max(minInterval, 0.9 / settings.fps)
        width = writer.width
        height = writer.height
        mask = [UInt8](repeating: 0, count: writer.width * writer.height)
    }

    /// `pixels` is `width * height` values laid out as BGRA read little-endian: `B | G<<8 | R<<16 | A<<24`.
    public func add(_ pixels: [UInt32], at time: Double) throws {
        precondition(pixels.count == width * height)
        if reference.isEmpty {
            firstTime = time
            reference = pixels
            for i in 0..<mask.count { mask[i] = 1 }
            pending = encode(pixels, bounds: (0, 0, width, height), first: true)
            pendingTime = time
            lastAcceptedTime = time
            lastKeyTime = time
            acceptedCount = 1
            return
        }
        if let every = keyframeInterval, time - lastKeyTime >= every {
            // A periodic full frame, whether or not anything changed, so a clip can start here.
            try flush(until: time)
            for i in 0..<mask.count { mask[i] = 1 }
            reference = pixels
            pending = encode(pixels, bounds: (0, 0, width, height), first: true)
            pendingTime = time
            lastAcceptedTime = time
            lastKeyTime = time
            acceptedCount += 1
            heldBack = nil
            return
        }
        if time - lastAcceptedTime < minInterval - 1e-6 {
            heldBack = pixels
            heldBackTime = time
            return
        }
        let (count, bounds) = measure(pixels, tolerance: settings.tolerance)
        let floor = max(1.0, settings.dropFraction * Double(width * height))
        guard let bounds, Double(count) >= floor else {
            heldBack = pixels
            heldBackTime = time
            return
        }
        try accept(pixels, bounds: bounds, at: time)
    }

    public func finish(endTime: Double) throws -> EncodeStats? {
        guard pending != nil else { return nil }
        // End on the real final state even if it was too small a change to keep mid-clip.
        if let last = heldBack {
            let (count, bounds) = measure(last, tolerance: 0)
            // This frame only exists to end on the real final state, so the stillness before it is the tail.
            if count > 0, let bounds { try accept(last, bounds: bounds, at: heldBackTime, closing: true) }
            heldBack = nil
        }
        try flush(until: max(endTime, pendingTime + 0.02), isLast: true)
        try writer.finish()
        return EncodeStats(frames: writer.frameCount, bytes: writer.bytesWritten,
                           width: width, height: height, duration: emittedCS / 100,
                           trimmedHead: trimmedHeadCS / 100, trimmedTail: trimmedTailCS / 100)
    }

    /// The held-back frame as it would be written if the clip ended at `time`, without ending anything.
    /// Lets a rolling buffer export up to the present moment.
    public func peekPending(at time: Double) -> (x: Int, y: Int, w: Int, h: Int, indices: [UInt8], palette: [UInt8], transparent: Int?, delayCS: Int)? {
        guard let f = pending else { return nil }
        let delay = max(settings.minDelayCS, Int(((time - pendingTime) * 100).rounded()))
        return (f.x, f.y, f.w, f.h, f.indices, f.palette, f.transparent, delay)
    }

    // MARK: - Accepting frames

    private func accept(_ pixels: [UInt32], bounds: (Int, Int, Int, Int), at time: Double, closing: Bool = false) throws {
        try flush(until: time, isLast: closing)
        pending = encode(pixels, bounds: bounds, first: false)
        pendingTime = time
        lastAcceptedTime = time
        acceptedCount += 1
        heldBack = nil
    }

    /// Fills `mask` with the pixels that moved past `tolerance` since they were last written.
    private func measure(_ pixels: [UInt32], tolerance: Int) -> (Int, (Int, Int, Int, Int)?) {
        var count = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        let w = width
        pixels.withUnsafeBufferPointer { px in
            reference.withUnsafeBufferPointer { ref in
                mask.withUnsafeMutableBufferPointer { m in
                    for y in 0..<height {
                        var rowChanged = false
                        for x in 0..<w {
                            let p = y * w + x
                            let a = px[p], b = ref[p]
                            var changed = false
                            if a != b {
                                let dr = abs(Int((a >> 16) & 255) - Int((b >> 16) & 255))
                                let dg = abs(Int((a >> 8) & 255) - Int((b >> 8) & 255))
                                let db = abs(Int(a & 255) - Int(b & 255))
                                changed = max(dr, dg, db) > tolerance
                            }
                            m[p] = changed ? 1 : 0
                            if changed {
                                count += 1
                                rowChanged = true
                                if x < minX { minX = x }
                                if x > maxX { maxX = x }
                            }
                        }
                        if rowChanged {
                            if y < minY { minY = y }
                            maxY = y
                        }
                    }
                }
            }
        }
        guard count > 0 else { return (0, nil) }
        return (count, (minX, minY, maxX - minX + 1, maxY - minY + 1))
    }

    // MARK: - Encoding one frame

    private func encode(_ pixels: [UInt32], bounds: (x: Int, y: Int, w: Int, h: Int), first: Bool) -> Encoded {
        let (bx, by, bw, bh) = bounds
        wu.reset()
        pixels.withUnsafeBufferPointer { px in
            mask.withUnsafeBufferPointer { m in
                for y in by..<(by + bh) {
                    for x in bx..<(bx + bw) {
                        let p = y * width + x
                        guard m[p] != 0 else { continue }
                        let v = px[p]
                        wu.add(r: Int((v >> 16) & 255), g: Int((v >> 8) & 255), b: Int(v & 255))
                    }
                }
            }
        }
        // The last palette slot is the transparent index on every frame but the first.
        let result = wu.build(maxColors: first ? settings.colors : settings.colors - 1)
        let transparent: Int? = first ? nil : result.count
        var palette = result.palette
        if transparent != nil { palette.append(contentsOf: [0, 0, 0]) }

        var out = [UInt8](repeating: 0, count: bw * bh)
        map(pixels, bounds: bounds, tag: result.tag, palette: result.palette, count: result.count,
            transparent: transparent, into: &out)

        // Pixels that were written now hold their new source colour.
        for y in by..<(by + bh) {
            for x in bx..<(bx + bw) {
                let p = y * width + x
                if mask[p] != 0 { reference[p] = pixels[p] }
            }
        }
        return Encoded(x: bx, y: by, w: bw, h: bh, indices: out, palette: palette, transparent: transparent)
    }

    /// Maps each changed pixel to a palette index.
    ///
    /// The Wu cell table is exact for an undithered pixel: its own cell held it when the palette was
    /// built. Dithering is applied only where that match is poor, so flat UI keeps its exact colours
    /// and stays uniform. A dithered colour can land in a cell no pixel occupied, whose table entry
    /// is arbitrary, so those cells resolve by nearest palette entry instead (cached per frame).
    private func map(_ pixels: [UInt32], bounds: (x: Int, y: Int, w: Int, h: Int), tag: [UInt8],
                     palette: [UInt8], count: Int, transparent: Int?, into out: inout [UInt8]) {
        let (bx, by, bw, bh) = bounds
        let skip = UInt8(truncatingIfNeeded: transparent ?? 0)
        let limit: Int
        switch settings.dither {
        case .off: limit = Int.max
        case .adaptive: limit = 120
        case .bayer: limit = 30
        }
        var nearest = [UInt8](repeating: 255, count: 32768)
        pixels.withUnsafeBufferPointer { px in
            mask.withUnsafeBufferPointer { m in
                palette.withUnsafeBufferPointer { pal in
                    tag.withUnsafeBufferPointer { tg in
                        nearest.withUnsafeMutableBufferPointer { near in
                            out.withUnsafeMutableBufferPointer { o in
                                for y in 0..<bh {
                                    for x in 0..<bw {
                                        let p = (by + y) * width + bx + x
                                        if transparent != nil && m[p] == 0 {
                                            o[y * bw + x] = skip
                                            continue
                                        }
                                        let v = px[p]
                                        let r = Int((v >> 16) & 255), g = Int((v >> 8) & 255), b = Int(v & 255)
                                        var k = Int(tg[(r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)])
                                        let er = r - Int(pal[k * 3]), eg = g - Int(pal[k * 3 + 1]), eb = b - Int(pal[k * 3 + 2])
                                        if er * er + eg * eg + eb * eb > limit {
                                            let bias = Self.bayer[((by + y) & 7) * 8 + ((bx + x) & 7)]
                                            let cell = (min(255, max(0, r + bias)) >> 3) << 10
                                                | (min(255, max(0, g + bias)) >> 3) << 5
                                                | (min(255, max(0, b + bias)) >> 3)
                                            if near[cell] == 255 {
                                                near[cell] = Self.closest(cell, pal, count)
                                            }
                                            k = Int(near[cell])
                                        }
                                        o[y * bw + x] = UInt8(k)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Palette entry nearest the centre of a 5-bit colour cell.
    private static func closest(_ cell: Int, _ pal: UnsafeBufferPointer<UInt8>, _ count: Int) -> UInt8 {
        let r = (cell >> 10) * 8 + 4, g = ((cell >> 5) & 31) * 8 + 4, b = (cell & 31) * 8 + 4
        var best = 0, bestDistance = Int.max
        for i in 0..<count {
            let dr = r - Int(pal[i * 3]), dg = g - Int(pal[i * 3 + 1]), db = b - Int(pal[i * 3 + 2])
            let d = dr * dr + dg * dg + db * db
            if d < bestDistance { bestDistance = d; best = i }
        }
        return UInt8(best)
    }

    /// 8x8 Bayer thresholds centred on zero. Indexed by absolute pixel position, so a pixel's
    /// threshold never changes between frames.
    private static let bayer: [Int] = (0..<64).map { i in
        let x = i % 8, y = i / 8
        var v = 0
        for bit in 0..<3 {
            let a = (y >> bit) & 1, b = ((x ^ y) >> bit) & 1
            v |= b << (2 * (2 - bit) + 1)
            v |= a << (2 * (2 - bit))
        }
        return Int((Double(v) - 31.5) * 0.35)
    }

    // MARK: - Writing

    /// Writes the held-back frame with a delay that runs up to `next`. Delays are rounded against
    /// the running total, so a long clip cannot drift, and clamped to the rate's minimum because
    /// viewers promote 0 and 1 cs to 10.
    private func flush(until next: Double, isLast: Bool = false) throws {
        guard let frame = pending else { return }
        let target = (next - firstTime) * 100 - trimmedCS
        var delay = max(settings.minDelayCS, Int((target - emittedCS).rounded()))

        // A capture started a beat early or stopped a beat late is mostly one still frame with a long
        // delay. Cap those, and remember what was cut so later delays do not stretch to make it up.
        if settings.trim {
            let first = writer.frameCount == 0
            let cap = first && isLast ? Self.onlyFrameCap : first ? Self.headCap : isLast ? Self.tailCap : Int.max
            if delay > cap {
                let cut = Double(delay - cap)
                trimmedCS += cut
                if first { trimmedHeadCS += cut } else { trimmedTailCS += cut }
                delay = cap
            }
        }
        try writer.addFrame(x: frame.x, y: frame.y, w: frame.w, h: frame.h, indices: frame.indices,
                            palette: frame.palette, transparent: frame.transparent, delayCS: delay)
        emittedCS += Double(delay)
        pending = nil
    }

    /// Longest a still opening, closing or lone frame may linger, in centiseconds.
    static let headCap = 50, tailCap = 80, onlyFrameCap = 100
}
