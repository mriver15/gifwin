import CoreGraphics
import Foundation
import Vision

/// On-device text recognition. Nothing leaves the machine and no model ships in the binary: the
/// recogniser is part of macOS.
public enum OCR {
    /// Recognised lines in reading order (top to bottom, then left to right).
    public static func lines(in image: CGImage, accurate: Bool = true, limit: Int = 80) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        // UI strings are identifiers, paths and product names; "correcting" them to words hurts more than it helps.
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let found = request.results else { return [] }

        let rows: [(y: Double, x: Double, text: String)] = found.compactMap { obs in
            guard let top = obs.topCandidates(1).first, top.confidence >= 0.3 else { return nil }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2 else { return nil }
            return (Double(obs.boundingBox.midY), Double(obs.boundingBox.minX), String(text.prefix(200)))
        }
        // Vision's origin is bottom-left, so a higher midY is higher on screen. Rows within 1.2% of the
        // height count as one line.
        let sorted = rows.sorted { abs($0.y - $1.y) > 0.012 ? $0.y > $1.y : $0.x < $1.x }
        return Array(sorted.prefix(limit).map(\.text))
    }
}
