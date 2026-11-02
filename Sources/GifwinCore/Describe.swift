import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Caption and alt text for a capture.
///
/// Tier 0 builds them from metadata and OCR text alone: deterministic, instant, always available.
/// Tier 2 asks the on-device language model to write them from the same facts. It runs after the
/// capture, never on its path, only when the system model is available, and a slow or failing model
/// falls back to Tier 0 rather than failing the capture. Both tiers see only the metadata and the
/// OCR text, so a caption cannot claim anything the manifest does not already contain.
public enum Describe {
    public struct Moment: Sendable {
        public var time: Double
        public var lines: [String]
        public init(time: Double, lines: [String]) {
            self.time = time
            self.lines = lines
        }
    }

    public struct Result: Sendable {
        public var caption: String
        public var altText: String
        /// `model` or `deterministic`.
        public var source: String
        /// Why the model was not used, when it was asked for and did not answer.
        public var note: String?
    }

    /// Whether the on-device caption model can be used, in words, for `doctor`.
    public static func modelStatus() -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "available"
            case .unavailable(let reason): return "unavailable (\(reason))"
            @unknown default: return "unavailable (unknown)"
            }
        }
        return "unavailable (needs macOS 26 or later)"
        #else
        return "unavailable (not built with FoundationModels)"
        #endif
    }

    public static func make(app: String, title: String, duration: Double, moments: [Moment], useModel: Bool) async -> Result {
        var note: String?
        if useModel {
            let attempt = await withModel(app: app, title: title, duration: duration, moments: moments)
            if let written = attempt.result { return written }
            note = attempt.note
        }
        var fallback = deterministic(app: app, title: title, duration: duration, moments: moments)
        fallback.note = note
        return fallback
    }

    static func deterministic(app: String, title: String, duration: Double, moments: [Moment]) -> Result {
        let subject = title.isEmpty ? app : "\(app): \(title)"
        let caption = String("\(subject), \(String(format: "%.1f", duration)) second capture".prefix(140))

        // The lines that change between moments are what the recording is about; the ones that stay put are chrome.
        var seen: [String: Int] = [:]
        for m in moments { for l in Set(m.lines) { seen[l, default: 0] += 1 } }
        let changing = moments.flatMap(\.lines).filter { seen[$0] == 1 && $0.count >= 4 }
        let shown = Array(NSOrderedSet(array: changing).array.prefix(6)) as? [String] ?? []

        var alt = "Screen recording of \(subject), \(String(format: "%.1f", duration)) seconds."
        if !shown.isEmpty { alt += " Text that appears during the recording includes: " + shown.map { "\"\($0)\"" }.joined(separator: ", ") + "." }
        else if let first = moments.first, !first.lines.isEmpty {
            alt += " Visible text includes: " + first.lines.prefix(4).map { "\"\($0)\"" }.joined(separator: ", ") + "."
        }
        return Result(caption: caption, altText: alt, source: "deterministic", note: nil)
    }

    private static func withModel(app: String, title: String, duration: Double, moments: [Moment]) async -> (result: Result?, note: String?) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return (nil, "model \(modelStatus())") }
            let evidence = moments.map { m in
                "[\(String(format: "%.1f", m.time))s] " + m.lines.prefix(14).joined(separator: " | ")
            }.joined(separator: "\n")
            let prompt = """
            You write metadata for a screen recording of a software window, for developers and screen readers.
            App: \(app)
            Window title: \(title.isEmpty ? "(none)" : title)
            Duration: \(String(format: "%.1f", duration)) seconds
            Text recognised on screen at selected moments:
            \(evidence)

            Reply with exactly two lines and nothing else.
            CAPTION: one sentence under 120 characters saying what the recording shows.
            ALT: two or three sentences for a screen reader describing what happens, using only the text above.
            """
            return await raced(seconds: 8) {
                do {
                    let reply = try await LanguageModelSession().respond(to: prompt)
                    guard let parsed = parse(reply.content) else {
                        return (nil, "model reply was not in the CAPTION/ALT format: \(String(reply.content.prefix(80)))")
                    }
                    return (parsed, nil)
                } catch {
                    return (nil, "model error: \(error)")
                }
            }
        }
        #endif
        return (nil, "model unavailable on this system")
    }

    /// Runs `work` against a deadline. The model's latency is unbounded from our side, the capture's is not.
    private static func raced(seconds: Double, _ work: @escaping @Sendable () async -> (Result?, String?)) async -> (result: Result?, note: String?) {
        await withTaskGroup(of: (Result?, String?).self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return (nil, "model did not answer within \(Int(seconds)) s")
            }
            let first = await group.next() ?? (nil, "no answer")
            group.cancelAll()
            return (first.0, first.1)
        }
    }

    /// Reads the model's two-line reply. Models dress answers up (bold labels, bullets, quotes), so labels
    /// are matched after stripping that, and anything that still does not yield both fields is rejected
    /// rather than guessed at.
    public static func parse(_ text: String) -> Result? {
        var caption: String?, alt: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.filter { $0 != "*" && $0 != "`" && $0 != "_" }
                .trimmingCharacters(in: CharacterSet(charactersIn: "-\u{2022} \t"))
            let upper = line.uppercased()
            if upper.hasPrefix("CAPTION:") { caption = clean(line.dropFirst(8)) }
            else if upper.hasPrefix("ALT:") { alt = clean(line.dropFirst(4)) }
            else if upper.hasPrefix("ALT TEXT:") { alt = clean(line.dropFirst(9)) }
        }
        guard let caption, let alt, !caption.isEmpty, !alt.isEmpty else { return nil }
        return Result(caption: String(caption.prefix(160)), altText: String(alt.prefix(600)), source: "model", note: nil)
    }

    private static func clean(_ s: Substring) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"\u{201C}\u{201D}"))
    }
}
