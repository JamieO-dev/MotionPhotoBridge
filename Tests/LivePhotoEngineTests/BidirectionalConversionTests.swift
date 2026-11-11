import AVFoundation
import Foundation
import ImageIO
import MotionPhotoCore
import Photos
import XCTest
@testable import LivePhotoEngine

/// Native macOS integration coverage for the new output directions. Fixtures
/// contain generated imagery/audio. These tests never add assets to Photos.
final class BidirectionalConversionTests: XCTestCase {
    private var directory: URL!
    private let androidFormats: [MotionPhotoOutputFormat] = [.googleMotionPhoto, .samsungMotionPhoto]

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MotionPhotoBridge-bidirectional-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testGoogleFixtureExportsOneMotionJPEGInBothAndroidFormats() async throws {
        // A lowercase word ending in "mp" still needs the literal uppercase
        // Motion Photo filename suffix. Reuse the ordinary conversion cases.
        let input = directory.appendingPathComponent("lamp.jpg")
        try FileManager.default.copyItem(at: fixture("google-modern"), to: input)
        let original = try Data(contentsOf: input)
        for format in androidFormats {
            let result = try await MotionPhotoConverter.convert(
                sourceURL: input, destinationDirectory: directory,
                options: ConversionOptions(outputFormat: format))
            _ = try await inspectAndroidExport(result, format: format,
                                               expectedTimestamp: 1_500_000,
                                               expectedDuration: 3, expectedAudioTracks: 1)
            XCTAssertEqual(result.photoURL.lastPathComponent, "lamp_MP.jpg")
            let report = try readReport(result)
            XCTAssertEqual(report["sourceFormat"] as? String, MotionPhotoSourceFormat.googleMotionPhoto.rawValue)
            XCTAssertEqual(report["outputFormat"] as? String, format.rawValue)
            XCTAssertEqual(report["audioIncluded"] as? Bool, true)
            XCTAssertNil(report["video"], "Android reports must not advertise a separate output movie")
            XCTAssertNil(report["identifier"], "Android outputs must not retain an Apple pairing identifier")
            XCTAssertEqual(try Data(contentsOf: input), original)
        }
        XCTAssertFalse(try contents(of: directory).contains { $0.hasPrefix(".motionphotobridge-") })
    }

    func testSamsungFixtureExportsGoogleWithAnExplicitFallbackTimestamp() async throws {
        let input = try fixture("samsung-sef")
        let original = try Data(contentsOf: input)
        let result = try await MotionPhotoConverter.convert(
            sourceURL: input, destinationDirectory: directory,
            options: ConversionOptions(outputFormat: .googleMotionPhoto))
        _ = try await inspectAndroidExport(result, format: .googleMotionPhoto,
                                           expectedTimestamp: 1_500_000,
                                           expectedDuration: 3, expectedAudioTracks: 1)
        XCTAssertTrue(result.warnings.contains { $0.contains("no key-photo timestamp") })
        XCTAssertEqual(try readReport(result)["sourceFormat"] as? String,
                       MotionPhotoSourceFormat.samsungMotionPhoto.rawValue)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testDetectedApplePairConvertsToBothAndroidFormatsWithoutChangingEitherResource() async throws {
        let input = directory.appendingPathComponent("already_MP.jpg")
        try FileManager.default.copyItem(at: fixture("google-modern"), to: input)
        let apple = try await MotionPhotoConverter.convert(
            sourceURL: input, destinationDirectory: directory,
            options: ConversionOptions(outputFormat: .appleLivePhoto))
        let appleVideo = try XCTUnwrap(apple.videoURL)
        let originalImage = try Data(contentsOf: apple.photoURL)
        let originalVideo = try Data(contentsOf: appleVideo)

        // Exercise the same detected-source conversion entry point the app uses.
        // Pairing edge cases are covered separately by the detector tests.
        let detections = await MotionSourceDetector.detect(urls: [apple.photoURL, appleVideo])
        let source = try XCTUnwrap(detections.compactMap(\.source).first)
        XCTAssertEqual(source.format, .appleLivePhoto)

        for format in androidFormats {
            let result = try await MotionPhotoConverter.convert(
                source: source, destinationDirectory: directory,
                options: ConversionOptions(outputFormat: format))
            _ = try await inspectAndroidExport(result, format: format,
                                               expectedTimestamp: 1_500_000,
                                               expectedDuration: 3, expectedAudioTracks: 1)
            XCTAssertEqual(result.photoURL.lastPathComponent, "already_MP.jpg",
                           "An existing uppercase MP suffix must not be duplicated")
            XCTAssertEqual(result.creationDate, apple.creationDate)
            let report = try readReport(result)
            XCTAssertEqual(report["sourceFormat"] as? String, MotionPhotoSourceFormat.appleLivePhoto.rawValue)
            XCTAssertEqual(report["sourceVideo"] as? String, appleVideo.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: apple.photoURL), originalImage,
                           "Converting away from Apple must not rewrite the source JPEG")
            XCTAssertEqual(try Data(contentsOf: appleVideo), originalVideo,
                           "Converting away from Apple must not rewrite the paired MOV")
        }
        XCTAssertEqual(try contents(of: apple.directoryURL),
                       ["conversion.json", apple.photoURL.lastPathComponent, appleVideo.lastPathComponent].sorted())
    }

    func testMutedFullLengthAndroidExportsRetainPortraitOrientation() async throws {
        let input = try fixture("rotated-google")
        for format in androidFormats {
            let result = try await MotionPhotoConverter.convert(
                sourceURL: input, destinationDirectory: directory,
                options: ConversionOptions(includeAudio: false, trimToThreeSeconds: false, outputFormat: format))
            let asset = try await inspectAndroidExport(result, format: format,
                                                       expectedTimestamp: 2_000_000,
                                                       expectedDuration: 4, expectedAudioTracks: 0)
            XCTAssertEqual(try readReport(result)["audioIncluded"] as? Bool, false)
            let properties = try imageProperties(result.photoURL)
            XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 6)

            // Decode through a display-oriented API, independently of checking
            // the stored transform's matrix or the converter's compositor.
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let displayedFrame = try generator.copyCGImage(at: CMTime(value: 1, timescale: 10), actualTime: nil)
            XCTAssertEqual(displayedFrame.width, 240)
            XCTAssertEqual(displayedFrame.height, 320)
        }
    }

    func testPhotosImporterRejectsAndroidBeforeOpeningFilesOrRequestingPermission() async throws {
        let authorizationBefore = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        for format in androidFormats {
            // Deliberately nonexistent URLs ensure the format guard executes
            // before media inspection. Supplying an accidental video URL also
            // proves that the guard checks format, not only videoURL != nil.
            for unexpectedVideo in [nil, directory.appendingPathComponent("does-not-exist.mov")] as [URL?] {
                let result = ConversionResult(
                    directoryURL: directory,
                    photoURL: directory.appendingPathComponent("does-not-exist.jpg"),
                    videoURL: unexpectedVideo, warnings: [], creationDate: nil,
                    outputFormat: format)
                do {
                    try await PhotosImporter.importPair(result)
                    XCTFail("Android output must not be sent to Apple Photos as a Live Photo")
                } catch ConversionError.unsupportedPhotosImport {
                    // Expected without file reads, an authorization prompt, or a transaction.
                } catch {
                    XCTFail("Expected unsupportedPhotosImport before any other operation; received \(error)")
                }
            }
        }
        XCTAssertEqual(PHPhotoLibrary.authorizationStatus(for: .addOnly), authorizationBefore)
        XCTAssertEqual(try contents(of: directory), [])
    }

    func testCancellationAfterMotionJPEGIsWrittenRemovesEveryStagedFile() async throws {
        let input = try fixture("google-modern")
        let original = try Data(contentsOf: input)
        for format in androidFormats {
            let destination = directory.appendingPathComponent("cancel-\(format.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let cancellation = BidirectionalCancellation()
            let operation = Task {
                try await MotionPhotoConverter.convert(
                    sourceURL: input, destinationDirectory: destination,
                    options: ConversionOptions(outputFormat: format)
                ) { progress, _ in
                    if progress >= 0.95 && progress < 1 {
                        cancellation.recordStagedMotionPhoto(Self.containsMotionJPEG(in: destination))
                        cancellation.cancel()
                    }
                }
            }
            cancellation.attach { operation.cancel() }
            do {
                _ = try await operation.value
                XCTFail("The operation must stop before publishing the staged output")
            } catch is CancellationError {
                XCTAssertTrue(cancellation.observedStagedMotionPhoto,
                              "This must exercise late cancellation after a valid embedded-motion JPEG was written")
                XCTAssertEqual(try contents(of: destination), [],
                               "Cancellation must remove the JPEG, encoded movie, extracted source, and staging directory")
            }
            XCTAssertEqual(try Data(contentsOf: input), original)
        }
    }

    /// Inspect the actual file returned to the user, then extract its movie to a
    /// test-only path for independent AVFoundation checks. The export directory
    /// must contain only the final JPEG and report, including hidden entries.
    private func inspectAndroidExport(_ result: ConversionResult, format: MotionPhotoOutputFormat,
                                      expectedTimestamp: Int64, expectedDuration: Double,
                                      expectedAudioTracks: Int) async throws -> AVURLAsset {
        XCTAssertEqual(result.outputFormat, format)
        XCTAssertNil(result.videoURL)
        XCTAssertFalse(result.supportsPhotosImport)
        XCTAssertEqual(try contents(of: result.directoryURL),
                       ["conversion.json", result.photoURL.lastPathComponent].sorted())
        XCTAssertEqual(result.photoURL.pathExtension.lowercased(), "jpg")
        XCTAssertTrue(result.photoURL.deletingPathExtension().lastPathComponent.hasSuffix("MP"))

        let data = try Data(contentsOf: result.photoURL)
        let payload = try MotionPhotoParser.parse(data: data)
        XCTAssertEqual(payload.format, format == .googleMotionPhoto ? .googleMotionPhoto : .samsungMotionPhoto)
        XCTAssertEqual(payload.presentationTimeMicroseconds, expectedTimestamp)
        let movie = data.subdata(in: payload.videoRange)
        XCTAssertGreaterThan(movie.count, 16)
        XCTAssertEqual(movie.subdata(in: 4..<8), Data("ftyp".utf8))
        XCTAssertNotEqual(movie.subdata(in: 8..<12), Data("qt  ".utf8), "The embedded container must be MPEG-4, not a renamed QuickTime movie")

        let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(image, 0, nil), "The exported JPEG must remain decodable with its embedded video")
        let properties = try imageProperties(result.photoURL)
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue, 320)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue, 240)
        XCTAssertNil((properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])?["17"])

        let extracted = directory.appendingPathComponent("inspection-\(UUID().uuidString).mp4")
        try movie.write(to: extracted)
        let asset = AVURLAsset(url: extracted)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
        let metadata = try await asset.load(.metadata)
        XCTAssertEqual(duration.seconds, expectedDuration, accuracy: 0.08)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, expectedAudioTracks)
        XCTAssertTrue(metadataTracks.isEmpty, "Android motion must not retain an Apple still-image timing track")
        XCTAssertFalse(metadata.contains { ($0.key as? String) == "com.apple.quicktime.content.identifier" })
        let track = try XCTUnwrap(videoTracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        XCTAssertTrue(descriptions.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 })
        return asset
    }

    private static func containsMotionJPEG(in directory: URL) -> Bool {
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in entries where url.pathExtension.lowercased() == "jpg" {
            if let data = try? Data(contentsOf: url), (try? MotionPhotoParser.parse(data: data)) != nil { return true }
        }
        return false
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "jpg", subdirectory: "Fixtures"))
    }

    private func contents(of url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    private func readReport(_ result: ConversionResult) throws -> [String: Any] {
        let data = try Data(contentsOf: result.directoryURL.appendingPathComponent("conversion.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func imageProperties(_ url: URL) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }
}

private final class BidirectionalCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var requested = false
    private var stagedMotionPhoto = false

    var observedStagedMotionPhoto: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stagedMotionPhoto
    }

    func recordStagedMotionPhoto(_ observed: Bool) {
        lock.lock()
        stagedMotionPhoto = stagedMotionPhoto || observed
        lock.unlock()
    }

    func attach(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        self.action = action
        let alreadyRequested = requested
        lock.unlock()
        if alreadyRequested { action() }
    }

    func cancel() {
        lock.lock()
        requested = true
        let current = action
        lock.unlock()
        current?()
    }
}
