import CoreGraphics
import Foundation
import Vision

/// Blanks credentials and personal data out of frames before they are encoded, so the unredacted pixels
/// never reach disk. It reads the screen with Vision, finds text matching `Secrets`, and replaces just
/// those words with a mosaic.
///
/// Reading every pixel of every frame would be too slow to keep up with live capture, so it reads only the
/// rows that changed since the last frame (plus a margin and the full width, so a token that is being
/// typed is seen whole) and remembers what it found in the rest. If it cannot keep up, ScreenCaptureKit
/// drops frames; it never lets one through unread.
public final class Redactor {
    private let width: Int
    private let height: Int
    private var previous: [UInt32]?
    /// Pixel rectangles currently masked, top-left origin.
    private var boxes: [CGRect] = []
    /// Count of masks applied over the life of the clip.
    public private(set) var applied = 0

    private static let margin = 28
    private static let block = 10
    private static let pad = 5.0

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Redacts `pixels` in place.
    public func process(_ pixels: inout [UInt32]) {
        let source = pixels
        if let previous, previous.count == pixels.count {
            if let rows = changedRows(previous, pixels) {
                let y0 = max(0, rows.lowerBound - Self.margin), y1 = min(height, rows.upperBound + Self.margin)
                let strip = CGRect(x: 0, y: y0, width: width, height: y1 - y0)
                boxes.removeAll { $0.intersects(strip) }
                boxes += detect(in: pixels, rows: y0..<y1)
            }
        } else {
            boxes = detect(in: pixels, rows: 0..<height)
        }
        previous = source
        for box in boxes { mosaic(&pixels, box) }
        applied += boxes.count
    }

    private func changedRows(_ a: [UInt32], _ b: [UInt32]) -> Range<Int>? {
        var first = -1, last = -1
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for y in 0..<height {
                    let base = y * width
                    var same = true
                    for x in 0..<width where pa[base + x] != pb[base + x] { same = false; break }
                    if !same { if first < 0 { first = y }; last = y }
                }
            }
        }
        return first < 0 ? nil : first..<(last + 1)
    }

    private func detect(in pixels: [UInt32], rows: Range<Int>) -> [CGRect] {
        let h = rows.count
        guard h > 0, let image = Self.image(pixels, width: width, rowRange: rows) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return [] }

        var found: [CGRect] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            for match in Secrets.matches(in: candidate.string) {
                // The word's own box where Vision can give it, otherwise the whole line to be safe.
                let box = (try? candidate.boundingBox(for: match.range))?.boundingBox ?? observation.boundingBox
                found.append(Self.pixelRect(box, width: width, height: h, offsetY: rows.lowerBound))
            }
        }
        return found
    }

    /// Vision reports 0...1 with the origin at the bottom left.
    private static func pixelRect(_ n: CGRect, width: Int, height: Int, offsetY: Int) -> CGRect {
        let x = n.minX * Double(width), w = n.width * Double(width)
        let h = n.height * Double(height)
        let y = (1 - n.maxY) * Double(height) + Double(offsetY)
        return CGRect(x: x - pad, y: y - pad, width: w + 2 * pad, height: h + 2 * pad)
    }

    private func mosaic(_ pixels: inout [UInt32], _ rect: CGRect) {
        let x0 = max(0, Int(rect.minX.rounded(.down))), x1 = min(width, Int(rect.maxX.rounded(.up)))
        let y0 = max(0, Int(rect.minY.rounded(.down))), y1 = min(height, Int(rect.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return }
        var by = y0
        while by < y1 {
            var bx = x0
            while bx < x1 {
                let ex = min(bx + Self.block, x1), ey = min(by + Self.block, y1)
                var r = 0, g = 0, b = 0, n = 0
                for y in by..<ey { for x in bx..<ex {
                    let v = pixels[y * width + x]
                    r += Int((v >> 16) & 255); g += Int((v >> 8) & 255); b += Int(v & 255); n += 1
                } }
                let average = UInt32(b / n) | UInt32(g / n) << 8 | UInt32(r / n) << 16 | 0xFF00_0000
                for y in by..<ey { for x in bx..<ex { pixels[y * width + x] = average } }
                bx += Self.block
            }
            by += Self.block
        }
    }

    /// A CGImage of `rowRange` of a packed BGRA frame.
    public static func image(_ pixels: [UInt32], width: Int, rowRange: Range<Int>) -> CGImage? {
        var slice = Array(pixels[(rowRange.lowerBound * width)..<(rowRange.upperBound * width)])
        return slice.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: width, height: rowRange.count, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage()
        }
    }
}
