import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Reads what is written inside windows, so a window can be found by its content and not just its title bar.
public enum WindowText {
    /// One still of the window, OCR'd. Cost is roughly a screenshot plus 50-250 ms of recognition.
    public static func lines(of window: SCWindow, maxEdge: Double = 1280, accurate: Bool = false) async -> [String] {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)
        let scale = Double(info.pointPixelScale)
        let w = Double(info.contentRect.width) * scale, h = Double(info.contentRect.height) * scale
        let shrink = min(1, maxEdge / max(w, h, 1))

        let config = SCStreamConfiguration()
        config.width = max(1, Int(w * shrink))
        config.height = max(1, Int(h * shrink))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return [] }
        return OCR.lines(in: image, accurate: accurate)
    }

    /// The text of every candidate window, read concurrently. Large windows first, capped, because
    /// each one costs a screenshot.
    public static func index(_ candidates: [(SCWindow, WindowInfo)], limit: Int = 16) async -> [UInt32: [String]] {
        let chosen = candidates.sorted { $0.1.width * $0.1.height > $1.1.width * $1.1.height }.prefix(limit)
        var out: [UInt32: [String]] = [:]
        await withTaskGroup(of: (UInt32, [String]).self) { group in
            for (window, info) in chosen {
                group.addTask { (info.id, await lines(of: window)) }
            }
            for await (id, lines) in group { out[id] = lines }
        }
        return out
    }
}

/// Version information for the application that owns a window.
public enum AppInfo {
    public static func version(pid: pid_t) -> String? {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL,
              let info = Bundle(url: url)?.infoDictionary else { return nil }
        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?) where s != b: return "\(s) (\(b))"
        case let (s?, _): return s
        case let (_, b?): return b
        default: return nil
        }
    }
}
