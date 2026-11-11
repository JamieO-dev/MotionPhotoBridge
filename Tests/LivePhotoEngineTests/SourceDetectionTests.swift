import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import MotionPhotoCore
import UniformTypeIdentifiers
import XCTest
@testable import LivePhotoEngine

/// These tests construct real JPEG/MOV resources without accessing Photos.
/// Native metadata readers are exercised; no identifier relationship is mocked.
final class SourceDetectionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MotionPhotoBridge-detection-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testEmbeddedFormatsAreAutomaticallyDetected() async throws {
        for (name, expected) in [("google-modern", MotionPhotoSourceFormat.googleMotionPhoto),
                                 ("google-legacy", .googleMicroVideo), ("samsung-sef", .samsungMotionPhoto)] {
            let source = try await MotionSourceDetector.detect(sourceURL: fixture(name))
            XCTAssertEqual(source.format, expected)
            XCTAssertNil(source.pairedVideoURL)
            XCTAssertEqual(source.resourceURLs.count, 1)
        }
    }

    func testSelectingBothHalvesAndDuplicateURLsCreatesOneJob() async throws {
        let pair = try await makePair()
        let results = await MotionSourceDetector.detect(urls: [pair.movie, pair.image, pair.movie, pair.image])
        XCTAssertEqual(results.count, 1)
        let source = try XCTUnwrap(results.first?.source)
        XCTAssertEqual(source.format, .appleLivePhoto)
        XCTAssertEqual(source.imageURL, pair.image)
        XCTAssertEqual(source.pairedVideoURL, pair.movie)
        XCTAssertEqual(source.presentationTimeMicroseconds, 1_250_000)
    }

    func testImageAloneFindsUppercaseMOVSiblingWithoutDoubleCounting() async throws {
        let pair = try await makePair()
        let source = try await MotionSourceDetector.detect(sourceURL: pair.image)
        XCTAssertEqual(source.format, .appleLivePhoto)
        let movie = try XCTUnwrap(source.pairedVideoURL)
        XCTAssertEqual(try Data(contentsOf: movie), try Data(contentsOf: pair.movie))
    }

    func testMovieAloneFindsItsImageSibling() async throws {
        let pair = try await makePair()
        let source = try await MotionSourceDetector.detect(sourceURL: pair.movie)
        XCTAssertEqual(source.imageURL, pair.image)
        XCTAssertEqual(source.pairedVideoURL, pair.movie)
    }

    func testRenamedSelectedHalvesMatchAcrossFolders() async throws {
        let pair = try await makePair()
        let other = try makeDirectory("other")
        let renamed = other.appendingPathComponent("a completely different name.mov")
        try FileManager.default.moveItem(at: pair.movie, to: renamed)
        let results = await MotionSourceDetector.detect(urls: [pair.image, renamed])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.source?.pairedVideoURL, renamed)
        XCTAssertNil(results.first?.errorMessage)
    }

    func testMatchingIdentifierWinsOverMisleadingFilename() async throws {
        let first = try await makePair()
        let second = try await makePair()
        let source = try await MotionSourceDetector.detect(sourceURL: first.image,
            candidateURLs: [second.movie, first.movie])
        XCTAssertEqual(source.pairedVideoURL, first.movie)
    }

    func testSameBasenameWithDifferentIdentifiersIsRejected() async throws {
        let first = try await makePair()
        let second = try await makePair()
        let isolated = try makeDirectory("mismatch")
        let image = isolated.appendingPathComponent("shared.jpg")
        let movie = isolated.appendingPathComponent("shared.mov")
        try FileManager.default.copyItem(at: first.image, to: image)
        try FileManager.default.copyItem(at: second.movie, to: movie)
        let message = try await failure(source: image, candidates: [movie])
        XCTAssertTrue(message.contains("different Live Photo identifiers"))
        let results = await MotionSourceDetector.detect(urls: [image, movie])
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.source == nil && $0.errorMessage != nil })
    }

    func testMissingMovieHasSpecificGuidance() async throws {
        let pair = try await makePair()
        try FileManager.default.removeItem(at: pair.movie)
        let message = try await failure(source: pair.image)
        XCTAssertTrue(message.contains("matching MOV is missing"))
    }

    func testSameFilenameCannotReplaceMissingMovieIdentifier() async throws {
        let pair = try await makePair(movieHasIdentifier: false)
        let message = try await failure(source: pair.image)
        XCTAssertTrue(message.contains("no Apple Live Photo pairing identifier"))
    }

    func testMovieCannotPairWithImageMissingAppleIdentifier() async throws {
        let pair = try await makePair(imageHasIdentifier: false)
        let message = try await failure(source: pair.movie)
        XCTAssertTrue(message.contains("no Apple Live Photo pairing identifier"))
    }

    func testDuplicateVideoIdentifiersAreAmbiguous() async throws {
        let pair = try await makePair()
        let duplicate = pair.movie.deletingLastPathComponent().appendingPathComponent("duplicate.mov")
        try FileManager.default.copyItem(at: pair.movie, to: duplicate)
        let message = try await failure(source: pair.image, candidates: [pair.movie, duplicate])
        XCTAssertTrue(message.contains("More than one video"))
    }

    func testDuplicateImageIdentifiersAreAmbiguous() async throws {
        let pair = try await makePair()
        let duplicate = pair.image.deletingLastPathComponent().appendingPathComponent("duplicate.jpg")
        try FileManager.default.copyItem(at: pair.image, to: duplicate)
        let message = try await failure(source: pair.movie, candidates: [pair.image, duplicate])
        XCTAssertTrue(message.contains("More than one image"))
    }

    func testHardLinkedResourceIsDeduplicated() async throws {
        let pair = try await makePair()
        let alias = pair.movie.deletingLastPathComponent().appendingPathComponent("same-resource.mov")
        try FileManager.default.linkItem(at: pair.movie, to: alias)
        let results = await MotionSourceDetector.detect(urls: [pair.image, pair.movie, alias])
        XCTAssertEqual(results.count, 1)
        XCTAssertNotNil(results.first?.source)
    }

    func testZeroStillImageMarkerIsAcceptedAlongsideMinusOneConvention() async throws {
        let pair = try await makePair(markers: [Marker(time: 1.25, value: 0)])
        let source = try await MotionSourceDetector.detect(sourceURL: pair.image, candidateURLs: [pair.movie])
        XCTAssertEqual(source.presentationTimeMicroseconds, 1_250_000)
    }

    func testMissingStillImageTimeProducesWarning() async throws {
        let pair = try await makePair(markers: [])
        let source = try await MotionSourceDetector.detect(sourceURL: pair.image, candidateURLs: [pair.movie])
        XCTAssertEqual(source.format, .appleLivePhoto)
        XCTAssertNil(source.presentationTimeMicroseconds)
        XCTAssertTrue(source.warnings.contains { $0.contains("no still-image timestamp") })
    }

    func testConflictingStillImageTimesAreRejected() async throws {
        let pair = try await makePair(markers: [Marker(time: 1, value: -1), Marker(time: 2, value: 0)])
        let message = try await failure(source: pair.image, candidates: [pair.movie])
        XCTAssertTrue(message.contains("conflicting still-image times"))
    }

    func testOnlyUnconsumedOrphansAndUnknownFilesProduceErrors() async throws {
        let pair = try await makePair()
        let original = try Data(contentsOf: fixture("google-modern"))
        let payload = try MotionPhotoParser.parse(data: original)
        let standalone = directory.appendingPathComponent("ordinary-video.mp4")
        try original.subdata(in: payload.videoRange).write(to: standalone)
        let unknown = directory.appendingPathComponent("notes.txt")
        try Data("Not a photo".utf8).write(to: unknown)
        let results = await MotionSourceDetector.detect(urls: [pair.movie, standalone, pair.image, unknown])
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.filter { $0.source != nil }.count, 1)
        XCTAssertEqual(results.filter { $0.errorMessage != nil }.count, 2)
    }

    func testStrippedMotionPhotoPreservesParserErrorType() async throws {
        let original = try Data(contentsOf: fixture("google-modern"))
        let payload = try MotionPhotoParser.parse(data: original)
        let stripped = directory.appendingPathComponent("stripped.jpg")
        try original.prefix(payload.videoRange.lowerBound).write(to: stripped)
        do {
            _ = try await MotionSourceDetector.detect(sourceURL: stripped)
            XCTFail("A still image cannot recreate stripped motion")
        } catch is MotionPhotoError {
            // Preserve the existing conversion API's failure type.
        }
    }

    func testOversizedFileIsRejectedBeforeLoadingItsContents() async throws {
        let file = directory.appendingPathComponent("oversized.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1_073_741_825)
        try handle.close()
        let message = try await failure(source: file)
        XCTAssertTrue(message.contains("1 GB limit"))
    }

    private func failure(source: URL, candidates: [URL] = []) async throws -> String {
        do {
            _ = try await MotionSourceDetector.detect(sourceURL: source, candidateURLs: candidates)
            XCTFail("The supplied resources should not form a valid source")
            return ""
        } catch { return error.localizedDescription }
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "jpg", subdirectory: "Fixtures"))
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let folder = directory.appendingPathComponent("\(name)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private struct Pair { let image: URL; let movie: URL }
    private struct Marker { let time: Double; let value: Int8 }

    private func makePair(imageHasIdentifier: Bool = true, movieHasIdentifier: Bool = true,
                          markers: [Marker] = [Marker(time: 1.25, value: -1)]) async throws -> Pair {
        let folder = try makeDirectory("pair")
        let imageURL = folder.appendingPathComponent("photo.jpg")
        let movieURL = folder.appendingPathComponent("photo.MOV")
        let rawMovie = folder.appendingPathComponent(".source.mp4")
        let identifier = UUID().uuidString
        let original = try Data(contentsOf: fixture("google-modern"))
        let payload = try MotionPhotoParser.parse(data: original)
        try original.subdata(in: payload.videoRange).write(to: rawMovie)
        defer { try? FileManager.default.removeItem(at: rawMovie) }

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [String: Any] = [:]
        if imageHasIdentifier { properties[kCGImagePropertyMakerAppleDictionary as String] = ["17": identifier] }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.imageWriteFailed }

        let asset = AVURLAsset(url: rawMovie)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: movieURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
        writer.add(input)
        if movieHasIdentifier {
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = "com.apple.quicktime.content.identifier" as NSString
            item.value = identifier as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            writer.metadata = [item]
        }

        var metadataInput: AVAssetWriterInput?
        var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
        if !markers.isEmpty {
            let specification: [[String: Any]] = [[
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String
            ]]
            var description: CMFormatDescription?
            let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: specification as CFArray, formatDescriptionOut: &description)
            XCTAssertEqual(status, noErr)
            let metadata = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: try XCTUnwrap(description))
            writer.add(metadata)
            metadataInput = metadata
            metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadata)
        }
        guard writer.startWriting() else { throw ConversionError.encodingFailed(writer.error?.localizedDescription ?? "Test writer failed") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw ConversionError.videoUnreadable(reader.error?.localizedDescription ?? "Test reader failed") }
        var videoDone = false
        var metadataDone = markers.isEmpty
        var markerIndex = 0
        let deadline = Date().addingTimeInterval(30)
        while !videoDone || !metadataDone {
            guard Date() < deadline else { throw ConversionError.encodingFailed("Test fixture writer timed out") }
            if writer.status == .failed || reader.status == .failed {
                throw ConversionError.encodingFailed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "Test fixture writing failed")
            }
            if !metadataDone, let metadataInput, metadataInput.isReadyForMoreMediaData, let metadataAdaptor {
                let marker = markers[markerIndex]
                let item = AVMutableMetadataItem()
                item.keySpace = .quickTimeMetadata
                item.key = "com.apple.quicktime.still-image-time" as NSString
                item.value = NSNumber(value: marker.value)
                item.dataType = kCMMetadataBaseDataType_SInt8 as String
                let range = CMTimeRange(start: CMTime(seconds: marker.time, preferredTimescale: 600), duration: CMTime(value: 1, timescale: 30))
                guard metadataAdaptor.append(AVTimedMetadataGroup(items: [item], timeRange: range)) else {
                    throw ConversionError.encodingFailed("Test marker could not be written")
                }
                markerIndex += 1
                if markerIndex == markers.count { metadataInput.markAsFinished(); metadataDone = true }
            }
            if !videoDone, input.isReadyForMoreMediaData {
                if let sample = output.copyNextSampleBuffer() {
                    guard input.append(sample) else { throw ConversionError.encodingFailed("Test frame could not be written") }
                } else { input.markAsFinished(); videoDone = true }
            }
            if !videoDone || !metadataDone { try await Task.sleep(nanoseconds: 500_000) }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw ConversionError.encodingFailed(writer.error?.localizedDescription ?? "Test movie did not finish") }
        return Pair(image: imageURL, movie: movieURL)
    }
}
