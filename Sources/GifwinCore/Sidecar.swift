import CoreGraphics
import CryptoKit
import Foundation

/// Facts about what was captured, known only at capture time and recorded so the clip can be cited.
public struct CaptureMeta: Codable, Sendable {
    public var app: String
    public var bundleId: String
    public var appVersion: String?
    public var windowId: UInt32
    public var windowTitle: String
    /// Window size in points, as the window server reports it.
    public var windowWidth: Int
    public var windowHeight: Int
    public var displayScale: Double
    public var startedAt: Date
    public var requestedSeconds: Double
    public var quality: String
    public var settings: EncoderSettings

    public init(app: String, bundleID: String, appVersion: String?, windowID: UInt32, windowTitle: String,
                windowWidth: Int, windowHeight: Int, displayScale: Double, startedAt: Date,
                requestedSeconds: Double, quality: String, settings: EncoderSettings) {
        self.app = app
        self.bundleId = bundleID
        self.appVersion = appVersion
        self.windowId = windowID
        self.windowTitle = windowTitle
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.displayScale = displayScale
        self.startedAt = startedAt
        self.requestedSeconds = requestedSeconds
        self.quality = quality
        self.settings = settings
    }
}

/// `<name>.gifwin.json`: the record that makes a GIF in a pull request a citation and not just a claim.
public struct Manifest: Codable, Sendable {
    public struct Tool: Codable, Sendable { public var name: String; public var version: String }
    public struct OS: Codable, Sendable { public var version: String; public var build: String }
    public struct Output: Codable, Sendable {
        /// gif, mp4 or webm.
        public var format: String
        public var file: String
        public var bytes: Int
        public var sha256: String
        public var width: Int
        public var height: Int
        public var frames: Int
        public var durationSeconds: Double
        public var delaysCentiseconds: [Int]
        public var trimmedHeadSeconds: Double?
        public var trimmedTailSeconds: Double?
        public var budgetMet: Bool?
    }
    public struct Keyframe: Codable, Sendable {
        public var index: Int
        public var timeSeconds: Double
        public var text: [String]
    }
    public struct Analysis: Codable, Sendable {
        public var contactSheet: String?
        public var keyframes: [Keyframe]
        public var caption: String
        public var altText: String
        /// `model` or `deterministic`.
        public var captionSource: String
        /// Why the model's caption was not used, when it was asked for.
        public var captionNote: String?
        /// False when `--no-ai` skipped OCR and the model.
        public var ocr: Bool
        public var redaction: Redaction
    }
    public struct Redaction: Codable, Sendable {
        /// Pixel redaction (`--redact auto`) was applied while recording.
        public var pixels: Bool
        /// Secret-looking strings replaced with [REDACTED] in the text below and in the caption.
        public var textMasked: Int
        /// Secret-looking strings still readable in the finished clip's keyframes. Should be 0 when `pixels` is on.
        public var residualInOutput: Int
    }

    public var schema = "gifwin.manifest/1"
    public var tool: Tool
    public var os: OS
    /// Absent for a GIF analysed after the fact, when nothing about its capture is known.
    public var capture: CaptureMeta?
    public var output: Output
    public var analysis: Analysis
}

public struct SidecarResult: Sendable {
    public var manifestURL: URL
    public var contactSheetURL: URL?
    public var manifest: Manifest
}

public enum Sidecar {
    public static func manifestURL(for gif: URL) -> URL { sibling(gif, ".gifwin.json") }
    public static func contactSheetURL(for gif: URL) -> URL { sibling(gif, ".contact.png") }

    private static func sibling(_ gif: URL, _ suffix: String) -> URL {
        gif.deletingLastPathComponent().appendingPathComponent(gif.deletingPathExtension().lastPathComponent + suffix)
    }

    /// Reads the capture facts back from an existing manifest, so re-analysing a clip keeps them.
    public static func existingCapture(for gif: URL) -> CaptureMeta? {
        guard let data = try? Data(contentsOf: manifestURL(for: gif)) else { return nil }
        return (try? decoder().decode(Manifest.self, from: data))?.capture
    }

    /// Analyses a finished GIF and writes its contact sheet and manifest beside it.
    ///
    /// - Parameter ai: run OCR and the caption model. Off, the keyframes and sheet are still made but
    ///   no text is read and the caption comes from metadata alone.
    /// - Parameter redacted: pixel redaction was applied during the capture; any secret still readable in
    ///   the output is then reported as residual.
    /// - Parameter analyzing: a file to read the frames from when `gif` itself cannot be read, such as the MP4 a WebM was made from.
    public static func write(gif: URL, capture: CaptureMeta?, result: CaptureResult?, ai: Bool, redacted: Bool = false,
                             analyzing: URL? = nil) async throws -> SidecarResult {
        let clip = try await Analysis.indexAny(analyzing ?? gif)
        let isGIF = gif.pathExtension.lowercased() == "gif"
        let picks = Analysis.keyframes(clip)

        // Decode the keyframes one at a time (a video's frame extractor is not built for parallel use), then
        // OCR them in parallel: recognition is the slowest step and the images are independent.
        let images: [Int: CGImage] = Dictionary(uniqueKeysWithValues: picks.compactMap { f in clip.image(f).map { (f, $0) } })
        var text: [Int: [String]] = [:]
        if ai {
            await withTaskGroup(of: (Int, [String]).self) { group in
                for frame in picks {
                    group.addTask {
                        guard let image = images[frame] else { return (frame, []) }
                        return (frame, OCR.lines(in: image))
                    }
                }
                for await (frame, lines) in group { text[frame] = lines }
            }
        }

        // Text read off the screen never goes into a file, or to the caption model, with credentials in it.
        var masked = 0
        for (frame, lines) in text {
            let safe = lines.map { Secrets.mask($0) }
            masked += safe.reduce(0) { $0 + $1.count }
            text[frame] = safe.map(\.text)
        }

        let data = try Data(contentsOf: gif)
        let app = capture?.app ?? "Unknown app"
        let title = capture?.windowTitle ?? ""
        let moments = picks.map { Describe.Moment(time: clip.start(of: $0), lines: text[$0] ?? []) }
        let words = await Describe.make(app: app, title: title, duration: clip.duration, moments: moments, useModel: ai)

        let sheetURL = contactSheetURL(for: gif)
        let footer = "\(title.isEmpty ? app : "\(app) - \(title)")  |  \(String(format: "%.1f", clip.duration))s  |  \(clip.count) frames  |  \(data.count / 1024) KB"
        var sheetWritten: URL?
        if let png = Analysis.contactSheet(clip, frames: picks, footer: String(footer.prefix(110))) {
            try png.write(to: sheetURL, options: .atomic)
            sheetWritten = sheetURL
        }

        let manifest = Manifest(
            tool: .init(name: "gifwin", version: Command.version),
            os: operatingSystem(),
            capture: capture,
            output: .init(format: gif.pathExtension.lowercased(), file: gif.lastPathComponent, bytes: data.count, sha256: sha256(data),
                          width: clip.width, height: clip.height, frames: isGIF ? clip.count : (result?.frames ?? clip.count),
                          durationSeconds: (clip.duration * 100).rounded() / 100,
                          delaysCentiseconds: isGIF ? clip.delays.map { Int(($0 * 100).rounded()) } : [],
                          trimmedHeadSeconds: result.map { $0.trimmedHead }, trimmedTailSeconds: result.map { $0.trimmedTail },
                          budgetMet: result.map { $0.budgetMet }),
            analysis: .init(contactSheet: sheetWritten?.lastPathComponent,
                            keyframes: picks.map { .init(index: $0, timeSeconds: (clip.start(of: $0) * 100).rounded() / 100, text: text[$0] ?? []) },
                            caption: words.caption, altText: words.altText, captionSource: words.source, captionNote: words.note, ocr: ai,
                            redaction: .init(pixels: redacted, textMasked: masked, residualInOutput: redacted ? masked : 0)))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let url = manifestURL(for: gif)
        try encoder.encode(manifest).write(to: url, options: .atomic)
        return SidecarResult(manifestURL: url, contactSheetURL: sheetWritten, manifest: manifest)
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func operatingSystem() -> Manifest.OS {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return .init(version: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)", build: String(cString: buffer))
    }
}
