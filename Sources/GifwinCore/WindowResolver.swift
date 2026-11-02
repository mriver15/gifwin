import Foundation
import ScreenCaptureKit

public struct WindowInfo: Sendable {
    public let id: UInt32
    public let app: String
    public let bundleID: String
    public let pid: Int32
    public let title: String
    public let width: Int
    public let height: Int
}

public enum WindowResolver {
    /// Capturable windows: normal layer, on screen, and big enough to be a real window.
    public static func candidates() async throws -> [(SCWindow, WindowInfo)] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw GifwinError.permission("Screen Recording permission is not granted.")
        }
        return content.windows
            .filter { $0.windowLayer == 0 && $0.frame.width >= 100 && $0.frame.height >= 60 && $0.owningApplication != nil }
            .map { w in
                (w, WindowInfo(id: w.windowID,
                               app: w.owningApplication?.applicationName ?? "",
                               bundleID: w.owningApplication?.bundleIdentifier ?? "",
                               pid: w.owningApplication?.processID ?? 0,
                               title: w.title ?? "",
                               width: Int(w.frame.width),
                               height: Int(w.frame.height)))
            }
            .sorted { $0.1.app.localizedCaseInsensitiveCompare($1.1.app) == .orderedAscending }
    }

    /// Selector order is fixed so results are reproducible:
    /// `id:<n>`, exact bundle id, exact app name, `title~<substring>`, then app-name substring.
    /// More than one match is never resolved silently.
    public static func resolve(_ selector: String, in all: [(SCWindow, WindowInfo)]) throws -> (SCWindow, WindowInfo) {
        let s = selector.trimmingCharacters(in: .whitespaces)
        let lower = s.lowercased()
        var stages: [[(SCWindow, WindowInfo)]] = []

        if lower.hasPrefix("id:"), let id = UInt32(s.dropFirst(3)) {
            stages.append(all.filter { $0.1.id == id })
        }
        stages.append(all.filter { $0.1.bundleID.lowercased() == lower })
        stages.append(all.filter { $0.1.app.lowercased() == lower })
        if lower.hasPrefix("title~") {
            let needle = String(lower.dropFirst(6))
            stages.append(all.filter { $0.1.title.lowercased().contains(needle) })
        }
        stages.append(all.filter { $0.1.app.lowercased().contains(lower) })

        guard let hits = stages.first(where: { !$0.isEmpty }) else {
            throw GifwinError(.noWindow, "No window matched '\(selector)'. Run `gifwin --list` to see candidates.")
        }
        guard hits.count == 1 else {
            let lines = hits.map { "  id:\($0.1.id)  \($0.1.app) \u{2014} \($0.1.title)  (\($0.1.width)x\($0.1.height))" }
            throw GifwinError(.noWindow, "'\(selector)' matched \(hits.count) windows; pick one with id:<n>:\n" + lines.joined(separator: "\n"))
        }
        return hits[0]
    }

    /// `text:<words>` keeps windows whose on-screen text contains the words. `ask:<words>` ranks windows by
    /// how many of the words appear in their text, title or application name, and needs a clear winner.
    /// Both read the screen literally; neither involves a language model.
    public static func resolveByContent(_ selector: String, in all: [(SCWindow, WindowInfo)]) async throws -> (SCWindow, WindowInfo) {
        let isAsk = selector.lowercased().hasPrefix("ask:")
        let query = String(selector.dropFirst(isAsk ? 4 : 5)).trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { throw GifwinError(.usage, "'\(selector)' needs words after the colon") }

        let text = await WindowText.index(all)
        let words = query.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }

        var scored: [(window: (SCWindow, WindowInfo), score: Int)] = []
        for entry in all {
            let haystack = ((text[entry.1.id] ?? []) + [entry.1.title, entry.1.app]).joined(separator: "\n").lowercased()
            let score = isAsk ? words.filter { haystack.contains($0) }.count : (haystack.contains(query) ? 1 : 0)
            if score > 0 { scored.append((entry, score)) }
        }
        guard let best = scored.map(\.score).max() else {
            throw GifwinError(.noWindow, "No window contains '\(query)'. Run `gifwin --list --ocr` to see what each window shows.")
        }
        let top = scored.filter { $0.score == best }
        guard top.count == 1 else {
            let lines = top.map { "  id:\($0.window.1.id)  \($0.window.1.app) \u{2014} \($0.window.1.title)  (\($0.window.1.width)x\($0.window.1.height))" }
            throw GifwinError(.noWindow, "'\(selector)' matched \(top.count) windows equally; pick one with id:<n>:\n" + lines.joined(separator: "\n"))
        }
        return top[0].window
    }
}
