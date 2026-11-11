import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum MotionPhotoFormat: String, Sendable {
    case googleMotionPhoto = "Google Motion Photo"
    case googleMicroVideo = "Google Microvideo"
    case samsungMotionPhoto = "Samsung Motion Photo"
    case heifMotionPhoto = "HEIF Motion Photo"
    case recoveredMotionPhoto = "Recovered Motion Photo"
}

/// Byte offsets are relative to the beginning of the supplied Data, even for a Data slice.
public struct MotionPhotoPayload: Sendable {
    public let videoRange: Range<Int>
    public let presentationTimeMicroseconds: Int64?
    public let format: MotionPhotoFormat
    public let warnings: [String]

    public init(videoRange: Range<Int>, presentationTimeMicroseconds: Int64?,
                format: MotionPhotoFormat, warnings: [String] = []) {
        self.videoRange = videoRange
        self.presentationTimeMicroseconds = presentationTimeMicroseconds
        self.format = format
        self.warnings = warnings
    }
}

public enum MotionPhotoError: LocalizedError, Sendable {
    case unsupportedImage, malformedImage, noEmbeddedVideo, motionDisabled, ambiguousVideo

    public var errorDescription: String? {
        switch self {
        case .unsupportedImage:
            return "Choose an original JPEG, HEIC, or AVIF Motion Photo."
        case .malformedImage:
            return "The photo is incomplete or has an invalid file structure."
        case .noEmbeddedVideo:
            return "No complete motion video was found. Export or copy the original Motion Photo; messaging apps and edited copies often remove its video."
        case .motionDisabled:
            return "This file’s metadata marks motion as disabled. Choose the original Motion Photo."
        case .ambiguousVideo:
            return "The file contains conflicting motion videos, so it cannot be converted reliably."
        }
    }
}

/// Reads containers, not media codecs. AVFoundation must validate and decode the
/// returned movie before use. The parser never modifies the supplied image.
public enum MotionPhotoParser {
    public static func parse(data: Data) throws -> MotionPhotoPayload {
        let bytes = Bytes(data)
        let image = try ImageContainer.read(bytes)
        let metadata = XMP.read(image.packets)
        let usesModernMetadata = metadata.camera["MotionPhoto"] != nil || !metadata.directories.isEmpty

        // The modern flag takes precedence over obsolete MicroVideo fields.
        if let flag = metadata.camera["MotionPhoto"], Int64(flag) != 1 {
            throw MotionPhotoError.motionDisabled
        }
        if !usesModernMetadata,
           let flag = metadata.camera["MicroVideo"], Int64(flag) != 1 {
            throw MotionPhotoError.motionDisabled
        }
        let timestampKey = usesModernMetadata
            ? "MotionPhotoPresentationTimestampUs" : "MicroVideoPresentationTimestampUs"
        let timestamp = (metadata.camera[timestampKey]
            ?? metadata.camera["MotionPhotoPresentationTimestampUs"])
            .flatMap(Int64.init).flatMap { $0 >= 0 ? $0 : nil }

        func finish(_ range: Range<Int>, _ format: MotionPhotoFormat,
                    _ warnings: [String] = []) -> MotionPhotoPayload {
            MotionPhotoPayload(videoRange: range, presentationTimeMicroseconds: timestamp,
                               format: format, warnings: warnings)
        }

        func allowed(_ range: Range<Int>, samsung: Bool = false) -> Bool {
            guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= bytes.count else { return false }
            if image.isJPEG { return range.lowerBound >= image.primaryEnd }
            let containers = samsung ? image.motionBoxes + image.samsungBoxes : image.motionBoxes
            return containers.contains {
                range.lowerBound >= $0.payload.lowerBound && range.upperBound <= $0.payload.upperBound
            }
        }

        // Samsung's indexed range is more precise than its XMP Length, which on
        // some versions includes the Samsung metadata trailer after the movie.
        var trailerEnds = [bytes.count]
        trailerEnds += image.motionBoxes.map { $0.end }
        trailerEnds += image.samsungBoxes.map { $0.end }
        let trailers = Array(Set(trailerEnds)).compactMap {
            SamsungTrailer.read(bytes, end: $0, minimumStart: image.isJPEG ? image.primaryEnd : 0)
        }
        var samsungRanges: [Range<Int>] = []
        for trailer in trailers {
            for entry in trailer.motionEntries {
                let range: Range<Int>
                if entry.count == 12, bytes.matches("mpv2", at: entry.lowerBound),
                   let start = bytes.u32BE(entry.lowerBound + 4),
                   let length = bytes.u32BE(entry.lowerBound + 8),
                   start <= bytes.count, length <= bytes.count - start {
                    range = start..<(start + length)
                } else {
                    range = entry
                }
                if allowed(range, samsung: true), Movie.isComplete(bytes, range: range) { samsungRanges.append(range) }
            }
        }
        if let range = try unique(samsungRanges) { return finish(range, .samsungMotionPhoto) }

        var directoryRanges: [Range<Int>] = []
        var nonstandardDirectory = false
        for items in metadata.directories {
            guard items.count >= 2, items.first?["Semantic"] == "Primary",
                  items.filter({ $0["Semantic"] == "MotionPhoto" }).count == 1 else { continue }
            var end = bytes.count
            var candidate: Range<Int>?
            var valid = true
            for (index, item) in items.enumerated().dropFirst().reversed() {
                guard let rawLength = item["Length"], let length = Int(rawLength),
                      length >= 0, length <= end else { valid = false; break }
                let start = end - length
                if item["Semantic"] == "MotionPhoto",
                   item["Mime"] == "video/mp4" || item["Mime"] == "video/quicktime" {
                    if length > 0 { candidate = start..<end }
                    if index != items.count - 1 { nonstandardDirectory = true }
                }
                end = start
            }
            if let paddingString = items.first?["Padding"] {
                guard let padding = Int(paddingString), padding >= 0,
                      padding <= end else { continue }
                if image.isJPEG && end - padding < image.primaryEnd { continue }
            }
            if valid, let candidate, allowed(candidate), Movie.isComplete(bytes, range: candidate) {
                directoryRanges.append(candidate)
            }
        }
        if let range = try unique(directoryRanges) {
            return finish(range, .googleMotionPhoto, nonstandardDirectory
                ? ["This file uses a nonstandard Motion Photo container order."] : [])
        }

        let boxRanges = image.motionBoxes.map(\.payload).filter {
            Movie.isComplete(bytes, range: $0)
        }
        if let range = try unique(boxRanges) { return finish(range, .heifMotionPhoto) }

        // Google's older format counts from EOF. Ignore this obsolete offset
        // when the modern MotionPhoto property is present (Android specification).
        if !usesModernMetadata,
           let offsetString = metadata.camera["MicroVideoOffset"],
           let offset = Int(offsetString), offset > 0, offset <= bytes.count {
            let range = (bytes.count - offset)..<bytes.count
            if allowed(range), Movie.isComplete(bytes, range: range) {
                return finish(range, .googleMicroVideo)
            }
        }

        // Bounded recovery is only possible outside the actual JPEG image, and
        // requires either an enabled motion flag or a Samsung block signature.
        // Never search EXIF thumbnails or accept a bare "ftyp" string as a movie.
        if image.isJPEG {
            let flagged = metadata.camera["MotionPhoto"] == "1" || metadata.camera["MicroVideo"] == "1"
            let endings = Set([bytes.count] + trailers.map(\.dataStart))
            var recovered: [Range<Int>] = []
            var cursor = image.primaryEnd
            var attempts = 0
            while cursor < bytes.count, attempts < 128,
                  let marker = bytes.find("ftyp", in: cursor..<bytes.count) {
                cursor = marker + 4
                attempts += 1
                let start = marker - 4
                guard start >= image.primaryEnd else { continue }
                let name = "MotionPhoto_Data"
                let header = start - name.utf8.count - 8
                let samsungSignature = header >= image.primaryEnd
                    && bytes.u16LE(header + 2) == 0x0a30
                    && bytes.u32LE(header + 4) == name.utf8.count
                    && bytes.matches(name, at: header + 8)
                guard flagged || samsungSignature else { continue }
                for end in endings where end > start {
                    let range = start..<end
                    if Movie.isComplete(bytes, range: range) { recovered.append(range) }
                }
            }
            if let range = try unique(recovered) {
                return finish(range, .recoveredMotionPhoto,
                    ["The motion video was recovered from its file structure because its location metadata was incomplete."])
            }
        }
        throw MotionPhotoError.noEmbeddedVideo
    }

    private static func unique(_ ranges: [Range<Int>]) throws -> Range<Int>? {
        let unique = Set(ranges)
        guard unique.count <= 1 else { throw MotionPhotoError.ambiguousVideo }
        return unique.first
    }
}

private struct Bytes {
    let data: Data
    init(_ data: Data) { self.data = data }
    var count: Int { data.count }
    subscript(_ index: Int) -> UInt8 { data[data.startIndex + index] }
    func contains(_ start: Int, _ length: Int) -> Bool {
        start >= 0 && start <= count && length >= 0 && length <= count - start
    }
    func part(_ range: Range<Int>) -> Data {
        data.subdata(in: (data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound))
    }
    func u16BE(_ index: Int) -> Int? {
        guard contains(index, 2) else { return nil }
        return Int(self[index]) << 8 | Int(self[index + 1])
    }
    func u16LE(_ index: Int) -> Int? {
        guard contains(index, 2) else { return nil }
        return Int(self[index]) | Int(self[index + 1]) << 8
    }
    func u32BE(_ index: Int) -> Int? {
        guard contains(index, 4) else { return nil }
        return (0..<4).reduce(0) { ($0 << 8) | Int(self[index + $1]) }
    }
    func u32LE(_ index: Int) -> Int? {
        guard contains(index, 4) else { return nil }
        return (0..<4).reduce(0) { $0 | Int(self[index + $1]) << ($1 * 8) }
    }
    func u64BE(_ index: Int) -> Int? {
        guard contains(index, 8) else { return nil }
        let value = (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(self[index + $1]) }
        return Int(exactly: value)
    }
    func matches(_ text: String, at index: Int) -> Bool {
        let pattern = Array(text.utf8)
        return contains(index, pattern.count) && pattern.enumerated().allSatisfy { self[index + $0.offset] == $0.element }
    }
    func find(_ text: String, in range: Range<Int>) -> Int? {
        guard !range.isEmpty, contains(range.lowerBound, range.count),
              let found = data.range(of: Data(text.utf8), options: [],
                  in: (data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)) else { return nil }
        return found.lowerBound - data.startIndex
    }
    func string(_ range: Range<Int>) -> String? { String(data: part(range), encoding: .utf8) }
}

private struct Box {
    let start: Int
    let end: Int
    let payload: Range<Int>
    let type: String
    let extendsToEnd: Bool

    static func read(_ bytes: Bytes, at start: Int, limit: Int) -> Box? {
        guard start >= 0, start <= limit, limit <= bytes.count, limit - start >= 8,
              let size32 = bytes.u32BE(start), let type = bytes.string((start + 4)..<(start + 8)),
              type.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else { return nil }
        let header = size32 == 1 ? 16 : 8
        let length: Int
        if size32 == 0 { length = limit - start }
        else if size32 == 1 {
            guard limit - start >= 16, let large = bytes.u64BE(start + 8) else { return nil }
            length = large
        } else { length = size32 }
        guard length >= header, length <= limit - start else { return nil }
        return Box(start: start, end: start + length, payload: (start + header)..<(start + length),
                   type: type, extendsToEnd: size32 == 0)
    }
}

private enum Movie {
    static let brands: Set<String> = ["isom", "iso2", "iso3", "iso4", "iso5", "iso6", "iso7", "iso8", "iso9",
        "mp41", "mp42", "avc1", "hvc1", "hev1", "qt  ", "3gp4", "3gp5", "3gp6", "3gp7", "3g2a", "M4V ", "MSNV", "dash"]

    static func fileBrands(_ bytes: Bytes, box: Box) -> Set<String> {
        guard box.type == "ftyp", box.payload.count >= 8, box.payload.count % 4 == 0 else { return [] }
        var result: Set<String> = []
        // An ftyp is small; reject malicious giant headers before building a set.
        guard box.payload.count <= 4096 else { return [] }
        for index in stride(from: box.payload.lowerBound, to: box.payload.upperBound, by: 4)
            where index != box.payload.lowerBound + 4 {
            if let brand = bytes.string(index..<(index + 4)) { result.insert(brand) }
        }
        return result
    }

    static func isComplete(_ bytes: Bytes, range: Range<Int>) -> Bool {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count,
              let first = Box.read(bytes, at: range.lowerBound, limit: range.upperBound),
              !fileBrands(bytes, box: first).isDisjoint(with: brands) else { return false }
        var cursor = first.end
        var sawMovie = false
        var sawMedia = false
        var count = 0
        while cursor < range.upperBound, count < 100_000 {
            guard let box = Box.read(bytes, at: cursor, limit: range.upperBound), box.type != "ftyp" else { return false }
            if box.type == "moov" { sawMovie = !box.payload.isEmpty }
            if box.type == "mdat" { sawMedia = !box.payload.isEmpty }
            cursor = box.end
            count += 1
        }
        return cursor == range.upperBound && sawMovie && sawMedia
    }
}

private struct ImageContainer {
    let isJPEG: Bool
    let primaryEnd: Int
    let packets: [Data]
    let motionBoxes: [Box]
    let samsungBoxes: [Box]

    static func read(_ bytes: Bytes) throws -> ImageContainer {
        if bytes.u16BE(0) == 0xffd8 { return try jpeg(bytes) }
        guard let first = Box.read(bytes, at: 0, limit: bytes.count), first.type == "ftyp" else {
            throw MotionPhotoError.unsupportedImage
        }
        let imageBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1", "avif", "avis"]
        guard !Movie.fileBrands(bytes, box: first).isDisjoint(with: imageBrands) else {
            throw MotionPhotoError.unsupportedImage
        }
        var cursor = 0
        var boxes: [Box] = []
        while cursor < bytes.count, boxes.count < 100_000 {
            guard let box = Box.read(bytes, at: cursor, limit: bytes.count),
                  !(box.type == "mpvd" && box.extendsToEnd) else { throw MotionPhotoError.malformedImage }
            boxes.append(box)
            cursor = box.end
        }
        guard cursor == bytes.count else { throw MotionPhotoError.malformedImage }
        let motion = boxes.filter { $0.type == "mpvd" }
        let end = boxes.first(where: { $0.type == "mpvd" || $0.type == "sefd" })?.start ?? bytes.count
        let packets = XMP.extractPackets(bytes, before: end)
        return ImageContainer(isJPEG: false, primaryEnd: end, packets: packets,
                              motionBoxes: motion, samsungBoxes: boxes.filter { $0.type == "sefd" })
    }

    private static func jpeg(_ bytes: Bytes) throws -> ImageContainer {
        var cursor = 2
        var inScan = false
        var packets: [Data] = []
        var extensions: [String: [(length: Int, offset: Int, data: Data)]] = [:]
        var extensionChunkCount = 0
        let xmpHeader = "http://ns.adobe.com/xap/1.0/\0"
        let extensionHeader = "http://ns.adobe.com/xmp/extension/\0"
        var metadataBytes = 0
        while cursor < bytes.count {
            if bytes[cursor] != 0xff {
                guard inScan else { throw MotionPhotoError.malformedImage }
                cursor += 1
                continue
            }
            while cursor < bytes.count && bytes[cursor] == 0xff { cursor += 1 }
            guard cursor < bytes.count else { break }
            let marker = bytes[cursor]
            cursor += 1
            if marker == 0 && inScan { continue }
            if marker == 0xd9 {
                for chunks in extensions.values {
                    let sorted = chunks.sorted { $0.offset < $1.offset }
                    guard let total = sorted.first?.length, total <= XMP.maximumPacket else { continue }
                    var extended = Data()
                    for chunk in sorted {
                        guard chunk.length == total, chunk.offset == extended.count,
                              chunk.data.count <= total - extended.count else { break }
                        extended.append(chunk.data)
                    }
                    if extended.count == total { packets.append(extended) }
                }
                return ImageContainer(isJPEG: true, primaryEnd: cursor, packets: packets,
                                      motionBoxes: [], samsungBoxes: [])
            }
            if marker == 0x01 || (0xd0...0xd7).contains(marker) { continue }
            guard marker != 0xd8, marker != 0,
                  let length = bytes.u16BE(cursor), length >= 2, bytes.contains(cursor, length) else {
                throw MotionPhotoError.malformedImage
            }
            let start = cursor + 2
            let end = cursor + length
            if marker == 0xe1, packets.count < 64, metadataBytes < XMP.maximumPacket * 4 {
                if bytes.matches(xmpHeader, at: start), end - start >= xmpHeader.utf8.count {
                    let packet = bytes.part((start + xmpHeader.utf8.count)..<end)
                    packets.append(packet)
                    metadataBytes += packet.count
                } else if extensionChunkCount < 512, bytes.matches(extensionHeader, at: start) {
                    let headerEnd = start + extensionHeader.utf8.count
                    if end - headerEnd >= 40,
                       let identifier = bytes.string(headerEnd..<(headerEnd + 32)),
                       extensions[identifier] != nil || extensions.count < 64,
                       let length = bytes.u32BE(headerEnd + 32), length > 0, length <= XMP.maximumPacket,
                       let offset = bytes.u32BE(headerEnd + 36), offset <= length,
                       end - (headerEnd + 40) > 0, end - (headerEnd + 40) <= length - offset {
                        let chunk = bytes.part((headerEnd + 40)..<end)
                        extensions[identifier, default: []].append((length, offset, chunk))
                        extensionChunkCount += 1
                        metadataBytes += chunk.count
                    }
                }
            }
            cursor = end
            if marker == 0xda { inScan = true }
        }
        throw MotionPhotoError.malformedImage
    }
}

private struct SamsungTrailer {
    let dataStart: Int
    let motionEntries: [Range<Int>]

    static func read(_ bytes: Bytes, end: Int, minimumStart: Int) -> SamsungTrailer? {
        guard end >= 20, end <= bytes.count, bytes.matches("SEFT", at: end - 4),
              let length = bytes.u32LE(end - 8), length >= 12, length <= end - 8 else { return nil }
        let directory = end - 8 - length
        guard directory >= minimumStart, bytes.matches("SEFH", at: directory),
              let count = bytes.u32LE(directory + 8), count <= 4096,
              count <= (length - 12) / 12 else { return nil }
        var ranges: [Range<Int>] = []
        var motion: [Range<Int>] = []
        for index in 0..<count {
            let entry = directory + 12 + index * 12
            guard let offset = bytes.u32LE(entry + 4), offset <= directory,
                  let size = bytes.u32LE(entry + 8), size >= 8, size <= offset else { return nil }
            let start = directory - offset
            guard start >= minimumStart,
                  bytes.u32LE(start) == bytes.u32LE(entry),
                  let nameLength = bytes.u32LE(start + 4), nameLength <= 1024, nameLength <= size - 8 else { return nil }
            let payload = (start + 8 + nameLength)..<(start + size)
            ranges.append(start..<(start + size))
            if bytes.u16LE(entry + 2) == 0x0a30,
               bytes.string((start + 8)..<(start + 8 + nameLength)) == "MotionPhoto_Data" {
                motion.append(payload)
            }
        }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for index in sorted.indices.dropFirst() where sorted[index - 1].upperBound > sorted[index].lowerBound { return nil }
        return SamsungTrailer(dataStart: sorted.first?.lowerBound ?? directory, motionEntries: motion)
    }
}

private struct XMP {
    static let maximumPacket = 2 * 1024 * 1024
    var camera: [String: String] = [:]
    var directories: [[[String: String]]] = []

    static func read(_ packets: [Data]) -> XMP {
        var result = XMP()
        for packet in packets.prefix(64) where packet.count <= maximumPacket {
            // Refuse DTDs/internal entity definitions as well as external entities.
            guard !packet.contains(0), String(data: packet, encoding: .utf8) != nil,
                  packet.range(of: Data("<!DOCTYPE".utf8)) == nil,
                  packet.range(of: Data("<!ENTITY".utf8)) == nil else { continue }
            let delegate = XMPDelegate()
            let parser = XMLParser(data: packet)
            parser.shouldProcessNamespaces = true
            parser.shouldReportNamespacePrefixes = true
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard parser.parse() else { continue }
            for (key, value) in delegate.camera {
                // A disabling flag anywhere in valid XMP is authoritative.
                if (key == "MotionPhoto" || key == "MicroVideo"),
                   let existing = result.camera[key], Int64(existing) != 1 { continue }
                result.camera[key] = value
            }
            result.directories += delegate.directories
        }
        return result
    }

    // HEIF stores XMP as an item, frequently near the end of its image mdat.
    // Look only in the image portion, with fixed search/packet limits. This also
    // accommodates arbitrary namespace prefixes on the xmpmeta/RDF root.
    static func extractPackets(_ bytes: Bytes, before end: Int) -> [Data] {
        let scanLimit = 64 * 1024 * 1024
        var regions = [0..<min(end, scanLimit)]
        if end > scanLimit { regions.append(max(scanLimit, end - 8 * 1024 * 1024)..<end) }
        var found: [Data] = []
        var starts: Set<Int> = []
        for token in ["xmpmeta", "RDF"] {
            for region in regions {
                var cursor = region.lowerBound
                var attempts = 0
                while cursor < region.upperBound, attempts < 256, found.count < 64,
                      let location = bytes.find(token, in: cursor..<region.upperBound) {
                    cursor = location + token.utf8.count
                    attempts += 1
                    var opening = location
                    while opening > region.lowerBound, location - opening < 128, bytes[opening] != 0x3c { opening -= 1 }
                    guard bytes[opening] == 0x3c, opening + 1 < location + token.utf8.count,
                          let name = bytes.string((opening + 1)..<(location + token.utf8.count)),
                          name.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                              || ($0 >= 48 && $0 <= 57) || $0 == 58 || $0 == 95 || $0 == 45 || $0 == 46 }),
                          !starts.contains(opening) else { continue }
                    let searchEnd = opening + min(maximumPacket, end - opening)
                    let close = "</\(name)>"
                    guard let closing = bytes.find(close, in: cursor..<searchEnd) else { continue }
                    let packetEnd = closing + close.utf8.count
                    found.append(bytes.part(opening..<packetEnd))
                    starts.insert(opening)
                    cursor = packetEnd
                }
            }
            if !found.isEmpty { break }
        }
        return found
    }
}

private final class XMPDelegate: NSObject, XMLParserDelegate {
    private let cameraKeys: Set<String> = ["MotionPhoto", "MicroVideo", "MicroVideoOffset",
        "MotionPhotoPresentationTimestampUs", "MicroVideoPresentationTimestampUs"]
    private let itemKeys: Set<String> = ["Semantic", "Mime", "Length", "Padding"]
    private let cameraURI = "http://ns.google.com/photos/1.0/camera/"
    private let containerURI = "http://ns.google.com/photos/1.0/container/"
    private let itemURI = "http://ns.google.com/photos/1.0/container/item/"
    private var prefixes: [String: [String]] = [:]
    private var depth = 0
    private var directoryDepth: Int?
    private var itemDepth: Int?
    private var items: [[String: String]] = []
    private var textStack: [String] = []
    private var captureTextStack: [Bool] = []
    var camera: [String: String] = [:]
    var directories: [[[String: String]]] = []

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        prefixes[prefix, default: []].append(namespaceURI)
    }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { _ = prefixes[prefix]?.popLast() }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        depth += 1
        guard depth <= 64, textStack.count < 64 else { parser.abortParsing(); return }
        textStack.append("")
        captureTextStack.append((namespaceURI == cameraURI && cameraKeys.contains(elementName))
            || (namespaceURI == itemURI && itemKeys.contains(elementName)))
        if namespaceURI == containerURI && elementName == "Directory" {
            guard directoryDepth == nil, directories.count < 64 else { parser.abortParsing(); return }
            directoryDepth = depth
            items = []
        }
        var itemAttributes: [String: String] = [:]
        for (qualified, value) in attributes {
            let parts = qualified.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let uri = prefixes[parts[0]]?.last else { continue }
            if uri == cameraURI { setCamera(parts[1], value) }
            if uri == itemURI, itemKeys.contains(parts[1]) { itemAttributes[parts[1]] = value }
        }
        if directoryDepth != nil, itemDepth == nil,
           (namespaceURI == containerURI && elementName == "Item" || !itemAttributes.isEmpty) {
            guard items.count < 1024 else { parser.abortParsing(); return }
            items.append(itemAttributes)
            itemDepth = depth
        } else if itemDepth != nil, !items.isEmpty {
            items[items.count - 1].merge(itemAttributes) { _, new in new }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Depth maps and other unrelated XMP properties can contain large base64
        // strings. Ignore their text rather than discarding valid motion fields.
        guard !textStack.isEmpty, captureTextStack.last == true else { return }
        guard textStack[textStack.count - 1].utf8.count + string.utf8.count <= 4096 else { parser.abortParsing(); return }
        textStack[textStack.count - 1] += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard captureTextStack.last == true, let text = String(data: CDATABlock, encoding: .utf8) else { return }
        self.parser(parser, foundCharacters: text)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let text = textStack.popLast()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _ = captureTextStack.popLast()
        if namespaceURI == cameraURI { setCamera(elementName, text) }
        if namespaceURI == itemURI, itemKeys.contains(elementName), itemDepth != nil, !items.isEmpty {
            items[items.count - 1][elementName] = text
        }
        if itemDepth == depth { itemDepth = nil }
        if directoryDepth == depth { directories.append(items); items = []; directoryDepth = nil }
        depth -= 1
    }

    private func setCamera(_ key: String, _ value: String) {
        guard cameraKeys.contains(key) else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if (key == "MotionPhoto" || key == "MicroVideo"), let previous = camera[key], Int64(previous) != 1 { return }
        camera[key] = trimmed
    }
}
