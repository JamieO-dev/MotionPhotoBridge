import XCTest
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import MotionPhotoCore
@testable import LivePhotoEngine

/// Runs on macOS. Uses generated colour patterns and a sine wave, not personal
/// media. Tests decode and inspect output; they never import into a Photos library.
final class ConversionIntegrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MotionPhotoBridge-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testRealEncodedFixturesHaveReadableMovies() async throws {
        for name in ["google-modern", "google-legacy", "samsung-sef", "rotated-google"] {
            let data = try Data(contentsOf: fixture(name))
            let payload = try MotionPhotoParser.parse(data: data)
            let movie = directory.appendingPathComponent(name + ".mp4")
            try data.subdata(in: payload.videoRange).write(to: movie)
            let asset = AVURLAsset(url: movie)
            let duration = try await asset.load(.duration)
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(duration.seconds, 4, accuracy: 0.1)
            XCTAssertEqual(videos.count, 1)
            XCTAssertEqual(audio.count, 1)
        }
    }

    func testModernPhotoProducesLinkedThreeSecondLivePhoto() async throws {
        let source = try fixture("google-modern")
        let original = try Data(contentsOf: source)
        let result = try await LivePhotoConverter.convert(sourceURL: source, destinationDirectory: directory)
        let asset = AVURLAsset(url: try XCTUnwrap(result.videoURL))
        let duration = try await asset.load(.duration)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(duration.seconds, 3, accuracy: 0.08)
        XCTAssertEqual(audio.count, 1)
        XCTAssertEqual(try Data(contentsOf: source), original, "Converting must never edit the source")
        XCTAssertEqual(try contents(of: result.directoryURL), ["conversion.json", "google-modern.jpg", "google-modern.mov"])
        let report = try readReport(result)
        XCTAssertEqual(report["audioIncluded"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(report["keyPhotoTime"] as? Double), 1.5, accuracy: 0.04)
        let expectedDate = ISO8601DateFormatter().date(from: "2024-02-29T12:34:56Z")
        XCTAssertEqual(result.creationDate, expectedDate)
        let properties = try imageProperties(result.photoURL)
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue, 320)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue, 240)
        XCTAssertNotNil((properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])?["17"])
    }

    func testLegacyFullClipCanBeMuted() async throws {
        let result = try await LivePhotoConverter.convert(
            sourceURL: fixture("google-legacy"), destinationDirectory: directory,
            options: ConversionOptions(includeAudio: false, trimToThreeSeconds: false))
        let asset = AVURLAsset(url: try XCTUnwrap(result.videoURL))
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(duration.seconds, 4, accuracy: 0.08)
        XCTAssertTrue(tracks.isEmpty)
        XCTAssertEqual(try readReport(result)["audioIncluded"] as? Bool, false)
    }

    func testSamsungSEFUsesOriginalStillAndTimingFallback() async throws {
        let result = try await LivePhotoConverter.convert(sourceURL: fixture("samsung-sef"), destinationDirectory: directory)
        XCTAssertTrue(result.warnings.contains { $0.contains("no key-photo timestamp") })
        XCTAssertEqual(try readReport(result)["format"] as? String, MotionPhotoFormat.samsungMotionPhoto.rawValue)
    }

    func testPortraitOrientationSurvivesConversion() async throws {
        let result = try await LivePhotoConverter.convert(sourceURL: fixture("rotated-google"), destinationDirectory: directory)
        let asset = AVURLAsset(url: try XCTUnwrap(result.videoURL))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let transform = try await track.load(.preferredTransform)
        let size = try await track.load(.naturalSize)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        XCTAssertEqual(abs(bounds.width), 240, accuracy: 1)
        XCTAssertEqual(abs(bounds.height), 320, accuracy: 1)
        XCTAssertEqual((try imageProperties(result.photoURL)[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 6)
    }

    func testHEICWithMPVDBoxWhenEncoderIsAvailable() async throws {
        let modern = try Data(contentsOf: fixture("google-modern"))
        let payload = try MotionPhotoParser.parse(data: modern)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(modern as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let sourceURL = directory.appendingPathComponent("synthetic-motion.heic")
        guard let encoder = CGImageDestinationCreateWithURL(sourceURL as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw XCTSkip("This runner cannot encode HEIC fixtures.")
        }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw XCTSkip("The runner's HEIC encoder was unavailable.") }
        var container = try Data(contentsOf: sourceURL)
        let movie = modern.subdata(in: payload.videoRange)
        let size = UInt32(movie.count + 8)
        container.append(contentsOf: [UInt8(truncatingIfNeeded: size >> 24), UInt8(truncatingIfNeeded: size >> 16),
                                     UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)])
        container.append(Data("mpvd".utf8))
        container.append(movie)
        try container.write(to: sourceURL)
        let result = try await LivePhotoConverter.convert(sourceURL: sourceURL, destinationDirectory: directory)
        XCTAssertEqual(try readReport(result)["format"] as? String, MotionPhotoFormat.heifMotionPhoto.rawValue)
    }

    func testCancellationBeforePublishRemovesPartialOutput() async throws {
        let source = try fixture("google-modern")
        let destination = try XCTUnwrap(directory)
        let handle = CancellationHandle()
        let task = Task {
            try await LivePhotoConverter.convert(sourceURL: source, destinationDirectory: destination) { progress, _ in
                if progress >= 0.88 { handle.cancel() }
            }
        }
        handle.attach { task.cancel() }
        do {
            _ = try await task.value
            XCTFail("Conversion should have been cancelled before publishing")
        } catch is CancellationError {
            XCTAssertEqual(try contents(of: destination), [])
        }
    }

    func testStrippedVideoFailsWithoutLeavingOutput() async throws {
        let original = try Data(contentsOf: fixture("google-modern"))
        let payload = try MotionPhotoParser.parse(data: original)
        let source = directory.appendingPathComponent("stripped.jpg")
        try original.prefix(payload.videoRange.lowerBound).write(to: source)
        do {
            _ = try await LivePhotoConverter.convert(sourceURL: source, destinationDirectory: directory)
            XCTFail("A still image cannot create missing motion")
        } catch is MotionPhotoError {
            XCTAssertEqual(try contents(of: directory), ["stripped.jpg"])
        }
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

private final class CancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var requested = false

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
