import CoreMedia
import Foundation
import ScreenCaptureKit

public struct CaptureResult: Sendable {
    public var url: URL
    public var width: Int
    public var height: Int
    public var frames: Int
    public var bytes: Int
    public var seconds: Double
    /// True when the stream ended before the requested duration (window closed).
    public var truncated: Bool
    /// False only when a byte budget was requested and even the end of the ladder was too big.
    public var budgetMet = true
    /// Re-encode passes spent meeting the budget.
    public var budgetSteps = 0
    public var trimmedHead = 0.0
    public var trimmedTail = 0.0
    /// Device pixels per point of the display the window was on.
    public var displayScale = 1.0
    /// `timeout` (ran the full duration), `predicate` (the `--until` condition was met) or `closed`.
    public var stoppedBy = "timeout"
    /// Seconds into the clip at which the predicate was met.
    public var predicateTime: Double?
    /// Regions blanked by pixel redaction over the clip, when it was on.
    public var maskedRegions = 0

    public init(url: URL, width: Int, height: Int, frames: Int, bytes: Int, seconds: Double, truncated: Bool,
                budgetMet: Bool = true, budgetSteps: Int = 0) {
        self.url = url
        self.width = width
        self.height = height
        self.frames = frames
        self.bytes = bytes
        self.seconds = seconds
        self.truncated = truncated
        self.budgetMet = budgetMet
        self.budgetSteps = budgetSteps
    }
}

/// What the capture in progress is doing, for a status display, and a way to end it early.
/// One at a time is enough: it serves the menu bar, which starts one capture at a time.
public enum CaptureProgress {
    private static let lock = NSLock()
    private static var started: Date?
    private static var bytes: (() -> Int)?
    private static var stopRequested = false

    public static func begin(bytes: @escaping () -> Int) {
        lock.lock(); started = Date(); self.bytes = bytes; stopRequested = false; lock.unlock()
    }
    public static func end() { lock.lock(); started = nil; bytes = nil; lock.unlock() }

    /// Seconds recorded and bytes written so far, or nil when nothing is recording.
    public static var current: (seconds: Double, bytes: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let started, let bytes else { return nil }
        return (Date().timeIntervalSince(started), bytes())
    }

    public static func requestStop() { lock.lock(); stopRequested = true; lock.unlock() }
    static var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stopRequested }
}

public enum Capture {
    /// Records one window to a GIF.
    ///
    /// - Parameters:
    ///   - seconds: the longest it will record. With `until`, it stops earlier when the condition is met.
    ///   - after: how long to keep recording once `until` is met, so the moment itself is in the clip.
    public static func record(window: SCWindow, seconds: Double, to url: URL, settings: EncoderSettings,
                              longEdge: Int? = nil, redact: Bool = false, format: OutputFormat = .gif,
                              until: StopCondition? = nil, after: Double = 1) async throws -> CaptureResult {
        let source = SCKFrameSource(window: window, settings: settings, longEdge: longEdge)
        var result = try await record(source: source, seconds: seconds, to: url, settings: settings,
                                      redact: redact, format: format, until: until, after: after)
        result.displayScale = source.displayScale
        return result
    }

    /// The same, from any frame source. This is the path the tests drive.
    public static func record(source: FrameSource, seconds: Double, to url: URL, settings: EncoderSettings,
                              redact: Bool = false, format: OutputFormat = .gif,
                              until: StopCondition? = nil, after: Double = 1) async throws -> CaptureResult {
        // `format` is how it is recorded: webm is recorded as mp4 and converted afterwards.
        let intake: Intake
        if format == .gif {
            intake = Intake(settings: settings, redact: redact, predicate: until, after: after,
                            inlinePredicate: source.isScripted) { w, h in try GIFWriter(url: url, width: w, height: h) }
        } else {
            intake = Intake(redact: redact, predicate: until, after: after, inlinePredicate: source.isScripted) { w, h in
                try VideoEncoder(url: url, width: w, height: h, fps: settings.fps, bitsPerPixel: Double(settings.colors) / 64)
            }
        }
        try await source.start { pixels, w, h, t in intake.feed(pixels, w, h, t) }
        CaptureProgress.begin { intake.bytes }
        defer { CaptureProgress.end() }

        // Poll so a window that closes, or a predicate that fires, ends the wait early instead of idling to the deadline.
        let deadline = Date().addingTimeInterval(seconds)
        var stoppedBy = "timeout"
        var firedAt: Double?
        while Date() < deadline && !source.hasEnded {
            if CaptureProgress.shouldStop { stoppedBy = "stopped"; break }
            if let fired = intake.firedTime(now: source.now) {
                firedAt = fired
                if source.now >= fired + after { stoppedBy = "predicate"; break }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if let reason = source.endReason, stoppedBy == "timeout" {
            // A scripted source runs out all at once, so the predicate may have fired inside it.
            if let fired = intake.firedTime(now: source.now) { firedAt = fired; stoppedBy = "predicate" }
            else { stoppedBy = reason }
        }
        // The clip ends when the deadline passed, not when the stream finishes tearing down.
        let endTime = min(source.now, firedAt.map { $0 + after } ?? .infinity)
        await source.stop()

        let stats: EncodeStats?
        do {
            stats = try intake.finish(endTime: endTime)
        } catch {
            if let e = error as? GifwinError { throw e }
            throw GifwinError(.outputUnwritable, "Could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard let stats else {
            throw GifwinError(.internalFailure, "No frames were delivered. Is the window visible and not minimized?")
        }
        var result = CaptureResult(url: url, width: stats.width, height: stats.height, frames: stats.frames,
                                   bytes: stats.bytes, seconds: stats.duration, truncated: stoppedBy == "closed")
        result.trimmedHead = stats.trimmedHead
        result.trimmedTail = stats.trimmedTail
        result.stoppedBy = stoppedBy
        result.maskedRegions = intake.maskedRegions
        if let firedAt, let first = intake.firstFrameTime { result.predicateTime = max(0, firedAt - first) }
        return result
    }
}
