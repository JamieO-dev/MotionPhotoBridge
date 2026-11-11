import Foundation
import AVFoundation
import ImageIO
import CoreVideo

enum LivePhotoValidator {
    /// Check the files on disk without requesting access to the Photos library.
    /// Actual PhotoKit ingestion occurs only when the user chooses to import.
    static func validate(photoURL: URL, videoURL: URL, identifier: String? = nil,
                         expectedKeyTime: Double? = nil) async throws {
        try Task.checkCancellation()
        guard let imageSource = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
              let apple = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
              let photoIdentifier = apple["17"] as? String, !photoIdentifier.isEmpty else {
            throw ConversionError.invalidLivePhoto("The JPEG is missing its Apple pairing identifier.")
        }
        if let identifier, photoIdentifier != identifier {
            throw ConversionError.invalidLivePhoto("The JPEG’s pairing identifier changed during export.")
        }
        let thumbnailOptions: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: 320,
            kCGImageSourceShouldCacheImmediately as String: true
        ]
        guard CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) != nil else {
            throw ConversionError.invalidLivePhoto("The exported JPEG could not be decoded.")
        }
        let asset = AVURLAsset(url: videoURL)
        let metadata = try await asset.load(.metadata)
        var movieIdentifier: String?
        for item in metadata where item.keySpace == .quickTimeMetadata &&
            (item.key as? String) == MovieWriter.contentIdentifierKey {
            movieIdentifier = try await item.load(.stringValue)
        }
        guard movieIdentifier == photoIdentifier else {
            throw ConversionError.invalidLivePhoto("The JPEG and MOV identifiers do not match.")
        }
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isNumeric, duration.seconds > 0, duration.seconds <= 121,
              let videoTrack = videoTracks.first else {
            throw ConversionError.invalidLivePhoto("The movie has no playable video duration.")
        }
        let formats = try await videoTrack.load(.formatDescriptions)
        guard formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }) else {
            throw ConversionError.invalidLivePhoto("The exported video is not H.264.")
        }
        try validateVideoFrame(asset: asset, track: videoTrack)
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        var markerTimes: [Double] = []
        for track in tracks {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else {
                throw ConversionError.invalidLivePhoto("The timing track could not be read.")
            }
            defer { reader.cancelReading() }
            var groupCount = 0
            while let group = adaptor.nextTimedMetadataGroup() {
                try Task.checkCancellation()
                groupCount += 1
                guard groupCount <= 10_000 else {
                    throw ConversionError.invalidLivePhoto("The timing track contains too many samples.")
                }
                for item in group.items where (item.key as? String) == MovieWriter.stillImageTimeKey {
                    guard group.timeRange.start.isNumeric,
                          group.timeRange.duration.isNumeric, group.timeRange.duration.seconds > 0,
                          item.dataType == (kCMMetadataBaseDataType_SInt8 as String),
                          let number = try await item.load(.numberValue), number.intValue == -1 else {
                        throw ConversionError.invalidLivePhoto("The still-image marker is malformed.")
                    }
                    markerTimes.append(group.timeRange.start.seconds)
                }
            }
            if reader.status == .failed {
                throw ConversionError.invalidLivePhoto(reader.error?.localizedDescription ?? "The timing track is damaged.")
            }
        }
        guard markerTimes.count == 1, let markerTime = markerTimes.first,
              markerTime >= 0, markerTime < duration.seconds else {
            throw ConversionError.invalidLivePhoto("Expected one still-image marker inside the movie’s timeline.")
        }
        if let expectedKeyTime, abs(markerTime - expectedKeyTime) > 0.08 {
            throw ConversionError.invalidLivePhoto("The key-photo timing did not survive trimming correctly.")
        }
        try Task.checkCancellation()
    }

    private static func validateVideoFrame(asset: AVAsset, track: AVAssetTrack) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        guard reader.canAdd(output) else {
            throw ConversionError.invalidLivePhoto("The exported video codec is not readable.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ConversionError.invalidLivePhoto(reader.error?.localizedDescription ?? "The exported video could not be opened.")
        }
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(), CMSampleBufferGetImageBuffer(sample) != nil else {
            throw ConversionError.invalidLivePhoto(reader.error?.localizedDescription ?? "The exported video has no decodable frames.")
        }
    }
}
