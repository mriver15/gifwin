import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public struct CaptureResult: Sendable {
    public let url: URL
    public let width: Int
    public let height: Int
    public let frames: Int
    public let bytes: Int
    public let seconds: Double
    /// True when the stream ended before the requested duration (window closed).
    public let truncated: Bool
}

/// Receives ScreenCaptureKit frames and streams them into a GIF.
///
/// Each frame is held back until the next one arrives so its delay is known before it is
/// written. ScreenCaptureKit only delivers `.complete` frames when pixels change, so an idle
/// window costs one frame with a long delay rather than a run of duplicates.
public final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let destination: URL
    private var writer: GIFWriter?
    private var pending: [UInt8]?
    private var pendingTime = 0.0
    private var firstTime = 0.0
    private var emittedCS = 0.0
    private var failure: Error?
    private(set) var streamEnded = false

    init(destination: URL) {
        self.destination = destination
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, failure == nil else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        do {
            if writer == nil {
                writer = try GIFWriter(url: destination,
                                       width: CVPixelBufferGetWidth(pixels),
                                       height: CVPixelBufferGetHeight(pixels))
                firstTime = t
            }
            let indices = Recorder.quantize(pixels)
            try flushPending(until: t)
            pending = indices
            pendingTime = t
        } catch {
            failure = error
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamEnded = true
    }

    /// Writes the held-back frame and closes the file. Call after the stream has stopped and its queue drained.
    func finish() throws -> (frames: Int, bytes: Int, width: Int, height: Int, duration: Double)? {
        if let failure { throw failure }
        guard let writer else { return nil }
        let now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        try flushPending(until: max(now, pendingTime + 0.02))
        try writer.finish()
        return (writer.frameCount, writer.bytesWritten, writer.width, writer.height, emittedCS / 100)
    }

    /// Cumulative rounding: each delay is the gap between the running total and where the next
    /// frame should start, so a long clip cannot drift. Clamped to 2 cs because viewers promote 0 and 1.
    private func flushPending(until next: Double) throws {
        guard let frame = pending, let writer else { return }
        let target = (next - firstTime) * 100
        let delay = max(2, Int((target - emittedCS).rounded()))
        try writer.addFrame(indices: frame, delayCS: delay)
        emittedCS += Double(delay)
        pending = nil
    }

    static func quantize(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [UInt8](repeating: 0, count: w * h) }
        var out = [UInt8](repeating: 0, count: w * h)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w {
                    // BGRA
                    dst[y * w + x] = GIFWriter.Palette.index(r: row[x * 4 + 2], g: row[x * 4 + 1], b: row[x * 4])
                }
            }
        }
        return out
    }
}

public enum Capture {
    public static let maxLongEdge = 1024.0
    public static let framesPerSecond = 12.5

    public static func record(window: SCWindow, seconds: Double, to url: URL) async throws -> CaptureResult {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)

        // Pixel size = window points x backing scale, capped on the long edge.
        let pixelScale = Double(info.pointPixelScale)
        var w = Double(info.contentRect.width) * pixelScale
        var h = Double(info.contentRect.height) * pixelScale
        let shrink = min(1, maxLongEdge / max(w, h))
        w = (w * shrink).rounded()
        h = (h * shrink).rounded()

        let config = SCStreamConfiguration()
        config.width = Int(w)
        config.height = Int(h)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 2, timescale: 25)
        config.queueDepth = 5
        config.showsCursor = true
        config.ignoreShadowsSingleWindow = true
        config.colorSpaceName = CGColorSpace.sRGB

        let recorder = Recorder(destination: url)
        let queue = DispatchQueue(label: "gifwin.frames")
        let stream = SCStream(filter: filter, configuration: config, delegate: recorder)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: queue)

        do {
            try await stream.startCapture()
        } catch {
            throw GifwinError(.permissionDenied, "Could not start capture: \(error.localizedDescription)")
        }

        // Poll so a window that closes mid-capture ends the wait early instead of idling to the deadline.
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !recorder.streamEnded {
            try await Task.sleep(for: .milliseconds(50))
        }
        let truncated = recorder.streamEnded
        if !truncated { try? await stream.stopCapture() }
        queue.sync {} // drain frames already delivered

        let finished: (frames: Int, bytes: Int, width: Int, height: Int, duration: Double)?
        do {
            finished = try recorder.finish()
        } catch {
            throw GifwinError(.outputUnwritable, "Could not write GIF: \(error.localizedDescription)")
        }
        guard let finished else {
            throw GifwinError(.internalFailure, "No frames were delivered. Is the window visible and not minimized?")
        }
        return CaptureResult(url: url, width: finished.width, height: finished.height,
                             frames: finished.frames, bytes: finished.bytes,
                             seconds: finished.duration, truncated: truncated)
    }
}
