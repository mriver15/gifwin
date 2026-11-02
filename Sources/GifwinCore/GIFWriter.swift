import Foundation

/// Where encoded frames go: a file while recording, or memory while watching.
public protocol GIFFrameSink: AnyObject {
    var width: Int { get }
    var height: Int { get }
    var frameCount: Int { get }
    var bytesWritten: Int { get }
    func addFrame(x: Int, y: Int, w: Int, h: Int, indices: [UInt8], palette: [UInt8], transparent: Int?, delayCS: Int) throws
    func finish() throws
}

/// Streaming GIF89a writer. Each frame carries its own local colour table, a sub-rectangle,
/// and an optional transparent index, so a frame can paint only the pixels that changed.
/// Frames are LZW-compressed and written as they arrive; memory stays near one frame.
public final class GIFWriter: GIFFrameSink {
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
        try write(Self.header(width: width, height: height))
    }

    /// Signature, screen descriptor and the loop-forever extension. No global colour table: every frame brings its own.
    public static func header(width: Int, height: Int) -> Data {
        var header = Data("GIF89a".utf8)
        header.appendLE16(width)
        header.appendLE16(height)
        header.append(contentsOf: [0x70, 0x00, 0x00])
        header.append(contentsOf: [0x21, 0xFF, 0x0B])
        header.append(Data("NETSCAPE2.0".utf8))
        header.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
        return header
    }

    public static let trailer = Data([0x3B])

    /// One complete frame: graphic control, image descriptor, local colour table and LZW data.
    ///
    /// - Parameters:
    ///   - indices: `w * h` palette indices for the rectangle, row-major.
    ///   - palette: RGB triplets, padded to a power of two. The transparent index, if any, must be inside it.
    ///   - transparent: index drawn as "leave the previous pixel", or nil.
    public static func frameBlock(x: Int, y: Int, w: Int, h: Int, indices: [UInt8], palette: [UInt8],
                                  transparent: Int?, delayCS: Int) -> Data {
        let entries = palette.count / 3
        precondition(entries >= 1 && entries <= 256 && indices.count == w * h && w > 0 && h > 0)
        var bits = 1
        while (1 << bits) < entries { bits += 1 }
        let minCode = max(2, bits)

        var block = Data()
        block.append(contentsOf: [0x21, 0xF9, 0x04, transparent == nil ? 0x04 : 0x05]) // leave in place
        block.appendLE16(min(max(delayCS, 2), 65535))
        block.append(UInt8(transparent ?? 0))
        block.append(0x00)
        block.append(0x2C)
        block.appendLE16(x)
        block.appendLE16(y)
        block.appendLE16(w)
        block.appendLE16(h)
        block.append(0x80 | UInt8(bits - 1)) // local colour table follows
        block.append(contentsOf: palette)
        block.append(contentsOf: [UInt8](repeating: 0, count: (1 << bits) * 3 - palette.count))
        block.append(UInt8(minCode))
        let compressed = LZW.compress(indices, minCodeSize: minCode)
        var offset = 0
        while offset < compressed.count {
            let n = min(255, compressed.count - offset)
            block.append(UInt8(n))
            block.append(contentsOf: compressed[offset..<offset + n])
            offset += n
        }
        block.append(0x00)
        return block
    }

    public func addFrame(x: Int = 0, y: Int = 0, w: Int, h: Int, indices: [UInt8],
                         palette: [UInt8], transparent: Int?, delayCS: Int) throws {
        precondition(!finished && x >= 0 && y >= 0 && x + w <= width && y + h <= height)
        try write(Self.frameBlock(x: x, y: y, w: w, h: h, indices: indices, palette: palette,
                                  transparent: transparent, delayCS: delayCS))
        frameCount += 1
    }

    public func finish() throws {
        guard !finished else { return }
        finished = true
        try write(Self.trailer)
        try handle.close()
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        bytesWritten += data.count
    }
}

enum LZW {
    /// GIF-flavoured LZW. Code-size growth follows giflib: the size is raised after emitting a
    /// code once the next free code reaches 2^size.
    static func compress(_ pixels: [UInt8], minCodeSize: Int) -> [UInt8] {
        let clear = 1 << minCodeSize, eoi = clear + 1
        var out = [UInt8]()
        out.reserveCapacity(pixels.count / 2)
        var acc: UInt32 = 0
        var nbits = 0
        var codeSize = minCodeSize + 1
        var next = eoi + 1
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
                next = eoi + 1
                codeSize = minCodeSize + 1
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

extension Data {
    mutating func appendLE16(_ v: Int) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }
}
