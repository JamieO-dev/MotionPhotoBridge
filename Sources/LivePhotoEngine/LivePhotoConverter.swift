import Foundation
import MotionPhotoCore

/// Compatibility entry point for the original Apple-output API.
public enum LivePhotoConverter {
    public static func convert(sourceURL: URL, destinationDirectory: URL,
                               options: ConversionOptions = ConversionOptions(),
                               progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws -> ConversionResult {
        try await MotionPhotoConverter.convert(sourceURL: sourceURL, destinationDirectory: destinationDirectory,
                                               options: options, progress: progress)
    }
}

public enum MotionPhotoConverter {
    /// Detect a standalone Motion Photo or an Apple pair beside the chosen file.
    public static func convert(sourceURL: URL, candidateURLs: [URL] = [], destinationDirectory: URL,
                               options: ConversionOptions = ConversionOptions(),
                               progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws -> ConversionResult {
        try Task.checkCancellation()
        progress(0.01, "Detecting the source format")
        let source = try await MotionSourceDetector.detect(sourceURL: sourceURL, candidateURLs: candidateURLs)
        return try await convert(source: source, destinationDirectory: destinationDirectory,
                                 options: options, progress: progress)
    }

    /// Converts any supported source to one of the three output formats.
    /// Input pairing is rechecked when a queued item starts, then staged output is
    /// published only after media, metadata, and container validation succeeds.
    public static func convert(source: MotionPhotoSource, destinationDirectory: URL,
                               options: ConversionOptions = ConversionOptions(),
                               progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws -> ConversionResult {
        try Task.checkCancellation()
        let scopeURLs = Array(Set(source.resourceURLs + [destinationDirectory]))
        let scopes = scopeURLs.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer {
            for (url, active) in scopes where active { url.stopAccessingSecurityScopedResource() }
        }
        progress(0.02, "Checking the source photo")
        let current = try await MotionSourceDetector.detect(sourceURL: source.imageURL,
                                                            candidateURLs: source.resourceURLs)
        for url in current.resourceURLs { try checkInputFile(url) }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: destinationDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue, fm.isWritableFile(atPath: destinationDirectory.path) else {
            throw ConversionError.invalidDestination
        }
        let imageData = try Data(contentsOf: current.imageURL, options: .mappedIfSafe)
        try Task.checkCancellation()
        let identifier = UUID().uuidString
        let stage = destinationDirectory.appendingPathComponent(".motionphotobridge-\(identifier)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        var published = false
        defer { if !published { try? fm.removeItem(at: stage) } }

        let basename = safeName(current.imageURL.deletingPathExtension().lastPathComponent)
        let isApple = options.outputFormat == .appleLivePhoto
        let photoName = isApple ? basename + ".jpg"
            : (basename.hasSuffix("MP") ? basename : basename + "_MP") + ".jpg"
        let movieName = isApple ? basename + ".mov" : nil
        let finalPhotoURL = stage.appendingPathComponent(photoName)
        let stillURL = isApple ? finalPhotoURL : stage.appendingPathComponent(".still.jpg")
        let encodedVideoURL = stage.appendingPathComponent(movieName ?? ".encoded.mp4")
        var extractedSourceURL: URL?
        let sourceVideoURL: URL
        var inputTimestamp = current.presentationTimeMicroseconds
        var sourceWarnings = current.warnings
        if let pairedVideo = current.pairedVideoURL {
            sourceVideoURL = pairedVideo
        } else {
            let payload = try MotionPhotoParser.parse(data: imageData)
            let extracted = stage.appendingPathComponent(".source.mp4")
            try imageData.subdata(in: payload.videoRange).write(to: extracted, options: .atomic)
            extractedSourceURL = extracted
            sourceVideoURL = extracted
            inputTimestamp = payload.presentationTimeMicroseconds
            sourceWarnings += payload.warnings
        }

        progress(0.08, "Preparing the original still photo")
        let still = try autoreleasepool {
            try StillImageWriter.write(data: imageData, to: stillURL, identifier: isApple ? identifier : nil)
        }
        try Task.checkCancellation()
        let movie = try await MovieWriter.write(sourceURL: sourceVideoURL, outputURL: encodedVideoURL,
                                               identifier: identifier, creationDate: still.creationDate,
                                               timestampMicroseconds: inputTimestamp,
                                               options: options) { fraction in
            progress(0.15 + fraction * 0.73, "Encoding motion for \(options.outputFormat.displayName)")
        }
        try Task.checkCancellation()
        if isApple {
            progress(0.90, "Checking the linked photo and video")
            try await LivePhotoValidator.validate(photoURL: stillURL, videoURL: encodedVideoURL,
                                                  identifier: identifier, expectedKeyTime: movie.timing.outputKeyTime)
        } else {
            progress(0.90, "Creating the Motion Photo file")
            // JPEG pixels and MP4 bytes are already final. The container writer
            // only inserts XMP and wraps the MPEG-4 payload in the chosen layout.
            let jpeg = try Data(contentsOf: stillURL, options: .mappedIfSafe)
            let video = try Data(contentsOf: encodedVideoURL, options: .mappedIfSafe)
            let timestamp = Int64((movie.timing.outputKeyTime * 1_000_000).rounded())
            let encoding: MotionPhotoEncoding = options.outputFormat == .googleMotionPhoto ? .google : .samsung
            let output = try MotionPhotoWriter.make(jpeg: jpeg, video: video,
                                                    presentationTimeMicroseconds: timestamp, format: encoding)
            try Task.checkCancellation()
            try output.write(to: finalPhotoURL, options: .atomic)
            progress(0.95, "Checking the Motion Photo container")
            try await MotionPhotoValidator.validate(photoURL: finalPhotoURL,
                                                    encodedVideoURL: encodedVideoURL,
                                                    expectedFormat: options.outputFormat,
                                                    expectedTimestampMicroseconds: timestamp)
            try fm.removeItem(at: stillURL)
            try fm.removeItem(at: encodedVideoURL)
        }
        if let extractedSourceURL { try fm.removeItem(at: extractedSourceURL) }
        var seenWarnings: Set<String> = []
        let warnings = (sourceWarnings + still.warnings + movie.warnings).filter { seenWarnings.insert($0).inserted }
        let report = ConversionReport(source: current.imageURL.lastPathComponent,
                                      sourceVideo: current.pairedVideoURL?.lastPathComponent,
                                      format: current.format.displayName,
                                      sourceFormat: current.format, outputFormat: options.outputFormat,
                                      identifier: isApple ? identifier : nil,
                                      photo: photoName, video: movieName,
                                      creationDate: still.creationDate, clipStart: movie.timing.start,
                                      clipDuration: movie.timing.duration,
                                      keyPhotoTime: movie.timing.outputKeyTime,
                                      audioIncluded: movie.audioIncluded, warnings: warnings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: stage.appendingPathComponent("conversion.json"), options: .atomic)
        try Task.checkCancellation()
        let finalURL = destinationDirectory.appendingPathComponent(
            "\(basename) - \(options.outputFormat.folderSuffix) \(identifier.prefix(8))", isDirectory: true)
        try fm.moveItem(at: stage, to: finalURL)
        published = true
        progress(1, "\(options.outputFormat.displayName) exported")
        return ConversionResult(directoryURL: finalURL,
                                photoURL: finalURL.appendingPathComponent(photoName),
                                videoURL: movieName.map { finalURL.appendingPathComponent($0) },
                                warnings: warnings, creationDate: still.creationDate,
                                outputFormat: options.outputFormat)
    }

    private static func checkInputFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw ConversionError.invalidSource("Choose original Motion Photo files or an Apple Live Photo’s original image and MOV.")
        }
        guard let size = values.fileSize, size > 0, size <= 1_073_741_824 else {
            throw ConversionError.invalidSource("A source file is empty or larger than the 1 GB safety limit.")
        }
    }

    private static func safeName(_ original: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))
        let filtered = original.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
        let trimmed = filtered.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var name = ""
        for character in trimmed {
            let next = String(character)
            guard name.utf8.count + next.utf8.count <= 140 else { break }
            name += next
        }
        return name.isEmpty ? "Motion Photo" : name
    }
}

private struct ConversionReport: Encodable {
    let appVersion = "2.0.1"
    let source: String
    let sourceVideo: String?
    let format: String
    let sourceFormat: MotionPhotoSourceFormat
    let outputFormat: MotionPhotoOutputFormat
    let identifier: String?
    let photo: String
    let video: String?
    let creationDate: Date?
    let clipStart: Double
    let clipDuration: Double
    let keyPhotoTime: Double
    let audioIncluded: Bool
    let warnings: [String]
    let imageEncoding = "JPEG, sRGB, quality 0.98; original pixel dimensions"
    let videoEncoding = "H.264, BT.709 SDR, up to 3840×2160 and 60 fps"
}
