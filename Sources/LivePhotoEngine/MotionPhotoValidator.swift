import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import ImageIO
import MotionPhotoCore

enum MotionPhotoValidator {
    static func validate(photoURL: URL, encodedVideoURL: URL,
                         expectedFormat: MotionPhotoOutputFormat,
                         expectedTimestampMicroseconds: Int64) async throws {
        try Task.checkCancellation()
        let data = try Data(contentsOf: photoURL, options: .mappedIfSafe)
        let payload = try MotionPhotoParser.parse(data: data)
        let expected: MotionPhotoFormat = expectedFormat == .googleMotionPhoto ? .googleMotionPhoto : .samsungMotionPhoto
        guard payload.format == expected else {
            throw ConversionError.invalidMotionPhoto("The output container does not match the selected format.")
        }
        guard payload.presentationTimeMicroseconds == expectedTimestampMicroseconds else {
            throw ConversionError.invalidMotionPhoto("The key-photo timestamp was not written correctly.")
        }
        // Check on-disk payload bytes against the actual encoded movie, then
        // independently decode the still and an H.264 frame with Apple APIs.
        let expectedMovie = try Data(contentsOf: encodedVideoURL, options: .mappedIfSafe)
        guard data.subdata(in: payload.videoRange) == expectedMovie else {
            throw ConversionError.invalidMotionPhoto("The embedded movie differs from the encoded video.")
        }
        let thumbnailOptions: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: 320,
            kCGImageSourceShouldCacheImmediately as String: true
        ]
        guard let image = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
              CGImageSourceCreateThumbnailAtIndex(image, 0, thumbnailOptions as CFDictionary) != nil else {
            throw ConversionError.invalidMotionPhoto("The output still image could not be decoded.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any] ?? [:]
        if let apple = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any], apple["17"] != nil {
            throw ConversionError.invalidMotionPhoto("The output still retains an obsolete Apple pairing identifier.")
        }
        let asset = AVURLAsset(url: encodedVideoURL)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
        let metadata = try await asset.load(.metadata)
        guard duration.isNumeric, duration.seconds > 0,
              Double(expectedTimestampMicroseconds) / 1_000_000 < duration.seconds,
              let videoTrack = videoTracks.first else {
            throw ConversionError.invalidMotionPhoto("The embedded video or its key-photo time is invalid.")
        }
        guard metadataTracks.isEmpty,
              !metadata.contains(where: { ($0.key as? String) == MovieWriter.contentIdentifierKey }) else {
            throw ConversionError.invalidMotionPhoto("Apple-specific movie metadata was not removed.")
        }
        let formats = try await videoTrack.load(.formatDescriptions)
        guard formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }) else {
            throw ConversionError.invalidMotionPhoto("Expected H.264 video in the MP4 container.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        guard reader.canAdd(output) else {
            throw ConversionError.invalidMotionPhoto("The embedded video is not readable.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ConversionError.invalidMotionPhoto(reader.error?.localizedDescription ?? "The embedded video could not be opened.")
        }
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(), CMSampleBufferGetImageBuffer(sample) != nil else {
            throw ConversionError.invalidMotionPhoto(reader.error?.localizedDescription ?? "The embedded video has no decodable frames.")
        }
        try Task.checkCancellation()
    }
}
