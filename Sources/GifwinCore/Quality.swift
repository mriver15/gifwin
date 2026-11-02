import Foundation

/// Everything that decides how a clip is encoded. The presets are the spec's table; `--colors`,
/// `--fps` and `--scale` override individual fields.
public struct EncoderSettings: Sendable, Equatable, Codable {
    public enum Dither: String, Sendable, Codable { case off, adaptive, bayer }

    public var colors: Int
    public var fps: Double
    public var longEdge: Int
    public var dither: Dither
    /// A frame whose changed-pixel share is below this is not written; the previous frame's delay absorbs it.
    public var dropFraction: Double
    /// Per-channel difference a pixel must exceed before it counts as changed.
    public var tolerance: Int
    /// Cap the still head and tail of a clip (see `FrameEncoder`). Off by default so the encoder
    /// reproduces its input's timing exactly; the CLI turns it on.
    public var trim = false

    /// GIF delays are whole centiseconds, so only these rates divide evenly.
    public static let allowedFPS: [Double] = [10, 12.5, 100.0 / 6.0, 20]

    public var minDelayCS: Int { Int((100 / fps).rounded()) }
}

public enum Quality: String, CaseIterable, Sendable {
    case draft, balanced, crisp, max

    public var settings: EncoderSettings {
        switch self {
        case .draft:
            return EncoderSettings(colors: 64, fps: 10, longEdge: 640, dither: .off, dropFraction: 0.0005, tolerance: 12)
        case .balanced:
            return EncoderSettings(colors: 128, fps: 12.5, longEdge: 1024, dither: .adaptive, dropFraction: 0.0002, tolerance: 6)
        case .crisp:
            return EncoderSettings(colors: 256, fps: 100.0 / 6.0, longEdge: 1280, dither: .bayer, dropFraction: 0.00005, tolerance: 3)
        case .max:
            return EncoderSettings(colors: 256, fps: 20, longEdge: 1600, dither: .bayer, dropFraction: 0, tolerance: 0)
        }
    }
}
