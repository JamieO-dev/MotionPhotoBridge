import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo

struct MovieWriteResult {
    let timing: ClipTiming
    let audioIncluded: Bool
    let warnings: [String]
}

enum MovieWriter {
    static let contentIdentifierKey = "com.apple.quicktime.content.identifier"
    static let stillImageTimeKey = "com.apple.quicktime.still-image-time"

    static func write(sourceURL: URL, outputURL: URL, identifier: String,
                      creationDate: Date?, timestampMicroseconds: Int64?,
                      options: ConversionOptions,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> MovieWriteResult {
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        // Android specifies that the primary video has the lowest track index.
        guard let track = videoTracks.first else {
            throw ConversionError.videoUnreadable("No video track was found.")
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominalRate = try await track.load(.nominalFrameRate)
        let sourceRange = try await track.load(.timeRange)
        let timing = try ClipTiming.make(sourceStart: sourceRange.start.seconds,
                                         sourceDuration: sourceRange.duration.seconds,
                                         timestampMicroseconds: timestampMicroseconds,
                                         framesPerSecond: Double(nominalRate),
                                         trim: options.trimToThreeSeconds)
        guard naturalSize.width.isFinite, naturalSize.height.isFinite,
              naturalSize.width >= 2, naturalSize.height >= 2,
              naturalSize.width <= 32_768, naturalSize.height <= 32_768 else {
            throw ConversionError.videoUnreadable("The video has invalid dimensions.")
        }
        guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy({ $0.isFinite }) else {
            throw ConversionError.videoUnreadable("The video has an invalid orientation transform.")
        }
        var warnings = timing.warnings
        if options.outputFormat == .appleLivePhoto && !options.trimToThreeSeconds && timing.duration > 3.1 {
            warnings.append("The full video is longer than a typical Live Photo. Some Apple playback or sharing features may shorten it.")
        }
        if videoTracks.count > 1 {
            warnings.append("The primary motion track was used. Auxiliary video tracks were not copied.")
        }
        if track.hasMediaCharacteristic(.containsHDRVideo) {
            warnings.append("The HDR motion video was converted to standard dynamic range (BT.709).")
        }
        let longest = max(naturalSize.width, naturalSize.height)
        let shortest = min(naturalSize.width, naturalSize.height)
        let scale = min(1, min(3840 / longest, 2160 / shortest))
        let width = max(2, Int(floor(naturalSize.width * scale / 2)) * 2)
        let height = max(2, Int(floor(naturalSize.height * scale / 2)) * 2)
        if CGFloat(width) != naturalSize.width || CGFloat(height) != naturalSize.height {
            warnings.append("The motion video was resized to \(width) × \(height) pixels for H.264 compatibility. The still image kept its original resolution.")
        }
        if nominalRate > 60 { warnings.append("The motion video was converted to 60 frames per second.") }
        let frameTime = CMTime(seconds: timing.frameDuration, preferredTimescale: 60_000)
        let clipStart = CMTime(seconds: timing.start, preferredTimescale: 60_000)
        let clipDuration = CMTime(seconds: timing.duration, preferredTimescale: 60_000)
        let clipRange = CMTimeRange(start: clipStart, duration: clipDuration)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = clipRange
        let isAppleOutput = options.outputFormat == .appleLivePhoto
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: isAppleOutput ? .mov : .mp4)
        writer.shouldOptimizeForNetworkUse = true
        // Android receives a real MPEG-4 container, not a renamed QuickTime MOV.
        // Apple pairing IDs and timing tracks belong only in Live Photo output.
        writer.metadata = isAppleOutput ? fileMetadata(identifier: identifier, creationDate: creationDate) : []

        // The built-in compositor performs HDR -> SDR colour conversion before
        // conversion to 8-bit pixels. Merely tagging an HDR frame as 709 is wrong.
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: width, height: height)
        composition.frameDuration = frameTime
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = sourceRange
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(CGAffineTransform(scaleX: CGFloat(width) / naturalSize.width,
                                            y: CGFloat(height) / naturalSize.height), at: sourceRange.start)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ConversionError.videoUnreadable("macOS does not support this video codec.")
        }
        reader.add(videoOutput)
        let frameRate = min(60, max(1, nominalRate.isFinite && nominalRate > 0 ? Double(nominalRate) : 30))
        let bitRate = max(2_000_000, min(40_000_000, Int(Double(width * height) * frameRate * 0.16)))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: max(1, Int(frameRate)),
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw ConversionError.encodingFailed("The H.264 encoder rejected the video settings.")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        // Preserve rotation/mirroring, then normalize the transformed bounds.
        // Even-dimension rounding can make x/y scales differ, so multiplying the
        // original translation by a coded-axis scale is not correct for 90° clips.
        let orientation = CGAffineTransform(a: transform.a, b: transform.b,
                                            c: transform.c, d: transform.d, tx: 0, ty: 0)
        let displayBounds = CGRect(x: 0, y: 0, width: width, height: height).applying(orientation)
        videoInput.transform = CGAffineTransform(a: orientation.a, b: orientation.b,
                                                c: orientation.c, d: orientation.d,
                                                tx: -displayBounds.minX, ty: -displayBounds.minY)
        guard writer.canAdd(videoInput) else { throw ConversionError.encodingFailed("Couldn’t create the video track.") }
        writer.add(videoInput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        if options.includeAudio, let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let audioRange = try await audioTrack.load(.timeRange)
            let intersection = CMTimeRangeGetIntersection(audioRange, otherRange: clipRange)
            if intersection.duration.isNumeric && intersection.duration.seconds > 0 {
                let formats = try await audioTrack.load(.formatDescriptions)
                let sourceChannels = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 2
                let channels = max(1, min(2, Int(sourceChannels)))
                let output = AVAssetReaderAudioMixOutput(audioTracks: [audioTrack], audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ])
                output.alwaysCopiesSampleData = false
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                input.expectsMediaDataInRealTime = false
                guard reader.canAdd(output), writer.canApply(outputSettings: settings, forMediaType: .audio), writer.canAdd(input) else {
                    throw ConversionError.encodingFailed("The audio track could not be converted. Retry with Keep audio turned off.")
                }
                reader.add(output)
                writer.add(input)
                audioOutput = output
                audioInput = input
            } else {
                warnings.append("The source audio does not overlap the selected clip, so this export is silent.")
            }
        }

        let metadata: (input: AVAssetWriterInput, adaptor: AVAssetWriterInputMetadataAdaptor)?
        if isAppleOutput {
            metadata = try makeStillImageMetadataInput()
        } else {
            metadata = nil
        }
        if let metadata {
            guard writer.canAdd(metadata.input) else {
                throw ConversionError.encodingFailed("Couldn’t create the Live Photo timing track.")
            }
            writer.add(metadata.input)
        }
        let marker = AVMutableMetadataItem()
        marker.keySpace = .quickTimeMetadata
        marker.key = stillImageTimeKey as NSString
        marker.value = NSNumber(value: Int8(-1))
        marker.dataType = kCMMetadataBaseDataType_SInt8 as String
        let markerStart = CMTime(seconds: timing.keyTime, preferredTimescale: 60_000)
        let markerLength = CMTime(seconds: min(timing.frameDuration, timing.end - timing.keyTime), preferredTimescale: 60_000)
        let markerGroup = AVTimedMetadataGroup(items: [marker], timeRange: CMTimeRange(start: markerStart, duration: markerLength))

        try Task.checkCancellation()
        guard writer.startWriting() else { throw ConversionError.encodingFailed(writer.error?.localizedDescription ?? "The writer did not start.") }
        writer.startSession(atSourceTime: clipStart)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw ConversionError.videoUnreadable(reader.error?.localizedDescription ?? "The reader did not start.")
        }
        var audioSamplesWritten = 0
        do {
            try await withTaskCancellationHandler {
                var videoDone = false
                var audioDone = audioInput == nil
                var metadataDone = metadata == nil
                var videoSamples = 0
                var lastActivity = Date.timeIntervalSinceReferenceDate
                var lastProgress = lastActivity
                // Service every track fairly. Waiting for only one input can
                // deadlock when AVAssetWriter applies inter-track back pressure.
                while !videoDone || !audioDone || !metadataDone {
                    try Task.checkCancellation()
                    if reader.status == .failed {
                        throw ConversionError.videoUnreadable(reader.error?.localizedDescription ?? "A sample could not be decoded.")
                    }
                    if writer.status == .failed || writer.status == .cancelled {
                        throw ConversionError.encodingFailed(writer.error?.localizedDescription ?? "The writer stopped unexpectedly.")
                    }
                    var advanced = false
                    if !metadataDone, let metadata, metadata.input.isReadyForMoreMediaData {
                        guard metadata.adaptor.append(markerGroup) else {
                            throw ConversionError.encodingFailed(writer.error?.localizedDescription ?? "Couldn’t write Live Photo timing.")
                        }
                        metadata.input.markAsFinished()
                        metadataDone = true
                        advanced = true
                    }
                    if !videoDone, videoInput.isReadyForMoreMediaData {
                        try autoreleasepool {
                            if let sample = videoOutput.copyNextSampleBuffer() {
                                guard videoInput.append(sample) else {
                                    throw ConversionError.encodingFailed(writer.error?.localizedDescription ?? "A video frame could not be written.")
                                }
                                videoSamples += 1
                                let now = Date.timeIntervalSinceReferenceDate
                                if now - lastProgress >= 0.1 {
                                    progress(min(0.99, max(0, (CMSampleBufferGetPresentationTimeStamp(sample).seconds - timing.start) / timing.duration)))
                                    lastProgress = now
                                }
                            } else {
                                videoInput.markAsFinished()
                                videoDone = true
                            }
                        }
                        advanced = true
                    }
                    if !audioDone, let input = audioInput, let output = audioOutput,
                       input.isReadyForMoreMediaData {
                        try autoreleasepool {
                            if let sample = output.copyNextSampleBuffer() {
                                guard input.append(sample) else {
                                    throw ConversionError.encodingFailed(writer.error?.localizedDescription ?? "An audio sample could not be written. Retry without audio.")
                                }
                                audioSamplesWritten += 1
                            } else {
                                input.markAsFinished()
                                audioDone = true
                            }
                        }
                        advanced = true
                    }
                    if advanced {
                        lastActivity = Date.timeIntervalSinceReferenceDate
                    } else {
                        guard Date.timeIntervalSinceReferenceDate - lastActivity < 60 else {
                            throw ConversionError.encodingFailed("The media encoder stopped responding.")
                        }
                        try await Task.sleep(nanoseconds: 2_000_000)
                    }
                }
                try Task.checkCancellation()
                guard videoSamples > 0 else { throw ConversionError.videoUnreadable("No decodable frames were found in the selected clip.") }
                guard reader.status != .failed else {
                    throw ConversionError.videoUnreadable(reader.error?.localizedDescription ?? "Reading failed.")
                }
                writer.endSession(atSourceTime: CMTimeRangeGetEnd(clipRange))
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    writer.finishWriting { continuation.resume() }
                }
                try Task.checkCancellation()
                guard writer.status == .completed else {
                    throw ConversionError.encodingFailed(writer.error?.localizedDescription ?? "The movie could not be finalized.")
                }
            } onCancel: {
                reader.cancelReading()
                writer.cancelWriting()
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        progress(1)
        if audioInput != nil && audioSamplesWritten == 0 {
            warnings.append("The selected interval contained no audio samples, so this export is silent.")
        }
        return MovieWriteResult(timing: timing, audioIncluded: audioSamplesWritten > 0, warnings: warnings)
    }

    private static func fileMetadata(identifier: String, creationDate: Date?) -> [AVMetadataItem] {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = contentIdentifierKey as NSString
        item.value = identifier as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        var result: [AVMetadataItem] = [item]
        if let creationDate {
            let date = AVMutableMetadataItem()
            date.keySpace = .quickTimeMetadata
            date.key = "com.apple.quicktime.creationdate" as NSString
            date.value = ISO8601DateFormatter().string(from: creationDate) as NSString
            date.dataType = kCMMetadataBaseDataType_UTF8 as String
            result.append(date)
        }
        return result
    }

    private static func makeStillImageMetadataInput() throws -> (input: AVAssetWriterInput, adaptor: AVAssetWriterInputMetadataAdaptor) {
        let specifications: [[String: Any]] = [[
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/\(stillImageTimeKey)",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String
        ]]
        var description: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: specifications as CFArray, formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw ConversionError.encodingFailed("Couldn’t describe the Live Photo timing track (\(status)).")
        }
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        input.expectsMediaDataInRealTime = false
        return (input, AVAssetWriterInputMetadataAdaptor(assetWriterInput: input))
    }
}
