import AppKit
import AVKit
import ImageIO
import LivePhotoEngine
import MotionPhotoCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct PhotoThumbnail: View {
    let url: URL
    let maxPixelSize: Int
    let fill: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.035)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .task(id: url) {
            image = nil
            let worker = Task.detached(priority: .utility) {
                ThumbnailDecoder.decode(url: url, maxPixelSize: maxPixelSize)
            }
            let data = await withTaskCancellationHandler(operation: {
                await worker.value
            }, onCancel: {
                worker.cancel()
            })
            guard !Task.isCancelled, let data else { return }
            image = NSImage(data: data)
        }
    }
}

private enum ThumbnailDecoder {
    static func decode(url: URL, maxPixelSize: Int) -> Data? {
        guard !Task.isCancelled else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary), !Task.isCancelled else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

@MainActor
struct ExportPreview: View {
    let target: PreviewTarget
    @Environment(\.dismiss) private var dismiss
    @State private var selection = 0
    @State private var player: AVPlayer?
    @State private var preparedMedia: PreviewMedia?
    @State private var previewError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.result.outputFormat.displayName)
                        .font(.headline)
                    Text(target.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Picker("Preview", selection: $selection) {
                Text("Photo").tag(0)
                Text("Motion").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .padding(.bottom, 16)

            ZStack {
                Color.black.opacity(0.94)
                if selection == 0 {
                    PhotoThumbnail(url: target.result.photoURL, maxPixelSize: 1600, fill: false)
                } else if player != nil {
                    VideoPlayer(player: player)
                } else if let previewError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                        Text("Motion preview unavailable")
                            .font(.headline)
                        Text(previewError)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(24)
                } else {
                    ProgressView("Preparing motion…")
                        .tint(.white)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .onChange(of: selection) { value in
                if value == 0 { player?.pause() }
            }

            HStack {
                Label(target.result.outputFormat.fileDescription, systemImage: target.result.videoURL == nil ? "photo" : "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([target.result.directoryURL])
                }
            }
            .padding(16)
        }
        .frame(width: 720, height: 580)
        .task(id: target.id) {
            let result = target.result
            let worker = Task.detached(priority: .userInitiated) {
                try PreviewMedia.prepare(result)
            }
            do {
                let media = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: {
                    worker.cancel()
                })
                guard !Task.isCancelled else { return }
                preparedMedia = media
                player = AVPlayer(url: media.videoURL)
            } catch {
                guard !Task.isCancelled else { return }
                previewError = error.localizedDescription
            }
        }
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            preparedMedia = nil
        }
    }
}

/// Holds a private temporary extraction only while its preview is alive. An
/// abandoned/cancelled preparation is cleaned up by deinit as well as by the
/// failure-path defer; original exports are never modified.
private final class PreviewMedia: @unchecked Sendable {
    let videoURL: URL
    private let temporaryDirectory: URL?

    private init(videoURL: URL, temporaryDirectory: URL? = nil) {
        self.videoURL = videoURL
        self.temporaryDirectory = temporaryDirectory
    }

    deinit {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    static func prepare(_ result: ConversionResult) throws -> PreviewMedia {
        try Task.checkCancellation()
        if let videoURL = result.videoURL { return PreviewMedia(videoURL: videoURL) }
        guard result.outputFormat != .appleLivePhoto else {
            throw ConversionError.invalidLivePhoto("The exported pair’s video is missing.")
        }
        let didStart = result.photoURL.startAccessingSecurityScopedResource()
        defer { if didStart { result.photoURL.stopAccessingSecurityScopedResource() } }
        let size = try result.photoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 1_073_741_824 else {
            throw ConversionError.invalidSource("The exported Motion Photo is empty or too large to preview.")
        }
        let data = try Data(contentsOf: result.photoURL, options: .mappedIfSafe)
        let payload = try MotionPhotoParser.parse(data: data)
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MotionPhotoBridge-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var prepared = false
        defer { if !prepared { try? FileManager.default.removeItem(at: directory) } }
        let videoURL = directory.appendingPathComponent("motion.mp4")
        try data.subdata(in: payload.videoRange).write(to: videoURL, options: .atomic)
        try Task.checkCancellation()
        let media = PreviewMedia(videoURL: videoURL, temporaryDirectory: directory)
        prepared = true
        return media
    }
}
