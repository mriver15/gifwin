import Foundation

/// Xiaolin Wu's variance-minimising colour quantizer ("Efficient Statistical Computations for
/// Optimal Color Quantization"). Single pass, deterministic, no random seeding.
///
/// Pixels are binned into a 32x32x32 histogram (5 bits a channel). The histogram is turned into
/// cumulative moments so the weight, colour sum and variance of any box are eight table reads,
/// and the box with the most variance is split at the best plane until `maxColors` boxes exist.
public final class Wu {
    struct Box {
        var r0 = 0, r1 = 0, g0 = 0, g1 = 0, b0 = 0, b1 = 0
        var vol = 0
    }

    public struct Result {
        /// RGB triplets, `count` entries.
        public var palette: [UInt8]
        public var count: Int
        /// 5-bit cell (`r << 10 | g << 5 | b`) -> palette index.
        public var tag: [UInt8]
    }

    private static let side = 33
    private static let cells = 33 * 33 * 33
    private var wt = [Int](repeating: 0, count: Wu.cells)
    private var mr = [Int](repeating: 0, count: Wu.cells)
    private var mg = [Int](repeating: 0, count: Wu.cells)
    private var mb = [Int](repeating: 0, count: Wu.cells)
    private var m2 = [Int](repeating: 0, count: Wu.cells)

    private enum Axis { case red, green, blue }

    public init() {}

    public func reset() {
        for i in 0..<Wu.cells { wt[i] = 0; mr[i] = 0; mg[i] = 0; mb[i] = 0; m2[i] = 0 }
    }

    @inline(__always)
    public func add(r: Int, g: Int, b: Int) {
        let i = Wu.idx((r >> 3) + 1, (g >> 3) + 1, (b >> 3) + 1)
        wt[i] += 1
        mr[i] += r
        mg[i] += g
        mb[i] += b
        m2[i] += r * r + g * g + b * b
    }

    @inline(__always)
    private static func idx(_ r: Int, _ g: Int, _ b: Int) -> Int { r * 1089 + g * 33 + b }

    public func build(maxColors k: Int) -> Result {
        accumulate()
        var boxes = [Box](repeating: Box(), count: max(k, 1))
        boxes[0] = Box(r0: 0, r1: 32, g0: 0, g1: 32, b0: 0, b1: 32, vol: 0)
        var variance = [Double](repeating: 0, count: max(k, 1))
        var count = 1

        if volume(boxes[0], wt) > 0 {
            var next = 0
            while count < k {
                var first = boxes[next]
                var second = Box()
                if cut(&first, &second) {
                    boxes[next] = first
                    boxes[count] = second
                    variance[next] = first.vol > 1 ? self.variance(first) : 0
                    variance[count] = second.vol > 1 ? self.variance(second) : 0
                    count += 1
                } else {
                    variance[next] = 0
                }
                next = 0
                var best = variance[0]
                for i in 1..<count where variance[i] > best {
                    best = variance[i]
                    next = i
                }
                if best <= 0 { break }
            }
        }

        var palette = [UInt8](repeating: 0, count: count * 3)
        var tag = [UInt8](repeating: 0, count: 32768)
        for i in 0..<count {
            let box = boxes[i]
            let w = volume(box, wt)
            if w > 0 {
                palette[i * 3] = UInt8(clamping: (volume(box, mr) + w / 2) / w)
                palette[i * 3 + 1] = UInt8(clamping: (volume(box, mg) + w / 2) / w)
                palette[i * 3 + 2] = UInt8(clamping: (volume(box, mb) + w / 2) / w)
            }
            Wu.paint(&tag, box, UInt8(i))
        }
        return Result(palette: palette, count: count, tag: tag)
    }

    /// Marks every 5-bit cell inside `box` with `value`. Kept out of line on purpose: inlined into
    /// `build`, this loop produced wrong tags in release builds only (two boxes' cells swapped; debug
    /// builds and a build with a print added were correct). Root cause not isolated, Swift 6.4 on
    /// macOS 27. `wuFindsExactColours` in encoder-checks guards it; run it in release.
    @inline(never)
    private static func paint(_ tag: inout [UInt8], _ box: Box, _ value: UInt8) {
        guard box.r1 > box.r0, box.g1 > box.g0, box.b1 > box.b0 else { return }
        var r = box.r0
        while r < box.r1 {
            var g = box.g0
            while g < box.g1 {
                let row = (r << 10) + (g << 5)
                var b = box.b0
                while b < box.b1 {
                    tag[row + b] = value
                    b += 1
                }
                g += 1
            }
            r += 1
        }
    }

    /// Turns the histogram into 3-D cumulative moments in place.
    private func accumulate() {
        var area = [Int](repeating: 0, count: 33), areaR = area, areaG = area, areaB = area, area2 = area
        for r in 1...32 {
            for i in 0..<33 { area[i] = 0; areaR[i] = 0; areaG[i] = 0; areaB[i] = 0; area2[i] = 0 }
            for g in 1...32 {
                var line = 0, lineR = 0, lineG = 0, lineB = 0, line2 = 0
                for b in 1...32 {
                    let i1 = Wu.idx(r, g, b)
                    line += wt[i1]; lineR += mr[i1]; lineG += mg[i1]; lineB += mb[i1]; line2 += m2[i1]
                    area[b] += line; areaR[b] += lineR; areaG[b] += lineG; areaB[b] += lineB; area2[b] += line2
                    let i2 = i1 - 1089
                    wt[i1] = wt[i2] + area[b]
                    mr[i1] = mr[i2] + areaR[b]
                    mg[i1] = mg[i2] + areaG[b]
                    mb[i1] = mb[i2] + areaB[b]
                    m2[i1] = m2[i2] + area2[b]
                }
            }
        }
    }

    private func volume(_ c: Box, _ m: [Int]) -> Int {
        m[Wu.idx(c.r1, c.g1, c.b1)] - m[Wu.idx(c.r1, c.g1, c.b0)] - m[Wu.idx(c.r1, c.g0, c.b1)] + m[Wu.idx(c.r1, c.g0, c.b0)]
            - m[Wu.idx(c.r0, c.g1, c.b1)] + m[Wu.idx(c.r0, c.g1, c.b0)] + m[Wu.idx(c.r0, c.g0, c.b1)] - m[Wu.idx(c.r0, c.g0, c.b0)]
    }

    /// Sum over the face of the box at its lower bound along `axis`.
    private func bottom(_ c: Box, _ axis: Axis, _ m: [Int]) -> Int {
        switch axis {
        case .red:
            return -m[Wu.idx(c.r0, c.g1, c.b1)] + m[Wu.idx(c.r0, c.g1, c.b0)] + m[Wu.idx(c.r0, c.g0, c.b1)] - m[Wu.idx(c.r0, c.g0, c.b0)]
        case .green:
            return -m[Wu.idx(c.r1, c.g0, c.b1)] + m[Wu.idx(c.r1, c.g0, c.b0)] + m[Wu.idx(c.r0, c.g0, c.b1)] - m[Wu.idx(c.r0, c.g0, c.b0)]
        case .blue:
            return -m[Wu.idx(c.r1, c.g1, c.b0)] + m[Wu.idx(c.r1, c.g0, c.b0)] + m[Wu.idx(c.r0, c.g1, c.b0)] - m[Wu.idx(c.r0, c.g0, c.b0)]
        }
    }

    /// Sum over the face of the box at plane `pos` along `axis`.
    private func top(_ c: Box, _ axis: Axis, _ pos: Int, _ m: [Int]) -> Int {
        switch axis {
        case .red:
            return m[Wu.idx(pos, c.g1, c.b1)] - m[Wu.idx(pos, c.g1, c.b0)] - m[Wu.idx(pos, c.g0, c.b1)] + m[Wu.idx(pos, c.g0, c.b0)]
        case .green:
            return m[Wu.idx(c.r1, pos, c.b1)] - m[Wu.idx(c.r1, pos, c.b0)] - m[Wu.idx(c.r0, pos, c.b1)] + m[Wu.idx(c.r0, pos, c.b0)]
        case .blue:
            return m[Wu.idx(c.r1, c.g1, pos)] - m[Wu.idx(c.r1, c.g0, pos)] - m[Wu.idx(c.r0, c.g1, pos)] + m[Wu.idx(c.r0, c.g0, pos)]
        }
    }

    private func variance(_ c: Box) -> Double {
        let dr = volume(c, mr), dg = volume(c, mg), db = volume(c, mb)
        let xx = m2[Wu.idx(c.r1, c.g1, c.b1)] - m2[Wu.idx(c.r1, c.g1, c.b0)] - m2[Wu.idx(c.r1, c.g0, c.b1)] + m2[Wu.idx(c.r1, c.g0, c.b0)]
            - m2[Wu.idx(c.r0, c.g1, c.b1)] + m2[Wu.idx(c.r0, c.g1, c.b0)] + m2[Wu.idx(c.r0, c.g0, c.b1)] - m2[Wu.idx(c.r0, c.g0, c.b0)]
        let w = volume(c, wt)
        guard w > 0 else { return 0 }
        return Double(xx) - Double(dr * dr + dg * dg + db * db) / Double(w)
    }

    /// Best split plane along one axis: maximises the sum of the two halves' (colour sum)^2 / weight.
    private func maximize(_ c: Box, _ axis: Axis, _ first: Int, _ last: Int,
                          _ wholeR: Int, _ wholeG: Int, _ wholeB: Int, _ wholeW: Int) -> (Double, Int) {
        let baseR = bottom(c, axis, mr), baseG = bottom(c, axis, mg), baseB = bottom(c, axis, mb), baseW = bottom(c, axis, wt)
        var best = 0.0
        var cutAt = -1
        var i = first
        while i < last {
            defer { i += 1 }
            var hr = baseR + top(c, axis, i, mr)
            var hg = baseG + top(c, axis, i, mg)
            var hb = baseB + top(c, axis, i, mb)
            var hw = baseW + top(c, axis, i, wt)
            if hw == 0 { continue }
            var temp = Double(hr * hr + hg * hg + hb * hb) / Double(hw)
            hr = wholeR - hr; hg = wholeG - hg; hb = wholeB - hb; hw = wholeW - hw
            if hw == 0 { continue }
            temp += Double(hr * hr + hg * hg + hb * hb) / Double(hw)
            if temp > best {
                best = temp
                cutAt = i
            }
        }
        return (best, cutAt)
    }

    private func cut(_ a: inout Box, _ b: inout Box) -> Bool {
        let wr = volume(a, mr), wg = volume(a, mg), wb = volume(a, mb), ww = volume(a, wt)
        let (maxR, cutR) = maximize(a, .red, a.r0 + 1, a.r1, wr, wg, wb, ww)
        let (maxG, cutG) = maximize(a, .green, a.g0 + 1, a.g1, wr, wg, wb, ww)
        let (maxB, cutB) = maximize(a, .blue, a.b0 + 1, a.b1, wr, wg, wb, ww)

        let axis: Axis
        if maxR >= maxG && maxR >= maxB {
            axis = .red
            if cutR < 0 { return false }
        } else if maxG >= maxR && maxG >= maxB {
            axis = .green
        } else {
            axis = .blue
        }

        b.r1 = a.r1; b.g1 = a.g1; b.b1 = a.b1
        switch axis {
        case .red:
            b.r0 = cutR; a.r1 = cutR; b.g0 = a.g0; b.b0 = a.b0
        case .green:
            if cutG < 0 { return false }
            b.g0 = cutG; a.g1 = cutG; b.r0 = a.r0; b.b0 = a.b0
        case .blue:
            if cutB < 0 { return false }
            b.b0 = cutB; a.b1 = cutB; b.r0 = a.r0; b.g0 = a.g0
        }
        a.vol = (a.r1 - a.r0) * (a.g1 - a.g0) * (a.b1 - a.b0)
        b.vol = (b.r1 - b.r0) * (b.g1 - b.g0) * (b.b1 - b.b0)
        return true
    }
}
