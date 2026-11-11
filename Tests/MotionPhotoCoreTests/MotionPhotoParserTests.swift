import Foundation
import XCTest
@testable import MotionPhotoCore

final class MotionPhotoParserTests: XCTestCase {
    func testGoogleLegacyOffsetAndTimestamp() throws {
        let movie = Fixture.movie()
        let image = Fixture.jpeg(xmp: Fixture.xmp(camera: "cam:MicroVideo=\"1\" cam:MicroVideoOffset=\"\(movie.count)\" cam:MicroVideoPresentationTimestampUs=\"1250000\""))
        let result = try MotionPhotoParser.parse(data: image + movie)
        XCTAssertEqual(result.videoRange, image.count..<(image.count + movie.count))
        XCTAssertEqual(result.presentationTimeMicroseconds, 1_250_000)
        XCTAssertEqual(result.format, .googleMicroVideo)
    }

    func testModernDirectoryWithArbitraryPrefixes() throws {
        let movie = Fixture.movie()
        let image = Fixture.jpeg(xmp: Fixture.xmp(camera: "cam:MotionPhoto=\"1\" cam:MotionPhotoPresentationTimestampUs=\"500000\"",
            items: [Fixture.item("Primary", "image/jpeg", length: 0), Fixture.item("MotionPhoto", "video/mp4", length: movie.count)]))
        let result = try MotionPhotoParser.parse(data: image + movie)
        XCTAssertEqual(result.videoRange, image.count..<(image.count + movie.count))
        XCTAssertEqual(result.format, .googleMotionPhoto)
        XCTAssertEqual(result.presentationTimeMicroseconds, 500_000)
    }

    func testContainerGainMapPaddingAndItemFollowingMovie() throws {
        let movie = Fixture.movie()
        let gainmap = Data(repeating: 0xab, count: 17)
        let extra = Data(repeating: 0xcd, count: 9)
        let padding = Data(repeating: 0, count: 23)
        let image = Fixture.jpeg(xmp: Fixture.xmp(camera: "cam:MotionPhoto=\"1\"", items: [
            Fixture.item("Primary", "image/jpeg", length: 0, padding: padding.count),
            Fixture.item("GainMap", "image/jpeg", length: gainmap.count),
            Fixture.item("MotionPhoto", "video/mp4", length: movie.count),
            Fixture.item("Extension", "application/octet-stream", length: extra.count)
        ]))
        let result = try MotionPhotoParser.parse(data: image + padding + gainmap + movie + extra)
        let start = image.count + padding.count + gainmap.count
        XCTAssertEqual(result.videoRange, start..<(start + movie.count))
        XCTAssertEqual(result.format, .googleMotionPhoto)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testXMLCameraPropertiesAndItemPropertiesAsElements() throws {
        let movie = Fixture.movie()
        let body = """
        <cam:MotionPhoto>1</cam:MotionPhoto><cam:MotionPhotoPresentationTimestampUs>42</cam:MotionPhotoPresentationTimestampUs>
        <c:Directory><rdf:Seq>
        <rdf:li rdf:parseType="Resource"><c:Item><i:Semantic>Primary</i:Semantic><i:Mime>image/jpeg</i:Mime></c:Item></rdf:li>
        <rdf:li rdf:parseType="Resource"><c:Item><i:Semantic>MotionPhoto</i:Semantic><i:Mime>video/mp4</i:Mime><i:Length>\(movie.count)</i:Length></c:Item></rdf:li>
        </rdf:Seq></c:Directory>
        """
        let image = Fixture.jpeg(xmp: Fixture.xmp(body: body))
        let result = try MotionPhotoParser.parse(data: image + movie)
        XCTAssertEqual(result.format, .googleMotionPhoto)
        XCTAssertEqual(result.presentationTimeMicroseconds, 42)
    }

    func testNegativeTimestampIsUnknown() throws {
        let movie = Fixture.movie()
        let image = Fixture.jpeg(xmp: Fixture.xmp(camera: "cam:MicroVideo=\"1\" cam:MicroVideoOffset=\"\(movie.count)\" cam:MicroVideoPresentationTimestampUs=\"-1\""))
        XCTAssertNil(try MotionPhotoParser.parse(data: image + movie).presentationTimeMicroseconds)
    }

    func testModernDisabledFlagOverridesOldEnabledFlag() {
        let movie = Fixture.movie()
        let image = Fixture.jpeg(xmp: Fixture.xmp(camera: "cam:MotionPhoto=\"0\" cam:MicroVideo=\"1\" cam:MicroVideoOffset=\"\(movie.count)\""))
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: image + movie)) { error in
            guard case MotionPhotoError.motionDisabled = error else { return XCTFail("Wrong error: \(error)") }
        }
    }

    func testSamsungSEFIndexedMovie() throws {
        let image = Fixture.jpeg()
        let movie = Fixture.movie()
        let (trailer, payloadOffset) = Fixture.sef(payload: movie)
        let result = try MotionPhotoParser.parse(data: image + trailer)
        let start = image.count + payloadOffset
        XCTAssertEqual(result.videoRange, start..<(start + movie.count))
        XCTAssertEqual(result.format, .samsungMotionPhoto)
    }

    func testSamsungTrailerWinsOverLengthIncludingTrailer() throws {
        let movie = Fixture.movie()
        let (trailer, payloadOffset) = Fixture.sef(payload: movie)
        let image = Fixture.jpeg(xmp: Fixture.xmp(camera: "cam:MotionPhoto=\"1\"", items: [
            Fixture.item("Primary", "image/jpeg", length: 0),
            Fixture.item("MotionPhoto", "video/mp4", length: trailer.count - payloadOffset)
        ]))
        let result = try MotionPhotoParser.parse(data: image + trailer)
        XCTAssertEqual(result.videoRange.count, movie.count)
        XCTAssertEqual(result.format, .samsungMotionPhoto)
    }

    func testSamsungJPEGMPV2PointerUsesBigEndianAbsoluteOffset() throws {
        let image = Fixture.jpeg()
        let movie = Fixture.movie()
        let pointer = Data("mpv2".utf8) + Fixture.be32(image.count) + Fixture.be32(movie.count)
        let (trailer, _) = Fixture.sef(payload: pointer)
        let result = try MotionPhotoParser.parse(data: image + movie + trailer)
        XCTAssertEqual(result.videoRange, image.count..<(image.count + movie.count))
        XCTAssertEqual(result.format, .samsungMotionPhoto)
    }

    func testSamsungHEIFWithSEFDOutsideMPVD() throws {
        let image = Fixture.heifPrefix()
        let movie = Fixture.movie()
        let pointer = Data("mpv2".utf8) + Fixture.be32(image.count + 8) + Fixture.be32(movie.count)
        let (trailer, _) = Fixture.sef(payload: pointer)
        let data = image + Fixture.box("mpvd", movie) + Fixture.box("sefd", trailer)
        let result = try MotionPhotoParser.parse(data: data)
        XCTAssertEqual(result.videoRange, (image.count + 8)..<(image.count + 8 + movie.count))
        XCTAssertEqual(result.format, .samsungMotionPhoto)
    }

    func testSamsungHEIFWithDirectMovieInsideSEFD() throws {
        let image = Fixture.heifPrefix()
        let movie = Fixture.movie()
        let (trailer, payloadOffset) = Fixture.sef(payload: movie)
        let result = try MotionPhotoParser.parse(data: image + Fixture.box("sefd", trailer))
        let start = image.count + 8 + payloadOffset
        XCTAssertEqual(result.videoRange, start..<(start + movie.count))
        XCTAssertEqual(result.format, .samsungMotionPhoto)
    }

    func testSamsungHEIFWithSEFDInsideMPVD() throws {
        let image = Fixture.heifPrefix()
        let movie = Fixture.movie()
        let pointer = Data("mpv2".utf8) + Fixture.be32(image.count + 8) + Fixture.be32(movie.count)
        let (trailer, _) = Fixture.sef(payload: pointer)
        let data = image + Fixture.box("mpvd", movie + Fixture.box("sefd", trailer))
        let result = try MotionPhotoParser.parse(data: data)
        XCTAssertEqual(result.videoRange.count, movie.count)
        XCTAssertEqual(result.format, .samsungMotionPhoto)
    }

    func testHEIFMPVDAndTimestampInEmbeddedXMP() throws {
        let xmp = Fixture.xmp(camera: "cam:MotionPhoto=\"1\" cam:MotionPhotoPresentationTimestampUs=\"999\"")
        let image = Fixture.heifPrefix() + Fixture.box("mdat", Data(xmp.utf8))
        let movie = Fixture.movie()
        let result = try MotionPhotoParser.parse(data: image + Fixture.box("mpvd", movie))
        XCTAssertEqual(result.videoRange, (image.count + 8)..<(image.count + 8 + movie.count))
        XCTAssertEqual(result.presentationTimeMicroseconds, 999)
        XCTAssertEqual(result.format, .heifMotionPhoto)
    }

    func testExtendedSizeMPVD() throws {
        let image = Fixture.heifPrefix()
        let movie = Fixture.movie()
        let box = Fixture.be32(1) + Data("mpvd".utf8) + Fixture.be64(movie.count + 16) + movie
        let result = try MotionPhotoParser.parse(data: image + box)
        XCTAssertEqual(result.videoRange, (image.count + 16)..<(image.count + 16 + movie.count))
    }

    func testTwoDistinctMPVDMoviesAreAmbiguous() {
        let data = Fixture.heifPrefix() + Fixture.box("mpvd", Fixture.movie())
            + Fixture.box("mpvd", Fixture.movie())
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: data)) { error in
            guard case MotionPhotoError.ambiguousVideo = error else { return XCTFail("Wrong error: \(error)") }
        }
    }

    func testVideoBoxMayHaveZeroLengthMDATToEnd() throws {
        let movie = Fixture.ftyp() + Fixture.box("moov", Fixture.box("free", Data([0])))
            + Fixture.be32(0) + Data("mdat".utf8) + Data([1, 2, 3])
        let image = Fixture.jpeg(xmp: Fixture.xmp(camera: "cam:MicroVideoOffset=\"\(movie.count)\""))
        XCTAssertEqual(try MotionPhotoParser.parse(data: image + movie).videoRange.count, movie.count)
    }

    func testZeroSizeMPVDIsRejected() {
        let data = Fixture.heifPrefix() + Fixture.be32(0) + Data("mpvd".utf8) + Fixture.movie()
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: data))
    }

    func testRecoveryOutsideJPEGWithMotionFlag() throws {
        let image = Fixture.jpeg(xmp: Fixture.xmp(camera: "cam:MotionPhoto=\"1\""))
        let movie = Fixture.movie()
        let padding = Data(repeating: 0x7f, count: 32)
        let result = try MotionPhotoParser.parse(data: image + padding + movie)
        XCTAssertEqual(result.videoRange.lowerBound, image.count + padding.count)
        XCTAssertEqual(result.format, .recoveredMotionPhoto)
    }

    func testRecoveryRequiresMotionEvidence() {
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: Fixture.jpeg() + Fixture.movie()))
    }

    func testEmbeddedMovieInEXIFIsNeverRecovered() {
        let metadata = Fixture.xmp(camera: "cam:MotionPhoto=\"1\"")
        let embedded = Data("Exif\0\0".utf8) + Fixture.movie()
        let image = Fixture.jpeg(xmp: metadata, extraAPP1: embedded)
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: image))
    }

    func testFakeFTYPWithoutCompleteMovieIsRejected() {
        let image = Fixture.jpeg(xmp: Fixture.xmp(camera: "cam:MotionPhoto=\"1\""))
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: image + Fixture.ftyp()))
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: image + Fixture.ftyp() + Fixture.box("mdat", Data([1, 2, 3]))))
    }

    func testPlainJPEGAndStandaloneMP4AreRejected() {
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: Fixture.jpeg()))
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: Fixture.movie()))
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: Data()))
    }

    func testTruncatedMovieIsRejected() {
        let movie = Fixture.movie()
        let image = Fixture.jpeg(xmp: Fixture.xmp(camera: "cam:MicroVideo=\"1\" cam:MicroVideoOffset=\"\(movie.count)\""))
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: image + movie.dropLast(1)))
    }

    func testInvalidOffsetAndOverflowDoNotTrap() {
        for value in ["-1", "0", "9999999999999999999999999999999", "18446744073709551615"] {
            let image = Fixture.jpeg(xmp: Fixture.xmp(camera: "cam:MicroVideoOffset=\"\(value)\""))
            XCTAssertThrowsError(try MotionPhotoParser.parse(data: image + Fixture.movie()))
        }
    }

    func testMalformedBoxSizesDoNotTrap() {
        let image = Fixture.jpeg(xmp: Fixture.xmp(camera: "cam:MotionPhoto=\"1\""))
        let badExtended = Fixture.be32(1) + Data("ftyp".utf8) + Data(repeating: 0xff, count: 8)
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: image + badExtended))
        let badSmall = Fixture.be32(4) + Data("ftyp".utf8)
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: image + badSmall))
    }

    func testInvalidSEFOffsetAndNameLengthDoNotTrap() {
        let image = Fixture.jpeg()
        var (trailer, _) = Fixture.sef(payload: Fixture.movie())
        let directory = trailer.count - 32
        trailer.replaceSubrange((directory + 16)..<(directory + 20), with: Fixture.le32(UInt32.max))
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: image + trailer))
        var (second, _) = Fixture.sef(payload: Fixture.movie())
        second.replaceSubrange(4..<8, with: Fixture.le32(UInt32.max))
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: image + second))
    }

    func testSEFPointerCannotPointIntoImageMetadata() {
        let embeddedMovie = Fixture.movie()
        let image = Fixture.jpeg(extraAPP1: embeddedMovie)
        // The APP1 payload starts after SOI, marker, and length.
        let pointer = Data("mpv2".utf8) + Fixture.be32(6) + Fixture.be32(embeddedMovie.count)
        let (trailer, _) = Fixture.sef(payload: pointer)
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: image + trailer))
    }

    func testDisabledMotionCannotBeResurrectedBySamsungTrailer() {
        let image = Fixture.jpeg(xmp: Fixture.xmp(camera: "cam:MotionPhoto=\"0\""))
        let (trailer, _) = Fixture.sef(payload: Fixture.movie())
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: image + trailer))
    }

    func testDTDAndEntityDeclarationsAreRefused() {
        let movie = Fixture.movie()
        let xmp = "<!DOCTYPE x [<!ENTITY offset '\(movie.count)'>]>" + Fixture.xmp(camera: "cam:MicroVideoOffset=\"&offset;\"")
        XCTAssertThrowsError(try MotionPhotoParser.parse(data: Fixture.jpeg(xmp: xmp) + movie))
    }

    func testDataSliceUsesRelativeOffsets() throws {
        let movie = Fixture.movie()
        let image = Fixture.jpeg(xmp: Fixture.xmp(camera: "cam:MicroVideoOffset=\"\(movie.count)\""))
        let container = Data(repeating: 0, count: 23) + image + movie
        let slice = container[23...]
        let result = try MotionPhotoParser.parse(data: slice)
        XCTAssertEqual(result.videoRange, image.count..<(image.count + movie.count))
    }

    func testJPEGEntropyStuffingAndRestartMarkers() throws {
        let movie = Fixture.movie()
        let xmp = Fixture.xmp(camera: "cam:MicroVideoOffset=\"\(movie.count)\"")
        let image = Fixture.jpeg(xmp: xmp, scan: Data([0x12, 0xff, 0x00, 0x34, 0xff, 0xd0, 0x56]))
        let result = try MotionPhotoParser.parse(data: image + movie)
        XCTAssertEqual(result.videoRange.lowerBound, image.count)
    }

    func testOutOfOrderExtendedXMPChunks() throws {
        let movie = Fixture.movie()
        let xmp = Data(Fixture.xmp(camera: "cam:MicroVideoOffset=\"\(movie.count)\" cam:MicroVideoPresentationTimestampUs=\"1234\"").utf8)
        let split = xmp.count / 2
        let identity = Data("0123456789ABCDEF0123456789ABCDEF".utf8)
        let header = Data("http://ns.adobe.com/xmp/extension/\0".utf8) + identity + Fixture.be32(xmp.count)
        let first = header + Fixture.be32(0) + xmp.prefix(split)
        let second = header + Fixture.be32(split) + xmp.dropFirst(split)
        let image = Data([0xff, 0xd8]) + Fixture.app1(second) + Fixture.app1(first) + Data([0xff, 0xd9])
        let result = try MotionPhotoParser.parse(data: image + movie)
        XCTAssertEqual(result.format, .googleMicroVideo)
        XCTAssertEqual(result.presentationTimeMicroseconds, 1234)
    }

    func testEmptyExtendedXMPChunksDoNotCrowdOutValidMetadata() throws {
        let movie = Fixture.movie()
        let identity = Data("0123456789ABCDEF0123456789ABCDEF".utf8)
        let emptyChunk = Data("http://ns.adobe.com/xmp/extension/\0".utf8) + identity
            + Fixture.be32(1) + Fixture.be32(0)
        var image = Data([0xff, 0xd8])
        for _ in 0..<600 { image += Fixture.app1(emptyChunk) }
        let xmp = Fixture.xmp(camera: "cam:MicroVideoOffset=\"\(movie.count)\"")
        image += Fixture.app1(Data("http://ns.adobe.com/xap/1.0/\0".utf8) + Data(xmp.utf8))
        image += Data([0xff, 0xd9])
        let result = try MotionPhotoParser.parse(data: image + movie)
        XCTAssertEqual(result.format, .googleMicroVideo)
    }

    func testLargeUnrelatedXMPPropertyDoesNotHideMotionFields() throws {
        let movie = Fixture.movie()
        let body = "<depth:Data xmlns:depth=\"http://ns.google.com/photos/1.0/depthmap/\">"
            + String(repeating: "A", count: 12_000) + "</depth:Data>"
        let image = Fixture.jpeg(xmp: Fixture.xmp(camera: "cam:MicroVideoOffset=\"\(movie.count)\"", body: body))
        XCTAssertEqual(try MotionPhotoParser.parse(data: image + movie).format, .googleMicroVideo)
    }

    func testCDATAElementTimestamp() throws {
        let movie = Fixture.movie()
        let image = Fixture.jpeg(xmp: Fixture.xmp(camera: "cam:MicroVideoOffset=\"\(movie.count)\"",
            body: "<cam:MicroVideoPresentationTimestampUs><![CDATA[900000]]></cam:MicroVideoPresentationTimestampUs>"))
        XCTAssertEqual(try MotionPhotoParser.parse(data: image + movie).presentationTimeMicroseconds, 900_000)
    }

    func testAllTruncationsOfSamsungFixtureAreSafeToParse() {
        let image = Fixture.jpeg()
        let (trailer, _) = Fixture.sef(payload: Fixture.movie())
        let full = image + trailer
        // A prefix ending exactly at the complete movie is recoverable from its
        // Samsung block signature; every other truncation must be safe to parse.
        for end in 0..<full.count {
            _ = try? MotionPhotoParser.parse(data: Data(full.prefix(end)))
        }
    }

    func testDeterministicRandomInputsDoNotCrash() {
        var state: UInt64 = 0x4d4f54494f4e
        for size in 0..<512 {
            var data = Data()
            for _ in 0..<size {
                state = state &* 6364136223846793005 &+ 1
                data.append(UInt8(truncatingIfNeeded: state >> 32))
            }
            _ = try? MotionPhotoParser.parse(data: data)
        }
    }
}

/// Structural fixtures deliberately do not claim to be decodable photographs or
/// videos. AVFoundation integration tests exercise actual encoded media on macOS.
private enum Fixture {
    static func be32(_ value: Int) -> Data { be32(UInt32(value)) }
    static func be32(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    static func le32(_ value: Int) -> Data { le32(UInt32(value)) }
    static func le32(_ value: UInt32) -> Data { Data(be32(value).reversed()) }
    static func be64(_ value: Int) -> Data { be32(UInt32(value >> 32)) + be32(UInt32(truncatingIfNeeded: value)) }
    static func box(_ type: String, _ payload: Data) -> Data { be32(payload.count + 8) + Data(type.utf8) + payload }
    static func ftyp() -> Data { box("ftyp", Data("isom".utf8) + be32(0) + Data("isommp42".utf8)) }
    static func movie() -> Data {
        ftyp() + box("moov", box("free", Data([0]))) + box("mdat", Data([1, 2, 3, 4, 5, 6]))
    }
    static func heifPrefix() -> Data { box("ftyp", Data("heic".utf8) + be32(0) + Data("heicmif1".utf8)) + box("meta", Data(repeating: 0, count: 4)) }
    static func app1(_ payload: Data) -> Data {
        let length = payload.count + 2
        return Data([0xff, 0xe1, UInt8(length >> 8), UInt8(length & 255)]) + payload
    }
    static func jpeg(xmp: String? = nil, extraAPP1: Data? = nil, scan: Data = Data([0x42])) -> Data {
        var data = Data([0xff, 0xd8])
        if let xmp { data += app1(Data("http://ns.adobe.com/xap/1.0/\0".utf8) + Data(xmp.utf8)) }
        if let extraAPP1 { data += app1(extraAPP1) }
        data += Data([0xff, 0xda, 0x00, 0x02]) + scan + Data([0xff, 0xd9])
        return data
    }
    static func xmp(camera: String = "", items: [String] = [], body: String = "") -> String {
        let directory = items.isEmpty ? "" : "<c:Directory><rdf:Seq>\(items.joined())</rdf:Seq></c:Directory>"
        return """
        <z:xmpmeta xmlns:z="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:cam="http://ns.google.com/photos/1.0/camera/" xmlns:c="http://ns.google.com/photos/1.0/container/" xmlns:i="http://ns.google.com/photos/1.0/container/item/" \(camera)>\(body)\(directory)</rdf:Description></rdf:RDF></z:xmpmeta>
        """
    }
    static func item(_ semantic: String, _ mime: String, length: Int, padding: Int? = nil) -> String {
        let padding = padding.map { " i:Padding=\"\($0)\"" } ?? ""
        return "<rdf:li rdf:parseType=\"Resource\"><c:Item i:Mime=\"\(mime)\" i:Semantic=\"\(semantic)\" i:Length=\"\(length)\"\(padding)/></rdf:li>"
    }
    static func sef(payload: Data) -> (data: Data, payloadOffset: Int) {
        let identifier = Data([0, 0, 0x30, 0x0a])
        let name = Data("MotionPhoto_Data".utf8)
        let prefix = identifier + le32(name.count) + name
        let block = prefix + payload
        let directory = Data("SEFH".utf8) + le32(107) + le32(1)
            + identifier + le32(block.count) + le32(block.count)
        return (block + directory + le32(directory.count) + Data("SEFT".utf8), prefix.count)
    }
}
