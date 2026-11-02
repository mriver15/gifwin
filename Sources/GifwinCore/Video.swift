import AVFoundation
import CoreVideo
import Foundation

public enum OutputFormat: String, Sendable, CaseIterable {
    case gif, mp4, webm
    public var fileExtension: String { rawValue }
}

/// H.264 video, written by the hardware encoder.
///
/// Presentation times come from the frames themselves, and a frame identical to the last is not written,
/// so a still window costs nothing: the previous frame simply lasts longer. This is why a screen recording
/// here is far smaller than a fixed-rate one.
public final class VideoEncoder: FrameConsumer {
    private let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    public let width: Int
    public let height: Int
    private let sourceWidth: Int
    private var previous: [UInt32]?
    private var firstTime = 0.0
    public private(set) var acceptedCount = 0
    public private(set) var lastAcceptedTime = -Double.infinity
    private var dropped = 0

    public var bytesWritten: Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }

    /// - Parameters:
    ///   - bitsPerPixel: bits per pixel per second at the source rate. A window's text and chrome compress
    ///     well; 2 is plenty for `balanced`.
    public init(url: URL, width: Int, height: Int, fps: Double, bitsPerPixel: Double) throws {
        // H.264 wants even dimensions; the last row and column of an odd frame are dropped.
        sourceWidth = width
        self.width = max(2, width & ~1)
        self.height = max(2, height & ~1)
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: self.width,
            AVVideoHeightKey: self.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(250_000, Int(Double(self.width * self.height) * bitsPerPixel)),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalKey: max(1, Int(fps * 2)),
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: self.width,
            kCVPixelBufferHeightKey as String: self.height,
        ])
        guard writer.canAdd(input) else { throw GifwinError(.internalFailure, "The video encoder cannot be configured for \(width)x\(height)") }
        writer.add(input)
        guard writer.startWriting() else {
            throw GifwinError(.outputUnwritable, "Cannot start writing \(url.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }

    public func add(_ pixels: [UInt32], at time: Double) throws {
        if previous == nil {
            firstTime = time
            writer.startSession(atSourceTime: .zero)
        } else if previous! == pixels {
            return   // nothing changed: the last frame lasts longer
        }
        // A busy encoder skips a frame rather than blocking the capture queue.
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { dropped += 1; return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { dropped += 1; return }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            pixels.withUnsafeBufferPointer { src in
                for y in 0..<height {
                    (base + y * stride).copyMemory(from: src.baseAddress! + y * sourceWidth, byteCount: width * 4)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let pts = CMTime(seconds: max(0, time - firstTime), preferredTimescale: 600)
        guard adaptor.append(buffer, withPresentationTime: pts) else {
            throw GifwinError(.internalFailure, "Video encoder failed: \(writer.error?.localizedDescription ?? "unknown")")
        }
        previous = pixels
        acceptedCount += 1
        lastAcceptedTime = time
    }

    public func finish(endTime: Double) throws -> EncodeStats? {
        guard acceptedCount > 0 else { return nil }
        let duration = max(0.04, endTime - firstTime)
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw GifwinError(.outputUnwritable, "Could not finish \(url.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown error")")
        }
        return EncodeStats(frames: acceptedCount, bytes: bytesWritten, width: width, height: height,
                           duration: duration, trimmedHead: 0, trimmedTail: 0)
    }
}

/// Converts a finished MP4 to WebM with ffmpeg. macOS cannot write WebM itself and the container only
/// holds VP8, VP9 and AV1, so this is a transcode, not a remux. ffmpeg is looked up, never bundled.
public enum WebM {
    static let searchPath = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]

    /// `GIFWIN_FFMPEG` names a binary to use instead; `none` says there is none, which is how the
    /// missing-ffmpeg path is tested on a machine that has it.
    public static func ffmpeg(env: [String: String] = [:]) -> URL? {
        let chosen = env["GIFWIN_FFMPEG"] ?? ProcessInfo.processInfo.environment["GIFWIN_FFMPEG"]
        if chosen == "none" { return nil }
        let candidates = [chosen].compactMap { $0 } + searchPath
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// VP9 constant quality; lower is better.
    static func crf(for settings: EncoderSettings) -> Int {
        switch settings.colors {
        case ..<80: return 40
        case ..<200: return 34
        default: return 28
        }
    }

    public static func transcode(_ mp4: URL, to webm: URL, settings: EncoderSettings, env: [String: String] = [:]) throws {
        guard let tool = ffmpeg(env: env) else {
            throw GifwinError(.internalFailure, "WebM output needs ffmpeg, which was not found. The MP4 was kept at \(mp4.path).",
                              remediation: "Install it with `brew install ffmpeg`, or use --format mp4, which needs nothing.",
                              slug: "ffmpeg_missing", details: ["fallback": mp4.path])
        }
        try? FileManager.default.removeItem(at: webm)
        let p = Process()
        p.executableURL = tool
        // Fixed arguments, no shell: paths are passed as arguments and cannot be read as options.
        p.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", mp4.path, "-an",
                       "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", String(crf(for: settings)), "-row-mt", "1",
                       "-pix_fmt", "yuv420p", webm.path]
        let errors = Pipe()
        p.standardError = errors
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch {
            throw GifwinError(.internalFailure, "Could not run ffmpeg: \(error.localizedDescription). The MP4 was kept at \(mp4.path).", slug: "ffmpeg_failed", details: ["fallback": mp4.path])
        }
        let text = errors.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: webm.path) else {
            let why = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GifwinError(.internalFailure, "ffmpeg could not make the WebM: \(String(why.suffix(300))). The MP4 was kept at \(mp4.path).",
                              slug: "ffmpeg_failed", details: ["fallback": mp4.path])
        }
    }
}
