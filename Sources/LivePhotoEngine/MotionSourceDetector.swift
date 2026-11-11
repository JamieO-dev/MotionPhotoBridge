import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import MotionPhotoCore

/// Identifies embedded Android Motion Photos and the two resources of an Apple
/// Live Photo. Filenames locate candidates; only matching embedded identifiers
/// establish an Apple pair. Detection never requests access to the Photos app.
public enum MotionSourceDetector {
    public static func detect(urls: [URL]) async -> [SourceDetectionResult] {
        let task = Task.detached(priority: .userInitiated) {
            let session = DetectionSession(inputs: uniqueURLs(urls))
            defer { session.close() }
            return await session.batch()
        }
        return await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    public static func detect(sourceURL: URL, candidateURLs: [URL] = []) async throws -> MotionPhotoSource {
        let input = sourceURL.standardizedFileURL
        let task = Task.detached(priority: .userInitiated) {
            let session = DetectionSession(inputs: uniqueURLs([sourceURL] + candidateURLs))
            defer { session.close() }
            try await session.prepare()
            return try await session.resolve(input)
        }
        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }
}

private enum ResourceIdentity: Hashable { case file(device: UInt64, inode: UInt64); case path(URL) }

private func resourceIdentity(_ url: URL) -> ResourceIdentity {
    if url.isFileURL,
       let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
       let device = attributes[.systemNumber] as? NSNumber,
       let inode = attributes[.systemFileNumber] as? NSNumber {
        return .file(device: device.uint64Value, inode: inode.uint64Value)
    }
    return .path(url)
}

private func uniqueURLs(_ urls: [URL]) -> [URL] {
    // On the usual case-insensitive Mac volume, photo.MOV and photo.mov can
    // address one file. Hard links likewise must not become ambiguous partners.
    var seen: Set<ResourceIdentity> = []
    return urls.map(\.standardizedFileURL).filter { seen.insert(resourceIdentity($0)).inserted }
}

/// A session is confined to one detached task. Each file's metadata is loaded
/// at most once, and each sibling directory is enumerated at most once.
private final class DetectionSession {
    private enum Kind: Equatable { case image, movie, unsupported }
    private struct ImageRecord {
        let embedded: MotionPhotoSource?
        let identifier: String?
        let parserError: Error
    }
    private struct MovieRecord {
        let identifier: String
        let asset: AVURLAsset
    }
    private struct MovieTiming {
        let timestamp: Int64?
        let warnings: [String]
    }
    private struct Siblings {
        var images: [URL] = []
        var movies: [URL] = []
        var truncated = false
        var readError: String?
    }
    private struct Candidates {
        let urls: [URL]
        let truncated: Bool
        let readError: String?
    }

    private static let maximumFileSize = 1_073_741_824
    private static let maximumDirectoryEntries = 2_048
    private static let maximumSiblingResources = 512
    private static let contentIdentifierKey = "com.apple.quicktime.content.identifier"
    private static let stillImageTimeKey = "com.apple.quicktime.still-image-time"
    private let inputs: [URL]
    private var imageCache: [URL: Result<ImageRecord, Error>] = [:]
    private var movieCache: [URL: Result<MovieRecord, Error>] = [:]
    private var timingCache: [URL: Result<MovieTiming, Error>] = [:]
    private var siblingCache: [URL: Siblings] = [:]
    private var selectedImagesByID: [String: [URL]] = [:]
    private var selectedMoviesByID: [String: [URL]] = [:]
    private var securityScopes: [URL: Bool] = [:]
    private var identityCache: [URL: ResourceIdentity] = [:]

    init(inputs: [URL]) { self.inputs = inputs }

    func close() {
        for (url, acquired) in securityScopes where acquired { url.stopAccessingSecurityScopedResource() }
        securityScopes.removeAll()
    }

    func prepare() async throws {
        // Index the whole selection first so renamed pairs work across folders
        // and results do not depend on which half was dropped first.
        for url in inputs {
            try Task.checkCancellation()
            switch kind(url) {
            case .image:
                if let image = try? readImage(url), image.embedded == nil, let identifier = image.identifier {
                    selectedImagesByID[identifier, default: []].append(url)
                }
            case .movie:
                if let movie = try? await readMovie(url) {
                    selectedMoviesByID[movie.identifier, default: []].append(url)
                }
            case .unsupported: break
            }
        }
        try Task.checkCancellation()
    }

    func batch() async -> [SourceDetectionResult] {
        do { try await prepare() } catch { /* resolve reports cancellation for every remaining input */ }
        var consumed: Set<URL> = []
        var results: [SourceDetectionResult] = []
        for input in inputs where !consumed.contains(input) {
            do {
                let source = try await resolve(input)
                consumed.formUnion(source.resourceURLs.map(\.standardizedFileURL))
                results.append(SourceDetectionResult(inputURL: input, source: source, errorMessage: nil))
            } catch {
                let message = error is CancellationError
                    ? "Format detection was cancelled. Add the file again to retry."
                    : error.localizedDescription
                results.append(SourceDetectionResult(inputURL: input, source: nil, errorMessage: message))
            }
        }
        return results
    }

    func resolve(_ url: URL) async throws -> MotionPhotoSource {
        try Task.checkCancellation()
        switch kind(url) {
        case .image:
            let image = try readImage(url)
            if let embedded = image.embedded { return embedded }
            guard image.identifier != nil else { throw image.parserError }
            return try await resolveAppleImage(url, image: image)
        case .movie:
            let movie = try await readMovie(url)
            var images = selectedImagesByID[movie.identifier] ?? []
            var discovery: Candidates?
            if images.isEmpty {
                let siblings = candidates(near: url, kind: .image)
                discovery = siblings
                for candidate in siblings.urls {
                    try Task.checkCancellation()
                    if let image = try? readImage(candidate), image.embedded == nil,
                       image.identifier == movie.identifier { images.append(candidate) }
                }
            }
            try Task.checkCancellation()
            guard images.count <= 1 else {
                throw invalid("More than one image has this Live Photo identifier. Select only the intended image and its MOV together.")
            }
            guard let imageURL = images.first else {
                throw missingPartner(for: url, expected: .image, candidates: discovery)
            }
            let image = try readImage(imageURL)
            let source = try await resolveAppleImage(imageURL, image: image)
            guard source.pairedVideoURL == url else {
                throw invalid("More than one video could belong to this Live Photo. Select only its original image and MOV together.")
            }
            return addingDiscoveryWarning(to: source, discovery: discovery)
        case .unsupported:
            throw invalid("Choose an original JPEG, HEIC, HEIF, or AVIF Motion Photo, or an Apple Live Photo image and MOV pair.")
        }
    }

    private func resolveAppleImage(_ url: URL, image: ImageRecord) async throws -> MotionPhotoSource {
        guard let identifier = image.identifier else { throw image.parserError }
        guard (selectedImagesByID[identifier]?.count ?? 0) <= 1 else {
            throw invalid("More than one selected image has this Live Photo identifier. Select only one image and its matching MOV.")
        }
        var movies = selectedMoviesByID[identifier] ?? []
        var discovery: Candidates?
        if movies.isEmpty {
            let siblings = candidates(near: url, kind: .movie)
            discovery = siblings
            for candidate in siblings.urls {
                try Task.checkCancellation()
                if let movie = try? await readMovie(candidate), movie.identifier == identifier { movies.append(candidate) }
            }
        }
        try Task.checkCancellation()
        guard movies.count <= 1 else {
            throw invalid("More than one video has this Live Photo identifier. Select only the intended image and MOV together.")
        }
        guard let movieURL = movies.first else {
            throw missingPartner(for: url, expected: .movie, candidates: discovery)
        }
        let timing = try await readTiming(movieURL)
        try Task.checkCancellation()
        let source = MotionPhotoSource(imageURL: url, pairedVideoURL: movieURL,
                                       format: .appleLivePhoto,
                                       presentationTimeMicroseconds: timing.timestamp,
                                       warnings: timing.warnings)
        return addingDiscoveryWarning(to: source, discovery: discovery)
    }

    private func addingDiscoveryWarning(to source: MotionPhotoSource, discovery: Candidates?) -> MotionPhotoSource {
        guard discovery?.truncated == true else { return source }
        let warning = "Sibling discovery reached its folder limit. The selected image and video identifiers match; add both halves explicitly when working with large folders."
        return MotionPhotoSource(imageURL: source.imageURL, pairedVideoURL: source.pairedVideoURL,
                                 format: source.format, presentationTimeMicroseconds: source.presentationTimeMicroseconds,
                                 warnings: source.warnings.contains(warning) ? source.warnings : source.warnings + [warning])
    }

    private func missingPartner(for url: URL, expected: Kind, candidates: Candidates?) -> Error {
        let selectedCandidates = inputs.filter { kind($0) == expected }
        let sameName = ((candidates?.urls ?? []) + selectedCandidates).filter {
            $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(url.deletingPathExtension().lastPathComponent) == .orderedSame
        }
        for candidate in sameName {
            switch expected {
            case .movie:
                if case .success? = movieCache[candidate] {
                    return invalid("The image and similarly named video have different Live Photo identifiers. Add the matching original files; renaming files does not link them.")
                }
                if case .failure(let error)? = movieCache[candidate] {
                    return invalid("The similarly named video could not be used: \(error.localizedDescription)")
                }
            case .image:
                if case .success(let image)? = imageCache[candidate] {
                    return invalid(image.identifier != nil
                        ? "The video and similarly named image have different Live Photo identifiers. Add both matching originals exported from Photos."
                        : "The similarly named image has no Apple Live Photo pairing identifier. Use both unmodified originals exported from Photos.")
                }
                if case .failure(let error)? = imageCache[candidate] {
                    return invalid("The similarly named image could not be read: \(error.localizedDescription)")
                }
            case .unsupported: break
            }
        }
        if candidates?.truncated == true {
            return invalid("No matching Live Photo partner was found within this folder’s scan limit. Add both the original image and MOV explicitly.")
        }
        if let readError = candidates?.readError {
            return invalid("The partner folder could not be read. Add both the original image and MOV explicitly. \(readError)")
        }
        return invalid(expected == .movie
            ? "This is an Apple Live Photo image, but its matching MOV is missing. Add the original MOV too, or keep both originals in the same folder."
            : "This is an Apple Live Photo video, but its matching image is missing. Add its original JPEG or HEIC too, or keep both originals in the same folder.")
    }

    private func readImage(_ url: URL) throws -> ImageRecord {
        if let cached = imageCache[url] { return try cached.get() }
        do {
            try checkFile(url)
            let record = try autoreleasepool { () throws -> ImageRecord in
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let parserError: Error
                do {
                    let payload = try MotionPhotoParser.parse(data: data)
                    try Task.checkCancellation()
                    let source = MotionPhotoSource(imageURL: url, format: sourceFormat(payload.format),
                                                   presentationTimeMicroseconds: payload.presentationTimeMicroseconds,
                                                   warnings: payload.warnings)
                    return ImageRecord(embedded: source, identifier: nil, parserError: MotionPhotoError.noEmbeddedVideo)
                } catch { parserError = error }
                try Task.checkCancellation()
                let options: [String: Any] = [kCGImageSourceShouldCache as String: false]
                guard let image = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
                      CGImageSourceGetCount(image) > 0,
                      let properties = CGImageSourceCopyPropertiesAtIndex(image, CGImageSourceGetPrimaryImageIndex(image), nil) as? [String: Any],
                      ((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0) > 0,
                      ((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0) > 0 else {
                    throw ConversionError.imageUnreadable
                }
                let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
                let identifier = validIdentifier(maker?["17"] as? String)
                return ImageRecord(embedded: nil, identifier: identifier, parserError: parserError)
            }
            imageCache[url] = .success(record)
            return record
        } catch {
            imageCache[url] = .failure(error)
            throw error
        }
    }

    private func readMovie(_ url: URL) async throws -> MovieRecord {
        if let cached = movieCache[url] { return try cached.get() }
        do {
            try checkFile(url)
            let asset = AVURLAsset(url: url)
            let metadata = try await asset.load(.metadata)
            var identifiers: Set<String> = []
            for item in metadata where matches(item, key: Self.contentIdentifierKey) {
                if let identifier = validIdentifier(try await item.load(.stringValue)) { identifiers.insert(identifier) }
            }
            try Task.checkCancellation()
            guard identifiers.count == 1, let identifier = identifiers.first else {
                throw invalid(identifiers.isEmpty
                    ? "The video has no Apple Live Photo pairing identifier. Use both original files exported from Photos."
                    : "The video has conflicting Live Photo identifiers and cannot be paired reliably.")
            }
            let result = MovieRecord(identifier: identifier, asset: asset)
            movieCache[url] = .success(result)
            return result
        } catch {
            movieCache[url] = .failure(error)
            throw error
        }
    }

    private func readTiming(_ url: URL) async throws -> MovieTiming {
        if let cached = timingCache[url] { return try cached.get() }
        do {
            let movie = try await readMovie(url)
            let duration = try await movie.asset.load(.duration)
            let videos = try await movie.asset.loadTracks(withMediaType: .video)
            guard !videos.isEmpty, duration.isNumeric, duration.seconds > 0, duration.seconds <= 120 else {
                throw invalid("The matching Live Photo movie has no video track or its duration is outside the supported two-minute limit.")
            }
            let tracks = try await movie.asset.loadTracks(withMediaType: .metadata)
            guard tracks.count <= 32 else { throw invalid("The Live Photo movie has too many metadata tracks.") }
            var timestamps: Set<Int64> = []
            var groupCount = 0
            for track in tracks {
                try Task.checkCancellation()
                let reader = try AVAssetReader(asset: movie.asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                guard reader.canAdd(output) else { throw invalid("The Live Photo timing track cannot be read.") }
                reader.add(output)
                let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
                guard reader.startReading() else {
                    throw invalid("The Live Photo timing track cannot be opened. \(reader.error?.localizedDescription ?? "")")
                }
                defer { reader.cancelReading() }
                while let group = autoreleasepool(invoking: { adaptor.nextTimedMetadataGroup() }) {
                    try Task.checkCancellation()
                    groupCount += 1
                    guard groupCount <= 10_000 else { throw invalid("The Live Photo has too many timing samples.") }
                    for item in group.items where matches(item, key: Self.stillImageTimeKey) {
                        let time = group.timeRange.start.seconds
                        guard let value = try await item.load(.numberValue),
                              value.doubleValue == 0 || value.doubleValue == -1,
                              group.timeRange.start.isNumeric, time.isFinite,
                              time >= 0, time < duration.seconds,
                              let microseconds = Int64(exactly: (time * 1_000_000).rounded()) else {
                            throw invalid("The Live Photo still-image timing metadata is malformed.")
                        }
                        timestamps.insert(microseconds)
                    }
                }
                if reader.status == .failed {
                    throw invalid("The Live Photo timing track is damaged. \(reader.error?.localizedDescription ?? "")")
                }
            }
            try Task.checkCancellation()
            guard timestamps.count <= 1 else {
                throw invalid("The Live Photo contains conflicting still-image times and cannot be converted reliably.")
            }
            let result = MovieTiming(timestamp: timestamps.first, warnings: timestamps.isEmpty
                ? ["The Live Photo has no still-image timestamp. The middle frame will be used for motion timing; the original still photo is retained."] : [])
            timingCache[url] = .success(result)
            return result
        } catch {
            timingCache[url] = .failure(error)
            throw error
        }
    }

    private func candidates(near url: URL, kind expected: Kind) -> Candidates {
        let folder = url.deletingLastPathComponent()
        let siblings = readSiblings(folder)
        let extensions = expected == .movie ? ["mov", "MOV", "mp4", "MP4"] : ["jpg", "JPG", "jpeg", "JPEG", "heic", "HEIC", "heif", "HEIF", "avif", "AVIF"]
        let stem = url.deletingPathExtension().lastPathComponent
        // Check exact sibling names even when a very large directory hits its
        // enumeration limit. These candidates still require an identifier match.
        let named = extensions.map { folder.appendingPathComponent(stem + "." + $0) }.filter {
            guard let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
        let enumerated = expected == .movie ? siblings.movies : siblings.images
        var seen: Set<ResourceIdentity> = []
        let urls = (named + enumerated).map(\.standardizedFileURL).filter { candidate in
            let identity = identityCache[candidate] ?? resourceIdentity(candidate)
            identityCache[candidate] = identity
            return seen.insert(identity).inserted
        }
        return Candidates(urls: urls, truncated: siblings.truncated, readError: siblings.readError)
    }

    private func readSiblings(_ folder: URL) -> Siblings {
        if let cached = siblingCache[folder] { return cached }
        retainAccess(folder)
        var result = Siblings()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        var enumerationError: String?
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants],
            errorHandler: { _, error in enumerationError = error.localizedDescription; return false })
        if let enumerator {
            var entries = 0
            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled { break }
                entries += 1
                if entries > Self.maximumDirectoryEntries || result.images.count + result.movies.count >= Self.maximumSiblingResources {
                    result.truncated = true
                    break
                }
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                switch kind(url) {
                case .image: result.images.append(url.standardizedFileURL)
                case .movie: result.movies.append(url.standardizedFileURL)
                case .unsupported: break
                }
            }
        } else {
            enumerationError = "The folder is unavailable or permission was not granted."
        }
        result.readError = enumerationError
        result.images.sort { $0.path < $1.path }
        result.movies.sort { $0.path < $1.path }
        siblingCache[folder] = result
        return result
    }

    private func checkFile(_ url: URL) throws {
        try Task.checkCancellation()
        guard url.isFileURL else { throw invalid("Choose local photo files from Finder.") }
        retainAccess(url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw invalid("Choose a regular image or video file.") }
        guard let size = values.fileSize, size > 0, size <= Self.maximumFileSize else {
            throw invalid("The file is empty or larger than the 1 GB limit.")
        }
    }

    private func retainAccess(_ url: URL) {
        if securityScopes[url] == nil { securityScopes[url] = url.startAccessingSecurityScopedResource() }
    }

    private func kind(_ url: URL) -> Kind {
        guard url.isFileURL else { return .unsupported }
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "heic", "heif", "avif": return .image
        case "mov", "mp4": return .movie
        default: return .unsupported
        }
    }

    private func validIdentifier(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 1_024,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func matches(_ item: AVMetadataItem, key: String) -> Bool {
        (item.keySpace == .quickTimeMetadata && (item.key as? String) == key)
            || item.identifier?.rawValue == "mdta/" + key
    }

    private func invalid(_ message: String) -> ConversionError { .invalidSource(message) }

    private func sourceFormat(_ format: MotionPhotoFormat) -> MotionPhotoSourceFormat {
        switch format {
        case .googleMotionPhoto: return .googleMotionPhoto
        case .googleMicroVideo: return .googleMicroVideo
        case .samsungMotionPhoto: return .samsungMotionPhoto
        case .heifMotionPhoto: return .heifMotionPhoto
        case .recoveredMotionPhoto: return .recoveredMotionPhoto
        }
    }
}
