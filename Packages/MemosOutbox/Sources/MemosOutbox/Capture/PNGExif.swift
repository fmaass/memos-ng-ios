import Foundation

/// The EXIF date tags of a PNG, read from the file's own chunks.
///
/// It exists because ImageIO does not find them all. A PNG carries EXIF in an `eXIf` chunk, and the
/// chunk is legal anywhere before `IEND` — including AFTER the image data. Apple's ImageIO reports
/// no EXIF dictionary at all for that placement (measured on macOS 26.6 / Swift 6.3.3, 2026-09-06,
/// on the vendored `png-exif-after-idat.png`), while the server's reader walks every chunk and finds
/// it. The contract is one rule set for every client, so the client that cannot see the tag grows
/// the reader rather than the artefact losing the case.
///
/// It is METADATA ONLY, in the strict sense: it reads the 8-byte chunk headers and SEEKS over every
/// payload except `eXIf`, so a 40 MB image costs the same few reads as a small one, and `IDAT` is
/// never read at all. It stops at `IEND`. Anything malformed is nothing at all — never an error.
enum PNGExif {
    static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    /// A PNG with more chunks than this is not a photograph anybody shared; the bound is what keeps
    /// a corrupt length field from becoming a loop.
    static let chunkLimit = 4096
    /// The most EXIF this will hold in memory. Real camera EXIF is a few kilobytes.
    static let maximumExifBytes = 1 << 20

    /// The two date tags, or nil when the file is not a PNG or carries no `eXIf`.
    static func dateTags(inFileAt url: URL) -> (dateTime: String?, offset: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), head == signature else { return nil }
        for _ in 0..<chunkLimit {
            guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return nil }
            let length = Int(bigEndian32(header, at: 0))
            let type = String(
                decoding: header[header.startIndex + 4..<header.startIndex + 8],
                as: UTF8.self)
            if type == "IEND" { return nil }
            if type == "eXIf" {
                guard length > 0, length <= maximumExifBytes,
                    let payload = try? handle.read(upToCount: length), payload.count == length
                else { return nil }
                return exifDates(inTIFF: payload)
            }
            // Past the payload and its CRC without reading either.
            guard let position = try? handle.offset(),
                (try? handle.seek(toOffset: position + UInt64(length) + 4)) != nil
            else { return nil }
        }
        return nil
    }

    /// `DateTimeOriginal`, and the offset beside it, out of a TIFF block.
    ///
    /// Only the Exif sub-IFD is resolved and only three tags are read from it. The GPS IFD
    /// (0x8825) is never followed — the tag whitelist is not a filter applied afterwards, it is
    /// the only thing this walk looks for.
    static func exifDates(inTIFF data: Data) -> (dateTime: String?, offset: String?)? {
        guard data.count >= 8 else { return nil }
        let base = data.startIndex
        let bigEndian: Bool
        switch (data[base], data[base + 1]) {
        case (0x4D, 0x4D): bigEndian = true
        case (0x49, 0x49): bigEndian = false
        default: return nil
        }
        func word(_ offset: Int) -> UInt16? {
            guard offset >= 0, offset + 2 <= data.count else { return nil }
            let high = UInt16(data[base + offset]), low = UInt16(data[base + offset + 1])
            return bigEndian ? (high << 8 | low) : (low << 8 | high)
        }
        func long(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            var value: UInt32 = 0
            for index in 0..<4 {
                let byte = UInt32(data[base + offset + (bigEndian ? index : 3 - index)])
                value = value << 8 | byte
            }
            return value
        }
        guard word(2) == 42, let ifd0 = long(4) else { return nil }

        /// The offset of the tag's value, whether it is inline or pointed at.
        func valueOffset(entry: Int, count: UInt32, size: Int) -> Int? {
            let bytes = Int(count) * size
            if bytes <= 4 { return entry + 8 }
            guard let pointer = long(entry + 8) else { return nil }
            return Int(pointer)
        }
        func ascii(entry: Int, count: UInt32) -> String? {
            guard let start = valueOffset(entry: entry, count: count, size: 1),
                start >= 0, start + Int(count) <= data.count
            else { return nil }
            let raw = data[(base + start)..<(base + start + Int(count))]
            let text = String(decoding: raw, as: UTF8.self)
                .split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false).first
            return text.map(String.init)?.trimmingCharacters(in: .whitespaces)
        }
        func entries(at ifd: Int) -> [(tag: UInt16, type: UInt16, count: UInt32, offset: Int)] {
            guard let count = word(ifd), count > 0, count < 1024 else { return [] }
            var found: [(tag: UInt16, type: UInt16, count: UInt32, offset: Int)] = []
            for index in 0..<Int(count) {
                let entry = ifd + 2 + index * 12
                guard let tag = word(entry), let type = word(entry + 2),
                    let items = long(entry + 4)
                else { break }
                found.append((tag, type, items, entry))
            }
            return found
        }

        var exifIFD: Int?
        for entry in entries(at: Int(ifd0)) where entry.tag == 0x8769 {
            guard let pointer = long(entry.offset + 8) else { continue }
            exifIFD = Int(pointer)
        }
        guard let exifIFD else { return nil }

        var dateTime: String?
        var offsetOriginal: String?
        var offsetPlain: String?
        for entry in entries(at: exifIFD) {
            switch entry.tag {
            case 0x9003: dateTime = ascii(entry: entry.offset, count: entry.count)
            case 0x9011: offsetOriginal = ascii(entry: entry.offset, count: entry.count)
            case 0x9010: offsetPlain = ascii(entry: entry.offset, count: entry.count)
            default: continue
            }
        }
        guard dateTime != nil || offsetOriginal != nil || offsetPlain != nil else { return nil }
        return (dateTime, offsetOriginal ?? offsetPlain)
    }

    private static func bigEndian32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        var value: UInt32 = 0
        for index in 0..<4 { value = value << 8 | UInt32(data[base + index]) }
        return value
    }
}
