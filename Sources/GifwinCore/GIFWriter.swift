import Foundation

/// Streaming GIF89a writer. Frames are LZW-compressed and written as they arrive,
/// so memory stays at roughly one frame regardless of clip length.
///
/// M0 is deliberately naive: one global 3-3-2 palette, full-frame writes, no diffing.
/// The quantizer and frame diffing replace `Palette` and `addFrame` in M1.
public final class GIFWriter {
    public enum Palette {
        /// 3 bits red, 3 bits green, 2 bits blue.
        public static func color(_ index: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            (UInt8((index >> 5) * 255 / 7), UInt8(((index >> 2) & 7) * 255 / 7), UInt8((index & 3) * 255 / 3))
        }

        @inline(__always)
        public static func index(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
            (r & 0xE0) | ((g & 0xE0) >> 3) | (b >> 6)
        }
    }

    public let width: Int
    public let height: Int
    public private(set) var frameCount = 0
    public private(set) var bytesWritten = 0

    private let handle: FileHandle
    private var finished = false

    public init(url: URL, width: Int, height: Int) throws {
        precondition(width > 0 && height > 0 && width <= 65535 && height <= 65535)
        self.width = width
        self.height = height
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)

        var header = Data("GIF89a".utf8)
        header.appendLE16(width)
        header.appendLE16(height)
        header.append(contentsOf: [0xF7, 0x00, 0x00]) // global table, 256 entries; background; aspect
        for i in 0..<256 {
            let c = Palette.color(i)
            header.append(contentsOf: [c.r, c.g, c.b])
        }
        header.append(contentsOf: [0x21, 0xFF, 0x0B])
        header.append(Data("NETSCAPE2.0".utf8))
        header.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00]) // loop forever
        try write(header)
    }

    /// `indices` is `width * height` palette indices, row-major, top row first.
    public func addFrame(indices: [UInt8], delayCS: Int) throws {
        precondition(!finished && indices.count == width * height)
        var block = Data()
        block.append(contentsOf: [0x21, 0xF9, 0x04, 0x04]) // graphic control: leave in place
        block.appendLE16(min(max(delayCS, 2), 65535))
        block.append(contentsOf: [0x00, 0x00])
        block.append(0x2C)
        block.appendLE16(0)
        block.appendLE16(0)
        block.appendLE16(width)
        block.appendLE16(height)
        block.append(0x00)
        block.append(8) // LZW minimum code size
        let compressed = LZW.compress(indices)
        var offset = 0
        while offset < compressed.count {
            let n = min(255, compressed.count - offset)
            block.append(UInt8(n))
            block.append(contentsOf: compressed[offset..<offset + n])
            offset += n
        }
        block.append(0x00)
        try write(block)
        frameCount += 1
    }

    public func finish() throws {
        guard !finished else { return }
        finished = true
        try write(Data([0x3B]))
        try handle.close()
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        bytesWritten += data.count
    }
}

enum LZW {
    /// GIF-flavoured LZW with an 8-bit alphabet. Code-size growth follows giflib:
    /// the size is raised after emitting a code once the next free code reaches 2^size.
    static func compress(_ pixels: [UInt8]) -> [UInt8] {
        let clear = 256, eoi = 257
        var out = [UInt8]()
        out.reserveCapacity(pixels.count / 2)
        var acc: UInt32 = 0
        var nbits = 0
        var codeSize = 9
        var next = 258
        var dict = [UInt32: UInt16](minimumCapacity: 4096)

        func emit(_ code: Int) {
            acc |= UInt32(code) << UInt32(nbits)
            nbits += codeSize
            while nbits >= 8 {
                out.append(UInt8(truncatingIfNeeded: acc))
                acc >>= 8
                nbits -= 8
            }
            if next >= (1 << codeSize) && codeSize < 12 { codeSize += 1 }
        }

        emit(clear)
        guard var prefix = pixels.first.map(Int.init) else {
            emit(eoi)
            if nbits > 0 { out.append(UInt8(truncatingIfNeeded: acc)) }
            return out
        }
        for byte in pixels.dropFirst() {
            let key = UInt32(prefix) << 8 | UInt32(byte)
            if let code = dict[key] {
                prefix = Int(code)
                continue
            }
            emit(prefix)
            prefix = Int(byte)
            if next >= 4095 {
                emit(clear)
                dict.removeAll(keepingCapacity: true)
                next = 258
                codeSize = 9
            } else {
                dict[key] = UInt16(next)
                next += 1
            }
        }
        emit(prefix)
        emit(eoi)
        if nbits > 0 { out.append(UInt8(truncatingIfNeeded: acc)) }
        return out
    }
}

private extension Data {
    mutating func appendLE16(_ v: Int) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }
}
