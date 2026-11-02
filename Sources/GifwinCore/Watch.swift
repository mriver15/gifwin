import Foundation
import ScreenCaptureKit

/// The last N seconds of a window, kept as already-compressed GIF frames.
///
/// A frame is a delta from the one before, so a clip cut from the middle is only valid if it starts on a
/// frame that stands alone. The encoder is told to emit a full frame every couple of seconds, the ring
/// always keeps whole segments from one of those to the next, and saving starts at the right one. Storing
/// compressed blocks rather than pixels is what keeps 30 seconds to a few megabytes.
public final class RingSink: GIFFrameSink {
    struct Frame {
        let block: Data
        let delayCS: Int
        let key: Bool
    }

    public let width: Int
    public let height: Int
    public private(set) var frameCount = 0
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var totalCS = 0
    private var held = 0
    private let keepCS: Int

    public init(width: Int, height: Int, keepSeconds: Double) {
        self.width = width
        self.height = height
        keepCS = Int(keepSeconds * 100)
    }

    /// Bytes currently held.
    public var bytesWritten: Int { lock.lock(); defer { lock.unlock() }; return held }
    /// Seconds of footage currently held.
    public var duration: Double { lock.lock(); defer { lock.unlock() }; return Double(totalCS) / 100 }
    /// The oldest frame held can stand alone, so the ring can always be saved from its start.
    public var startsOnKeyframe: Bool { lock.lock(); defer { lock.unlock() }; return frames.first?.key ?? true }
    public var heldFrames: Int { lock.lock(); defer { lock.unlock() }; return frames.count }

    public func addFrame(x: Int, y: Int, w: Int, h: Int, indices: [UInt8], palette: [UInt8], transparent: Int?, delayCS: Int) throws {
        let block = GIFWriter.frameBlock(x: x, y: y, w: w, h: h, indices: indices, palette: palette,
                                         transparent: transparent, delayCS: delayCS)
        let key = transparent == nil && x == 0 && y == 0 && w == width && h == height
        lock.lock()
        defer { lock.unlock() }
        frames.append(Frame(block: block, delayCS: min(max(delayCS, 2), 65535), key: key))
        totalCS += frames[frames.count - 1].delayCS
        held += block.count
        frameCount += 1
        evict()
    }

    public func finish() throws {}

    /// Drops the oldest whole segment while what remains still covers `keepCS`.
    private func evict() {
        while let next = frames.indices.dropFirst().first(where: { frames[$0].key }) {
            let segment = frames[..<next].reduce(0) { $0 + $1.delayCS }
            guard totalCS - segment >= keepCS else { return }
            held -= frames[..<next].reduce(0) { $0 + $1.block.count }
            frames.removeFirst(next)
            totalCS -= segment
        }
    }

    /// A complete GIF of at least the last `seconds` (it starts on the nearest full frame before that),
    /// with `extra` as its closing frame.
    func gif(lastSeconds seconds: Double, extra: (block: Data, delayCS: Int)?) -> (data: Data, frames: Int, seconds: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard !frames.isEmpty else { return nil }
        let total = totalCS + (extra?.delayCS ?? 0)
        let cutoff = total - Int(seconds * 100)
        var start = 0, elapsed = 0
        for (i, f) in frames.enumerated() {
            if f.key && elapsed <= cutoff { start = i }
            elapsed += f.delayCS
        }
        var data = GIFWriter.header(width: width, height: height)
        var cs = 0
        for f in frames[start...] { data.append(f.block); cs += f.delayCS }
        if let extra { data.append(extra.block); cs += extra.delayCS }
        data.append(GIFWriter.trailer)
        return (data, frames.count - start + (extra == nil ? 0 : 1), Double(cs) / 100)
    }
}

/// One window being watched: frames flow through the usual pipeline into a ring instead of a file.
public final class Watcher: @unchecked Sendable {
    public let info: WindowInfo
    public let rolling: Double
    public let displayScale: Double
    public let startedAt = Date()
    private let source: FrameSource
    private let intake: Intake

    /// Full frames this often, in seconds. A saved clip can run this much longer than asked.
    public static let keyframeInterval = 2.0

    init(info: WindowInfo, rolling: Double, displayScale: Double, source: FrameSource, intake: Intake) {
        self.info = info
        self.rolling = rolling
        self.displayScale = displayScale
        self.source = source
        self.intake = intake
    }

    public static func start(source: FrameSource, info: WindowInfo, rolling: Double, settings: EncoderSettings,
                             redact: Bool = false, displayScale: Double = 1) async throws -> Watcher {
        var tuned = settings
        tuned.trim = false  // a ring keeps real time, still stretches included
        // The ring's size is only known once the first frame arrives, so the intake makes it then.
        let intake = Intake(settings: tuned, redact: redact, keyframeInterval: keyframeInterval) { w, h in
            RingSink(width: w, height: h, keepSeconds: rolling)
        }
        try await source.start { pixels, w, h, t in intake.feed(pixels, w, h, t) }
        return Watcher(info: info, rolling: rolling, displayScale: displayScale, source: source, intake: intake)
    }

    private var ring: RingSink? { intake.sink as? RingSink }

    public var isActive: Bool { !source.hasEnded && intake.failure == nil }
    public var heldSeconds: Double { ring?.duration ?? 0 }
    public var heldBytes: Int { ring?.bytesWritten ?? 0 }
    public var heldFrames: Int { ring?.heldFrames ?? 0 }
    public var startsOnKeyframe: Bool { ring?.startsOnKeyframe ?? true }

    /// Writes (at least) the last `seconds` to `url` as a GIF.
    public func save(lastSeconds seconds: Double, to url: URL) throws -> CaptureResult {
        guard let ring else { throw GifwinError(.internalFailure, "Nothing has been recorded yet; the window has not produced a frame.") }
        var extra: (block: Data, delayCS: Int)?
        // The newest frame is held back until the next one arrives; include it as the clip's last frame.
        if let p = intake.encoder?.peekPending(at: source.now) {
            extra = (GIFWriter.frameBlock(x: p.x, y: p.y, w: p.w, h: p.h, indices: p.indices, palette: p.palette,
                                          transparent: p.transparent, delayCS: p.delayCS), p.delayCS)
        }
        guard let clip = ring.gif(lastSeconds: seconds, extra: extra) else {
            throw GifwinError(.internalFailure, "Nothing has been recorded yet.")
        }
        do { try clip.data.write(to: url, options: .atomic) }
        catch { throw GifwinError(.outputUnwritable, "Cannot write \(url.path): \(error.localizedDescription)") }
        var result = CaptureResult(url: url, width: ring.width, height: ring.height, frames: clip.frames,
                                   bytes: clip.data.count, seconds: clip.seconds, truncated: false)
        result.displayScale = displayScale
        return result
    }

    public func stop() async { await source.stop() }
}

/// The watchers running in this process. The helper stays alive while any exists.
public enum Watchers {
    private static let lock = NSLock()
    private static var all: [UInt32: Watcher] = [:]

    public static func add(_ w: Watcher) { lock.lock(); all[w.info.id] = w; lock.unlock() }
    public static func remove(_ id: UInt32) -> Watcher? { lock.lock(); defer { lock.unlock() }; return all.removeValue(forKey: id) }

    /// Watchers still producing frames; ones whose window closed are dropped.
    public static func active() -> [Watcher] {
        lock.lock()
        defer { lock.unlock() }
        all = all.filter { $0.value.isActive }
        return all.values.sorted { $0.info.id < $1.info.id }
    }
    public static var count: Int { active().count }

    /// A selector the same way windows are named: `id:<n>`, a bundle id, or an app name. With none, the
    /// only watcher, if there is exactly one.
    public static func find(_ selector: String?) -> Result<Watcher, GifwinError> {
        let running = active()
        guard let selector, !selector.isEmpty else {
            if running.count == 1 { return .success(running[0]) }
            return .failure(GifwinError(.noWindow, running.isEmpty ? "Nothing is being watched. Start with: gifwin watch --window <app>"
                                        : "More than one window is being watched; pick one with --window:\n" + running.map { "  id:\($0.info.id)  \($0.info.app)" }.joined(separator: "\n")))
        }
        let lower = selector.lowercased()
        let hits = running.filter {
            lower == "id:\($0.info.id)" || $0.info.bundleID.lowercased() == lower
                || $0.info.app.lowercased() == lower || $0.info.app.lowercased().contains(lower)
        }
        if hits.count == 1 { return .success(hits[0]) }
        return .failure(GifwinError(.noWindow, hits.isEmpty ? "No watched window matches '\(selector)'." : "'\(selector)' matches \(hits.count) watched windows; pick one with id:<n>."))
    }
}
