import Compression
import Foundation

/// A small ZIP writer for the packages Narengi produces (DOCX, EPUB, XLSX, ODS): stored or deflated
/// entries, UTF-8 names, no ZIP64. EPUB and ODS need their `mimetype` entry first and stored; callers
/// control the order and the method.
struct ZipWriter {
    private struct Entry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let offset: UInt32
    }

    private var body = Data()
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(date: Date = Date()) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date)
        let year = max(1980, c.year ?? 1980)
        dosTime = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        dosDate = UInt16(((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
    }

    /// Adds a file. `compress: false` stores it as is (required for EPUB's `mimetype`).
    mutating func add(_ name: String, data: Data, compress: Bool = true) throws {
        guard data.count < Int(UInt32.max) / 2, entries.count < 65_000 else {
            throw ConversionError.encodeFailed("ZIP (too large)")
        }
        let crc = Self.crc32(data)
        var method: UInt16 = 0
        var payload = data
        if compress, !data.isEmpty, let deflated = Self.deflate(data), deflated.count < data.count {
            method = 8
            payload = deflated
        }
        let offset = UInt32(body.count)
        let nameData = Data(name.utf8)

        body.appendLE(UInt32(0x04034b50))
        body.appendLE(UInt16(20))                 // version needed
        body.appendLE(UInt16(0x0800))             // UTF-8 names
        body.appendLE(method)
        body.appendLE(dosTime)
        body.appendLE(dosDate)
        body.appendLE(crc)
        body.appendLE(UInt32(payload.count))
        body.appendLE(UInt32(data.count))
        body.appendLE(UInt16(nameData.count))
        body.appendLE(UInt16(0))                  // extra length
        body.append(nameData)
        body.append(payload)

        entries.append(Entry(name: name, method: method, crc: crc, compressedSize: UInt32(payload.count),
                             uncompressedSize: UInt32(data.count), offset: offset))
    }

    mutating func add(_ name: String, text: String, compress: Bool = true) throws {
        try add(name, data: Data(text.utf8), compress: compress)
    }

    /// The complete archive.
    func finalized() -> Data {
        var out = body
        let directoryStart = UInt32(out.count)
        for entry in entries {
            let nameData = Data(entry.name.utf8)
            out.appendLE(UInt32(0x02014b50))
            out.appendLE(UInt16(20))              // version made by
            out.appendLE(UInt16(20))              // version needed
            out.appendLE(UInt16(0x0800))
            out.appendLE(entry.method)
            out.appendLE(dosTime)
            out.appendLE(dosDate)
            out.appendLE(entry.crc)
            out.appendLE(entry.compressedSize)
            out.appendLE(entry.uncompressedSize)
            out.appendLE(UInt16(nameData.count))
            out.appendLE(UInt16(0))               // extra
            out.appendLE(UInt16(0))               // comment
            out.appendLE(UInt16(0))               // disk
            out.appendLE(UInt16(0))               // internal attrs
            out.appendLE(UInt32(0))               // external attrs
            out.appendLE(entry.offset)
            out.append(nameData)
        }
        let directorySize = UInt32(out.count) - directoryStart
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(directorySize)
        out.appendLE(directoryStart)
        out.appendLE(UInt16(0))
        return out
    }

    func write(to url: URL) throws {
        do {
            try finalized().write(to: url)
        } catch {
            throw ConversionError.outputUnwritable(url.deletingLastPathComponent().path)
        }
    }

    // MARK: - Primitives

    /// Raw DEFLATE (RFC 1951), which is what ZIP entries hold; Apple's COMPRESSION_ZLIB emits exactly that.
    private static func deflate(_ data: Data) -> Data? {
        let capacity = data.count + data.count / 10 + 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        return written > 0 ? Data(bytes: destination, count: written) : nil
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
