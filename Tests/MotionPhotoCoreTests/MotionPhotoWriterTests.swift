import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
@testable import MotionPhotoCore

final class MotionPhotoWriterTests: XCTestCase {
    func testGoogleWritesModernDirectoryAndMovieAtEOF() throws {
        let jpeg = WriterFixture.jpeg()
        let video = WriterFixture.movie()
        let output = try MotionPhotoWriter.make(jpeg: jpeg, video: video,
            presentationTimeMicroseconds: 1_250_000, format: .google)
        let xmp = try WriterFixture.readOutputXMP(output)
        XCTAssertEqual(xmp.camera["MotionPhoto"], "1")
        XCTAssertEqual(xmp.camera["MotionPhotoVersion"], "1")
        XCTAssertEqual(xmp.camera["MotionPhotoPresentationTimestampUs"], "1250000")
        XCTAssertNil(xmp.camera["MicroVideoOffset"])
        XCTAssertEqual(xmp.items.count, 2)
        XCTAssertEqual(xmp.items[0], ["Mime": "image/jpeg", "Semantic": "Primary", "Length": "0", "Padding": "0"])
        XCTAssertEqual(xmp.items[1], ["Mime": "video/mp4", "Semantic": "MotionPhoto", "Length": "\(video.count)"])
        XCTAssertEqual(Data(output.suffix(video.count)), video)
        let movieStart = output.count - video.count
        XCTAssertEqual(Data(output[(movieStart - 2)..<movieStart]), Data([0xff, 0xd9]))
        XCTAssertEqual(output.count, jpeg.count + video.count + xmp.segmentRange.count)
    }

    func testSamsungSEFHeaderAndEntriesHaveIndependentExpectedOffsets() throws {
        let jpeg = WriterFixture.jpeg()
        let video = WriterFixture.movie()
        let output = try MotionPhotoWriter.make(jpeg: jpeg, video: video,
            presentationTimeMicroseconds: 800_000, format: .samsung)
        let xmp = try WriterFixture.readOutputXMP(output)
        let imageEnd = jpeg.count + xmp.segmentRange.count
        let dataBlockStart = imageEnd
        let movieStart = imageEnd + 24
        let versionStart = movieStart + video.count
        let directoryStart = versionStart + 31
        XCTAssertEqual(output.count, directoryStart + 44)

        // SEF block ID: two reserved bytes followed by the little-endian tag ID.
        XCTAssertEqual(Data(output[dataBlockStart..<(dataBlockStart + 4)]), Data([0, 0, 0x30, 0x0a]))
        XCTAssertEqual(WriterFixture.le32(output, dataBlockStart + 4), 16)
        XCTAssertEqual(String(data: output[(dataBlockStart + 8)..<movieStart], encoding: .ascii), "MotionPhoto_Data")
        XCTAssertEqual(Data(output[movieStart..<versionStart]), video)

        XCTAssertEqual(Data(output[versionStart..<(versionStart + 4)]), Data([0, 0, 0x31, 0x0a]))
        XCTAssertEqual(WriterFixture.le32(output, versionStart + 4), 19)
        XCTAssertEqual(String(data: output[(versionStart + 8)..<(versionStart + 27)], encoding: .ascii), "MotionPhoto_Version")
        XCTAssertEqual(String(data: output[(versionStart + 27)..<directoryStart], encoding: .ascii), "mpv3")

        XCTAssertEqual(String(data: output[directoryStart..<(directoryStart + 4)], encoding: .ascii), "SEFH")
        XCTAssertEqual(WriterFixture.le32(output, directoryStart + 4), 107)
        XCTAssertEqual(WriterFixture.le32(output, directoryStart + 8), 2)
        XCTAssertEqual(WriterFixture.le32(output, directoryStart + 16), UInt32(video.count + 55))
        XCTAssertEqual(WriterFixture.le32(output, directoryStart + 20), UInt32(video.count + 24))
        XCTAssertEqual(WriterFixture.le32(output, directoryStart + 28), 31)
        XCTAssertEqual(WriterFixture.le32(output, directoryStart + 32), 31)
        XCTAssertEqual(WriterFixture.le32(output, output.count - 8), 36)
        XCTAssertEqual(Data(output.suffix(4)), Data("SEFT".utf8))
        XCTAssertEqual(xmp.items[0]["Padding"], "24")
        XCTAssertEqual(xmp.items[1]["Length"], "\(video.count + 75)")
        let encodedLength = try XCTUnwrap(xmp.items[1]["Length"])
        let resourceLength = try XCTUnwrap(Int(encodedLength))
        XCTAssertEqual(output.count - resourceLength, movieStart)
        XCTAssertEqual(xmp.camera["MotionPhotoPresentationTimestampUs"], "800000")
    }

    func testBothFormatsRoundTripThroughParserWithExactVideoBytes() throws {
        let jpeg = WriterFixture.jpeg()
        let video = WriterFixture.movie()
        for format in [MotionPhotoEncoding.google, .samsung] {
            let output = try MotionPhotoWriter.make(jpeg: jpeg, video: video,
                presentationTimeMicroseconds: 250_000, format: format)
            let payload = try MotionPhotoParser.parse(data: output)
            XCTAssertEqual(payload.format, format == .google ? .googleMotionPhoto : .samsungMotionPhoto)
            XCTAssertEqual(output.subdata(in: payload.videoRange), video)
            XCTAssertEqual(payload.presentationTimeMicroseconds, 250_000)
            XCTAssertTrue(payload.warnings.isEmpty)
        }
    }

    func testTimestampZeroSurvivesBothFormats() throws {
        for format in [MotionPhotoEncoding.google, .samsung] {
            let output = try MotionPhotoWriter.make(jpeg: WriterFixture.jpeg(), video: WriterFixture.movie(),
                presentationTimeMicroseconds: 0, format: format)
            XCTAssertEqual(try MotionPhotoParser.parse(data: output).presentationTimeMicroseconds, 0)
        }
    }

    func testUnspecifiedAndMinusOneTimestampHaveUnspecifiedMeaning() throws {
        for timestamp in [nil, Int64(-1)] {
            for format in [MotionPhotoEncoding.google, .samsung] {
                let output = try MotionPhotoWriter.make(jpeg: WriterFixture.jpeg(), video: WriterFixture.movie(),
                    presentationTimeMicroseconds: timestamp, format: format)
                XCTAssertNil(try MotionPhotoParser.parse(data: output).presentationTimeMicroseconds)
                XCTAssertEqual(try WriterFixture.readOutputXMP(output).camera["MotionPhotoPresentationTimestampUs"], "-1")
            }
        }
    }

    func testInvalidNegativeTimestampIsRejected() {
        for timestamp in [Int64(-2), Int64.min] {
            XCTAssertThrowsError(try MotionPhotoWriter.make(jpeg: WriterFixture.jpeg(), video: WriterFixture.movie(),
                presentationTimeMicroseconds: timestamp, format: .google)) {
                XCTAssertEqual($0 as? MotionPhotoWriterError, .invalidTimestamp)
            }
        }
    }

    func testMaximumTimestampHasSafeNumericXMLRepresentation() throws {
        let output = try MotionPhotoWriter.make(jpeg: WriterFixture.jpeg(), video: WriterFixture.movie(),
            presentationTimeMicroseconds: Int64.max, format: .google)
        XCTAssertEqual(try WriterFixture.readOutputXMP(output).camera["MotionPhotoPresentationTimestampUs"], "9223372036854775807")
        XCTAssertEqual(try MotionPhotoParser.parse(data: output).presentationTimeMicroseconds, Int64.max)
    }

    func testEXIFICCAndCompressedImageBytesArePreserved() throws {
        let exif = WriterFixture.segment(0xe1, Data("Exif\0\0original-camera-date-location".utf8))
        let icc = WriterFixture.segment(0xe2, Data("ICC_PROFILE\0\u{1}\u{1}original-profile".utf8))
        let jpeg = WriterFixture.jpeg(extra: exif + icc)
        let output = try MotionPhotoWriter.make(jpeg: jpeg, video: WriterFixture.movie(),
            presentationTimeMicroseconds: 0, format: .google)
        let packet = try WriterFixture.readOutputXMP(output)
        var restored = Data(output.prefix(jpeg.count + packet.segmentRange.count))
        restored.removeSubrange(packet.segmentRange)
        XCTAssertEqual(restored, jpeg)
        XCTAssertNotNil(output.range(of: exif))
        XCTAssertNotNil(output.range(of: icc))
        // APP0/JFIF remains the first segment, before the new XMP.
        XCTAssertEqual(Array(output.prefix(4)), [0xff, 0xd8, 0xff, 0xe0])
    }

    func testOldStandardAndExtendedXMPAreReplaced() throws {
        let old = WriterFixture.segment(0xe1, Data("http://ns.adobe.com/xap/1.0/\0".utf8)
            + Data("<old Camera:MotionPhoto=\"0\"/>".utf8))
        let extensionPacket = WriterFixture.segment(0xe1, Data("http://ns.adobe.com/xmp/extension/\0obsolete-extended-data".utf8))
        let extra = WriterFixture.segment(0xe1, Data("Exif\0\0preserve-this".utf8))
        let jpeg = WriterFixture.jpeg(extra: old + extra + extensionPacket)
        let output = try MotionPhotoWriter.make(jpeg: jpeg, video: WriterFixture.movie(),
            presentationTimeMicroseconds: 7, format: .google)
        XCTAssertNil(output.range(of: Data("<old".utf8)))
        XCTAssertNil(output.range(of: Data("obsolete-extended-data".utf8)))
        XCTAssertNotNil(output.range(of: extra))
        XCTAssertEqual(try MotionPhotoParser.parse(data: output).presentationTimeMicroseconds, 7)
        let packet = try WriterFixture.readOutputXMP(output)
        var restored = Data(output.prefix(jpeg.count - old.count - extensionPacket.count + packet.segmentRange.count))
        restored.removeSubrange(packet.segmentRange)
        XCTAssertEqual(restored, WriterFixture.jpeg(extra: extra))
    }

    func testInputMotionPhotoCannotBeBlindlyAppendedAgain() throws {
        let first = try MotionPhotoWriter.make(jpeg: WriterFixture.jpeg(), video: WriterFixture.movie(),
            presentationTimeMicroseconds: 0, format: .google)
        XCTAssertThrowsError(try MotionPhotoWriter.make(jpeg: first, video: WriterFixture.movie(),
            presentationTimeMicroseconds: 0, format: .samsung)) {
            XCTAssertEqual($0 as? MotionPhotoWriterError, .jpegContainsTrailingData)
        }
    }

    func testAnyBytesAfterTrueEOIAreRejected() {
        for suffix in [Data([0]), Data([0xff, 0xd9]), WriterFixture.movie()] {
            XCTAssertThrowsError(try MotionPhotoWriter.make(jpeg: WriterFixture.jpeg() + suffix,
                video: WriterFixture.movie(), presentationTimeMicroseconds: nil, format: .google)) {
                XCTAssertEqual($0 as? MotionPhotoWriterError, .jpegContainsTrailingData)
            }
        }
    }

    func testEOIInsideAPPMetadataDoesNotTruncateTheImage() throws {
        let fakeEOI = WriterFixture.segment(0xe1, Data("Exif\0\0".utf8) + Data([0xff, 0xd9, 0xff, 0xd8]))
        let jpeg = WriterFixture.jpeg(extra: fakeEOI)
        let output = try MotionPhotoWriter.make(jpeg: jpeg, video: WriterFixture.movie(),
            presentationTimeMicroseconds: nil, format: .google)
        XCTAssertEqual(try MotionPhotoParser.parse(data: output).videoRange.count, WriterFixture.movie().count)
        XCTAssertNotNil(output.range(of: fakeEOI))
    }

    func testStuffedFFAndRestartMarkersArePreserved() throws {
        let jpeg = WriterFixture.jpeg(scan: Data([0x41, 0xff, 0x00, 0x42, 0xff, 0xd3, 0x43]))
        let output = try MotionPhotoWriter.make(jpeg: jpeg, video: WriterFixture.movie(),
            presentationTimeMicroseconds: nil, format: .google)
        XCTAssertNotNil(output.range(of: Data([0x41, 0xff, 0x00, 0x42, 0xff, 0xd3, 0x43, 0xff, 0xd9])))
        XCTAssertEqual(try MotionPhotoParser.parse(data: output).videoRange.count, WriterFixture.movie().count)
    }

    func testProgressiveMultipleScansAreAccepted() throws {
        var progressiveFrame = WriterFixture.frame
        progressiveFrame[1] = 0xc2
        let firstScan = WriterFixture.segment(0xda, Data([1, 1, 0, 0, 0, 0]))
        let secondScan = WriterFixture.segment(0xda, Data([1, 1, 0, 1, 63, 0]))
        let scans = firstScan + Data([0x01, 0xff, 0x00, 0x02])
            + WriterFixture.segment(0xc4, Data([0])) + secondScan + Data([0x03])
        let jpeg = Data([0xff, 0xd8]) + progressiveFrame + scans + Data([0xff, 0xd9])
        let output = try MotionPhotoWriter.make(jpeg: jpeg, video: WriterFixture.movie(),
            presentationTimeMicroseconds: 0, format: .google)
        XCTAssertEqual(try MotionPhotoParser.parse(data: output).format, .googleMotionPhoto)
    }

    func testDataSlicesUseTheirOwnRelativeOffsets() throws {
        let paddedJPEG = Data(repeating: 0, count: 13) + WriterFixture.jpeg()
        let paddedVideo = Data(repeating: 0, count: 9) + WriterFixture.movie()
        let output = try MotionPhotoWriter.make(jpeg: paddedJPEG[13...], video: paddedVideo[9...],
            presentationTimeMicroseconds: 0, format: .samsung)
        let result = try MotionPhotoParser.parse(data: output)
        XCTAssertEqual(output.subdata(in: result.videoRange), WriterFixture.movie())
    }

    func testInputBuffersAreUnchanged() throws {
        let jpeg = WriterFixture.jpeg()
        let video = WriterFixture.movie()
        let jpegCopy = jpeg
        let videoCopy = video
        _ = try MotionPhotoWriter.make(jpeg: jpeg, video: video, presentationTimeMicroseconds: 0, format: .samsung)
        XCTAssertEqual(jpeg, jpegCopy)
        XCTAssertEqual(video, videoCopy)
    }

    func testTruncatedJPEGAndInvalidSegmentLengthAreRejected() {
        let valid = WriterFixture.jpeg()
        let badInputs = [Data(), Data([0xff, 0xd8, 0xff, 0xd9]), Data(valid.dropLast()),
                         Data([0xff, 0xd8, 0xff, 0xe1, 0xff, 0xff, 0, 0]),
                         Data([0xff, 0xd8, 0xff, 0xe1, 0, 1])]
        for jpeg in badInputs {
            XCTAssertThrowsError(try MotionPhotoWriter.make(jpeg: jpeg, video: WriterFixture.movie(),
                presentationTimeMicroseconds: nil, format: .google)) {
                XCTAssertEqual($0 as? MotionPhotoWriterError, .invalidJPEG)
            }
        }
    }

    func testTruncatedOrUnbrandedMoviesAreRejected() {
        let movie = WriterFixture.movie()
        let inputs = [Data(), Data(movie.dropLast()), WriterFixture.box("mdat", Data([1])),
                      WriterFixture.box("ftyp", Data("qt  ".utf8) + WriterFixture.be32(0))
                        + WriterFixture.box("moov", Data([1])) + WriterFixture.box("mdat", Data([1]))]
        for video in inputs {
            XCTAssertThrowsError(try MotionPhotoWriter.make(jpeg: WriterFixture.jpeg(), video: video,
                presentationTimeMicroseconds: nil, format: .google)) {
                XCTAssertEqual($0 as? MotionPhotoWriterError, .invalidVideo)
            }
        }
    }

    func testMovieRequiresBothMovieAndMediaBoxes() {
        let ftyp = WriterFixture.ftyp
        for video in [ftyp, ftyp + WriterFixture.box("moov", Data([1])), ftyp + WriterFixture.box("mdat", Data([1]))] {
            XCTAssertThrowsError(try MotionPhotoWriter.make(jpeg: WriterFixture.jpeg(), video: video,
                presentationTimeMicroseconds: nil, format: .samsung))
        }
    }

    func testOversizedExtendedBoxClaimsAreRejectedWithoutAllocation() {
        let huge = WriterFixture.be32(1) + Data("ftyp".utf8) + Data(repeating: 0xff, count: 8)
        XCTAssertThrowsError(try MotionPhotoWriter.make(jpeg: WriterFixture.jpeg(), video: huge,
            presentationTimeMicroseconds: nil, format: .google)) {
            XCTAssertEqual($0 as? MotionPhotoWriterError, .invalidVideo)
        }
    }

    func testOutputSizeGateRejectsOverflowAndExcessWithoutAllocating() throws {
        XCTAssertEqual(try MotionPhotoOutputSize.checkedTotal([1_073_741_800, 24]), 1_073_741_824)
        for counts in [[Int.max], [1_073_741_824, 1], [-1], [Int.max, Int.max]] {
            XCTAssertThrowsError(try MotionPhotoOutputSize.checkedTotal(counts)) {
                XCTAssertEqual($0 as? MotionPhotoWriterError, .fileTooLarge)
            }
        }
    }

    func testZeroLengthMDATToEndRemainsExtractable() throws {
        let video = WriterFixture.ftyp + WriterFixture.box("moov", WriterFixture.box("free", Data([1])))
            + WriterFixture.be32(0) + Data("mdat".utf8) + Data([1, 2, 3])
        for format in [MotionPhotoEncoding.google, .samsung] {
            let output = try MotionPhotoWriter.make(jpeg: WriterFixture.jpeg(), video: video,
                presentationTimeMicroseconds: 0, format: format)
            let result = try MotionPhotoParser.parse(data: output)
            XCTAssertEqual(output.subdata(in: result.videoRange), video)
        }
    }

    func testJPEGSegmentLengthMatchesActualXMPAndFitsUInt16() throws {
        let output = try MotionPhotoWriter.make(jpeg: WriterFixture.jpeg(), video: WriterFixture.movie(),
            presentationTimeMicroseconds: Int64.max, format: .samsung)
        let packet = try WriterFixture.readOutputXMP(output)
        let length = Int(output[packet.segmentRange.lowerBound + 2]) << 8 | Int(output[packet.segmentRange.lowerBound + 3])
        XCTAssertEqual(length + 2, packet.segmentRange.count)
        XCTAssertLessThanOrEqual(length, 65_535)
    }
}

/// These small fixtures exercise binary layout; actual image/codec decoding is
/// covered by the macOS integration suite with encoded media.
private enum WriterFixture {
    static func be32(_ value: Int) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    static func le32(_ data: Data, _ index: Int) -> UInt32 {
        UInt32(data[index]) | UInt32(data[index + 1]) << 8
            | UInt32(data[index + 2]) << 16 | UInt32(data[index + 3]) << 24
    }
    static func box(_ name: String, _ payload: Data) -> Data { be32(payload.count + 8) + Data(name.utf8) + payload }
    static let ftyp = box("ftyp", Data("mp42".utf8) + be32(0) + Data("isommp42".utf8))
    static func movie() -> Data { ftyp + box("moov", box("free", Data([1]))) + box("mdat", Data([2, 3, 4, 5])) }
    static func segment(_ marker: UInt8, _ payload: Data) -> Data {
        let length = payload.count + 2
        return Data([0xff, marker, UInt8(length >> 8), UInt8(length & 255)]) + payload
    }
    static let frame = segment(0xc0, Data([8, 0, 1, 0, 1, 1, 1, 0x11, 0]))
    static let scanHeader = segment(0xda, Data([1, 1, 0, 0, 63, 0]))
    static func jpeg(extra: Data = Data(), scan: Data = Data([0x3f])) -> Data {
        Data([0xff, 0xd8]) + segment(0xe0, Data("JFIF\0\u{1}\u{1}\0\0\u{1}\0\u{1}\0\0".utf8))
            + extra + frame + scanHeader + scan + Data([0xff, 0xd9])
    }

    struct OutputXMP {
        let segmentRange: Range<Int>
        let camera: [String: String]
        let items: [[String: String]]
    }

    static func readOutputXMP(_ data: Data) throws -> OutputXMP {
        let marker = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
        let header = try XCTUnwrap(data.range(of: marker))
        let start = header.lowerBound - 4
        XCTAssertEqual(data[start], 0xff)
        XCTAssertEqual(data[start + 1], 0xe1)
        let length = Int(data[start + 2]) << 8 | Int(data[start + 3])
        let end = start + 2 + length
        let xml = data.subdata(in: header.upperBound..<end)
        let delegate = OutputXMPReader()
        let parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.delegate = delegate
        XCTAssertTrue(parser.parse(), parser.parserError?.localizedDescription ?? "XMP failed to parse")
        return OutputXMP(segmentRange: start..<end, camera: delegate.camera, items: delegate.items)
    }
}

private final class OutputXMPReader: NSObject, XMLParserDelegate {
    var camera: [String: String] = [:]
    var items: [[String: String]] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        for (key, value) in attributes where key.hasPrefix("Camera:") {
            camera[String(key.dropFirst(7))] = value
        }
        if namespaceURI == "http://ns.google.com/photos/1.0/container/", elementName == "Item" {
            var item: [String: String] = [:]
            for (key, value) in attributes where key.hasPrefix("Item:") { item[String(key.dropFirst(5))] = value }
            items.append(item)
        }
    }
}
