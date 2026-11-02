import CoreMedia
import CoreVideo
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

/// Receives ScreenCaptureKit frames and streams them through a `FrameEncoder`.
public final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let destination: URL
    private let settings: EncoderSettings
    private var encoder: FrameEncoder?
    private var failure: Error?
    private(set) var streamEnded = false

    init(destination: URL, settings: EncoderSettings) {
        self.destination = destination
        self.settings = settings
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, failure == nil else { return }
        // `.idle` means nothing changed; no pixels, so nothing to encode.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        do {
            if encoder == nil {
                let writer = try GIFWriter(url: destination, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
                encoder = FrameEncoder(writer: writer, settings: settings)
            }
            try encoder?.add(Recorder.pixels(buffer), at: t)
        } catch {
            failure = error
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamEnded = true
    }

    /// Closes the file. Call after the stream has stopped and its queue drained.
    func finish(endTime: Double) throws -> EncodeStats? {
        if let failure { throw failure }
        return try encoder?.finish(endTime: endTime)
    }

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

public enum Capture {
    public static func record(window: SCWindow, seconds: Double, to url: URL,
                              settings: EncoderSettings, longEdge: Int? = nil) async throws -> CaptureResult {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)

        // Pixel size = window points x backing scale, capped on the long edge.
        let pixelScale = Double(info.pointPixelScale)
        var w = Double(info.contentRect.width) * pixelScale
        var h = Double(info.contentRect.height) * pixelScale
        let shrink = min(1, Double(longEdge ?? settings.longEdge) / max(w, h))
        w = (w * shrink).rounded()
        h = (h * shrink).rounded()

        let config = SCStreamConfiguration()
        config.width = Int(w)
        config.height = Int(h)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(seconds: 1 / settings.fps, preferredTimescale: 600)
        config.queueDepth = 5
        config.showsCursor = true
        config.ignoreShadowsSingleWindow = true
        config.colorSpaceName = CGColorSpace.sRGB

        let recorder = Recorder(destination: url, settings: settings)
        let queue = DispatchQueue(label: "gifwin.frames")
        let stream = SCStream(filter: filter, configuration: config, delegate: recorder)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: queue)

        do {
            try await stream.startCapture()
        } catch {
            throw GifwinError.permission("Could not start capture: \(error.localizedDescription)")
        }

        // Poll so a window that closes mid-capture ends the wait early instead of idling to the deadline.
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !recorder.streamEnded {
            try await Task.sleep(for: .milliseconds(50))
        }
        let truncated = recorder.streamEnded
        // The clip ends when the deadline passed, not when stopCapture finishes tearing the stream down.
        let endTime = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        if !truncated { try? await stream.stopCapture() }
        queue.sync {} // drain frames already delivered

        let stats: EncodeStats?
        do {
            stats = try recorder.finish(endTime: endTime)
        } catch {
            throw GifwinError(.outputUnwritable, "Could not write GIF: \(error.localizedDescription)")
        }
        guard let stats else {
            throw GifwinError(.internalFailure, "No frames were delivered. Is the window visible and not minimized?")
        }
        var result = CaptureResult(url: url, width: stats.width, height: stats.height, frames: stats.frames,
                                   bytes: stats.bytes, seconds: stats.duration, truncated: truncated)
        result.trimmedHead = stats.trimmedHead
        result.trimmedTail = stats.trimmedTail
        result.displayScale = pixelScale
        return result
    }
}
