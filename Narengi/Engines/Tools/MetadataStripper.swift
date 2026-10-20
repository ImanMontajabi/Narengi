import Foundation

/// Lossless metadata removal for JPEG, PNG, WebP and GIF: the compressed pixels are never touched.
///
/// JPEG drops APP1 (EXIF/XMP), APP13 (IPTC), comments and vendor APP segments but keeps JFIF, ICC (APP2) and
/// Adobe (APP14). A photo with a non-default EXIF orientation keeps a minimal EXIF block holding only the
/// orientation, so it still shows upright. Ported from Satsuma's `metadata.rs` (MIT, © sonatina-dream).
enum MetadataStripper {
    static func strip(_ data: Data, format: String) throws -> Data {
        switch format {
        case "JPG": return try stripJPEG(data)
        case "PNG": return try stripPNG(data)
        case "WEBP": return try stripWebP(data)
        case "GIF": return try stripGIF(data)
        default: throw ConversionError.unsupported(from: format, to: "metadata removal")
        }
    }

    private static func corrupt(_ what: String) -> ConversionError {
        .custom("The \(what) file looks damaged.")
    }

    // MARK: JPEG

    static func stripJPEG(_ input: Data) throws -> Data {
        let data = [UInt8](input)
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else { throw corrupt("JPEG") }
        var out = Array(data[..<2])
        var orientation: UInt16?
        var wroteOrientation = false
        var pos = 2
        while pos < data.count {
            guard data[pos] == 0xFF else { throw corrupt("JPEG") }
            var m = pos + 1
            while m < data.count, data[m] == 0xFF { m += 1 }  // fill bytes
            if m >= data.count { break }
            let marker = data[m]
            let segmentStart = m - 1
            if marker == 0xD9 {
                out += data[segmentStart...]
                return Data(out)
            }
            if (0xD0...0xD7).contains(marker) || marker == 0x01 {
                out += data[segmentStart...m]
                pos = m + 1
                continue
            }
            guard m + 3 <= data.count else { throw corrupt("JPEG") }
            let length = Int(data[m + 1]) << 8 | Int(data[m + 2])
            let end = m + 1 + length
            guard length >= 2, end <= data.count else { throw corrupt("JPEG") }
            let payload = data[(m + 3)..<end]

            let keep: Bool
            switch marker {
            case 0xE0, 0xE2, 0xEE: keep = true  // JFIF, ICC profile, Adobe
            case 0xE1:
                if payload.starts(with: [0x45, 0x78, 0x69, 0x66, 0, 0]) {  // "Exif\0\0"
                    orientation = orientation ?? exifOrientation(Array(payload.dropFirst(6)))
                }
                keep = false
            case 0xE3...0xED, 0xEF, 0xFE: keep = false
            default: keep = true
            }
            // The minimal orientation block goes right before the first table/frame segment, after the header APPs.
            let headerApp = marker == 0xE0 || marker == 0xE2 || marker == 0xEE
            if keep, !headerApp, !wroteOrientation {
                if let o = orientation, (2...8).contains(o) { out += orientationSegment(o) }
                wroteOrientation = true
            }
            if keep { out += data[segmentStart..<end] }
            if marker == 0xDA {  // start of scan: the rest is entropy-coded data and EOI
                out += data[end...]
                return Data(out)
            }
            pos = end
        }
        return Data(out)
    }

    /// Orientation tag (0x0112) of a TIFF-structured EXIF block.
    static func exifOrientation(_ tiff: [UInt8]) -> UInt16? {
        guard tiff.count >= 8 else { return nil }
        let little: Bool
        switch (tiff[0], tiff[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        func u16(_ i: Int) -> UInt16? {
            guard i >= 0, i + 2 <= tiff.count else { return nil }
            return little ? UInt16(tiff[i]) | UInt16(tiff[i + 1]) << 8 : UInt16(tiff[i]) << 8 | UInt16(tiff[i + 1])
        }
        func u32(_ i: Int) -> Int? {
            guard i >= 0, i + 4 <= tiff.count else { return nil }
            let b = tiff[i..<(i + 4)].map(Int.init)
            return little ? b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24 : b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
        }
        guard let ifd = u32(4), let count = u16(ifd) else { return nil }
        for k in 0..<Int(count) {
            let entry = ifd + 2 + k * 12
            guard let tag = u16(entry) else { return nil }
            if tag == 0x0112 { return u16(entry + 8) }
        }
        return nil
    }

    /// An APP1 segment with an EXIF block containing only the orientation.
    static func orientationSegment(_ orientation: UInt16) -> [UInt8] {
        var tiff: [UInt8] = [0x4D, 0x4D, 0, 0x2A, 0, 0, 0, 8]  // big-endian header, IFD0 at 8
        tiff += [0, 1]                                         // one entry
        tiff += [0x01, 0x12, 0, 3, 0, 0, 0, 1]                  // tag 0x0112, SHORT, count 1
        tiff += [UInt8(orientation >> 8), UInt8(orientation & 0xFF), 0, 0]
        tiff += [0, 0, 0, 0]                                   // no next IFD
        let length = 2 + 6 + tiff.count
        return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + Array("Exif".utf8) + [0, 0] + tiff
    }

    // MARK: PNG

    static func stripPNG(_ input: Data) throws -> Data {
        let data = [UInt8](input)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.starts(with: signature) else { throw corrupt("PNG") }
        var out = signature
        var pos = signature.count
        let dropped: Set<String> = ["tEXt", "zTXt", "iTXt", "eXIf", "tIME"]
        while pos + 12 <= data.count {
            let length = Int(data[pos]) << 24 | Int(data[pos + 1]) << 16 | Int(data[pos + 2]) << 8 | Int(data[pos + 3])
            let end = pos + 12 + length
            guard end <= data.count else { throw corrupt("PNG") }
            let kind = String(decoding: data[(pos + 4)..<(pos + 8)], as: UTF8.self)
            if !dropped.contains(kind) { out += data[pos..<end] }
            pos = end
            if kind == "IEND" { break }
        }
        return Data(out)
    }

    // MARK: WebP

    static func stripWebP(_ input: Data) throws -> Data {
        let data = [UInt8](input)
        guard data.count >= 12, Array(data[0..<4]) == Array("RIFF".utf8), Array(data[8..<12]) == Array("WEBP".utf8) else {
            throw corrupt("WebP")
        }
        var body: [UInt8] = []
        var pos = 12
        while pos + 8 <= data.count {
            let fourCC = String(decoding: data[pos..<(pos + 4)], as: UTF8.self)
            let size = Int(data[pos + 4]) | Int(data[pos + 5]) << 8 | Int(data[pos + 6]) << 16 | Int(data[pos + 7]) << 24
            let padded = size + (size & 1)
            let end = min(pos + 8 + padded, data.count)
            guard pos + 8 + size <= data.count else { throw corrupt("WebP") }
            switch fourCC {
            case "EXIF", "XMP ": break
            case "VP8X":
                var chunk = Array(data[pos..<end])
                if chunk.count > 8 { chunk[8] &= ~(0x08 | 0x04) }  // clear the EXIF and XMP flags
                body += chunk
            default: body += data[pos..<end]
            }
            pos = end
        }
        var out = Array("RIFF".utf8)
        let riffSize = UInt32(body.count + 4)
        out += [UInt8(riffSize & 0xFF), UInt8(riffSize >> 8 & 0xFF), UInt8(riffSize >> 16 & 0xFF), UInt8(riffSize >> 24 & 0xFF)]
        out += Array("WEBP".utf8)
        out += body
        return Data(out)
    }

    // MARK: GIF

    static func stripGIF(_ input: Data) throws -> Data {
        let data = [UInt8](input)
        guard data.count >= 13, data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) else {
            throw corrupt("GIF")
        }
        let flags = data[10]
        var pos = 13
        if flags & 0x80 != 0 { pos += 3 * (1 << (Int(flags & 0x07) + 1)) }
        guard pos <= data.count else { throw corrupt("GIF") }
        var out = Array(data[..<pos])

        /// End of the sub-block chain that starts at `start`.
        func skipBlocks(_ start: Int) throws -> Int {
            var p = start
            while true {
                guard p < data.count else { throw corrupt("GIF") }
                let length = Int(data[p])
                p += 1 + length
                if length == 0 { return p }
                guard p <= data.count else { throw corrupt("GIF") }
            }
        }

        while pos < data.count {
            switch data[pos] {
            case 0x3B:
                out.append(0x3B)
                return Data(out)
            case 0x21:
                guard pos + 1 < data.count else { throw corrupt("GIF") }
                let label = data[pos + 1]
                let end = try skipBlocks(pos + 2)
                let keep: Bool
                switch label {
                case 0xFE: keep = false  // comment
                case 0xFF:
                    let id = pos + 14 <= data.count ? Array(data[(pos + 3)..<(pos + 14)]) : []
                    keep = id == Array("NETSCAPE2.0".utf8) || id == Array("ANIMEXTS1.0".utf8)
                default: keep = true
                }
                if keep { out += data[pos..<end] }
                pos = end
            case 0x2C:
                guard pos + 9 < data.count else { throw corrupt("GIF") }
                var p = pos + 10
                let localFlags = data[pos + 9]
                if localFlags & 0x80 != 0 { p += 3 * (1 << (Int(localFlags & 0x07) + 1)) }
                p += 1  // LZW minimum code size
                let end = try skipBlocks(p)
                out += data[pos..<end]
                pos = end
            default:
                throw corrupt("GIF")
            }
        }
        return Data(out)
    }
}
