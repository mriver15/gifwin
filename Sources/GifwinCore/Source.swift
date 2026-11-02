import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Where frames come from. ScreenCaptureKit in real use, a scripted list in tests, so everything below
/// capture (redaction, encoding, predicates, the rolling buffer) can be exercised with no screen,
/// no permission and no timing dependence.
public protocol FrameSource: AnyObject {
    /// Begins delivering frames. `time` is seconds on this source's own clock, the same one `now` reads.
    func start(_ handler: @escaping @Sendable (_ pixels: [UInt32], _ width: Int, _ height: Int, _ time: Double) -> Void) async throws
    func stop() async
    /// The source has nothing more to give: the window closed, or a scripted source ran out.
    var hasEnded: Bool { get }
    /// Why it ended: `closed` (the window went away) or `ended` (a scripted source ran out).
    var endReason: String? { get }
    /// True for a source that hands over everything at once. Predicates are then checked inline and
    /// deterministically, because a burst is faster than text recognition.
    var isScripted: Bool { get }
    var now: Double { get }
}

/// A scripted source. Delivers every frame at once, at `i / fps`, and reports the clock as having run to
/// the end, so a test never waits.
public final class SyntheticSource: FrameSource {
    private let frames: [[UInt32]]
    private let width: Int
    private let height: Int
    private let fps: Double
    private let staysOpen: Bool
    private var stopped = false
    public var hasEnded: Bool { stopped || (!staysOpen && delivered) }
    private var delivered = false
    public var endReason: String? { hasEnded ? "ended" : nil }
    public var isScripted: Bool { true }

    /// - Parameter staysOpen: behave like a live window that is still there after its frames are delivered.
    public init(frames: [[UInt32]], width: Int, height: Int, fps: Double, staysOpen: Bool = false) {
        self.staysOpen = staysOpen
        self.frames = frames
        self.width = width
        self.height = height
        self.fps = fps
    }

    public func start(_ handler: @escaping @Sendable ([UInt32], Int, Int, Double) -> Void) async throws {
        for (i, f) in frames.enumerated() { handler(f, width, height, Double(i) / fps) }
        delivered = true
    }
    public func stop() async { stopped = true }
    public var now: Double { Double(frames.count) / fps }
}

/// A window, streamed by ScreenCaptureKit.
public final class SCKFrameSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate {
    private let stream: SCStream
    private let queue = DispatchQueue(label: "gifwin.frames")
    private var handler: (@Sendable ([UInt32], Int, Int, Double) -> Void)?
    private var ended = false
    /// Device pixels per point of the display the window is on.
    public let displayScale: Double
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(window: SCWindow, settings: EncoderSettings, longEdge: Int? = nil) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)

        // Pixel size = window points x backing scale, capped on the long edge.
        displayScale = Double(info.pointPixelScale)
        var w = Double(info.contentRect.width) * displayScale
        var h = Double(info.contentRect.height) * displayScale
        let shrink = min(1, Double(longEdge ?? settings.longEdge) / max(w, h))
        w = (w * shrink).rounded()
        h = (h * shrink).rounded()
        pixelWidth = Int(w)
        pixelHeight = Int(h)

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(seconds: 1 / settings.fps, preferredTimescale: 600)
        config.queueDepth = 5
        config.showsCursor = true
        config.ignoreShadowsSingleWindow = true
        config.colorSpaceName = CGColorSpace.sRGB
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        super.init()
    }

    public func start(_ handler: @escaping @Sendable ([UInt32], Int, Int, Double) -> Void) async throws {
        self.handler = handler
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        do {
            try await stream.startCapture()
        } catch {
            throw GifwinError.permission("Could not start capture: \(error.localizedDescription)")
        }
    }

    public func stop() async {
        if !ended { try? await stream.stopCapture() }
        queue.sync {} // let frames already delivered finish
    }

    public var hasEnded: Bool { ended }
    public var endReason: String? { ended ? "closed" : nil }
    public var isScripted: Bool { false }
    public var now: Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // `.idle` means nothing changed; no pixels, so nothing to encode.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        handler?(Self.pixels(buffer), CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), t)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) { ended = true }

    /// Copies a BGRA buffer into a tightly packed array, dropping row padding.
    static func pixels(_ buffer: CVPixelBuffer) -> [UInt32] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [UInt32](repeating: 0, count: w * h) }
        return [UInt32](unsafeUninitializedCapacity: w * h) { out, count in
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
                (out.baseAddress! + y * w).update(from: row, count: w)
            }
            count = w * h
        }
    }
}

/// What ends a recording early.
public enum StopCondition: Sendable, Equatable {
    /// Some on-screen text appears (case-insensitive).
    case text(String)
    /// The screen has been still for this many seconds after something changed.
    case quiet(Double)
    /// Anything on screen changes.
    case change

    public static func parse(_ s: String) -> StopCondition? {
        let lower = s.lowercased()
        if lower == "change" { return .change }
        if lower.hasPrefix("quiet:"), let n = Double(s.dropFirst(6)), n > 0 { return .quiet(n) }
        if lower.hasPrefix("text:"), s.count > 5 { return .text(String(s.dropFirst(5))) }
        return nil
    }
}

/// The path a frame takes: optional redaction, then an encoder. Also watches for the condition that
/// should end the recording.
public final class Intake: @unchecked Sendable {
    private let redact: Bool
    private let makeConsumer: (Int, Int) throws -> FrameConsumer
    private let condition: StopCondition?
    private let after: Double
    private let inline: Bool
    private final class SinkBox: @unchecked Sendable { var sink: GIFFrameSink? }
    private var sinkBox: SinkBox?

    private let lock = NSLock()
    public private(set) var consumer: FrameConsumer?
    private var redactor: Redactor?
    public private(set) var failure: Error?
    public private(set) var firstFrameTime: Double?
    private var firedAt: Double?
    private var lastOCR = -Double.infinity
    private var ocrBusy = false
    private let ocrQueue = DispatchQueue(label: "gifwin.predicate", qos: .utility)

    public init(redact: Bool = false, predicate: StopCondition? = nil, after: Double = 1, inlinePredicate: Bool = false,
                makeConsumer: @escaping (Int, Int) throws -> FrameConsumer) {
        self.redact = redact
        self.condition = predicate
        self.after = after
        self.inline = inlinePredicate
        self.makeConsumer = makeConsumer
    }

    /// A GIF intake: frames go through the GIF encoder into the sink `makeSink` provides.
    public convenience init(settings: EncoderSettings, redact: Bool = false, keyframeInterval: Double? = nil,
                            predicate: StopCondition? = nil, after: Double = 1, inlinePredicate: Bool = false,
                            makeSink: @escaping (Int, Int) throws -> GIFFrameSink) {
        let box = SinkBox()
        self.init(redact: redact, predicate: predicate, after: after, inlinePredicate: inlinePredicate) { w, h in
            let sink = try makeSink(w, h)
            box.sink = sink
            return FrameEncoder(writer: sink, settings: settings, keyframeInterval: keyframeInterval)
        }
        self.sinkBox = box
    }

    /// The GIF encoder, when this intake feeds one.
    public var encoder: FrameEncoder? { lock.lock(); defer { lock.unlock() }; return consumer as? FrameEncoder }
    public var sink: GIFFrameSink? { sinkBox?.sink }

    /// Bytes written so far; a live estimate of the file's size.
    public var bytes: Int { lock.lock(); defer { lock.unlock() }; return consumer?.bytesWritten ?? 0 }
    public var maskedRegions: Int { lock.lock(); defer { lock.unlock() }; return redactor?.applied ?? 0 }

    public func feed(_ pixels: [UInt32], _ width: Int, _ height: Int, _ time: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        // Once the condition has been met and its tail recorded, nothing later belongs in the clip.
        if let fired = firedAt, time > fired + after { return }
        do {
            if consumer == nil {
                consumer = try makeConsumer(width, height)
                redactor = redact ? Redactor(width: width, height: height) : nil
                firstFrameTime = time
            }
            if case .text(let needle)? = condition, firedAt == nil { checkText(pixels, width, height, time, needle) }

            // The redactor sees the frame before the encoder does, so unredacted pixels are never written.
            var frame = pixels
            redactor?.process(&frame)
            try consumer?.add(frame, at: time)

            if case .change? = condition, firedAt == nil, (consumer?.acceptedCount ?? 0) >= 2 { firedAt = time }
        } catch {
            failure = error
        }
    }

    /// When the condition was met, in the source's clock, or nil. `now` lets "quiet" notice time passing
    /// when no frames are arriving.
    public func firedTime(now: Double) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        if firedAt != nil { return firedAt }
        if case .quiet(let seconds)? = condition, let consumer, consumer.acceptedCount >= 2,
           now - consumer.lastAcceptedTime >= seconds {
            firedAt = consumer.lastAcceptedTime + seconds
        }
        return firedAt
    }

    public func finish(endTime: Double) throws -> EncodeStats? {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        return try consumer?.finish(endTime: endTime)
    }

    /// Text recognition at about 2 Hz on a background queue; a slow recogniser costs reaction time, never frames.
    private func checkText(_ pixels: [UInt32], _ width: Int, _ height: Int, _ time: Double, _ needle: String) {
        guard time - lastOCR >= 0.5, !ocrBusy, let image = Redactor.image(pixels, width: width, rowRange: 0..<height) else { return }
        lastOCR = time
        let wanted = needle.lowercased()
        if inline {
            if OCR.lines(in: image, accurate: false, limit: 200).joined(separator: "\n").lowercased().contains(wanted) { firedAt = time }
            return
        }
        ocrBusy = true
        ocrQueue.async { [weak self] in
            let hit = OCR.lines(in: image, accurate: false, limit: 200).joined(separator: "\n").lowercased().contains(wanted)
            guard let self else { return }
            self.lock.lock()
            if hit, self.firedAt == nil { self.firedAt = time }
            self.ocrBusy = false
            self.lock.unlock()
        }
    }
}
