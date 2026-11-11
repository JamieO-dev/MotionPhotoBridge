import Foundation

public enum MotionPhotoEncoding: String, Sendable {
    case google
    case samsung
}

public enum MotionPhotoWriterError: LocalizedError, Equatable, Sendable {
    case invalidJPEG
    case jpegContainsTrailingData
    case invalidVideo
    case invalidTimestamp
    case fileTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidJPEG:
            return "A complete standalone JPEG is required to create a Motion Photo."
        case .jpegContainsTrailingData:
            return "The still image contains trailing data. Re-encode the still image before adding a new motion video."
        case .invalidVideo:
            return "The motion video is not a complete MP4 file. Re-encode it as MP4 before creating a Motion Photo."
        case .invalidTimestamp:
            return "The key-photo timestamp must be zero or greater, or unspecified."
        case .fileTooLarge:
            return "The resulting Motion Photo would exceed the 1 GB size limit."
        }
    }
}

/// Builds a new JPEG Motion Photo without changing either input.
///
/// `jpeg` must be a clean, standalone JPEG ending at its real EOI marker. Existing
/// standard and extended XMP packets are replaced; EXIF, ICC, other APP segments,
/// and compressed image bytes are preserved. The caller must decode/re-encode
/// source photos first, and must supply a playable MP4 with a video track.
///
/// Google output follows Android Motion Photo 1.0: the MP4 is the last resource.
/// Samsung output uses indexed SEF 107 blocks with MotionPhoto_Version = "mpv3",
/// matching the direct-video JPEG layout used by the MotionPhoto2 producer.
/// Samsung's XMP resource length includes the trailing SEF metadata; its SEF
/// index records the exact MP4 length. Samsung Gallery compatibility still
/// requires verification on the intended phone and Gallery version.
/// Format references: https://developer.android.com/media/platform/motion-photo-format
/// and https://github.com/PetrVys/MotionPhoto2/blob/main/SamsungTags.py .
public enum MotionPhotoWriter {
    public static func make(jpeg: Data, video: Data,
                            presentationTimeMicroseconds: Int64?,
                            format: MotionPhotoEncoding) throws -> Data {
        guard jpeg.count <= MotionPhotoOutputSize.maximumBytes,
              video.count <= MotionPhotoOutputSize.maximumBytes else {
            throw MotionPhotoWriterError.fileTooLarge
        }
        let timestamp = presentationTimeMicroseconds ?? -1
        guard timestamp >= -1 else { throw MotionPhotoWriterError.invalidTimestamp }

        let jpegBytes = MotionWriterBytes(jpeg)
        let layout = try MotionWriterJPEG.inspect(jpegBytes)
        guard MotionWriterMovie.isComplete(MotionWriterBytes(video)) else {
            throw MotionPhotoWriterError.invalidVideo
        }
        let trailer = try MotionWriterTrailer.make(videoCount: video.count, format: format)
        let packet = try xmpPacket(videoLength: video.count + trailer.afterVideo.count,
                                   padding: trailer.beforeVideo.count, timestamp: timestamp)
        let removedCount = layout.removedXMP.reduce(0) { $0 + $1.count }
        let expectedSize = try MotionPhotoOutputSize.checkedTotal([
            jpeg.count - removedCount, packet.count, trailer.beforeVideo.count,
            video.count, trailer.afterVideo.count
        ])

        var result = Data()
        result.reserveCapacity(expectedSize)
        var cursor = 0
        var inserted = false
        func appendImageRange(_ range: Range<Int>) {
            if !inserted && range.contains(layout.insertAt) {
                result.append(jpegBytes.slice(range.lowerBound..<layout.insertAt))
                result.append(packet)
                result.append(jpegBytes.slice(layout.insertAt..<range.upperBound))
                inserted = true
            } else {
                result.append(jpegBytes.slice(range))
            }
        }
        for removed in layout.removedXMP {
            appendImageRange(cursor..<removed.lowerBound)
            cursor = removed.upperBound
        }
        appendImageRange(cursor..<jpeg.count)
        // insertAt is the first non-APP/non-COM marker, which cannot be removed.
        guard inserted else { throw MotionPhotoWriterError.invalidJPEG }
        result.append(trailer.beforeVideo)
        result.append(video)
        result.append(trailer.afterVideo)
        return result
    }

    private static func xmpPacket(videoLength: Int, padding: Int, timestamp: Int64) throws -> Data {
        // All substitutions are validated integers. No source XML is copied.
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:Camera="http://ns.google.com/photos/1.0/camera/" xmlns:Container="http://ns.google.com/photos/1.0/container/" xmlns:Item="http://ns.google.com/photos/1.0/container/item/" Camera:MotionPhoto="1" Camera:MotionPhotoVersion="1" Camera:MotionPhotoPresentationTimestampUs="\(timestamp)">
              <Container:Directory><rdf:Seq>
                <rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="image/jpeg" Item:Semantic="Primary" Item:Length="0" Item:Padding="\(padding)"/></rdf:li>
                <rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="video/mp4" Item:Semantic="MotionPhoto" Item:Length="\(videoLength)"/></rdf:li>
              </rdf:Seq></Container:Directory>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        let payload = Data(MotionWriterJPEG.xmpHeader.utf8) + Data(xml.utf8)
        guard payload.count <= 65_533 else { throw MotionPhotoWriterError.fileTooLarge }
        let length = payload.count + 2 // JPEG segment length includes its own two bytes.
        return Data([0xff, 0xe1, UInt8(length >> 8), UInt8(length & 255)]) + payload
    }
}

/// Central size gate also lets tests exercise overflow without allocating huge files.
enum MotionPhotoOutputSize {
    static let maximumBytes = 1_073_741_824

    static func checkedTotal(_ lengths: [Int]) throws -> Int {
        var total = 0
        for length in lengths {
            guard length >= 0, length <= maximumBytes - total else {
                throw MotionPhotoWriterError.fileTooLarge
            }
            total += length
        }
        return total
    }
}

private struct MotionWriterBytes {
    let data: Data
    init(_ data: Data) { self.data = data }
    var count: Int { data.count }
    subscript(_ index: Int) -> UInt8 { data[data.startIndex + index] }
    func fits(_ index: Int, _ length: Int) -> Bool {
        index >= 0 && index <= count && length >= 0 && length <= count - index
    }
    func slice(_ range: Range<Int>) -> Data {
        data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)]
    }
    func matches(_ string: String, at start: Int, before end: Int) -> Bool {
        let bytes = Array(string.utf8)
        guard start >= 0, start <= end, end <= count, bytes.count <= end - start else { return false }
        return bytes.enumerated().allSatisfy { self[start + $0.offset] == $0.element }
    }
    func bigEndian(_ index: Int, bytes: Int) -> UInt64? {
        guard bytes <= 8, fits(index, bytes) else { return nil }
        return (0..<bytes).reduce(UInt64(0)) { ($0 << 8) | UInt64(self[index + $1]) }
    }
}

private struct MotionWriterJPEG {
    static let xmpHeader = "http://ns.adobe.com/xap/1.0/\0"
    static let extendedXMPHeader = "http://ns.adobe.com/xmp/extension/\0"
    let removedXMP: [Range<Int>]
    let insertAt: Int

    static func inspect(_ bytes: MotionWriterBytes) throws -> MotionWriterJPEG {
        guard bytes.bigEndian(0, bytes: 2) == 0xffd8 else { throw MotionPhotoWriterError.invalidJPEG }
        var cursor = 2
        var entropy = false
        var sawFrame = false
        var sawScan = false
        var insertion: Int?
        var removed: [Range<Int>] = []
        var segmentCount = 0
        while cursor < bytes.count {
            if bytes[cursor] != 0xff {
                guard entropy else { throw MotionPhotoWriterError.invalidJPEG }
                cursor += 1
                continue
            }
            let markerStart = cursor
            while cursor < bytes.count && bytes[cursor] == 0xff { cursor += 1 }
            guard cursor < bytes.count else { throw MotionPhotoWriterError.invalidJPEG }
            let marker = bytes[cursor]
            cursor += 1
            if marker == 0x00, entropy { continue }
            if (0xd0...0xd7).contains(marker), entropy { continue }
            if marker == 0xd9 {
                guard sawFrame, sawScan else { throw MotionPhotoWriterError.invalidJPEG }
                guard cursor == bytes.count else { throw MotionPhotoWriterError.jpegContainsTrailingData }
                return MotionWriterJPEG(removedXMP: removed, insertAt: insertion ?? markerStart)
            }
            guard marker != 0, marker != 0xd8, !(0xd0...0xd7).contains(marker) else {
                throw MotionPhotoWriterError.invalidJPEG
            }
            if marker == 0x01 { continue } // JPEG TEM marker has no length field.
            guard let rawLength = bytes.bigEndian(cursor, bytes: 2), rawLength >= 2 else {
                throw MotionPhotoWriterError.invalidJPEG
            }
            let length = Int(rawLength)
            guard bytes.fits(cursor, length) else { throw MotionPhotoWriterError.invalidJPEG }
            let payload = cursor + 2
            let end = cursor + length
            segmentCount += 1
            guard segmentCount <= 100_000 else { throw MotionPhotoWriterError.invalidJPEG }

            let isAPP = (0xe0...0xef).contains(marker)
            if insertion == nil, !isAPP, marker != 0xfe { insertion = markerStart }
            if marker == 0xe1,
               bytes.matches(xmpHeader, at: payload, before: end)
                || bytes.matches(extendedXMPHeader, at: payload, before: end) {
                removed.append(markerStart..<end)
            }
            let isFrame = (0xc0...0xcf).contains(marker)
                && marker != 0xc4 && marker != 0xc8 && marker != 0xcc
            if isFrame {
                // SOF: precision, height, width, component count, then 3 bytes/component.
                guard length >= 11, let height = bytes.bigEndian(payload + 1, bytes: 2), height > 0,
                      let width = bytes.bigEndian(payload + 3, bytes: 2), width > 0 else {
                    throw MotionPhotoWriterError.invalidJPEG
                }
                let components = Int(bytes[payload + 5])
                guard components > 0, length == 8 + components * 3 else {
                    throw MotionPhotoWriterError.invalidJPEG
                }
                sawFrame = true
            }
            if marker == 0xda {
                guard sawFrame, length >= 6 else { throw MotionPhotoWriterError.invalidJPEG }
                let components = Int(bytes[payload])
                guard components > 0, length == 6 + components * 2 else {
                    throw MotionPhotoWriterError.invalidJPEG
                }
                sawScan = true
                entropy = true
            } else if marker != 0xdc {
                entropy = false // DNL may appear within entropy data.
            }
            cursor = end
        }
        throw MotionPhotoWriterError.invalidJPEG
    }
}

private enum MotionWriterMovie {
    private static let brands: Set<String> = ["isom", "iso2", "iso3", "iso4", "iso5", "iso6", "iso7", "iso8", "iso9",
        "mp41", "mp42", "avc1", "hvc1", "hev1", "3gp4", "3gp5", "3gp6", "3gp7", "M4V ", "MSNV", "dash"]

    static func isComplete(_ bytes: MotionWriterBytes) -> Bool {
        var cursor = 0
        var count = 0
        var sawMovie = false
        var sawMedia = false
        while cursor < bytes.count, count < 100_000 {
            guard bytes.fits(cursor, 8), let size32 = bytes.bigEndian(cursor, bytes: 4),
                  let type = String(data: bytes.slice((cursor + 4)..<(cursor + 8)), encoding: .ascii),
                  type.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else { return false }
            let header = size32 == 1 ? 16 : 8
            let length: Int
            if size32 == 0 { length = bytes.count - cursor }
            else if size32 == 1 {
                guard let size64 = bytes.bigEndian(cursor + 8, bytes: 8), let value = Int(exactly: size64) else { return false }
                length = value
            } else { length = Int(size32) }
            guard length >= header, bytes.fits(cursor, length) else { return false }
            let payload = cursor + header
            let end = cursor + length
            if count == 0 {
                guard type == "ftyp", end - payload >= 8, end - payload <= 4096,
                      (end - payload) % 4 == 0 else { return false }
                var compatible = false
                for offset in stride(from: payload, to: end, by: 4) where offset != payload + 4 {
                    if let brand = String(data: bytes.slice(offset..<(offset + 4)), encoding: .ascii), brands.contains(brand) {
                        compatible = true
                    }
                }
                guard compatible else { return false }
            } else if type == "ftyp" { return false }
            if type == "moov" {
                guard !sawMovie, end > payload else { return false }
                sawMovie = true
            }
            if type == "mdat", end > payload { sawMedia = true }
            cursor = end
            count += 1
        }
        return cursor == bytes.count && sawMovie && sawMedia
    }
}

private struct MotionWriterTrailer {
    let beforeVideo: Data
    let afterVideo: Data

    static func make(videoCount: Int, format: MotionPhotoEncoding) throws -> MotionWriterTrailer {
        guard format == .samsung else { return MotionWriterTrailer(beforeVideo: Data(), afterVideo: Data()) }
        // Direct video payload for JPEG. "mpv2" is only a pointer representation
        // in other Samsung layouts and must never replace these MP4 bytes.
        let dataName = Data("MotionPhoto_Data".utf8)
        let versionName = Data("MotionPhoto_Version".utf8)
        let dataCode = Data([0, 0, 0x30, 0x0a])
        let versionCode = Data([0, 0, 0x31, 0x0a])
        let prefix = dataCode + littleEndian(dataName.count) + dataName
        let version = versionCode + littleEndian(versionName.count) + versionName + Data("mpv3".utf8)
        let dataLength = try MotionPhotoOutputSize.checkedTotal([prefix.count, videoCount])
        let dataOffset = try MotionPhotoOutputSize.checkedTotal([dataLength, version.count])
        var directory = Data("SEFH".utf8) + littleEndian(107) + littleEndian(2)
        directory += dataCode + littleEndian(dataOffset) + littleEndian(dataLength)
        directory += versionCode + littleEndian(version.count) + littleEndian(version.count)
        let directoryLength = directory.count
        directory += littleEndian(directoryLength) + Data("SEFT".utf8)
        return MotionWriterTrailer(beforeVideo: prefix, afterVideo: version + directory)
    }

    private static func littleEndian(_ value: Int) -> Data {
        // All values are bounded by the 1 GiB size gate or are small constants.
        let number = UInt32(value)
        return Data([UInt8(truncatingIfNeeded: number), UInt8(truncatingIfNeeded: number >> 8),
                     UInt8(truncatingIfNeeded: number >> 16), UInt8(truncatingIfNeeded: number >> 24)])
    }
}
