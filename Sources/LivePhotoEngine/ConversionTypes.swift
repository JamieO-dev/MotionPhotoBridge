import Foundation

public enum MotionPhotoOutputFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case appleLivePhoto
    case googleMotionPhoto
    case samsungMotionPhoto

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleLivePhoto: return "Apple Live Photo"
        case .googleMotionPhoto: return "Google Motion Photo"
        case .samsungMotionPhoto: return "Samsung Motion Photo"
        }
    }

    public var fileDescription: String {
        switch self {
        case .appleLivePhoto: return "JPEG + MOV pair"
        case .googleMotionPhoto: return "One JPEG with embedded MP4"
        case .samsungMotionPhoto: return "One JPEG with Samsung motion data"
        }
    }

    var folderSuffix: String {
        self == .appleLivePhoto ? "Live Photo" : displayName
    }
}

public enum MotionPhotoSourceFormat: String, Codable, Sendable {
    case appleLivePhoto
    case googleMotionPhoto
    case googleMicroVideo
    case samsungMotionPhoto
    case heifMotionPhoto
    case recoveredMotionPhoto

    public var displayName: String {
        switch self {
        case .appleLivePhoto: return "Apple Live Photo"
        case .googleMotionPhoto: return "Google Motion Photo"
        case .googleMicroVideo: return "Google Motion Photo (legacy)"
        case .samsungMotionPhoto: return "Samsung Motion Photo"
        case .heifMotionPhoto: return "HEIF Motion Photo"
        case .recoveredMotionPhoto: return "Recovered Motion Photo"
        }
    }

    public var outputFormat: MotionPhotoOutputFormat? {
        switch self {
        case .appleLivePhoto: return .appleLivePhoto
        case .googleMotionPhoto, .googleMicroVideo: return .googleMotionPhoto
        case .samsungMotionPhoto: return .samsungMotionPhoto
        case .heifMotionPhoto, .recoveredMotionPhoto: return nil
        }
    }
}

public struct MotionPhotoSource: Sendable {
    public let imageURL: URL
    public let pairedVideoURL: URL?
    public let format: MotionPhotoSourceFormat
    public let presentationTimeMicroseconds: Int64?
    public let warnings: [String]

    public init(imageURL: URL, pairedVideoURL: URL? = nil, format: MotionPhotoSourceFormat,
                presentationTimeMicroseconds: Int64? = nil, warnings: [String] = []) {
        self.imageURL = imageURL
        self.pairedVideoURL = pairedVideoURL
        self.format = format
        self.presentationTimeMicroseconds = presentationTimeMicroseconds
        self.warnings = warnings
    }

    public var resourceURLs: [URL] {
        [imageURL] + (pairedVideoURL.map { [$0] } ?? [])
    }
}

public struct SourceDetectionResult: Sendable {
    public let inputURL: URL
    public let source: MotionPhotoSource?
    public let errorMessage: String?

    public init(inputURL: URL, source: MotionPhotoSource?, errorMessage: String?) {
        self.inputURL = inputURL
        self.source = source
        self.errorMessage = errorMessage
    }
}

public struct ConversionOptions: Sendable {
    public var includeAudio: Bool
    public var trimToThreeSeconds: Bool
    public var outputFormat: MotionPhotoOutputFormat

    public init(includeAudio: Bool = true, trimToThreeSeconds: Bool = true,
                outputFormat: MotionPhotoOutputFormat = .appleLivePhoto) {
        self.includeAudio = includeAudio
        self.trimToThreeSeconds = trimToThreeSeconds
        self.outputFormat = outputFormat
    }
}

public struct ConversionResult: Sendable {
    public let directoryURL: URL
    public let photoURL: URL
    public let videoURL: URL?
    public let outputFormat: MotionPhotoOutputFormat
    public let warnings: [String]
    public let creationDate: Date?

    public init(directoryURL: URL, photoURL: URL, videoURL: URL?,
                warnings: [String], creationDate: Date?,
                outputFormat: MotionPhotoOutputFormat = .appleLivePhoto) {
        self.directoryURL = directoryURL
        self.photoURL = photoURL
        self.videoURL = videoURL
        self.warnings = warnings
        self.creationDate = creationDate
        self.outputFormat = outputFormat
    }

    public var supportsPhotosImport: Bool { outputFormat == .appleLivePhoto && videoURL != nil }
}

public enum ConversionError: LocalizedError {
    case invalidSource(String)
    case invalidDestination
    case imageUnreadable
    case imageTooLarge
    case imageWriteFailed
    case videoUnreadable(String)
    case encodingFailed(String)
    case invalidLivePhoto(String)
    case invalidMotionPhoto(String)
    case unsupportedPhotosImport
    case photosPermissionDenied
    case photosImportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSource(let message): return message
        case .invalidDestination:
            return "Choose an existing folder where you can save the converted photos."
        case .imageUnreadable:
            return "macOS couldn’t decode the still image. Try an original JPEG or HEIC file, or update macOS for newer image codecs."
        case .imageTooLarge:
            return "This image is too large to convert safely (maximum 250 megapixels and 32,768 pixels per side)."
        case .imageWriteFailed:
            return "The JPEG couldn’t be written. Check the destination’s free space and permissions."
        case .videoUnreadable(let message):
            return "The motion video couldn’t be read. \(message)"
        case .encodingFailed(let message):
            return "The motion video couldn’t be encoded. \(message)"
        case .invalidLivePhoto(let message):
            return "The converted pair didn’t pass validation. \(message)"
        case .invalidMotionPhoto(let message):
            return "The converted Motion Photo didn’t pass validation. \(message)"
        case .unsupportedPhotosImport:
            return "Choose Apple Live Photo output to add moving photos to Apple Photos. Google and Samsung outputs are saved as Motion Photo JPEG files."
        case .photosPermissionDenied:
            return "Photos access wasn’t granted. The exported files are safe. Allow MotionPhotoBridge in System Settings → Privacy & Security → Photos, then retry importing."
        case .photosImportFailed(let message):
            return "The pair was exported, but Photos couldn’t import it. \(message)"
        }
    }
}

/// A bounded interval in the original video's presentation timeline.
/// All metadata and media samples use this same timeline until the media writer
/// maps `start` to zero; trimming must never shift the key photo independently.
struct ClipTiming {
    let start: Double
    let duration: Double
    let keyTime: Double
    let frameDuration: Double
    let warnings: [String]

    var end: Double { start + duration }
    var outputKeyTime: Double { keyTime - start }

    static func make(sourceStart: Double, sourceDuration: Double,
                     timestampMicroseconds: Int64?, framesPerSecond: Double,
                     trim: Bool) throws -> ClipTiming {
        guard sourceStart.isFinite, sourceStart >= 0,
              sourceDuration.isFinite, sourceDuration >= 1.0 / 600, sourceDuration <= 120 else {
            throw ConversionError.videoUnreadable("Expected a video between one frame and two minutes long.")
        }
        let fps = framesPerSecond.isFinite && framesPerSecond >= 1
            ? min(framesPerSecond, 60) : 30
        let frame = min(1 / fps, sourceDuration)
        let lastFrame = max(sourceStart, sourceStart + sourceDuration - frame)
        let midpoint = sourceStart + sourceDuration / 2
        var warnings: [String] = []
        var key: Double
        if let timestampMicroseconds, timestampMicroseconds >= 0 {
            let supplied = Double(timestampMicroseconds) / 1_000_000
            if supplied >= sourceStart && supplied < sourceStart + sourceDuration {
                key = supplied
            } else {
                key = midpoint
                warnings.append("The key-photo timestamp was outside the video. The middle frame was used for timing.")
            }
        } else {
            key = midpoint
            warnings.append("The source has no key-photo timestamp. The middle frame was used for timing; the original still photo was kept.")
        }
        // Quantize to the compositor's frame grid, including variable-rate sources.
        key = sourceStart + floor((key - sourceStart) / frame) * frame
        key = min(max(key, sourceStart), lastFrame)
        let duration = trim ? min(3, sourceDuration) : sourceDuration
        var start = min(max(key - duration / 2, sourceStart), sourceStart + sourceDuration - duration)
        // Prefer a real frame boundary without extending past the source.
        start = sourceStart + floor(max(0, start - sourceStart) / frame) * frame
        start = max(sourceStart, min(start, sourceStart + sourceDuration - duration))
        return ClipTiming(start: start, duration: duration, keyTime: key,
                          frameDuration: frame, warnings: warnings)
    }
}
